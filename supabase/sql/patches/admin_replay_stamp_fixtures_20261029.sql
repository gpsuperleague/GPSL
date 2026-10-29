-- =============================================================================
-- Admin reset for replay: stamp fixtures so Fixtures kick-off can show
-- "Catch-up / replay" even before the play month has locked.
--
-- is_catch_up stays calendar-only (month closed). is_admin_replay is separate
-- UI signal; cleared automatically when the fixture is played again.
--
-- Also backfills Champ A MD1 CRI vs BES (9338).
-- Safe re-run.
-- =============================================================================

ALTER TABLE public.competition_fixtures
  ADD COLUMN IF NOT EXISTS admin_replay_reset_at timestamptz;

COMMENT ON COLUMN public.competition_fixtures.admin_replay_reset_at IS
  'Set by admin_fixture_reset_for_replay; cleared when status becomes played.';

CREATE OR REPLACE FUNCTION public.competition_fixtures_clear_admin_replay_on_played()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NEW.status = 'played'
     AND OLD.status IS DISTINCT FROM 'played' THEN
    NEW.admin_replay_reset_at := NULL;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_competition_fixtures_clear_admin_replay
  ON public.competition_fixtures;

CREATE TRIGGER trg_competition_fixtures_clear_admin_replay
  BEFORE UPDATE OF status ON public.competition_fixtures
  FOR EACH ROW
  EXECUTE FUNCTION public.competition_fixtures_clear_admin_replay_on_played();

-- Stamp on admin wipe (full body keeps prior v_row / season_id fixes)
CREATE OR REPLACE FUNCTION public.admin_fixture_reset_for_replay(
  p_fixture_id bigint,
  p_reason text DEFAULT NULL,
  p_confirm_phrase text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_fid bigint := p_fixture_id;
  v_f public.competition_fixtures%ROWTYPE;
  v_home text;
  v_away text;
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
  v_note text;
  v_video jsonb;
  v_ledger record;
  v_n int := 0;
  v_stats int := 0;
  v_subs int := 0;
  v_ledger_n int := 0;
  v_susp int := 0;
  v_inj int := 0;
  v_inj_restored int := 0;
  v_fit_home jsonb;
  v_fit_away jsonb;
  v_before jsonb;
  v_after jsonb;
  v_preserve jsonb := '[]'::jsonb;
  v_elem jsonb;
  v_phase text;
BEGIN
  IF NOT public.is_gpsl_admin()
     AND current_user NOT IN ('postgres', 'supabase_admin', 'service_role') THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF coalesce(btrim(p_confirm_phrase), '') <> 'RESET FIXTURE REPLAY' THEN
    RAISE EXCEPTION 'Confirmation phrase required — type exactly: RESET FIXTURE REPLAY';
  END IF;

  IF v_fid IS NULL THEN
    RAISE EXCEPTION 'fixture_id required';
  END IF;

  SELECT * INTO v_f
  FROM public.competition_fixtures
  WHERE id = v_fid;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Fixture % not found', v_fid;
  END IF;

  v_home := upper(btrim(v_f.home_club_short_name));
  v_away := upper(btrim(v_f.away_club_short_name));
  v_reason := coalesce(v_reason, 'Admin reset for replay');
  v_note := format(
    'Admin fixture reset for replay (%s) %s',
    v_reason,
    to_char(now() AT TIME ZONE 'Europe/London', 'YYYY-MM-DD HH24:MI')
  );

  v_before := public.admin_fixture_reset_preview(v_fid);

  IF to_regprocedure('public.match_video_admin_clear(bigint, text)') IS NOT NULL THEN
    v_video := public.match_video_admin_clear(v_fid, NULL);
  END IF;
  DELETE FROM public.fixture_match_video_pending WHERE fixture_id = v_fid;
  DELETE FROM public.fixture_match_videos WHERE fixture_id = v_fid;

  IF to_regclass('public.match_video_breach_reports') IS NOT NULL THEN
    UPDATE public.match_video_breach_reports
    SET review_note = trim(both E'\n' from coalesce(review_note, '') || E'\n' || v_note)
    WHERE fixture_id = v_fid;
  END IF;

  DELETE FROM public.competition_finance_ledger
  WHERE fixture_id = v_fid
    AND entry_type = 'gate_match_video';
  GET DIAGNOSTICS v_n = ROW_COUNT;
  v_ledger_n := v_ledger_n + v_n;

  FOR v_ledger IN
    SELECT id, club_short_name, amount
    FROM public.competition_finance_ledger
    WHERE fixture_id = v_fid
  LOOP
    IF to_regprocedure('public.competition_credit_club_balance(text, numeric)') IS NOT NULL THEN
      PERFORM public.competition_credit_club_balance(
        v_ledger.club_short_name,
        -coalesce(v_ledger.amount, 0)
      );
    END IF;
    DELETE FROM public.competition_finance_ledger WHERE id = v_ledger.id;
    v_ledger_n := v_ledger_n + 1;
  END LOOP;

  IF to_regclass('public.competition_match_player_stats') IS NOT NULL THEN
    DELETE FROM public.competition_match_player_stats WHERE fixture_id = v_fid;
    GET DIAGNOSTICS v_stats = ROW_COUNT;
  END IF;

  IF to_regclass('public.competition_result_submissions') IS NOT NULL THEN
    DELETE FROM public.competition_result_submissions WHERE fixture_id = v_fid;
    GET DIAGNOSTICS v_subs = ROW_COUNT;
  END IF;

  IF to_regclass('public.competition_player_injury_fixtures') IS NOT NULL THEN
    SELECT coalesce(jsonb_agg(jsonb_build_object(
             'injury_id', iff.injury_id,
             'phase', iff.phase,
             'served', iff.served
           )), '[]'::jsonb)
    INTO v_preserve
    FROM public.competition_player_injury_fixtures iff
    JOIN public.competition_player_injuries i ON i.id = iff.injury_id
    WHERE iff.fixture_id = v_fid
      AND i.source_fixture_id IS DISTINCT FROM v_fid;
  END IF;

  IF to_regclass('public.competition_player_suspension_matches') IS NOT NULL THEN
    DELETE FROM public.competition_player_suspension_matches
    WHERE fixture_id = v_fid;
  END IF;
  IF to_regclass('public.competition_player_suspensions') IS NOT NULL THEN
    DELETE FROM public.competition_player_suspensions
    WHERE source_fixture_id = v_fid;
    GET DIAGNOSTICS v_susp = ROW_COUNT;
  END IF;

  IF to_regclass('public.competition_player_injury_fixtures') IS NOT NULL THEN
    DELETE FROM public.competition_player_injury_fixtures
    WHERE fixture_id = v_fid;
  END IF;
  IF to_regclass('public.competition_player_injuries') IS NOT NULL THEN
    UPDATE public.competition_player_injuries i
    SET status = 'cancelled'
    WHERE i.source_fixture_id = v_fid
      AND i.status = 'active';
    GET DIAGNOSTICS v_inj = ROW_COUNT;
  END IF;

  IF to_regprocedure('public.competition_resync_pending_suspensions(bigint, text)') IS NOT NULL THEN
    PERFORM public.competition_resync_pending_suspensions(v_f.season_id, v_home);
    PERFORM public.competition_resync_pending_suspensions(v_f.season_id, v_away);
  END IF;

  IF to_regclass('public.competition_fixture_match_fitness_tick') IS NOT NULL THEN
    DELETE FROM public.competition_fixture_match_fitness_tick
    WHERE fixture_id = v_fid;
  END IF;

  UPDATE public.competition_fixtures
  SET
    status = 'scheduled',
    home_goals = NULL,
    away_goals = NULL,
    is_forfeit = false,
    forfeit_loser_club = NULL,
    is_void = false,
    admin_replay_reset_at = now()
  WHERE id = v_fid;

  DELETE FROM public.competition_fixture_schedule_proposal WHERE fixture_id = v_fid;
  DELETE FROM public.competition_fixture_checkin WHERE fixture_id = v_fid;

  UPDATE public.competition_fixture_schedule
  SET
    status = 'unscheduled',
    agreed_kickoff_at = NULL,
    pending_proposal_id = NULL,
    response_due_at = NULL,
    response_required_club_short_name = NULL,
    response_miss_count = 0,
    no_show_club_short_name = NULL,
    no_show_kickoff_at = NULL,
    home_proposal_count = 0,
    away_proposal_count = 0,
    discord_hint_shown = false,
    mutual_override_used = false,
    updated_at = now()
  WHERE fixture_id = v_fid;

  IF NOT FOUND THEN
    INSERT INTO public.competition_fixture_schedule (fixture_id, season_id, status)
    VALUES (v_fid, v_f.season_id, 'unscheduled')
    ON CONFLICT (fixture_id) DO UPDATE
    SET status = 'unscheduled',
        agreed_kickoff_at = NULL,
        pending_proposal_id = NULL,
        home_proposal_count = 0,
        away_proposal_count = 0,
        updated_at = now();
  END IF;

  IF to_regclass('public.competition_player_injury_fixtures') IS NOT NULL THEN
    FOR v_elem IN
      SELECT value
      FROM jsonb_array_elements(coalesce(v_preserve, '[]'::jsonb))
    LOOP
      v_phase := lower(coalesce(v_elem->>'phase', 'out'));

      IF coalesce((v_elem->>'served')::boolean, false)
         AND to_regprocedure(
               'public.competition_injury_undo_absence_serve(bigint,text)'
             ) IS NOT NULL THEN
        PERFORM public.competition_injury_undo_absence_serve(
          (v_elem->>'injury_id')::bigint,
          v_phase
        );
      END IF;

      IF EXISTS (
        SELECT 1
        FROM public.competition_player_injuries i
        WHERE i.id = (v_elem->>'injury_id')::bigint
          AND i.status = 'active'
          AND (
            coalesce(i.matches_out_remaining, 0) > 0
            OR coalesce(i.recovery_remaining, 0) > 0
          )
      ) THEN
        INSERT INTO public.competition_player_injury_fixtures (
          injury_id, fixture_id, phase, served
        )
        VALUES (
          (v_elem->>'injury_id')::bigint,
          v_fid,
          v_phase,
          false
        )
        ON CONFLICT (injury_id, fixture_id) DO UPDATE
          SET phase = EXCLUDED.phase,
              served = false;
        v_inj_restored := v_inj_restored + 1;
      END IF;
    END LOOP;
  END IF;

  IF to_regprocedure('public.competition_resync_pending_injuries(bigint, text)') IS NOT NULL THEN
    PERFORM public.competition_resync_pending_injuries(v_f.season_id, v_home);
    PERFORM public.competition_resync_pending_injuries(v_f.season_id, v_away);
  END IF;

  UPDATE public.competition_inbox
  SET archived_at = coalesce(archived_at, now()),
      read_at = coalesce(read_at, now())
  WHERE fixture_id = v_fid
    AND archived_at IS NULL
    AND message_type IN (
      'match_time_proposed',
      'match_time_countered',
      'match_time_proposal_sent',
      'match_time_counter_sent',
      'match_time_accepted',
      'match_rescheduled',
      'match_emergency_drop',
      'match_checkin_open',
      'match_mutual_override_requested',
      'match_mutual_override_applied',
      'match_no_show',
      'result_to_confirm',
      'result_submitted',
      'result_confirmed'
    );
  GET DIAGNOSTICS v_n = ROW_COUNT;

  IF to_regprocedure('public.admin_match_fitness_rebuild_streaks(bigint, text)') IS NOT NULL THEN
    v_fit_home := public.admin_match_fitness_rebuild_streaks(v_f.season_id, v_home);
    v_fit_away := public.admin_match_fitness_rebuild_streaks(v_f.season_id, v_away);
  END IF;

  v_after := public.admin_fixture_reset_preview(v_fid);

  RETURN jsonb_build_object(
    'ok', true,
    'fixture_id', v_fid,
    'reason', v_reason,
    'home', v_home,
    'away', v_away,
    'admin_replay_reset_at', now(),
    'cleared', jsonb_build_object(
      'stats', v_stats,
      'submissions', v_subs,
      'ledger_rows', v_ledger_n,
      'suspensions', v_susp,
      'injuries_cancelled', v_inj,
      'injury_absences_restored', v_inj_restored,
      'inbox_archived', v_n,
      'video_clear', v_video
    ),
    'fitness_rebuild', jsonb_build_object(
      'home', v_fit_home,
      'away', v_fit_away
    ),
    'before', v_before,
    'after', v_after
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.admin_fixture_reset_for_replay(bigint, text, text)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_fixture_reset_for_replay(bigint, text, text)
  TO authenticated;

DROP VIEW IF EXISTS public.competition_fixtures_public;

CREATE VIEW public.competition_fixtures_public
WITH (security_invoker = false)
AS
SELECT
  f.id,
  f.season_id,
  f.division,
  f.competition_type,
  f.cup_code,
  f.cup_round,
  f.cup_match,
  f.cup_leg,
  f.matchday,
  f.gpsl_month,
  f.week_in_month,
  f.home_club_short_name,
  hc."Club" AS home_club_name,
  f.away_club_short_name,
  ac."Club" AS away_club_name,
  f.weather,
  f.pitch_condition,
  f.kit_season,
  public.competition_club_continent(f.home_club_short_name) AS home_continent,
  f.venue_name,
  f.venue_capacity,
  f.home_goals,
  f.away_goals,
  f.status,
  f.is_forfeit,
  public.match_schedule_fixture_is_catch_up(f.id) AS is_catch_up,
  (
    f.admin_replay_reset_at IS NOT NULL
    AND f.status = 'scheduled'
  ) AS is_admin_replay,
  sub.submission_id,
  sub.submission_status,
  sub.submitted_by_club,
  sub.proposed_home_goals,
  sub.proposed_away_goals,
  sub.proposed_et_home_goals,
  sub.proposed_et_away_goals,
  sub.proposed_pen_winner_club,
  COALESCE(sch.status, 'unscheduled'::text) AS schedule_status,
  sch.agreed_kickoff_at,
  sch.pending_proposal_id AS schedule_pending_proposal_id,
  sch.home_proposal_count AS schedule_home_proposal_count,
  sch.away_proposal_count AS schedule_away_proposal_count,
  COALESCE(sch.discord_hint_shown, false) AS schedule_discord_hint,
  sch.response_due_at AS schedule_response_due_at,
  sch.response_required_club_short_name AS schedule_response_required_club,
  chk.home_checked_in,
  chk.away_checked_in,
  public.fixture_is_manual_black_box(f.id) AS manual_black_box
FROM public.competition_fixtures f
JOIN public.competition_seasons s ON s.id = f.season_id
JOIN public."Clubs" hc ON hc."ShortName" = f.home_club_short_name
JOIN public."Clubs" ac ON ac."ShortName" = f.away_club_short_name
LEFT JOIN public.competition_fixture_schedule sch ON sch.fixture_id = f.id
LEFT JOIN LATERAL (
  SELECT
    EXISTS (
      SELECT 1 FROM public.competition_fixture_checkin c
      WHERE c.fixture_id = f.id AND c.club_short_name = f.home_club_short_name
    ) AS home_checked_in,
    EXISTS (
      SELECT 1 FROM public.competition_fixture_checkin c
      WHERE c.fixture_id = f.id AND c.club_short_name = f.away_club_short_name
    ) AS away_checked_in
) chk ON true
LEFT JOIN LATERAL (
  SELECT
    rs.id AS submission_id,
    rs.status AS submission_status,
    rs.submitted_by_club,
    rs.home_goals AS proposed_home_goals,
    rs.away_goals AS proposed_away_goals,
    rs.et_home_goals AS proposed_et_home_goals,
    rs.et_away_goals AS proposed_et_away_goals,
    rs.pen_winner_club_short_name AS proposed_pen_winner_club
  FROM public.competition_result_submissions rs
  WHERE rs.fixture_id = f.id
    AND rs.status = 'pending'::text
    AND (
      public.is_gpsl_admin()
      OR public.my_club_shortname() = f.home_club_short_name
      OR public.my_club_shortname() = f.away_club_short_name
    )
  LIMIT 1
) sub ON true
WHERE s.status = 'active'::text
  AND s.is_current = true;

REVOKE ALL ON public.competition_fixtures_public FROM PUBLIC;
REVOKE ALL ON public.competition_fixtures_public FROM anon, authenticated;
GRANT SELECT ON public.competition_fixtures_public TO authenticated;
GRANT SELECT ON public.competition_fixtures_public TO anon;

-- Existing admin wipe (CRI vs BES Champ A MD1)
UPDATE public.competition_fixtures
SET admin_replay_reset_at = coalesce(admin_replay_reset_at, now())
WHERE id = 9338
  AND status = 'scheduled';

NOTIFY pgrst, 'reload schema';

-- Verify
SELECT
  f.id,
  f.home_club_short_name,
  f.away_club_short_name,
  f.status,
  f.admin_replay_reset_at,
  public.match_schedule_fixture_is_catch_up(f.id) AS is_catch_up,
  (
    f.admin_replay_reset_at IS NOT NULL
    AND f.status = 'scheduled'
  ) AS is_admin_replay
FROM public.competition_fixtures f
WHERE f.id = 9338;
