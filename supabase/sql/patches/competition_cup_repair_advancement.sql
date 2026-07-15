-- =============================================================================
-- Repair League Cup (or any cup) advancement without redrawing
--
-- Fixes cascade where bye-seeded Last 32 / later rounds stayed "Club vs TBD"
-- and month deploy only saw a handful of fixtures.
--
-- Does NOT change the bracket draw. It:
--   1) Sets winners from played cup fixtures (incl. pens)
--   2) Auto-completes first-round byes (home only)
--   3) Advances winners into child slots
--   4) Creates fixtures wherever both clubs are now known
--
-- Run in Supabase SQL editor, then:
--   SELECT public.competition_cup_repair_advancement();
-- Optional: SELECT public.competition_cup_repair_advancement(NULL, 'league_cup');
-- Safe re-run.
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
  WHERE id = p_fixture_id
    AND competition_type = 'cup';

  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  IF v_fixture.status IS DISTINCT FROM 'played' THEN
    RETURN NULL;
  END IF;

  IF v_fixture.home_goals IS NULL OR v_fixture.away_goals IS NULL THEN
    RETURN NULL;
  END IF;

  IF v_fixture.home_goals > v_fixture.away_goals THEN
    v_winner := v_fixture.home_club_short_name;
  ELSIF v_fixture.away_goals > v_fixture.home_goals THEN
    v_winner := v_fixture.away_club_short_name;
  ELSIF nullif(btrim(coalesce(v_fixture.cup_pen_winner_club_short_name, '')), '') IS NOT NULL THEN
    v_winner := btrim(v_fixture.cup_pen_winner_club_short_name);
  ELSE
    RETURN NULL;
  END IF;

  RETURN v_winner;
END;
$function$;

CREATE OR REPLACE FUNCTION public.competition_cup_repair_advancement(
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
  v_pass int;
  v_winners_set int := 0;
  v_byes_set int := 0;
  v_advanced int := 0;
  v_fixtures_created int := 0;
  v_incomplete_r2 int := 0;
  v_incomplete_later int := 0;
  v_missing_child int := 0;
  v_r2_fixtures int := 0;
  v_r3_fixtures int := 0;
  v_node record;
  v_winner text;
  v_before_home text;
  v_before_away text;
  v_child public.competition_cup_bracket_nodes;
  v_had_fixture boolean;
  v_first_round int;
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

  IF v_season IS NULL THEN
    RAISE EXCEPTION 'No current season';
  END IF;

  SELECT min(round_no) INTO v_first_round
  FROM public.competition_cup_bracket_nodes
  WHERE season_id = v_season AND cup_code = v_cup;

  IF v_first_round IS NULL THEN
    RAISE EXCEPTION 'No bracket nodes for % season %', v_cup, v_season;
  END IF;

  -- Several passes so R1 → R2 → R3 cascade in one call
  FOR v_pass IN 1..8 LOOP
    -- 1) Sync winners from played fixtures (no re-pay of prizes)
    FOR v_node IN
      SELECT n.*
      FROM public.competition_cup_bracket_nodes n
      JOIN public.competition_fixtures f ON f.id = n.fixture_id
      WHERE n.season_id = v_season
        AND n.cup_code = v_cup
        AND f.status = 'played'
        AND (
          n.winner_club_short_name IS NULL
          OR n.winner_club_short_name IS DISTINCT FROM
            public.competition_cup_repair_node_winner_from_fixture(f.id)
        )
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
        v_winners_set := v_winners_set + 1;
      END IF;
    END LOOP;

    -- 2) First-round byes: home only, no fixture → winner = home
    FOR v_node IN
      SELECT *
      FROM public.competition_cup_bracket_nodes
      WHERE season_id = v_season
        AND cup_code = v_cup
        AND round_no = v_first_round
        AND coalesce(cup_leg, 1) = 1
        AND home_club_short_name IS NOT NULL
        AND away_club_short_name IS NULL
        AND fixture_id IS NULL
        AND winner_club_short_name IS NULL
    LOOP
      UPDATE public.competition_cup_bracket_nodes
      SET winner_club_short_name = v_node.home_club_short_name
      WHERE id = v_node.id;
      v_byes_set := v_byes_set + 1;
    END LOOP;

    -- 3) Advance every node that has a winner + child wiring
    FOR v_node IN
      SELECT *
      FROM public.competition_cup_bracket_nodes
      WHERE season_id = v_season
        AND cup_code = v_cup
        AND winner_club_short_name IS NOT NULL
        AND child_node_id IS NOT NULL
        AND child_slot IS NOT NULL
      ORDER BY round_no, match_no
    LOOP
      SELECT * INTO v_child
      FROM public.competition_cup_bracket_nodes
      WHERE id = v_node.child_node_id;

      IF NOT FOUND THEN
        CONTINUE;
      END IF;

      v_before_home := v_child.home_club_short_name;
      v_before_away := v_child.away_club_short_name;

      PERFORM public.competition_cup_advance_node_winner(v_node.id);

      SELECT home_club_short_name, away_club_short_name
      INTO v_child.home_club_short_name, v_child.away_club_short_name
      FROM public.competition_cup_bracket_nodes
      WHERE id = v_node.child_node_id;

      IF v_child.home_club_short_name IS DISTINCT FROM v_before_home
         OR v_child.away_club_short_name IS DISTINCT FROM v_before_away THEN
        v_advanced := v_advanced + 1;
      END IF;
    END LOOP;

    -- 4) Create fixtures for any complete node still missing one
    FOR v_node IN
      SELECT *
      FROM public.competition_cup_bracket_nodes
      WHERE season_id = v_season
        AND cup_code = v_cup
        AND home_club_short_name IS NOT NULL
        AND away_club_short_name IS NOT NULL
        AND fixture_id IS NULL
    LOOP
      v_had_fixture := false;
      PERFORM public.competition_create_cup_fixture_for_node(v_node.id);
      SELECT fixture_id IS NOT NULL INTO v_had_fixture
      FROM public.competition_cup_bracket_nodes
      WHERE id = v_node.id;
      IF v_had_fixture THEN
        v_fixtures_created := v_fixtures_created + 1;
      END IF;
    END LOOP;
  END LOOP;

  SELECT count(*)::int INTO v_missing_child
  FROM public.competition_cup_bracket_nodes
  WHERE season_id = v_season
    AND cup_code = v_cup
    AND round_no = v_first_round
    AND coalesce(cup_leg, 1) = 1
    AND (
      (home_club_short_name IS NOT NULL AND away_club_short_name IS NOT NULL)
      OR (home_club_short_name IS NOT NULL AND away_club_short_name IS NULL)
    )
    AND child_node_id IS NULL;

  SELECT count(*)::int INTO v_incomplete_r2
  FROM public.competition_cup_bracket_nodes
  WHERE season_id = v_season
    AND cup_code = v_cup
    AND round_no = v_first_round + 1
    AND coalesce(cup_leg, 1) = 1
    AND (
      (home_club_short_name IS NOT NULL AND away_club_short_name IS NULL)
      OR (home_club_short_name IS NULL AND away_club_short_name IS NOT NULL)
      OR (home_club_short_name IS NULL AND away_club_short_name IS NULL)
    );

  SELECT count(*)::int INTO v_incomplete_later
  FROM public.competition_cup_bracket_nodes
  WHERE season_id = v_season
    AND cup_code = v_cup
    AND round_no > v_first_round + 1
    AND coalesce(cup_leg, 1) = 1
    AND (
      (home_club_short_name IS NOT NULL AND away_club_short_name IS NULL)
      OR (home_club_short_name IS NULL AND away_club_short_name IS NOT NULL)
    );

  SELECT count(*)::int INTO v_r2_fixtures
  FROM public.competition_cup_bracket_nodes
  WHERE season_id = v_season
    AND cup_code = v_cup
    AND round_no = v_first_round + 1
    AND coalesce(cup_leg, 1) = 1
    AND fixture_id IS NOT NULL;

  SELECT count(*)::int INTO v_r3_fixtures
  FROM public.competition_cup_bracket_nodes
  WHERE season_id = v_season
    AND cup_code = v_cup
    AND round_no = v_first_round + 2
    AND coalesce(cup_leg, 1) = 1
    AND fixture_id IS NOT NULL;

  RETURN jsonb_build_object(
    'ok', true,
    'season_id', v_season,
    'cup_code', v_cup,
    'winners_synced_from_fixtures', v_winners_set,
    'bye_winners_set', v_byes_set,
    'child_slots_updated', v_advanced,
    'fixtures_created', v_fixtures_created,
    'r1_nodes_missing_child_wiring', v_missing_child,
    'last32_incomplete_nodes', v_incomplete_r2,
    'later_incomplete_nodes', v_incomplete_later,
    'last32_fixtures_now', v_r2_fixtures,
    'last16_fixtures_now', v_r3_fixtures,
    'note', CASE
      WHEN v_missing_child > 0 THEN
        'Some R1 nodes have no child_node_id — bracket wiring is broken; may need redraw.'
      WHEN v_incomplete_r2 > 0 THEN
        'Some Last 32 ties still await an R1 winner (unplayed December ties). Play/simulate those, then re-run repair.'
      WHEN v_r3_fixtures < 8 AND v_cup = 'league_cup' THEN
        'Last 16 still short of 8 fixtures — finish remaining Last 32 ties, then re-run repair / month deploy.'
      ELSE
        'Advancement repaired. Re-check cups.html and month deploy preview.'
    END
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_cup_repair_node_winner_from_fixture(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.competition_cup_repair_advancement(bigint, text) TO authenticated;

NOTIFY pgrst, 'reload schema';

-- Run once after applying this file:
-- SELECT public.competition_cup_repair_advancement();
