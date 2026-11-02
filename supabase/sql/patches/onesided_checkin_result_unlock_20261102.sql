-- =============================================================================
-- One-sided check-in: checked-in club may enter the result (auto)
-- =============================================================================
-- After the check-in window closes, if exactly one club checked in:
--   • no-show fine + season strike still apply (via fixture_try_checkin_forfeit)
--   • that checked-in club can submit the Match Day result
--   • the no-show club cannot submit first
--
-- Admin unlock (admin_fixture_unlock_result_entry) remains as a fallback.
-- Safe re-run.
-- =============================================================================

ALTER TABLE public.competition_fixture_schedule
  ADD COLUMN IF NOT EXISTS admin_result_unlock_at timestamptz,
  ADD COLUMN IF NOT EXISTS admin_result_unlock_by uuid,
  ADD COLUMN IF NOT EXISTS admin_result_unlock_note text;

CREATE OR REPLACE FUNCTION public.match_schedule_assert_ready_to_play(p_fixture_id bigint)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_fixture public.competition_fixtures;
  v_kickoff timestamptz;
  v_window_end timestamptz;
  v_home_in boolean;
  v_away_in boolean;
  v_club text;
  v_checked text;
  v_missed text;
BEGIN
  IF public.is_gpsl_admin() THEN
    RETURN;
  END IF;

  -- Record no-show / fine / strike when the check-in window has closed
  IF to_regprocedure('public.fixture_try_checkin_forfeit(bigint)') IS NOT NULL THEN
    PERFORM public.fixture_try_checkin_forfeit(p_fixture_id);
  END IF;

  SELECT * INTO v_fixture FROM public.competition_fixtures WHERE id = p_fixture_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Fixture not found';
  END IF;

  IF v_fixture.status = 'played' THEN
    RAISE EXCEPTION 'This fixture has already been played';
  END IF;

  IF v_fixture.status <> 'scheduled' THEN
    RAISE EXCEPTION 'Fixture is not open for result entry';
  END IF;

  IF to_regprocedure('public.fixture_is_manual_black_box(bigint)') IS NOT NULL
     AND public.fixture_is_manual_black_box(p_fixture_id) THEN
    RETURN;
  END IF;

  v_kickoff := public.match_schedule_agreed_kickoff(p_fixture_id);
  IF v_kickoff IS NULL THEN
    RAISE EXCEPTION 'Kick-off time must be agreed before entering a result';
  END IF;

  SELECT EXISTS (
    SELECT 1 FROM public.competition_fixture_checkin c
    WHERE c.fixture_id = p_fixture_id
      AND c.club_short_name = v_fixture.home_club_short_name
  ) INTO v_home_in;

  SELECT EXISTS (
    SELECT 1 FROM public.competition_fixture_checkin c
    WHERE c.fixture_id = p_fixture_id
      AND c.club_short_name = v_fixture.away_club_short_name
  ) INTO v_away_in;

  IF v_home_in AND v_away_in THEN
    NULL; -- normal path
  ELSIF (v_home_in AND NOT v_away_in) OR (v_away_in AND NOT v_home_in) THEN
    v_window_end :=
      v_kickoff + (public.match_schedule_checkin_minutes() || ' minutes')::interval;
    IF now() < v_window_end THEN
      RAISE EXCEPTION 'Both clubs must check in before entering a result';
    END IF;

    BEGIN
      v_club := upper(nullif(btrim(public.my_club_shortname()), ''));
    EXCEPTION
      WHEN OTHERS THEN
        v_club := NULL;
    END;

    IF v_club IS NULL THEN
      RAISE EXCEPTION 'No club linked to this account';
    END IF;

    IF v_home_in THEN
      v_checked := upper(v_fixture.home_club_short_name);
      v_missed := upper(v_fixture.away_club_short_name);
    ELSE
      v_checked := upper(v_fixture.away_club_short_name);
      v_missed := upper(v_fixture.home_club_short_name);
    END IF;

    IF v_club <> v_checked THEN
      RAISE EXCEPTION
        'You missed check-in — only % can submit the result (your no-show penalty still applies)',
        v_checked;
    END IF;

    -- Audit: auto unlock for onesided check-in (does not waive penalties)
    UPDATE public.competition_fixture_schedule s
    SET admin_result_unlock_at = coalesce(s.admin_result_unlock_at, now()),
        admin_result_unlock_note = coalesce(
          s.admin_result_unlock_note,
          format(
            'onesided_checkin_auto: %s may submit; %s missed check-in',
            v_checked,
            v_missed
          )
        ),
        updated_at = now()
    WHERE s.fixture_id = p_fixture_id;
  ELSE
    RAISE EXCEPTION 'Both clubs must check in before entering a result';
  END IF;

  IF NOT public.match_schedule_result_month_allows_submit(p_fixture_id) THEN
    RAISE EXCEPTION
      'Result entry is closed for this fixture until its GPSL month (or a later month) is open';
  END IF;
END;
$function$;

COMMENT ON FUNCTION public.match_schedule_assert_ready_to_play(bigint) IS
  'Result entry gate: both check-ins, or after check-in window one check-in from the submitting club (no-show still penalised).';

GRANT EXECUTE ON FUNCTION public.match_schedule_assert_ready_to_play(bigint)
  TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';
