-- =============================================================================
-- LATE START one kind's draft clock (default: manager)
-- Requires draft_schedules_per_type.sql first.
-- =============================================================================

DO $$
DECLARE
  v_kind text := 'manager'; -- player | manager | club
  v_start timestamptz;
  v_finish timestamptz;
  v_offset_sec int;
  v_day1_uk timestamp without time zone;
BEGIN
  v_day1_uk := (timezone('Europe/London', now()))::date + time '19:00';
  v_start := v_day1_uk AT TIME ZONE 'Europe/London';

  IF now() < v_start THEN
    v_start := now() - interval '5 seconds';
  END IF;

  v_offset_sec := floor(random() * (9 * 60 + 58 + 1))::int;
  v_finish :=
    ((timezone('Europe/London', now()))::date + time '19:00') AT TIME ZONE 'Europe/London'
    + interval '23 hours'
    + interval '50 minutes'
    + make_interval(secs => v_offset_sec);

  IF v_kind = 'player' THEN
    UPDATE public.global_settings
    SET draft_auction_enabled = true,
        draft_auction_start_time = v_start,
        draft_random_finish_time = v_finish,
        updated_at = now()
    WHERE id = 1;
  ELSIF v_kind = 'club' THEN
    UPDATE public.global_settings
    SET club_auction_enabled = true,
        club_auction_start_time = v_start,
        club_auction_random_finish_time = v_finish,
        updated_at = now()
    WHERE id = 1;
  ELSE
    UPDATE public.global_settings
    SET manager_draft_auction_enabled = true,
        manager_draft_auction_start_time = v_start,
        manager_draft_random_finish_time = v_finish,
        updated_at = now()
    WHERE id = 1;
  END IF;

  RAISE NOTICE 'Late start kind=% start=% finish=%', v_kind, v_start, v_finish;
END $$;

SELECT
  draft_auction_enabled AS player_on,
  manager_draft_auction_enabled AS manager_on,
  club_auction_enabled AS club_on,
  draft_auction_start_time AT TIME ZONE 'Europe/London' AS player_start_uk,
  manager_draft_auction_start_time AT TIME ZONE 'Europe/London' AS manager_start_uk,
  club_auction_start_time AT TIME ZONE 'Europe/London' AS club_start_uk
FROM public.global_settings
WHERE id = 1;

NOTIFY pgrst, 'reload schema';
