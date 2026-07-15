-- =============================================================================
-- Cup finals Wembley — fix venue stamp backfill detection
--
-- For gate receipt corrections (balances + ledger), run:
--   competition_cup_final_gate_backfill.sql
--   or SELECT public.competition_admin_backfill_cup_final_gates(NULL, false);
--
-- Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.competition_fixture_is_cup_final(
  p_fixture public.competition_fixtures
)
RETURNS boolean
LANGUAGE sql
STABLE
SET search_path = public
AS $$
  SELECT coalesce(p_fixture.competition_type, '') = 'cup'
    AND p_fixture.cup_code IS NOT NULL
    AND p_fixture.cup_round IS NOT NULL
    AND (
      EXISTS (
        SELECT 1
        FROM public.competition_cup_round_schedule s
        WHERE s.cup_code = p_fixture.cup_code
          AND s.round_no = p_fixture.cup_round::smallint
          AND s.stage = 'final'
      )
      OR p_fixture.cup_round = (
        SELECT max(n.round_no)
        FROM public.competition_cup_bracket_nodes n
        WHERE n.season_id = p_fixture.season_id
          AND n.cup_code = p_fixture.cup_code
      )
      OR p_fixture.cup_round = (
        SELECT max(s.round_no)
        FROM public.competition_cup_round_schedule s
        WHERE s.cup_code = p_fixture.cup_code
      )
      OR lower(coalesce(
        (
          SELECT s.round_label
          FROM public.competition_cup_round_schedule s
          WHERE s.cup_code = p_fixture.cup_code
            AND s.round_no = p_fixture.cup_round::smallint
          ORDER BY s.cup_leg DESC
          LIMIT 1
        ),
        ''
      )) LIKE '%final%'
    );
$$;

CREATE OR REPLACE FUNCTION public.competition_apply_cup_final_venue(p_fixture_id bigint)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_fixture public.competition_fixtures;
  v_name text;
  v_cap int;
BEGIN
  IF p_fixture_id IS NULL THEN
    RETURN;
  END IF;

  SELECT * INTO v_fixture
  FROM public.competition_fixtures
  WHERE id = p_fixture_id;

  IF NOT FOUND OR NOT public.competition_fixture_is_cup_final(v_fixture) THEN
    RETURN;
  END IF;

  SELECT
    coalesce(nullif(btrim(gs.cup_final_venue_name), ''), 'Wembley Stadium'),
    greatest(coalesce(gs.cup_final_venue_capacity, 90000), 1)
  INTO v_name, v_cap
  FROM public.global_settings gs
  WHERE gs.id = 1;

  v_name := coalesce(v_name, 'Wembley Stadium');
  v_cap := coalesce(v_cap, 90000);

  UPDATE public.competition_fixtures
  SET venue_name = v_name,
      venue_capacity = v_cap
  WHERE id = p_fixture_id;
END;
$function$;

CREATE OR REPLACE FUNCTION public.competition_admin_backfill_cup_final_venues()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_name text;
  v_cap int;
  v_via_helper int := 0;
  v_via_schedule int := 0;
  v_via_max_round int := 0;
  r record;
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  SELECT
    coalesce(nullif(btrim(gs.cup_final_venue_name), ''), 'Wembley Stadium'),
    greatest(coalesce(gs.cup_final_venue_capacity, 90000), 1)
  INTO v_name, v_cap
  FROM public.global_settings gs
  WHERE gs.id = 1;

  v_name := coalesce(v_name, 'Wembley Stadium');
  v_cap := coalesce(v_cap, 90000);

  FOR r IN
    SELECT f.id
    FROM public.competition_fixtures f
    WHERE f.competition_type = 'cup'
      AND public.competition_fixture_is_cup_final(f)
  LOOP
    UPDATE public.competition_fixtures
    SET venue_name = v_name,
        venue_capacity = v_cap
    WHERE id = r.id;
    v_via_helper := v_via_helper + 1;
  END LOOP;

  UPDATE public.competition_fixtures f
  SET venue_name = v_name,
      venue_capacity = v_cap
  FROM public.competition_cup_round_schedule s
  WHERE f.competition_type = 'cup'
    AND s.cup_code = f.cup_code
    AND s.round_no = f.cup_round::smallint
    AND s.stage = 'final'
    AND (
      f.venue_name IS DISTINCT FROM v_name
      OR f.venue_capacity IS DISTINCT FROM v_cap
    );

  GET DIAGNOSTICS v_via_schedule = ROW_COUNT;

  UPDATE public.competition_fixtures f
  SET venue_name = v_name,
      venue_capacity = v_cap
  WHERE f.competition_type = 'cup'
    AND f.cup_round = (
      SELECT max(n.round_no)
      FROM public.competition_cup_bracket_nodes n
      WHERE n.season_id = f.season_id
        AND n.cup_code = f.cup_code
    )
    AND (
      f.venue_name IS DISTINCT FROM v_name
      OR f.venue_capacity IS DISTINCT FROM v_cap
    );

  GET DIAGNOSTICS v_via_max_round = ROW_COUNT;

  RETURN jsonb_build_object(
    'ok', true,
    'venue_name', v_name,
    'venue_capacity', v_cap,
    'stamped_via_is_final', v_via_helper,
    'extra_via_schedule_join', v_via_schedule,
    'extra_via_max_bracket_round', v_via_max_round,
    'finals_now', (
      SELECT count(*)::int
      FROM public.competition_fixtures f
      WHERE f.competition_type = 'cup'
        AND f.venue_name IS NOT NULL
    ),
    'sample', (
      SELECT coalesce(
        jsonb_agg(
          jsonb_build_object(
            'id', x.id,
            'cup_code', x.cup_code,
            'cup_round', x.cup_round,
            'venue_name', x.venue_name,
            'venue_capacity', x.venue_capacity,
            'home', x.home_club_short_name,
            'away', x.away_club_short_name
          )
          ORDER BY x.cup_code, x.id
        ),
        '[]'::jsonb
      )
      FROM (
        SELECT f.id, f.cup_code, f.cup_round, f.venue_name, f.venue_capacity,
               f.home_club_short_name, f.away_club_short_name
        FROM public.competition_fixtures f
        WHERE f.competition_type = 'cup'
          AND f.venue_name IS NOT NULL
        ORDER BY f.cup_code, f.id
        LIMIT 20
      ) x
    )
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_fixture_is_cup_final(public.competition_fixtures) TO authenticated;
GRANT EXECUTE ON FUNCTION public.competition_apply_cup_final_venue(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.competition_admin_backfill_cup_final_venues() TO authenticated;

SELECT public.competition_admin_backfill_cup_final_venues();

NOTIFY pgrst, 'reload schema';
