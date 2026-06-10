-- =============================================================================
-- International call-ups via GPDB — any GPSL player matching nation, 23 cap, 2 GKs
-- Run after competition_international.sql (safe re-run)
-- =============================================================================

ALTER TABLE public.international_squad_callups
  ALTER COLUMN club_short_name DROP NOT NULL;

-- ON CONFLICT cannot use deferrable unique constraints (original schema used DEFERRABLE)
ALTER TABLE public.international_squad_callups
  DROP CONSTRAINT IF EXISTS international_squad_callups_unique;

ALTER TABLE public.international_squad_callups
  ADD CONSTRAINT international_squad_callups_unique UNIQUE (nation_code, player_id);

CREATE OR REPLACE FUNCTION public.international_normalize_nation_label(p_text text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT upper(
    regexp_replace(
      regexp_replace(coalesce(btrim(p_text), ''), '\s+', '', 'g'),
      '[^A-Za-z]',
      '',
      'g'
    )
  );
$$;

CREATE OR REPLACE FUNCTION public.international_player_matches_nation(
  p_player_id text,
  p_nation_code text
)
RETURNS boolean
LANGUAGE sql
STABLE
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public."Players" p
    JOIN public.international_nations n ON n.code = upper(btrim(p_nation_code))
    WHERE p."Konami_ID"::text = btrim(p_player_id)
      AND (
        public.international_normalize_nation_label(p."Nation")
          = public.international_normalize_nation_label(n.name)
        OR public.international_normalize_nation_label(p."Nation")
          = upper(n.code)
      )
  );
$$;

CREATE OR REPLACE FUNCTION public.international_nation_active_squad_count(p_nation_code text)
RETURNS integer
LANGUAGE sql
STABLE
SET search_path = public
AS $$
  SELECT count(*)::integer
  FROM public.international_squad_callups sc
  WHERE sc.nation_code = upper(btrim(p_nation_code))
    AND sc.is_active = true;
$$;

CREATE OR REPLACE FUNCTION public.international_nation_active_gk_count(p_nation_code text)
RETURNS integer
LANGUAGE sql
STABLE
SET search_path = public
AS $$
  SELECT count(*)::integer
  FROM public.international_squad_callups sc
  JOIN public."Players" p ON p."Konami_ID"::text = sc.player_id
  WHERE sc.nation_code = upper(btrim(p_nation_code))
    AND sc.is_active = true
    AND upper(btrim(coalesce(p."Position", ''))) = 'GK';
$$;

CREATE OR REPLACE FUNCTION public.international_call_up_player(p_player_id text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_nation text := public.international_my_nation_code();
  v_cycle_id bigint;
  v_player_club text;
  v_squad_count integer;
BEGIN
  IF v_nation IS NULL THEN
    RAISE EXCEPTION 'You have not been assigned a national team';
  END IF;

  IF NOT public.international_player_matches_nation(p_player_id, v_nation) THEN
    RAISE EXCEPTION 'Player nationality does not match your national team';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public."Players" p
    WHERE p."Konami_ID"::text = btrim(p_player_id)
  ) THEN
    RAISE EXCEPTION 'Player not found';
  END IF;

  SELECT nullif(btrim(p."Contracted_Team"), '')
  INTO v_player_club
  FROM public."Players" p
  WHERE p."Konami_ID"::text = btrim(p_player_id);

  v_squad_count := public.international_nation_active_squad_count(v_nation);

  IF NOT EXISTS (
    SELECT 1
    FROM public.international_squad_callups sc
    WHERE sc.nation_code = v_nation
      AND sc.player_id = btrim(p_player_id)
      AND sc.is_active = true
  ) AND v_squad_count >= 23 THEN
    RAISE EXCEPTION 'National squad is full (23 players)';
  END IF;

  SELECT id INTO v_cycle_id
  FROM public.international_wc_cycles
  ORDER BY cycle_no DESC
  LIMIT 1;

  UPDATE public.international_squad_callups
  SET is_active = false,
      released_at = now()
  WHERE player_id = btrim(p_player_id)
    AND nation_code <> v_nation
    AND is_active = true;

  IF EXISTS (
    SELECT 1
    FROM public.international_squad_callups sc
    WHERE sc.nation_code = v_nation
      AND sc.player_id = btrim(p_player_id)
  ) THEN
    UPDATE public.international_squad_callups
    SET is_active = true,
        released_at = NULL,
        called_at = now(),
        club_short_name = v_player_club,
        cycle_id = v_cycle_id
    WHERE nation_code = v_nation
      AND player_id = btrim(p_player_id);
  ELSE
    INSERT INTO public.international_squad_callups (
      nation_code,
      player_id,
      club_short_name,
      cycle_id,
      is_active
    )
    VALUES (
      v_nation,
      btrim(p_player_id),
      v_player_club,
      v_cycle_id,
      true
    );
  END IF;
END;
$function$;

CREATE OR REPLACE FUNCTION public.international_release_callup(p_player_id text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_nation text := public.international_my_nation_code();
  v_is_gk boolean;
  v_gk_count integer;
BEGIN
  IF v_nation IS NULL THEN
    RAISE EXCEPTION 'You have not been assigned a national team';
  END IF;

  SELECT upper(btrim(coalesce(p."Position", ''))) = 'GK'
  INTO v_is_gk
  FROM public."Players" p
  WHERE p."Konami_ID"::text = btrim(p_player_id);

  IF coalesce(v_is_gk, false) THEN
    v_gk_count := public.international_nation_active_gk_count(v_nation);
    IF v_gk_count <= 2 THEN
      RAISE EXCEPTION 'National squad must keep at least 2 goalkeepers';
    END IF;
  END IF;

  UPDATE public.international_squad_callups
  SET is_active = false,
      released_at = now()
  WHERE nation_code = v_nation
    AND player_id = btrim(p_player_id)
    AND is_active = true;
END;
$function$;

DROP VIEW IF EXISTS public.international_squad_public;
CREATE VIEW public.international_squad_public
WITH (security_invoker = false)
AS
SELECT
  sc.nation_code,
  n.name AS nation_name,
  n.flag_emoji,
  sc.player_id,
  p."Name" AS player_name,
  p."Position" AS player_position,
  p."Age" AS player_age,
  p."Rating" AS player_rating,
  p."Nation" AS player_nation,
  sc.club_short_name,
  sc.called_at,
  coalesce(ipc.caps, 0) AS intl_caps,
  coalesce(ipc.goals, 0) AS intl_goals,
  coalesce(ipc.assists, 0) AS intl_assists,
  coalesce(ipc.potm, 0) AS intl_potm,
  CASE
    WHEN coalesce(ipc.rating_count, 0) > 0
      THEN round(ipc.rating_sum / ipc.rating_count, 2)
    ELSE NULL
  END AS intl_avg_rating
FROM public.international_squad_callups sc
JOIN public.international_nations n ON n.code = sc.nation_code
LEFT JOIN public."Players" p ON p."Konami_ID"::text = sc.player_id
LEFT JOIN public.international_player_career ipc ON ipc.player_id = sc.player_id
WHERE sc.is_active = true;

GRANT SELECT ON public.international_squad_public TO authenticated;
GRANT EXECUTE ON FUNCTION public.international_call_up_player(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.international_release_callup(text) TO authenticated;

NOTIFY pgrst, 'reload schema';
