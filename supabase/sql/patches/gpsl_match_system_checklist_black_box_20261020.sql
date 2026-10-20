-- =============================================================================
-- GPSL match system OFF (manual black-box): stop propose / checklist pressure
--
-- Both clubs OFF → fixture_is_manual_black_box(id). Those fixtures must not:
--   • appear in Dashboard "Arrange now" (owner_upcoming_arrangements)
--   • show Propose / Waiting-for-home schedule steps on matchday checklist
--   • accept fixture_schedule_propose / accept
--   • count as home-propose debt on season-ready checklist
--   • take arrangement late-fee tariffs (mutual forfeit at month lock instead)
--
-- Safe re-run. Requires gpsl_match_system_toggle_20261020.sql.
-- Inject needles are CRLF-normalized (Windows patch files).
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. Dashboard "Arrange now" — skip black-box
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.owner_upcoming_arrangements()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := upper(nullif(btrim(coalesce(public.my_club_shortname(), '')), ''));
  v_season bigint;
  v_out jsonb := '[]'::jsonb;
  r record;
  v_side text;
  v_state text;
  v_home_proposed boolean;
BEGIN
  IF v_club IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_club', 'fixtures', '[]'::jsonb);
  END IF;

  SELECT id INTO v_season
  FROM public.competition_seasons
  WHERE is_current = true
  ORDER BY id DESC
  LIMIT 1;

  IF v_season IS NULL THEN
    RETURN jsonb_build_object('ok', true, 'fixtures', '[]'::jsonb);
  END IF;

  FOR r IN
    SELECT
      f.id, f.gpsl_month, f.matchday, f.competition_type, f.cup_code, f.cup_round,
      f.home_club_short_name, f.away_club_short_name,
      cal.unlock_at,
      s.status AS sched_status,
      s.response_required_club_short_name AS reply_club,
      s.response_due_at
    FROM public.competition_fixtures f
    JOIN public.competition_season_calendar cal
      ON cal.season_id = f.season_id
     AND lower(btrim(cal.gpsl_month)) = lower(btrim(f.gpsl_month))
    LEFT JOIN public.competition_fixture_schedule s ON s.fixture_id = f.id
    WHERE f.season_id = v_season
      AND f.status = 'scheduled'
      AND coalesce(f.competition_type, 'league') IN ('league', 'cup')
      AND v_club IN (upper(btrim(f.home_club_short_name)), upper(btrim(f.away_club_short_name)))
      AND cal.unlock_at > now()
      AND cal.unlock_at <= now() + interval '15 days'
      AND coalesce(s.status, 'unscheduled') <> 'agreed'
      AND NOT public.competition_fixture_involves_vacant_club(f.id)
      AND NOT (
        to_regprocedure('public.fixture_is_manual_black_box(bigint)') IS NOT NULL
        AND public.fixture_is_manual_black_box(f.id)
      )
    ORDER BY cal.unlock_at, f.competition_type DESC, f.matchday, f.cup_round, f.id
  LOOP
    v_side := CASE WHEN upper(btrim(r.home_club_short_name)) = v_club THEN 'home' ELSE 'away' END;
    BEGIN
      v_home_proposed := public.match_schedule_home_has_proposed(r.id, now());
    EXCEPTION WHEN OTHERS THEN
      v_home_proposed := coalesce(r.sched_status, 'unscheduled') <> 'unscheduled';
    END;

    v_state := CASE
      WHEN coalesce(r.sched_status, 'unscheduled') = 'negotiating'
           AND upper(btrim(coalesce(r.reply_club, ''))) = v_club THEN 'reply'
      WHEN coalesce(r.sched_status, 'unscheduled') = 'negotiating' THEN 'waiting'
      WHEN v_side = 'home' AND NOT v_home_proposed THEN 'propose'
      ELSE 'waiting_home'
    END;

    v_out := v_out || jsonb_build_array(jsonb_build_object(
      'fixture_id', r.id,
      'side', v_side,
      'opponent_short_name', CASE WHEN v_side = 'home'
        THEN upper(btrim(r.away_club_short_name)) ELSE upper(btrim(r.home_club_short_name)) END,
      'gpsl_month', r.gpsl_month,
      'matchday', r.matchday,
      'competition_type', r.competition_type,
      'cup_code', r.cup_code,
      'cup_round', r.cup_round,
      'propose_by', r.unlock_at,
      'late_fee_from', r.unlock_at - interval '48 hours',
      'response_due_at', r.response_due_at,
      'state', v_state
    ));
  END LOOP;

  RETURN jsonb_build_object('ok', true, 'club_short_name', v_club, 'fixtures', v_out);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.owner_upcoming_arrangements() TO authenticated;

-- ---------------------------------------------------------------------------
-- 2–6. Inject black-box gates into live functions (CRLF-normalized needles)
-- ---------------------------------------------------------------------------

DO $inject_checklist_bb$
DECLARE
  v_def text;
  v_old text;
  v_new text;
BEGIN
  IF to_regprocedure('public.matchday_checklist_for_club(text,boolean)') IS NULL THEN
    RAISE NOTICE 'matchday_checklist_for_club missing';
    RETURN;
  END IF;

  v_old := replace($n$    -- 1. Kick-off agreed
    IF v_played OR (v_sch_found AND v_sch.status = 'agreed') THEN
      v_step := jsonb_build_object('key', 'schedule', 'label', 'Kick-off agreed', 'state', 'done',
        'due_at', CASE WHEN v_sch_found THEN v_sch.agreed_kickoff_at END);
    ELSIF v_sch_found AND v_sch.status = 'negotiating' THEN
$n$, E'\r\n', E'\n');

  v_new := replace($n$    -- 1. Kick-off agreed
    IF v_played OR (v_sch_found AND v_sch.status = 'agreed') THEN
      v_step := jsonb_build_object('key', 'schedule', 'label', 'Kick-off agreed', 'state', 'done',
        'due_at', CASE WHEN v_sch_found THEN v_sch.agreed_kickoff_at END);
    ELSIF to_regprocedure('public.fixture_is_manual_black_box(bigint)') IS NOT NULL
          AND public.fixture_is_manual_black_box(r.id) THEN
      v_step := jsonb_build_object(
        'key', 'schedule',
        'label', 'Manual arrange (GPSL off)',
        'state', 'na',
        'href', v_matchday_href
      );
    ELSIF v_sch_found AND v_sch.status = 'negotiating' THEN
$n$, E'\r\n', E'\n');

  SELECT replace(pg_get_functiondef('public.matchday_checklist_for_club(text,boolean)'::regprocedure), E'\r\n', E'\n')
    INTO v_def;

  IF position('Manual arrange (GPSL off)' IN v_def) > 0 THEN
    RAISE NOTICE 'checklist already BB-aware';
    RETURN;
  END IF;
  IF position(v_old IN v_def) = 0 THEN
    RAISE WARNING 'checklist schedule needle not found — BB skip NOT applied';
    RETURN;
  END IF;
  EXECUTE replace(v_def, v_old, v_new);
  RAISE NOTICE 'checklist BB schedule step applied';
END;
$inject_checklist_bb$;

DO $inject_propose_bb$
DECLARE
  v_oid oid;
  v_src text;
  v_needle text;
  v_insert text;
BEGIN
  v_needle := replace($n$  IF to_regprocedure('public.club_assert_has_manager_for_matches(text)') IS NOT NULL THEN
    PERFORM public.club_assert_has_manager_for_matches(v_club);
  END IF;$n$, E'\r\n', E'\n');

  v_insert := replace($n$  IF to_regprocedure('public.club_assert_has_manager_for_matches(text)') IS NOT NULL THEN
    PERFORM public.club_assert_has_manager_for_matches(v_club);
  END IF;

  IF to_regprocedure('public.fixture_is_manual_black_box(bigint)') IS NOT NULL
     AND public.fixture_is_manual_black_box(p_fixture_id) THEN
    RAISE EXCEPTION 'Both clubs have GPSL match system OFF — arrange this fixture off-site (no in-app propose).';
  END IF;$n$, E'\r\n', E'\n');

  SELECT p.oid INTO v_oid
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'fixture_schedule_propose'
  ORDER BY p.oid DESC LIMIT 1;

  IF v_oid IS NULL THEN
    RAISE WARNING 'fixture_schedule_propose missing';
    RETURN;
  END IF;

  v_src := replace(pg_get_functiondef(v_oid), E'\r\n', E'\n');
  IF position('Both clubs have GPSL match system OFF' IN v_src) > 0 THEN
    RAISE NOTICE 'propose already BB-guarded';
    RETURN;
  END IF;
  IF position(v_needle IN v_src) = 0 THEN
    RAISE WARNING 'propose manager needle not found — BB guard NOT applied';
    RETURN;
  END IF;
  EXECUTE replace(v_src, v_needle, v_insert);
  RAISE NOTICE 'propose BB guard applied';
END;
$inject_propose_bb$;

DO $inject_accept_bb$
DECLARE
  v_oid oid;
  v_src text;
  v_needle text;
  v_insert text;
BEGIN
  v_needle := replace($n$  IF to_regprocedure('public.club_assert_has_manager_for_matches(text)') IS NOT NULL THEN
    PERFORM public.club_assert_has_manager_for_matches(v_club);
  END IF;$n$, E'\r\n', E'\n');

  v_insert := replace($n$  IF to_regprocedure('public.club_assert_has_manager_for_matches(text)') IS NOT NULL THEN
    PERFORM public.club_assert_has_manager_for_matches(v_club);
  END IF;

  IF to_regprocedure('public.fixture_is_manual_black_box(bigint)') IS NOT NULL
     AND EXISTS (
       SELECT 1
       FROM public.competition_fixture_schedule_proposal p
       WHERE p.id = p_proposal_id
         AND public.fixture_is_manual_black_box(p.fixture_id)
     ) THEN
    RAISE EXCEPTION 'Both clubs have GPSL match system OFF — arrange this fixture off-site (no in-app accept).';
  END IF;$n$, E'\r\n', E'\n');

  SELECT p.oid INTO v_oid
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'fixture_schedule_accept'
  ORDER BY p.oid DESC LIMIT 1;

  IF v_oid IS NULL THEN
    RAISE WARNING 'fixture_schedule_accept missing';
    RETURN;
  END IF;

  v_src := replace(pg_get_functiondef(v_oid), E'\r\n', E'\n');
  IF position('Both clubs have GPSL match system OFF' IN v_src) > 0 THEN
    RAISE NOTICE 'accept already BB-guarded';
    RETURN;
  END IF;
  IF position(v_needle IN v_src) = 0 THEN
    RAISE WARNING 'accept manager needle not found — BB guard NOT applied';
    RETURN;
  END IF;
  EXECUTE replace(v_src, v_needle, v_insert);
  RAISE NOTICE 'accept BB guard applied';
END;
$inject_accept_bb$;

DO $inject_ctx_bb$
DECLARE
  v_def text;
  v_old text;
  v_new text;
BEGIN
  IF to_regprocedure('public.match_schedule_fixture_context(bigint)') IS NULL THEN
    RAISE NOTICE 'match_schedule_fixture_context missing';
    RETURN;
  END IF;

  v_old := replace($n$'can_propose_first', (v_role = 'home' AND v_status = 'unscheduled' AND v_fixture.status = 'scheduled' AND v_has_mgr),
    'can_respond', (v_pending.id IS NOT NULL AND v_pending.proposed_by_club_short_name <> v_club AND v_status = 'negotiating' AND v_has_mgr),$n$, E'\r\n', E'\n');

  v_new := replace($n$'manual_black_box', (
      to_regprocedure('public.fixture_is_manual_black_box(bigint)') IS NOT NULL
      AND public.fixture_is_manual_black_box(p_fixture_id)
    ),
    'can_propose_first', (
      v_role = 'home' AND v_status = 'unscheduled' AND v_fixture.status = 'scheduled' AND v_has_mgr
      AND NOT (
        to_regprocedure('public.fixture_is_manual_black_box(bigint)') IS NOT NULL
        AND public.fixture_is_manual_black_box(p_fixture_id)
      )
    ),
    'can_respond', (
      v_pending.id IS NOT NULL AND v_pending.proposed_by_club_short_name <> v_club
      AND v_status = 'negotiating' AND v_has_mgr
      AND NOT (
        to_regprocedure('public.fixture_is_manual_black_box(bigint)') IS NOT NULL
        AND public.fixture_is_manual_black_box(p_fixture_id)
      )
    ),$n$, E'\r\n', E'\n');

  SELECT replace(pg_get_functiondef('public.match_schedule_fixture_context(bigint)'::regprocedure), E'\r\n', E'\n')
    INTO v_def;

  IF position('''manual_black_box''' IN v_def) > 0
     AND position('fixture_is_manual_black_box(p_fixture_id)' IN
       substring(v_def from position('''can_propose_first''' IN v_def) for 500)) > 0 THEN
    RAISE NOTICE 'context already BB-aware';
    RETURN;
  END IF;
  IF position(v_old IN v_def) = 0 THEN
    RAISE WARNING 'context can_propose needle not found — BB flags NOT applied';
    RETURN;
  END IF;
  EXECUTE replace(v_def, v_old, v_new);
  RAISE NOTICE 'context BB flags applied';
END;
$inject_ctx_bb$;

DO $inject_fines_bb$
DECLARE
  v_def text;
  v_old text;
  v_new text;
BEGIN
  IF to_regprocedure('public.competition_enforce_scheduling_arrangement_fines(bigint,text)') IS NULL THEN
    RAISE NOTICE 'arrangement fines missing';
    RETURN;
  END IF;

  v_old := replace($n$    IF EXISTS (
      SELECT 1 FROM public.competition_fixture_schedule s
      WHERE s.fixture_id = v_f.id AND s.status = 'agreed'
    ) THEN
      v_skipped := v_skipped + 1;
      CONTINUE;
    END IF;
$n$, E'\r\n', E'\n');

  v_new := replace($n$    IF EXISTS (
      SELECT 1 FROM public.competition_fixture_schedule s
      WHERE s.fixture_id = v_f.id AND s.status = 'agreed'
    ) THEN
      v_skipped := v_skipped + 1;
      CONTINUE;
    END IF;

    IF to_regprocedure('public.fixture_is_manual_black_box(bigint)') IS NOT NULL
       AND public.fixture_is_manual_black_box(v_f.id) THEN
      v_skipped := v_skipped + 1;
      CONTINUE;
    END IF;
$n$, E'\r\n', E'\n');

  SELECT replace(
    pg_get_functiondef('public.competition_enforce_scheduling_arrangement_fines(bigint,text)'::regprocedure),
    E'\r\n', E'\n'
  ) INTO v_def;

  IF position('fixture_is_manual_black_box(v_f.id)' IN v_def) > 0 THEN
    RAISE NOTICE 'fines already skip BB';
    RETURN;
  END IF;
  IF position(v_old IN v_def) = 0 THEN
    RAISE WARNING 'fines agreed-skip needle not found — BB skip NOT applied';
    RETURN;
  END IF;
  EXECUTE replace(v_def, v_old, v_new);
  RAISE NOTICE 'fines BB skip applied';
END;
$inject_fines_bb$;

DO $inject_ready_bb$
DECLARE
  v_def text;
  v_old text;
  v_new text;
BEGIN
  IF to_regprocedure('public.gpsl_owner_ready_items(text,bigint)') IS NULL THEN
    RAISE NOTICE 'gpsl_owner_ready_items missing';
    RETURN;
  END IF;

  v_old := replace($n$    IF coalesce(r.sched_status, 'unscheduled') = 'agreed' THEN
      v_proposed := true;
    ELSE
      BEGIN
        v_proposed := public.match_schedule_home_has_proposed(r.id, now());
      EXCEPTION WHEN OTHERS THEN
        v_proposed := coalesce(r.sched_status, 'unscheduled') <> 'unscheduled';
      END;
    END IF;
$n$, E'\r\n', E'\n');

  v_new := replace($n$    IF coalesce(r.sched_status, 'unscheduled') = 'agreed' THEN
      v_proposed := true;
    ELSIF to_regprocedure('public.fixture_is_manual_black_box(bigint)') IS NOT NULL
          AND public.fixture_is_manual_black_box(r.id) THEN
      v_proposed := true;
    ELSE
      BEGIN
        v_proposed := public.match_schedule_home_has_proposed(r.id, now());
      EXCEPTION WHEN OTHERS THEN
        v_proposed := coalesce(r.sched_status, 'unscheduled') <> 'unscheduled';
      END;
    END IF;
$n$, E'\r\n', E'\n');

  SELECT replace(pg_get_functiondef('public.gpsl_owner_ready_items(text,bigint)'::regprocedure), E'\r\n', E'\n')
    INTO v_def;

  IF position('fixture_is_manual_black_box(r.id)' IN v_def) > 0 THEN
    RAISE NOTICE 'ready propose already BB-aware';
  ELSIF position(v_old IN v_def) = 0 THEN
    RAISE WARNING 'ready propose needle not found — BB skip NOT applied';
  ELSE
    EXECUTE replace(v_def, v_old, v_new);
    RAISE NOTICE 'ready propose BB applied';
  END IF;

  SELECT replace(pg_get_functiondef('public.gpsl_owner_ready_items(text,bigint)'::regprocedure), E'\r\n', E'\n')
    INTO v_def;

  v_old := replace($n$  SELECT count(*)::int INTO v_replies
  FROM public.competition_fixtures f
  JOIN public.competition_fixture_schedule s ON s.fixture_id = f.id
  WHERE f.season_id = p_season
    AND f.status = 'scheduled'
    AND s.status = 'negotiating'
    AND upper(btrim(coalesce(s.response_required_club_short_name, ''))) = v_club;
$n$, E'\r\n', E'\n');

  v_new := replace($n$  SELECT count(*)::int INTO v_replies
  FROM public.competition_fixtures f
  JOIN public.competition_fixture_schedule s ON s.fixture_id = f.id
  WHERE f.season_id = p_season
    AND f.status = 'scheduled'
    AND s.status = 'negotiating'
    AND upper(btrim(coalesce(s.response_required_club_short_name, ''))) = v_club
    AND NOT (
      to_regprocedure('public.fixture_is_manual_black_box(bigint)') IS NOT NULL
      AND public.fixture_is_manual_black_box(f.id)
    );
$n$, E'\r\n', E'\n');

  IF position('INTO v_replies' IN v_def) > 0
     AND position('fixture_is_manual_black_box(f.id)' IN
       substring(v_def from position('INTO v_replies' IN v_def) for 700)) > 0 THEN
    RAISE NOTICE 'ready replies already BB-aware';
    RETURN;
  END IF;
  IF position(v_old IN v_def) = 0 THEN
    RAISE WARNING 'ready replies needle not found — BB skip NOT applied';
    RETURN;
  END IF;
  EXECUTE replace(v_def, v_old, v_new);
  RAISE NOTICE 'ready replies BB applied';
END;
$inject_ready_bb$;

NOTIFY pgrst, 'reload schema';
