-- =============================================================================
-- Prestige cups: auto-draw next round when a tie completes
-- 2026-09-22
--
-- Problem: Nov SF / Dec Final fixtures only appear when both child slots are
-- filled AND create_cup_fixture runs. That chain often stalled (two-leg pens,
-- orphan fixtures, swallowed errors) and month lock never healed brackets.
--
-- Fix:
--   1) Harden competition_cup_on_fixture_played → always advance + ensure ready
--   2) Harden competition_cup_advance_node_winner → ensure cup ready after write
--   3) competition_cup_ensure_ready_fixtures — push winners + create fixtures
--   4) competition_cup_auto_draw_prestige_cups — heal all prestige cups
--   5) Soft-wire into competition_run_month_lock_jobs (scheduling stage)
--
-- Safe re-run. After apply, also heals current season once at end of file.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Ensure every ready bracket node has a fixture (and parent winners are pushed)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.competition_cup_ensure_ready_fixtures(
  p_season_id bigint,
  p_cup_code text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season bigint := p_season_id;
  v_cup text;
  v_parent record;
  v_node record;
  v_slots int := 0;
  v_created int := 0;
  v_two_leg int := 0;
BEGIN
  IF v_season IS NULL THEN
    SELECT s.id INTO v_season
    FROM public.competition_seasons s
    WHERE s.is_current = true
    ORDER BY s.id DESC
    LIMIT 1;
  END IF;

  IF v_season IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_season');
  END IF;

  IF to_regprocedure('public.competition_cup_normalize_code(text)') IS NOT NULL THEN
    v_cup := public.competition_cup_normalize_code(p_cup_code);
  ELSE
    v_cup := lower(nullif(btrim(p_cup_code), ''));
  END IF;

  IF v_cup IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_cup');
  END IF;

  -- Sync two-leg winners onto leg-2 nodes when helper exists
  IF to_regprocedure('public.competition_cup_repair_sync_two_leg_winners(bigint, text)') IS NOT NULL THEN
    BEGIN
      v_two_leg := public.competition_cup_repair_sync_two_leg_winners(v_season, v_cup);
    EXCEPTION WHEN OTHERS THEN
      v_two_leg := 0;
    END;
  END IF;

  -- Push every known winner into its child slot
  FOR v_parent IN
    SELECT *
    FROM public.competition_cup_bracket_nodes
    WHERE season_id = v_season
      AND cup_code = v_cup
      AND winner_club_short_name IS NOT NULL
      AND child_node_id IS NOT NULL
      AND child_slot IN ('home', 'away')
    ORDER BY round_no, match_no, coalesce(cup_leg, 1)
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
      v_slots := v_slots + 1;
    END IF;
  END LOOP;

  -- Create fixtures for any node that now has both clubs
  FOR v_node IN
    SELECT *
    FROM public.competition_cup_bracket_nodes
    WHERE season_id = v_season
      AND cup_code = v_cup
      AND home_club_short_name IS NOT NULL
      AND away_club_short_name IS NOT NULL
      AND fixture_id IS NULL
    ORDER BY round_no, match_no, coalesce(cup_leg, 1)
  LOOP
    BEGIN
      PERFORM public.competition_create_cup_fixture_for_node(v_node.id);
      IF EXISTS (
        SELECT 1
        FROM public.competition_cup_bracket_nodes
        WHERE id = v_node.id
          AND fixture_id IS NOT NULL
      ) THEN
        v_created := v_created + 1;
      END IF;
    EXCEPTION WHEN OTHERS THEN
      -- Keep going; other ties may still draw
      NULL;
    END;
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true,
    'season_id', v_season,
    'cup_code', v_cup,
    'two_leg_winners_synced', v_two_leg,
    'child_slots_filled', v_slots,
    'fixtures_created', v_created
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_cup_ensure_ready_fixtures(bigint, text) TO authenticated;

-- ---------------------------------------------------------------------------
-- Heal all prestige cups for a season (month-lock / post-result safety net)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.competition_cup_auto_draw_prestige_cups(
  p_season_id bigint DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season bigint := p_season_id;
  v_cup text;
  v_res jsonb;
  v_out jsonb := '[]'::jsonb;
BEGIN
  IF v_season IS NULL THEN
    SELECT s.id INTO v_season
    FROM public.competition_seasons s
    WHERE s.is_current = true
    ORDER BY s.id DESC
    LIMIT 1;
  END IF;

  IF v_season IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_season');
  END IF;

  FOREACH v_cup IN ARRAY ARRAY['super8', 'plate', 'shield', 'bowl']
  LOOP
    BEGIN
      -- Prefer full force-fill when available (admin-gated inside; service_role ok)
      IF to_regprocedure('public.competition_cup_repair_force_fill(bigint, text)') IS NOT NULL
         AND (
           (to_regprocedure('public.is_gpsl_admin()') IS NOT NULL AND public.is_gpsl_admin())
           OR current_user IN ('postgres', 'supabase_admin', 'service_role')
         )
      THEN
        v_res := public.competition_cup_repair_force_fill(v_season, v_cup);
      ELSE
        v_res := public.competition_cup_ensure_ready_fixtures(v_season, v_cup);
      END IF;
      v_out := v_out || jsonb_build_array(
        jsonb_build_object('cup_code', v_cup) || coalesce(v_res, '{}'::jsonb)
      );
    EXCEPTION WHEN OTHERS THEN
      v_out := v_out || jsonb_build_array(
        jsonb_build_object('cup_code', v_cup, 'ok', false, 'error', SQLERRM)
      );
    END;
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true,
    'season_id', v_season,
    'cups', v_out
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_cup_auto_draw_prestige_cups(bigint) TO authenticated;

-- ---------------------------------------------------------------------------
-- Advance: after writing child slot, ensure whole cup is drawn for ready ties
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.competition_cup_advance_node_winner(p_node_id bigint)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_node public.competition_cup_bracket_nodes;
  v_child public.competition_cup_bracket_nodes;
  v_winner text;
BEGIN
  SELECT * INTO v_node FROM public.competition_cup_bracket_nodes WHERE id = p_node_id;
  IF NOT FOUND THEN
    RETURN;
  END IF;

  v_winner := v_node.winner_club_short_name;
  IF v_winner IS NULL OR v_node.child_node_id IS NULL OR v_node.child_slot IS NULL THEN
    RETURN;
  END IF;

  SELECT * INTO v_child FROM public.competition_cup_bracket_nodes WHERE id = v_node.child_node_id;
  IF NOT FOUND THEN
    RETURN;
  END IF;

  IF v_node.child_slot = 'home' THEN
    UPDATE public.competition_cup_bracket_nodes
    SET home_club_short_name = v_winner
    WHERE id = v_child.id
      AND home_club_short_name IS DISTINCT FROM v_winner;
  ELSE
    UPDATE public.competition_cup_bracket_nodes
    SET away_club_short_name = v_winner
    WHERE id = v_child.id
      AND away_club_short_name IS DISTINCT FROM v_winner;
  END IF;

  SELECT * INTO v_child FROM public.competition_cup_bracket_nodes WHERE id = v_node.child_node_id;

  IF v_child.home_club_short_name IS NOT NULL AND v_child.away_club_short_name IS NOT NULL THEN
    PERFORM public.competition_create_cup_fixture_for_node(v_child.id);
  END IF;

  -- Heal any other ready nodes in this cup (sibling SF etc.)
  PERFORM public.competition_cup_ensure_ready_fixtures(v_node.season_id, v_node.cup_code);
END;
$function$;

-- ---------------------------------------------------------------------------
-- On fixture played: resolve winner, advance, auto-draw next round
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.competition_cup_on_fixture_played(p_fixture_id bigint)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_fixture public.competition_fixtures;
  v_node public.competition_cup_bracket_nodes;
  v_leg1_node public.competition_cup_bracket_nodes;
  v_leg1_fixture public.competition_fixtures;
  v_winner text;
  v_tie_home text;
  v_tie_away text;
  v_pen text;
BEGIN
  SELECT * INTO v_fixture
  FROM public.competition_fixtures
  WHERE id = p_fixture_id;

  IF NOT FOUND OR v_fixture.competition_type <> 'cup' THEN
    RETURN;
  END IF;

  IF v_fixture.home_goals IS NULL OR v_fixture.away_goals IS NULL THEN
    RETURN;
  END IF;

  SELECT * INTO v_node
  FROM public.competition_cup_bracket_nodes
  WHERE fixture_id = p_fixture_id;

  -- Orphan played cup fixture → try relink by round/match/leg/clubs
  IF NOT FOUND THEN
    UPDATE public.competition_cup_bracket_nodes n
    SET fixture_id = v_fixture.id
    WHERE n.season_id = v_fixture.season_id
      AND n.cup_code = v_fixture.cup_code
      AND n.fixture_id IS NULL
      AND n.round_no = coalesce(v_fixture.cup_round, n.round_no)
      AND n.match_no = coalesce(v_fixture.cup_match, n.match_no)
      AND coalesce(n.cup_leg, 1) = coalesce(v_fixture.cup_leg, 1)
      AND n.home_club_short_name = v_fixture.home_club_short_name
      AND n.away_club_short_name = v_fixture.away_club_short_name;

    SELECT * INTO v_node
    FROM public.competition_cup_bracket_nodes
    WHERE fixture_id = p_fixture_id;
  END IF;

  IF NOT FOUND THEN
    PERFORM public.competition_pay_cup_fixture_prizes(p_fixture_id);
    RETURN;
  END IF;

  v_pen := nullif(btrim(coalesce(v_fixture.cup_pen_winner_club_short_name, '')), '');

  -- Two-legged: this fixture is leg 2
  IF v_node.leg1_node_id IS NOT NULL THEN
    -- Prefer shared repair resolver when present
    IF to_regprocedure('public.competition_cup_repair_two_leg_winner_for_node(bigint)') IS NOT NULL THEN
      v_winner := public.competition_cup_repair_two_leg_winner_for_node(v_node.id);
    END IF;

    IF v_winner IS NULL THEN
      SELECT * INTO v_leg1_node
      FROM public.competition_cup_bracket_nodes
      WHERE id = v_node.leg1_node_id;

      SELECT * INTO v_leg1_fixture
      FROM public.competition_fixtures
      WHERE id = v_leg1_node.fixture_id;

      IF v_leg1_fixture.id IS NULL OR v_leg1_fixture.status <> 'played'
         OR v_leg1_fixture.home_goals IS NULL OR v_leg1_fixture.away_goals IS NULL THEN
        PERFORM public.competition_pay_cup_fixture_prizes(p_fixture_id);
        RETURN;
      END IF;

      v_tie_home := v_leg1_node.home_club_short_name;
      v_tie_away := v_leg1_node.away_club_short_name;

      v_winner := public.competition_cup_two_leg_winner(
        v_leg1_fixture.home_goals,
        v_leg1_fixture.away_goals,
        v_fixture.home_goals,
        v_fixture.away_goals,
        v_tie_home,
        v_tie_away,
        v_fixture.home_club_short_name,
        v_fixture.away_club_short_name
      );

      IF v_winner IS NULL THEN
        v_winner := v_pen;
      END IF;

      IF v_winner IS NULL THEN
        v_winner := nullif(btrim(coalesce(v_leg1_fixture.cup_pen_winner_club_short_name, '')), '');
      END IF;
    END IF;

    IF v_winner IS NULL THEN
      -- Level agg, no pens yet — cannot draw next round
      PERFORM public.competition_pay_cup_fixture_prizes(p_fixture_id);
      RETURN;
    END IF;

    UPDATE public.competition_cup_bracket_nodes
    SET winner_club_short_name = v_winner
    WHERE id = v_node.id;

    PERFORM public.competition_cup_advance_node_winner(v_node.id);
    PERFORM public.competition_pay_cup_fixture_prizes(p_fixture_id);
    PERFORM public.competition_cup_ensure_ready_fixtures(v_node.season_id, v_node.cup_code);
    RETURN;
  END IF;

  -- Two-legged: this fixture is leg 1 only — wait for leg 2
  IF EXISTS (
    SELECT 1
    FROM public.competition_cup_bracket_nodes leg2
    WHERE leg2.leg1_node_id = v_node.id
  ) THEN
    PERFORM public.competition_pay_cup_fixture_prizes(p_fixture_id);
    RETURN;
  END IF;

  -- Single-leg: score or pens
  IF v_fixture.home_goals > v_fixture.away_goals THEN
    v_winner := v_fixture.home_club_short_name;
  ELSIF v_fixture.away_goals > v_fixture.home_goals THEN
    v_winner := v_fixture.away_club_short_name;
  ELSIF v_pen IS NOT NULL THEN
    v_winner := v_pen;
  ELSE
    PERFORM public.competition_pay_cup_fixture_prizes(p_fixture_id);
    RETURN;
  END IF;

  UPDATE public.competition_cup_bracket_nodes
  SET winner_club_short_name = v_winner
  WHERE id = v_node.id;

  PERFORM public.competition_cup_advance_node_winner(v_node.id);
  PERFORM public.competition_pay_cup_fixture_prizes(p_fixture_id);
  PERFORM public.competition_cup_ensure_ready_fixtures(v_node.season_id, v_node.cup_code);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_cup_on_fixture_played(bigint) TO authenticated;

-- ---------------------------------------------------------------------------
-- Soft-wire month lock: after scheduling stage, auto-draw prestige cups
-- (redefines runner to call helper; if stage runner missing, helper still usable)
-- ---------------------------------------------------------------------------

DO $wire$
DECLARE
  v_src text;
  v_new text;
BEGIN
  -- Prefer 4-arg runner if present
  IF to_regprocedure('public.competition_run_month_lock_jobs(bigint, boolean, text, text)') IS NULL THEN
    RETURN;
  END IF;

  -- Idempotent: only inject once
  SELECT pg_get_functiondef(
    'public.competition_run_month_lock_jobs(bigint, boolean, text, text)'::regprocedure
  ) INTO v_src;

  IF v_src IS NULL THEN
    RETURN;
  END IF;

  IF position('competition_cup_auto_draw_prestige_cups' IN v_src) > 0 THEN
    RETURN;
  END IF;

  -- Insert a prestige auto-draw block just before RETURN v_out
  IF position('RETURN v_out;' IN v_src) = 0 THEN
    RETURN;
  END IF;

  v_new := replace(
    v_src,
    'RETURN v_out;',
    $blk$
  -- Prestige cups: ensure next-round fixtures exist after lock jobs
  BEGIN
    IF to_regprocedure('public.competition_cup_auto_draw_prestige_cups(bigint)') IS NOT NULL THEN
      v_out := v_out || jsonb_build_object(
        'prestige_cup_auto_draw',
        public.competition_cup_auto_draw_prestige_cups(p_season_id)
      );
    END IF;
  EXCEPTION WHEN OTHERS THEN
    v_out := v_out || jsonb_build_object(
      'prestige_cup_auto_draw',
      jsonb_build_object('ok', false, 'error', SQLERRM)
    );
  END;

  RETURN v_out;
$blk$
  );

  -- pg_get_functiondef returns CREATE OR REPLACE ... — execute it
  IF v_new IS DISTINCT FROM v_src THEN
    EXECUTE v_new;
  END IF;
EXCEPTION WHEN OTHERS THEN
  RAISE NOTICE 'Month-lock prestige auto-draw wire skipped: %', SQLERRM;
END;
$wire$;

-- ---------------------------------------------------------------------------
-- Heal current season now (safe; creates only missing ready fixtures)
-- ---------------------------------------------------------------------------

DO $heal$
DECLARE
  v_res jsonb;
BEGIN
  v_res := public.competition_cup_auto_draw_prestige_cups(NULL);
  RAISE NOTICE 'prestige_cup_auto_draw: %', v_res;
EXCEPTION WHEN OTHERS THEN
  RAISE NOTICE 'prestige_cup_auto_draw heal skipped: %', SQLERRM;
END;
$heal$;

NOTIFY pgrst, 'reload schema';
