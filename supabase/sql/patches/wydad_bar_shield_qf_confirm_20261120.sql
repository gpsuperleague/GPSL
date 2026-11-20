-- Shield quarter-final: Wydad vs Barcelona, fixture 9959, submission 202.
-- Confirm Barcelona's 1-4 and Barcelona's player stats.
-- Wydad's stats stay empty. Their one-time stats edit stays open
-- for the GPSL month this result is posted in.
-- Safe re-run: does nothing once 202 is already confirmed.

DO $confirm$
DECLARE
  v_sub public.competition_result_submissions;
  v_fixture public.competition_fixtures;
  v_home_total smallint;
  v_away_total smallint;
  v_home_name text;
  v_away_name text;
  v_label text;
  v_body text;
BEGIN
  PERFORM set_config('statement_timeout', '180s', true);
  PERFORM set_config('gpsl.skip_clinch_scan', 'on', true);
  PERFORM set_config('gpsl.skip_bookies_reprice', 'on', true);
  PERFORM set_config('gpsl.defer_injury_fitness', 'on', true);

  SELECT * INTO v_sub
  FROM public.competition_result_submissions
  WHERE id = 202;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Submission 202 not found';
  END IF;

  IF v_sub.status = 'confirmed' THEN
    RETURN;
  END IF;

  IF v_sub.status IS DISTINCT FROM 'pending'
     OR v_sub.fixture_id IS DISTINCT FROM 9959
     OR v_sub.submitted_by_club IS DISTINCT FROM 'BAR'
     OR v_sub.home_goals IS DISTINCT FROM 1
     OR v_sub.away_goals IS DISTINCT FROM 4
     OR v_sub.et_home_goals IS NOT NULL
     OR v_sub.et_away_goals IS NOT NULL
     OR v_sub.pen_winner_club_short_name IS NOT NULL THEN
    RAISE EXCEPTION 'Submission 202 is not the pending Barcelona 1-4';
  END IF;

  SELECT * INTO v_fixture FROM public.competition_fixtures WHERE id = 9959;

  IF NOT FOUND
     OR v_fixture.status IS DISTINCT FROM 'scheduled'
     OR v_fixture.home_club_short_name IS DISTINCT FROM 'WYD'
     OR v_fixture.away_club_short_name IS DISTINCT FROM 'BAR'
     OR v_fixture.competition_type IS DISTINCT FROM 'cup'
     OR v_fixture.cup_code IS DISTINCT FROM 'shield'
     OR v_fixture.cup_round IS DISTINCT FROM 4 THEN
    RAISE EXCEPTION 'Fixture 9959 is not the scheduled Wydad vs Barcelona Shield quarter-final';
  END IF;

  IF public.competition_cup_winner_from_submission(
    v_sub.home_goals, v_sub.away_goals, v_sub.et_home_goals, v_sub.et_away_goals,
    v_sub.pen_winner_club_short_name,
    v_fixture.home_club_short_name, v_fixture.away_club_short_name
  ) IS DISTINCT FROM 'BAR' THEN
    RAISE EXCEPTION 'Cup winner from this score is not Barcelona';
  END IF;

  SELECT t.home_total, t.away_total
  INTO v_home_total, v_away_total
  FROM public.competition_cup_open_play_totals(
    v_sub.home_goals, v_sub.away_goals, v_sub.et_home_goals, v_sub.et_away_goals
  ) t;

  UPDATE public.competition_fixtures
  SET home_goals = v_home_total,
      away_goals = v_away_total,
      cup_pen_winner_club_short_name = NULL,
      status = 'played'
  WHERE id = 9959
    AND status = 'scheduled';

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Fixture 9959 was not updated';
  END IF;

  PERFORM public.competition_apply_submission_player_stats(202);
  PERFORM public.competition_settle_fixture_gates(9959);

  IF to_regprocedure('public.competition_tv_settle_fixture(bigint)') IS NOT NULL THEN
    PERFORM public.competition_tv_settle_fixture(9959);
  END IF;

  IF to_regprocedure('public.competition_try_award_challenges(bigint,text,boolean)') IS NOT NULL THEN
    BEGIN
      PERFORM public.competition_try_award_challenges(v_fixture.season_id, 'WYD', false);
      PERFORM public.competition_try_award_challenges(v_fixture.season_id, 'BAR', false);
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'challenges after confirm 9959: %', SQLERRM;
    END;
  END IF;

  PERFORM public.competition_cup_on_fixture_played(9959);

  UPDATE public.competition_result_submissions
  SET status = 'confirmed',
      responded_by_club = 'WYD',
      responded_at = now()
  WHERE id = 202
    AND status = 'pending';

  UPDATE public.competition_inbox
  SET read_at = coalesce(read_at, now())
  WHERE submission_id = 202
    AND recipient_club_short_name = 'WYD'
    AND message_type = 'result_to_confirm';

  SELECT "Club" INTO v_home_name FROM public."Clubs" WHERE "ShortName" = 'WYD';
  SELECT "Club" INTO v_away_name FROM public."Clubs" WHERE "ShortName" = 'BAR';
  v_label := public.competition_cup_fixture_label(v_fixture);
  v_body := format(
    '%s — %s–%s confirmed from Barcelona''s submission. Wydad player stats were left blank and can still be added while this GPSL month is open.',
    v_label, v_home_total, v_away_total
  );

  PERFORM public.competition_inbox_notify(
    'BAR',
    'result_confirmed',
    9959,
    202,
    format('Result confirmed: %s vs %s', v_home_name, v_away_name),
    v_body
  );

  PERFORM set_config('gpsl.defer_injury_fitness', 'off', true);
  IF to_regprocedure('public.competition_serve_injuries_for_fixture(bigint)') IS NOT NULL THEN
    BEGIN
      PERFORM public.competition_serve_injuries_for_fixture(9959);
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'injury roll after confirm 9959: %', SQLERRM;
    END;
  END IF;
END;
$confirm$;

SELECT jsonb_build_object(
  'fixture', (
    SELECT jsonb_build_object(
      'id', f.id,
      'status', f.status,
      'score', f.home_goals || '-' || f.away_goals,
      'posted_month', f.result_posted_gpsl_month,
      'wyd_edit_used', f.home_stats_edit_used_at,
      'bar_edit_used', f.away_stats_edit_used_at
    )
    FROM public.competition_fixtures f
    WHERE f.id = 9959
  ),
  'submission', (
    SELECT jsonb_build_object(
      'id', s.id,
      'status', s.status,
      'by', s.submitted_by_club,
      'responded_by', s.responded_by_club
    )
    FROM public.competition_result_submissions s
    WHERE s.id = 202
  ),
  'bar_stat_rows', (
    SELECT count(*)
    FROM public.competition_match_player_stats m
    WHERE m.fixture_id = 9959
      AND m.club_short_name = 'BAR'
  ),
  'wyd_stat_rows', (
    SELECT count(*)
    FROM public.competition_match_player_stats m
    WHERE m.fixture_id = 9959
      AND m.club_short_name = 'WYD'
  )
);
