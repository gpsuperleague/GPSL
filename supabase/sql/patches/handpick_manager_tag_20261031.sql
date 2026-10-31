-- Mid-season handpick: one temp-tagged manager per club (MGDB ☐ / handpick page).
-- Safe re-run. Apply after handpick_basket_* patches.

CREATE TABLE IF NOT EXISTS public.club_handpick_manager (
  club_short_name text PRIMARY KEY,
  manager_id bigint NOT NULL REFERENCES public."Managers"(id) ON DELETE CASCADE,
  added_by uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  added_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS club_handpick_manager_mgr_idx
  ON public.club_handpick_manager (manager_id);

ALTER TABLE public.club_handpick_manager ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS club_handpick_manager_admin_all ON public.club_handpick_manager;
CREATE POLICY club_handpick_manager_admin_all
  ON public.club_handpick_manager
  FOR ALL
  TO authenticated
  USING (public.is_gpsl_admin())
  WITH CHECK (public.is_gpsl_admin());

DROP POLICY IF EXISTS club_handpick_manager_owner_select ON public.club_handpick_manager;
CREATE POLICY club_handpick_manager_owner_select
  ON public.club_handpick_manager
  FOR SELECT
  TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public."Clubs" c
      WHERE c."ShortName" = club_handpick_manager.club_short_name
        AND c.owner_id = auth.uid()
    )
  );

COMMENT ON TABLE public.club_handpick_manager IS
  'Soft handpick wishlist manager (one per club). Not contracted until admin approves.';

-- Clear manager tag when handpick intake turns off (extend basket trigger)
CREATE OR REPLACE FUNCTION public.trg_clubs_handpick_basket_clear()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF TG_OP = 'UPDATE'
     AND coalesce(OLD.handpick_intake, false)
     AND NOT coalesce(NEW.handpick_intake, false) THEN
    DELETE FROM public.club_handpick_basket
    WHERE club_short_name = upper(btrim(NEW."ShortName"));
    DELETE FROM public.club_handpick_manager
    WHERE club_short_name = upper(btrim(NEW."ShortName"));
  END IF;
  RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.handpick_manager_set(
  p_manager_id bigint,
  p_tagged boolean,
  p_club_short_name text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := upper(btrim(coalesce(p_club_short_name, '')));
  v_mid bigint := p_manager_id;
  v_name text;
  v_mv numeric := 0;
  v_rating numeric;
  v_nation text;
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_authenticated');
  END IF;

  IF v_club = '' THEN
    v_club := upper(btrim(coalesce(public.my_club_shortname(), '')));
  END IF;

  IF v_club = '' OR NOT public.handpick_caller_may_access_club(v_club) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_allowed');
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public."Clubs" c
    WHERE upper(c."ShortName") = v_club
      AND coalesce(c.handpick_intake, false)
  ) AND NOT public.is_gpsl_admin() THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_in_handpick');
  END IF;

  IF v_mid IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'bad_manager');
  END IF;

  IF NOT p_tagged THEN
    DELETE FROM public.club_handpick_manager
    WHERE club_short_name = v_club
      AND manager_id = v_mid;
    RETURN jsonb_build_object(
      'ok', true,
      'tagged', false,
      'club', v_club,
      'manager_id', v_mid
    );
  END IF;

  SELECT
    m.name,
    m.rating,
    nullif(btrim(m.nation::text), ''),
    coalesce(
      nullif(regexp_replace(coalesce(m.market_value::text, ''), '[^0-9.]', '', 'g'), '')::numeric,
      0
    )
  INTO v_name, v_rating, v_nation, v_mv
  FROM public."Managers" m
  WHERE m.id = v_mid;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'manager_not_found');
  END IF;

  IF nullif(btrim(coalesce((
    SELECT m.contracted_club::text FROM public."Managers" m WHERE m.id = v_mid
  ), '')), '') IS NOT NULL THEN
    RETURN jsonb_build_object(
      'ok', false,
      'reason', 'not_free_agent',
      'detail', 'Only free-agent managers can be handpicked'
    );
  END IF;

  INSERT INTO public.club_handpick_manager (club_short_name, manager_id, added_by)
  VALUES (v_club, v_mid, auth.uid())
  ON CONFLICT (club_short_name) DO UPDATE
    SET manager_id = excluded.manager_id,
        added_by = excluded.added_by,
        added_at = now();

  RETURN jsonb_build_object(
    'ok', true,
    'tagged', true,
    'club', v_club,
    'manager_id', v_mid,
    'manager', jsonb_build_object(
      'manager_id', v_mid,
      'manager_name', v_name,
      'rating', v_rating,
      'nation', v_nation,
      'market_value', v_mv
    )
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.handpick_manager_set(bigint, boolean, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.handpick_manager_set(bigint, boolean, text) TO authenticated;

-- Basket list: players (with age/wage) + tagged manager
CREATE OR REPLACE FUNCTION public.handpick_basket_list(
  p_club_short_name text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := upper(btrim(coalesce(p_club_short_name, '')));
  v_mgr jsonb;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  IF v_club = '' THEN
    v_club := upper(btrim(coalesce(public.my_club_shortname(), '')));
  END IF;

  IF v_club = '' OR NOT public.handpick_caller_may_access_club(v_club) THEN
    RETURN jsonb_build_object(
      'ok', true,
      'club', NULL,
      'handpick_intake', false,
      'player_ids', '[]'::jsonb,
      'players', '[]'::jsonb,
      'manager', NULL
    );
  END IF;

  SELECT to_jsonb(r) INTO v_mgr
  FROM (
    SELECT
      hm.manager_id,
      hm.added_at,
      m.name AS manager_name,
      m.rating,
      nullif(btrim(m.nation::text), '') AS nation,
      coalesce(
        nullif(regexp_replace(coalesce(m.market_value::text, ''), '[^0-9.]', '', 'g'), '')::numeric,
        0
      ) AS market_value,
      nullif(btrim(m.contracted_club::text), '') AS contracted_club
    FROM public.club_handpick_manager hm
    LEFT JOIN public."Managers" m ON m.id = hm.manager_id
    WHERE hm.club_short_name = v_club
  ) r;

  -- Hide stale tag if manager is no longer FA (cleanup happens on next set/clear)
  IF v_mgr IS NOT NULL AND nullif(btrim(coalesce(v_mgr->>'contracted_club', '')), '') IS NOT NULL THEN
    v_mgr := NULL;
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'club', v_club,
    'handpick_intake', EXISTS (
      SELECT 1 FROM public."Clubs" c
      WHERE upper(c."ShortName") = v_club
        AND coalesce(c.handpick_intake, false)
    ),
    'player_ids', coalesce((
      SELECT jsonb_agg(b.player_id ORDER BY b.added_at, b.player_id)
      FROM public.club_handpick_basket b
      WHERE b.club_short_name = v_club
    ), '[]'::jsonb),
    'players', coalesce((
      SELECT jsonb_agg(to_jsonb(r) ORDER BY r.added_at, r.player_name)
      FROM (
        SELECT
          b.player_id,
          b.added_at,
          p."Name" AS player_name,
          p."Position" AS position,
          p."Rating" AS rating,
          p."Nation" AS nation,
          CASE
            WHEN p."Age" IS NULL OR btrim(p."Age"::text) = '' THEN NULL
            ELSE round(btrim(p."Age"::text)::numeric)::int
          END AS age,
          coalesce(
            nullif(regexp_replace(coalesce(p.market_value::text, ''), '[^0-9.]', '', 'g'), '')::numeric,
            0
          ) AS market_value,
          coalesce(
            nullif(regexp_replace(coalesce(p.contract_wage::text, ''), '[^0-9.]', '', 'g'), '')::numeric,
            0
          ) AS contract_wage,
          nullif(btrim(p."Contracted_Team"::text), '') AS contracted_team
        FROM public.club_handpick_basket b
        LEFT JOIN public."Players" p ON p."Konami_ID"::text = b.player_id
        WHERE b.club_short_name = v_club
      ) r
    ), '[]'::jsonb),
    'manager', v_mgr
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.handpick_basket_clear(
  p_club_short_name text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := upper(btrim(coalesce(p_club_short_name, '')));
  v_n int := 0;
  v_mgr int := 0;
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_authenticated');
  END IF;

  IF v_club = '' THEN
    v_club := upper(btrim(coalesce(public.my_club_shortname(), '')));
  END IF;

  IF NOT public.handpick_caller_may_access_club(v_club) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_allowed');
  END IF;

  DELETE FROM public.club_handpick_basket
  WHERE club_short_name = v_club;
  GET DIAGNOSTICS v_n = ROW_COUNT;

  DELETE FROM public.club_handpick_manager
  WHERE club_short_name = v_club;
  GET DIAGNOSTICS v_mgr = ROW_COUNT;

  RETURN jsonb_build_object(
    'ok', true,
    'club', v_club,
    'cleared', v_n,
    'manager_cleared', v_mgr > 0
  );
END;
$function$;

NOTIFY pgrst, 'reload schema';
