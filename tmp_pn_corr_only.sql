-- Correct BES vs FLA fixture 9426 (2026-11-05 19:30 UK)
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_bes_owner uuid;
  v_season bigint;
BEGIN
  SELECT owner_id INTO v_bes_owner FROM public."Clubs" WHERE "ShortName" = 'BES';
  SELECT season_id INTO v_season FROM public.competition_fixtures WHERE id = 9426;

  -- Drop erroneous BES both_miss event (BES Discord check-in 19:20:48)
  DELETE FROM public.competition_fixture_no_show_events
  WHERE fixture_id = 9426
    AND club_short_name = 'BES'
    AND both_miss = true
    AND kickoff_at = '2026-11-05 19:30:00+00'::timestamptz;

  -- FLA really missed; keep event but clear both_miss flag
  UPDATE public.competition_fixture_no_show_events
  SET both_miss = false
  WHERE fixture_id = 9426
    AND club_short_name = 'FLA'
    AND kickoff_at = '2026-11-05 19:30:00+00'::timestamptz
    AND both_miss = true;

  IF v_bes_owner IS NOT NULL AND v_season IS NOT NULL THEN
    UPDATE public.competition_owner_season_strikes
    SET strike_count = greatest(strike_count - 1, 0),
        updated_at = now()
    WHERE season_id = v_season
      AND owner_id = v_bes_owner
      AND strike_count > 0;
  END IF;

  UPDATE public.competition_fixture_schedule
  SET admin_result_unlock_note = 'onesided_checkin_auto: BES may submit or either may reschedule; FLA missed check-in (corrected 2026-11-06: Play Now one-press expire had wiped BES KO check-in before both_miss)',
      updated_at = now()
  WHERE fixture_id = 9426
    AND coalesce(admin_result_unlock_note, '') ILIKE '%both_miss%';
END $$;
