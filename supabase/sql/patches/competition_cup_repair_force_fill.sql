-- =============================================================================
-- League Cup repair v2 — diagnose + force-fill next-round slots from parents
--
-- Run after competition_cup_repair_advancement.sql (or alone).
--
--   SELECT public.competition_cup_repair_diagnose();
--   SELECT public.competition_cup_repair_force_fill();
--
-- Safe re-run. Admin only.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.competition_cup_repair_node_winner_from_fixture(
  p_fixture_id bigint
)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_fixture public.competition_fixtures;
  v_winner text;
BEGIN
  SELECT * INTO v_fixture
  FROM public.competition_fixtures
  WHERE id = p_fixture_id AND competition_type = 'cup';

  IF NOT FOUND OR v_fixture.status IS DISTINCT FROM 'played' THEN
    RETURN NULL;
  END IF;
  IF v_fixture.home_goals IS NULL OR v_fixture.away_goals IS NULL THEN
    RETURN NULL;
  END IF;

  IF v_fixture.home_goals > v_fixture.away_goals THEN
    RETURN v_fixture.home_club_short_name;
  ELSIF v_fixture.away_goals > v_fixture.home_goals THEN
    RETURN v_fixture.away_club_short_name;
  ELSIF nullif(btrim(coalesce(v_fixture.cup_pen_winner_club_short_name, '')), '') IS NOT NULL THEN
    RETURN btrim(v_fixture.cup_pen_winner_club_short_name);
  END IF;
  RETURN NULL;
END;
$function$;

CREATE OR REPLACE FUNCTION public.competition_cup_repair_diagnose(
  p_season_id bigint DEFAULT NULL,
  p_cup_code text DEFAULT 'league_cup'
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season bigint := p_season_id;
  v_cup text := coalesce(nullif(btrim(p_cup_code), ''), 'league_cup');
  v_first int;
  v_incomplete jsonb;
  v_unplayed_r1 jsonb;
  v_orphans int;
BEGIN
  IF NOT public.is_gpsl_admin()
     AND current_user NOT IN ('postgres', 'supabase_admin', 'service_role') THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF v_season IS NULL THEN
    SELECT s.id INTO v_season
    FROM public.competition_seasons s
    WHERE s.is_current = true
    ORDER BY s.id DESC
    LIMIT 1;
  END IF;

  SELECT min(round_no) INTO v_first
  FROM public.competition_cup_bracket_nodes
  WHERE season_id = v_season AND cup_code = v_cup;

  SELECT coalesce(jsonb_agg(x ORDER BY x.round_no, x.match_no), '[]'::jsonb)
  INTO v_incomplete
  FROM (
    SELECT
      n.round_no,
      n.match_no,
      n.id AS node_id,
      n.home_club_short_name AS home,
      n.away_club_short_name AS away,
      n.fixture_id,
      (
        SELECT coalesce(jsonb_agg(
          jsonb_build_object(
            'parent_id', p.id,
            'parent_round', p.round_no,
            'parent_match', p.match_no,
            'parent_home', p.home_club_short_name,
            'parent_away', p.away_club_short_name,
            'parent_winner', p.winner_club_short_name,
            'parent_fixture_id', p.fixture_id,
            'parent_fixture_status', f.status,
            'child_slot', p.child_slot,
            'is_bye', (p.away_club_short_name IS NULL AND p.fixture_id IS NULL)
          )
          ORDER BY p.child_slot
        ), '[]'::jsonb)
        FROM public.competition_cup_bracket_nodes p
        LEFT JOIN public.competition_fixtures f ON f.id = p.fixture_id
        WHERE p.child_node_id = n.id
      ) AS parents
    FROM public.competition_cup_bracket_nodes n
    WHERE n.season_id = v_season
      AND n.cup_code = v_cup
      AND coalesce(n.cup_leg, 1) = 1
      AND n.round_no > v_first
      AND (
        n.home_club_short_name IS NULL
        OR n.away_club_short_name IS NULL
      )
  ) x;

  SELECT coalesce(jsonb_agg(
    jsonb_build_object(
      'node_id', n.id,
      'match_no', n.match_no,
      'home', n.home_club_short_name,
      'away', n.away_club_short_name,
      'fixture_id', n.fixture_id,
      'fixture_status', f.status,
      'child_node_id', n.child_node_id,
      'child_slot', n.child_slot,
      'winner', n.winner_club_short_name
    )
    ORDER BY n.match_no
  ), '[]'::jsonb)
  INTO v_unplayed_r1
  FROM public.competition_cup_bracket_nodes n
  LEFT JOIN public.competition_fixtures f ON f.id = n.fixture_id
  WHERE n.season_id = v_season
    AND n.cup_code = v_cup
    AND n.round_no = v_first
    AND coalesce(n.cup_leg, 1) = 1
    AND n.home_club_short_name IS NOT NULL
    AND n.away_club_short_name IS NOT NULL
    AND (n.fixture_id IS NULL OR f.status IS DISTINCT FROM 'played' OR n.winner_club_short_name IS NULL);

  SELECT count(*)::int INTO v_orphans
  FROM public.competition_fixtures f
  WHERE f.season_id = v_season
    AND f.competition_type = 'cup'
    AND f.cup_code = v_cup
    AND f.status = 'played'
    AND NOT EXISTS (
      SELECT 1 FROM public.competition_cup_bracket_nodes n WHERE n.fixture_id = f.id
    );

  RETURN jsonb_build_object(
    'ok', true,
    'season_id', v_season,
    'cup_code', v_cup,
    'incomplete_later_rounds', v_incomplete,
    'unresolved_r1_ties', v_unplayed_r1,
    'played_fixtures_not_linked_to_nodes', v_orphans
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.competition_cup_repair_force_fill(
  p_season_id bigint DEFAULT NULL,
  p_cup_code text DEFAULT 'league_cup'
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season bigint := p_season_id;
  v_cup text := coalesce(nullif(btrim(p_cup_code), ''), 'league_cup');
  v_first int;
  v_pass int;
  v_linked int := 0;
  v_winners int := 0;
  v_byes int := 0;
  v_filled int := 0;
  v_fixtures int := 0;
  v_bye_rows int := 0;
  v_node record;
  v_parent record;
  v_fx public.competition_fixtures;
  v_winner text;
  v_diag jsonb;
BEGIN
  IF NOT public.is_gpsl_admin()
     AND current_user NOT IN ('postgres', 'supabase_admin', 'service_role') THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF v_season IS NULL THEN
    SELECT s.id INTO v_season
    FROM public.competition_seasons s
    WHERE s.is_current = true
    ORDER BY s.id DESC
    LIMIT 1;
  END IF;

  SELECT min(round_no) INTO v_first
  FROM public.competition_cup_bracket_nodes
  WHERE season_id = v_season AND cup_code = v_cup;

  IF v_first IS NULL THEN
    RAISE EXCEPTION 'No bracket for % / season %', v_cup, v_season;
  END IF;

  -- A) Relink played cup fixtures that aren't attached to nodes
  FOR v_fx IN
    SELECT f.*
    FROM public.competition_fixtures f
    WHERE f.season_id = v_season
      AND f.competition_type = 'cup'
      AND f.cup_code = v_cup
      AND f.status = 'played'
      AND NOT EXISTS (
        SELECT 1 FROM public.competition_cup_bracket_nodes n WHERE n.fixture_id = f.id
      )
  LOOP
    UPDATE public.competition_cup_bracket_nodes n
    SET fixture_id = v_fx.id
    WHERE n.season_id = v_season
      AND n.cup_code = v_cup
      AND n.fixture_id IS NULL
      AND n.round_no = coalesce(v_fx.cup_round, n.round_no)
      AND n.match_no = coalesce(v_fx.cup_match, n.match_no)
      AND n.home_club_short_name = v_fx.home_club_short_name
      AND n.away_club_short_name = v_fx.away_club_short_name;
    IF FOUND THEN
      v_linked := v_linked + 1;
    ELSE
      UPDATE public.competition_cup_bracket_nodes n
      SET fixture_id = v_fx.id
      WHERE n.id = (
        SELECT n2.id
        FROM public.competition_cup_bracket_nodes n2
        WHERE n2.season_id = v_season
          AND n2.cup_code = v_cup
          AND n2.fixture_id IS NULL
          AND n2.home_club_short_name = v_fx.home_club_short_name
          AND n2.away_club_short_name = v_fx.away_club_short_name
        ORDER BY n2.round_no
        LIMIT 1
      );
      IF FOUND THEN
        v_linked := v_linked + 1;
      END IF;
    END IF;
  END LOOP;

  FOR v_pass IN 1..10 LOOP
    -- B) Sync winners from linked played fixtures
    FOR v_node IN
      SELECT n.*
      FROM public.competition_cup_bracket_nodes n
      JOIN public.competition_fixtures f ON f.id = n.fixture_id
      WHERE n.season_id = v_season
        AND n.cup_code = v_cup
        AND f.status = 'played'
    LOOP
      v_winner := public.competition_cup_repair_node_winner_from_fixture(v_node.fixture_id);
      IF v_winner IS NULL THEN
        CONTINUE;
      END IF;
      UPDATE public.competition_cup_bracket_nodes
      SET winner_club_short_name = v_winner
      WHERE id = v_node.id
        AND winner_club_short_name IS DISTINCT FROM v_winner;
      IF FOUND THEN
        v_winners := v_winners + 1;
      END IF;
    END LOOP;

    -- C) Bye winners
    UPDATE public.competition_cup_bracket_nodes
    SET winner_club_short_name = home_club_short_name
    WHERE season_id = v_season
      AND cup_code = v_cup
      AND round_no = v_first
      AND coalesce(cup_leg, 1) = 1
      AND home_club_short_name IS NOT NULL
      AND away_club_short_name IS NULL
      AND fixture_id IS NULL
      AND winner_club_short_name IS NULL;
    GET DIAGNOSTICS v_bye_rows = ROW_COUNT;
    v_byes := v_byes + v_bye_rows;

    -- D) Force-write every parent winner into its child slot
    FOR v_parent IN
      SELECT *
      FROM public.competition_cup_bracket_nodes
      WHERE season_id = v_season
        AND cup_code = v_cup
        AND winner_club_short_name IS NOT NULL
        AND child_node_id IS NOT NULL
        AND child_slot IN ('home', 'away')
      ORDER BY round_no, match_no
    LOOP
      IF v_parent.child_slot = 'home' THEN
        UPDATE public.competition_cup_bracket_nodes
        SET home_club_short_name = v_parent.winner_club_short_name
        WHERE id = v_parent.child_node_id
          AND home_club_short_name IS DISTINCT FROM v_parent.winner_club_short_name;
      ELSE
        UPDATE public.competition_cup_bracket_nodes
        SET away_club_short_name = v_parent.winner_club_short_name
        WHERE id = v_parent.child_node_id
          AND away_club_short_name IS DISTINCT FROM v_parent.winner_club_short_name;
      END IF;
      IF FOUND THEN
        v_filled := v_filled + 1;
      END IF;
    END LOOP;

    -- E) Create fixtures for complete nodes
    FOR v_node IN
      SELECT *
      FROM public.competition_cup_bracket_nodes
      WHERE season_id = v_season
        AND cup_code = v_cup
        AND home_club_short_name IS NOT NULL
        AND away_club_short_name IS NOT NULL
        AND fixture_id IS NULL
    LOOP
      PERFORM public.competition_create_cup_fixture_for_node(v_node.id);
      IF EXISTS (
        SELECT 1 FROM public.competition_cup_bracket_nodes
        WHERE id = v_node.id AND fixture_id IS NOT NULL
      ) THEN
        v_fixtures := v_fixtures + 1;
      END IF;
    END LOOP;
  END LOOP;

  -- Prefer schedule-aware create if available
  IF to_regprocedure('public.competition_cup_sync_all_scheduled_cup_fixtures(bigint, text)') IS NOT NULL THEN
    PERFORM public.competition_cup_sync_all_scheduled_cup_fixtures(v_season, v_cup);
  END IF;

  v_diag := public.competition_cup_repair_diagnose(v_season, v_cup);

  RETURN jsonb_build_object(
    'ok', true,
    'season_id', v_season,
    'cup_code', v_cup,
    'fixtures_relinked', v_linked,
    'winners_synced', v_winners,
    'bye_winners_set', v_byes,
    'child_slots_force_filled', v_filled,
    'fixtures_created', v_fixtures,
    'still_incomplete', v_diag -> 'incomplete_later_rounds',
    'still_unresolved_r1', v_diag -> 'unresolved_r1_ties',
    'note', CASE
      WHEN jsonb_array_length(coalesce(v_diag -> 'unresolved_r1_ties', '[]'::jsonb)) > 0 THEN
        'Last 32/16 still blocked by unfinished Last 64 ties listed in still_unresolved_r1. Play or simulate those December cup fixtures, then re-run force fill.'
      WHEN jsonb_array_length(coalesce(v_diag -> 'incomplete_later_rounds', '[]'::jsonb)) > 0 THEN
        'Some later-round slots still empty — check still_incomplete.parents for missing child wiring or missing winners.'
      ELSE
        'Bracket advancement looks complete. Refresh cups.html / month deploy.'
    END
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_cup_repair_diagnose(bigint, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.competition_cup_repair_force_fill(bigint, text) TO authenticated;

NOTIFY pgrst, 'reload schema';

-- After applying:
-- SELECT public.competition_cup_repair_force_fill();
-- SELECT public.competition_cup_repair_diagnose();
