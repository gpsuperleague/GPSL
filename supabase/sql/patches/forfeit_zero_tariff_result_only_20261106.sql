-- 3–0 forfeits whose tariff is ₿0 (result only, no extra money).
-- fixture_apply_forfeit wrote the score and then charged the tariff.
-- competition_apply_club_fine_tariff rejects amount 0, so the 3–0 rolled back.
-- A fixed, active tariff at ₿0 now skips the charge. A positive amount still charges.
-- A missing tariff still raises, so a typo cannot silently drop a real fine.
--
-- Covers:
--   match_window_expiry           unplayed window / attempt-3 award
--   match_no_show_fixture_forfeit third no-show (the ₿1.5m is a separate tariff)
-- Safe re-run.

CREATE OR REPLACE FUNCTION public.fixture_apply_forfeit(
  p_fixture_id bigint,
  p_loser_club text,
  p_tariff_code text,
  p_reason text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_fixture public.competition_fixtures;
  v_home_goals smallint;
  v_away_goals smallint;
  v_winner text;
  v_title text;
  v_body text;
  v_charge boolean := true;
BEGIN
  SELECT * INTO v_fixture
  FROM public.competition_fixtures
  WHERE id = p_fixture_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Fixture not found';
  END IF;

  IF v_fixture.status = 'played' THEN
    RETURN;
  END IF;

  IF p_loser_club NOT IN (v_fixture.home_club_short_name, v_fixture.away_club_short_name) THEN
    RAISE EXCEPTION 'Loser must be a club in this fixture';
  END IF;

  v_winner := CASE
    WHEN p_loser_club = v_fixture.home_club_short_name THEN v_fixture.away_club_short_name
    ELSE v_fixture.home_club_short_name
  END;

  IF v_winner = v_fixture.home_club_short_name THEN
    v_home_goals := 3;
    v_away_goals := 0;
  ELSE
    v_home_goals := 0;
    v_away_goals := 3;
  END IF;

  UPDATE public.competition_result_submissions
  SET status = 'rejected',
      reject_reason = 'Superseded by forfeit',
      responded_at = now()
  WHERE fixture_id = p_fixture_id
    AND status = 'pending';

  UPDATE public.competition_fixtures
  SET
    home_goals = v_home_goals,
    away_goals = v_away_goals,
    status = 'played',
    is_forfeit = true,
    forfeit_loser_club = p_loser_club
  WHERE id = p_fixture_id;

  SELECT t.amount_mode = 'manual' OR coalesce(t.amount, 0) > 0
  INTO v_charge
  FROM public.competition_fine_tariff t
  WHERE t.code = p_tariff_code
    AND t.is_active;

  IF NOT FOUND THEN
    v_charge := true;
  END IF;

  IF v_charge THEN
    PERFORM public.competition_apply_club_fine_tariff(
      p_loser_club,
      p_tariff_code,
      NULL,
      coalesce(p_reason, 'Match forfeit'),
      p_fixture_id,
      v_fixture.season_id
    );
  END IF;

  IF v_fixture.competition_type = 'cup' THEN
    PERFORM public.competition_cup_on_fixture_played(p_fixture_id);
  ELSIF v_fixture.competition_type = 'league' THEN
    PERFORM public.competition_try_pay_league_division_prizes(
      v_fixture.season_id,
      v_fixture.division
    );
  END IF;

  v_title := public.competition_fixture_inbox_title(p_fixture_id, 'Match forfeited');
  v_body := public.competition_fixture_inbox_body(
    p_fixture_id,
    format('%s forfeited 3–0. %s', public.club_display_name(p_loser_club), coalesce(p_reason, ''))
  );

  PERFORM public.owner_inbox_send(
    'match_forfeit_applied', v_title, v_body,
    v_fixture.home_club_short_name, NULL, p_fixture_id,
    NULL, NULL, NULL,
    'fixture_schedule.html?fixture=' || p_fixture_id::text,
    'forfeit:' || p_fixture_id::text || ':home',
    v_fixture.gpsl_month, v_fixture.season_id, NULL
  );
  PERFORM public.owner_inbox_send(
    'match_forfeit_applied', v_title, v_body,
    v_fixture.away_club_short_name, NULL, p_fixture_id,
    NULL, NULL, NULL,
    'fixture_schedule.html?fixture=' || p_fixture_id::text,
    'forfeit:' || p_fixture_id::text || ':away',
    v_fixture.gpsl_month, v_fixture.season_id, NULL
  );
END;
$function$;

NOTIFY pgrst, 'reload schema';
