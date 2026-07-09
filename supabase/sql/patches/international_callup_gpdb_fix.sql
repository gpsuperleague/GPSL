-- =============================================================================
-- Fix: "Player not in your club squad" on GPDB Call up
--
-- Live DB still has the v1 international_call_up_player from
-- competition_international.sql (club-squad only). Replace with GPDB rules:
--   - You manage a national team
--   - Player GPDB Nation matches that team
--   - Squad max 23, min 2 GKs on release
--   - Player can be at any club (or free / foreign)
--
-- Run once in Supabase SQL Editor, then retry Call up on GPDB.
-- Safe re-run. Prefer this over re-running the full international_callup_gpdb.sql
-- if you only need the call-up fix.
-- =============================================================================

ALTER TABLE public.international_squad_callups
  ALTER COLUMN club_short_name DROP NOT NULL;

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

-- Prefer label-map resolve when pool patch is deployed; fall back to name/code match
CREATE OR REPLACE FUNCTION public.international_player_matches_nation(
  p_player_id text,
  p_nation_code text
)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SET search_path = public
AS $function$
DECLARE
  v_code text := upper(btrim(p_nation_code));
  v_label text;
  v_resolved text;
BEGIN
  IF v_code IS NULL OR v_code = '' THEN
    RETURN false;
  END IF;

  SELECT p."Nation" INTO v_label
  FROM public."Players" p
  WHERE p."Konami_ID"::text = btrim(p_player_id);

  IF v_label IS NULL THEN
    RETURN false;
  END IF;

  IF to_regprocedure('public.international_resolve_gpdb_nation_code(text)') IS NOT NULL THEN
    v_resolved := public.international_resolve_gpdb_nation_code(v_label);
    IF v_resolved IS NOT NULL AND v_resolved = v_code THEN
      RETURN true;
    END IF;
  END IF;

  RETURN EXISTS (
    SELECT 1
    FROM public.international_nations n
    WHERE n.code = v_code
      AND (
        public.international_normalize_nation_label(v_label)
          = public.international_normalize_nation_label(n.name)
        OR public.international_normalize_nation_label(v_label) = upper(n.code)
        OR (
          to_regprocedure('public.international_catalog_match_code(text)') IS NOT NULL
          AND public.international_catalog_match_code(v_label) = n.code
        )
      )
  );
END;
$function$;

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

  IF NOT EXISTS (
    SELECT 1 FROM public."Players" p
    WHERE p."Konami_ID"::text = btrim(p_player_id)
  ) THEN
    RAISE EXCEPTION 'Player not found';
  END IF;

  IF NOT public.international_player_matches_nation(p_player_id, v_nation) THEN
    RAISE EXCEPTION 'Player nationality does not match your national team';
  END IF;

  -- Only store club_short_name when it is a real GPSL club (FK-safe)
  SELECT c."ShortName"
  INTO v_player_club
  FROM public."Players" p
  JOIN public."Clubs" c
    ON c."ShortName" = nullif(btrim(p."Contracted_Team"), '')
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

  -- Release from any other nation
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

GRANT EXECUTE ON FUNCTION public.international_normalize_nation_label(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.international_player_matches_nation(text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.international_nation_active_squad_count(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.international_nation_active_gk_count(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.international_call_up_player(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.international_release_callup(text) TO authenticated;

NOTIFY pgrst, 'reload schema';
