-- =============================================================================
-- Cup: retract next-round advancement when a fixture result is cleared
-- 2026-10-29
--
-- Bug: admin_fixture_reset_for_replay wiped the result but left
-- competition_cup_bracket_nodes.winner_club_short_name and the child-round
-- home/away (and fixture) still showing the old winner — e.g. Shield draw.
--
-- Fix:
--   1) competition_cup_retract_advancement_for_fixture(fixture_id)
--   2) Call it from admin_fixture_reset_for_replay
--   3) Heal any current-season stale advancements (winner set, fixture unplayed)
--
-- Safe re-run / idempotent.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.competition_cup_retract_advancement_for_fixture(
  p_fixture_id bigint
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_f public.competition_fixtures%ROWTYPE;
  v_node public.competition_cup_bracket_nodes%ROWTYPE;
  v_child public.competition_cup_bracket_nodes%ROWTYPE;
  v_cf public.competition_fixtures%ROWTYPE;
  v_winner text;
  v_cleared_slot text;
  v_child_fixture_removed boolean := false;
  v_nodes int := 0;
BEGIN
  IF p_fixture_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'fixture_id required');
  END IF;

  SELECT * INTO v_f FROM public.competition_fixtures WHERE id = p_fixture_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'fixture_not_found');
  END IF;

  IF v_f.competition_type IS DISTINCT FROM 'cup' THEN
    RETURN jsonb_build_object('ok', true, 'skipped', 'not_cup');
  END IF;

  -- Clear pens on this fixture (result already wiped by caller, or we do it)
  BEGIN
    UPDATE public.competition_fixtures
    SET cup_pen_winner_club_short_name = NULL
    WHERE id = p_fixture_id
      AND cup_pen_winner_club_short_name IS NOT NULL;
  EXCEPTION WHEN undefined_column THEN
    NULL;
  END;

  -- Node(s) that use this fixture (1-leg, or the linked leg)
  FOR v_node IN
    SELECT n.*
    FROM public.competition_cup_bracket_nodes n
    WHERE n.fixture_id = p_fixture_id
  LOOP
    v_nodes := v_nodes + 1;
    v_winner := nullif(btrim(coalesce(v_node.winner_club_short_name, '')), '');

    -- Clear this tie's winner
    UPDATE public.competition_cup_bracket_nodes
    SET winner_club_short_name = NULL,
        both_eliminated = false
    WHERE id = v_node.id;

    IF v_winner IS NULL OR v_node.child_node_id IS NULL OR v_node.child_slot IS NULL THEN
      CONTINUE;
    END IF;

    SELECT * INTO v_child
    FROM public.competition_cup_bracket_nodes
    WHERE id = v_node.child_node_id;

    IF NOT FOUND THEN
      CONTINUE;
    END IF;

    -- Block if next round already finished
    IF v_child.winner_club_short_name IS NOT NULL THEN
      RAISE EXCEPTION
        'Cannot retract cup advancement for fixture % — next-round node % already has winner %. Re-clear that tie first.',
        p_fixture_id, v_child.id, v_child.winner_club_short_name;
    END IF;

    IF v_child.fixture_id IS NOT NULL THEN
      SELECT * INTO v_cf FROM public.competition_fixtures WHERE id = v_child.fixture_id;
      IF FOUND AND v_cf.status = 'played'
         AND v_cf.home_goals IS NOT NULL AND v_cf.away_goals IS NOT NULL THEN
        RAISE EXCEPTION
          'Cannot retract cup advancement for fixture % — next-round fixture % is already played.',
          p_fixture_id, v_child.fixture_id;
      END IF;
    END IF;

    -- Pull the advanced club out of the child slot
    IF v_node.child_slot = 'home'
       AND upper(btrim(coalesce(v_child.home_club_short_name, ''))) = upper(v_winner) THEN
      UPDATE public.competition_cup_bracket_nodes
      SET home_club_short_name = NULL
      WHERE id = v_child.id;
      v_cleared_slot := 'home';
    ELSIF v_node.child_slot = 'away'
       AND upper(btrim(coalesce(v_child.away_club_short_name, ''))) = upper(v_winner) THEN
      UPDATE public.competition_cup_bracket_nodes
      SET away_club_short_name = NULL
      WHERE id = v_child.id;
      v_cleared_slot := 'away';
    END IF;

    -- Next-round fixture is incomplete once a feeder is pulled — remove if unplayed
    SELECT * INTO v_child
    FROM public.competition_cup_bracket_nodes
    WHERE id = v_node.child_node_id;

    IF v_child.fixture_id IS NOT NULL
       AND (v_child.home_club_short_name IS NULL OR v_child.away_club_short_name IS NULL) THEN
      SELECT * INTO v_cf FROM public.competition_fixtures WHERE id = v_child.fixture_id;
      IF FOUND AND coalesce(v_cf.status, '') IS DISTINCT FROM 'played' THEN
        DELETE FROM public.competition_fixture_schedule_proposal WHERE fixture_id = v_cf.id;
        DELETE FROM public.competition_fixture_checkin WHERE fixture_id = v_cf.id;
        DELETE FROM public.competition_fixture_schedule WHERE fixture_id = v_cf.id;
        DELETE FROM public.competition_result_submissions WHERE fixture_id = v_cf.id;
        BEGIN
          DELETE FROM public.fixture_match_video_pending WHERE fixture_id = v_cf.id;
          DELETE FROM public.fixture_match_videos WHERE fixture_id = v_cf.id;
        EXCEPTION WHEN undefined_table THEN
          NULL;
        END;
        UPDATE public.competition_cup_bracket_nodes
        SET fixture_id = NULL
        WHERE id = v_child.id;
        DELETE FROM public.competition_fixtures WHERE id = v_cf.id;
        v_child_fixture_removed := true;
      END IF;
    ELSIF v_child.fixture_id IS NOT NULL
          AND v_child.home_club_short_name IS NOT NULL
          AND v_child.away_club_short_name IS NOT NULL THEN
      -- Both sides still filled (unusual after retract) — sync fixture clubs
      UPDATE public.competition_fixtures f
      SET home_club_short_name = v_child.home_club_short_name,
          away_club_short_name = v_child.away_club_short_name
      WHERE f.id = v_child.fixture_id
        AND coalesce(f.status, '') IS DISTINCT FROM 'played';
    END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true,
    'fixture_id', p_fixture_id,
    'cup_code', v_f.cup_code,
    'nodes_cleared', v_nodes,
    'cleared_child_slot', v_cleared_slot,
    'child_fixture_removed', v_child_fixture_removed
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.competition_cup_retract_advancement_for_fixture(bigint)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.competition_cup_retract_advancement_for_fixture(bigint)
  TO authenticated, service_role;

COMMENT ON FUNCTION public.competition_cup_retract_advancement_for_fixture(bigint) IS
  'Clear cup node winner and pull club out of next-round slot after a result is wiped. Removes unplayed next-round fixture if a feeder slot becomes empty.';

-- Heal helper: any node with a winner but no played fixture
CREATE OR REPLACE FUNCTION public.admin_cup_retract_stale_advancements(
  p_cup_code text DEFAULT NULL,
  p_dry_run boolean DEFAULT true
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  r record;
  v_res jsonb;
  v_n int := 0;
  v_details jsonb := '[]'::jsonb;
  v_cup text := nullif(lower(btrim(coalesce(p_cup_code, ''))), '');
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  FOR r IN
    SELECT n.id AS node_id, n.fixture_id, n.cup_code, n.winner_club_short_name,
           n.round_no, n.match_no, n.child_node_id, n.child_slot
    FROM public.competition_cup_bracket_nodes n
    JOIN public.competition_seasons s ON s.id = n.season_id AND s.is_current
    LEFT JOIN public.competition_fixtures f ON f.id = n.fixture_id
    WHERE n.winner_club_short_name IS NOT NULL
      AND n.fixture_id IS NOT NULL
      AND (v_cup IS NULL OR lower(btrim(n.cup_code)) = v_cup)
      AND (
        f.status IS DISTINCT FROM 'played'
        OR f.home_goals IS NULL
        OR f.away_goals IS NULL
      )
    ORDER BY n.cup_code, n.round_no, n.match_no
  LOOP
    v_n := v_n + 1;
    IF p_dry_run THEN
      v_details := v_details || jsonb_build_array(jsonb_build_object(
        'node_id', r.node_id,
        'fixture_id', r.fixture_id,
        'cup_code', r.cup_code,
        'winner', r.winner_club_short_name,
        'round_no', r.round_no,
        'match_no', r.match_no,
        'child_node_id', r.child_node_id,
        'child_slot', r.child_slot
      ));
    ELSE
      v_res := public.competition_cup_retract_advancement_for_fixture(r.fixture_id);
      v_details := v_details || jsonb_build_array(v_res);
    END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true,
    'dry_run', p_dry_run,
    'cup_code', v_cup,
    'count', v_n,
    'details', v_details
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.admin_cup_retract_stale_advancements(text, boolean)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_cup_retract_stale_advancements(text, boolean)
  TO authenticated;

-- Wire into fixture reset (before RETURN)
DO $wire$
DECLARE
  v_def text;
  v_oid oid;
  v_marker text := 'competition_cup_retract_advancement_for_fixture';
  v_old text;
  v_new text;
BEGIN
  v_oid := to_regprocedure('public.admin_fixture_reset_for_replay(bigint,text,text)');
  IF v_oid IS NULL THEN
    RAISE WARNING 'admin_fixture_reset_for_replay missing — cup retract not wired into reset';
    RETURN;
  END IF;

  SELECT pg_get_functiondef(v_oid) INTO v_def;
  IF position(v_marker IN v_def) > 0 THEN
    RAISE NOTICE 'Cup retract already wired into fixture reset';
    RETURN;
  END IF;

  v_new :=
    E'  -- Cup: pull winner out of next-round draw after result wipe\n'
    || E'  DECLARE\n'
    || E'    v_cup_retract jsonb;\n'
    || E'  BEGIN\n'
    || E'    NULL;\n'
    || E'  END;\n';

  -- Prefer a simple insert before v_after := preview / RETURN
  -- Use DECLARE-free block:
  v_new :=
    E'  -- Cup: retract next-round advancement after clearing a cup result\n'
    || E'  IF to_regprocedure(''public.competition_cup_retract_advancement_for_fixture(bigint)'') IS NOT NULL THEN\n'
    || E'    BEGIN\n'
    || E'      PERFORM public.competition_cup_retract_advancement_for_fixture(v_fid);\n'
    || E'    EXCEPTION WHEN OTHERS THEN\n'
    || E'      RAISE EXCEPTION ''Fixture reset OK but cup retract failed: %'', SQLERRM;\n'
    || E'    END;\n'
    || E'  END IF;\n'
    || E'\n'
    || E'  v_after := public.admin_fixture_reset_preview(v_fid);';

  IF position(E'  v_after := public.admin_fixture_reset_preview(v_fid);' IN v_def) > 0 THEN
    v_old := E'  v_after := public.admin_fixture_reset_preview(v_fid);';
    EXECUTE replace(v_def, v_old, v_new);
    RAISE NOTICE 'Wired cup retract into admin_fixture_reset_for_replay';
  ELSE
    RAISE WARNING 'Could not locate v_after := preview in fixture reset — wire manually';
  END IF;
EXCEPTION
  WHEN OTHERS THEN
    RAISE WARNING 'Cup retract wire into reset failed: %', SQLERRM;
END;
$wire$;

NOTIFY pgrst, 'reload schema';

-- Dry-run then apply heal for Shield (and report)
SELECT public.admin_cup_retract_stale_advancements('shield', true) AS shield_stale_dry_run;
SELECT public.admin_cup_retract_stale_advancements('shield', false) AS shield_stale_applied;
