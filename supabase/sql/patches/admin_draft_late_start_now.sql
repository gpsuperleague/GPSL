-- =============================================================================
-- LATE START manager draft — normal Day-1 / Day-2 rules, bidding open NOW
--
-- Day-1  = today's 19:00 Europe/London (already passed → bidding is live)
-- Day-2  = Day-1 + 23h50m + random 0–9m58s  (usual 18:50–18:59:58 UK window)
-- Manager ON, club + player OFF (edit flags below if needed).
--
-- Run in Supabase SQL Editor. Hard-refresh MGDB / Manager Draft after.
-- =============================================================================

DO $$
DECLARE
  v_start timestamptz;
  v_finish timestamptz;
  v_offset_sec int;
  v_day1_uk timestamp without time zone;
BEGIN
  -- Today's 19:00 UK as Day-1 (same as a normal draft that opened tonight)
  v_day1_uk := (timezone('Europe/London', now()))::date + time '19:00';
  v_start := v_day1_uk AT TIME ZONE 'Europe/London';

  -- If somehow run before 19:00 UK, open immediately but keep Day-2 from tonight 19:00
  IF now() < v_start THEN
    v_start := now() - interval '5 seconds';
    v_day1_uk := (timezone('Europe/London', now()))::date + time '19:00';
  END IF;

  v_offset_sec := floor(random() * (9 * 60 + 58 + 1))::int;
  -- Finish from nominal tonight 19:00 Day-1 (not from the early start instant)
  v_finish :=
    ((timezone('Europe/London', now()))::date + time '19:00') AT TIME ZONE 'Europe/London'
    + interval '23 hours'
    + interval '50 minutes'
    + make_interval(secs => v_offset_sec);

  UPDATE public.global_settings
  SET draft_auction_enabled = false,
      manager_draft_auction_enabled = true,
      club_auction_enabled = false,
      draft_auction_start_time = v_start,
      draft_random_finish_time = v_finish,
      updated_at = now()
  WHERE id = 1;

  RAISE NOTICE 'Manager late start: Day-1 start=% finish=% (live now if start <= now)',
    v_start, v_finish;
END $$;

SELECT
  draft_auction_enabled AS player_on,
  manager_draft_auction_enabled AS manager_on,
  club_auction_enabled AS club_on,
  draft_auction_start_time AT TIME ZONE 'Europe/London' AS start_uk,
  draft_random_finish_time AT TIME ZONE 'Europe/London' AS finish_uk,
  now() >= draft_auction_start_time AS started,
  now() < draft_random_finish_time AS before_finish,
  (now() >= draft_auction_start_time AND now() < draft_random_finish_time) AS bidding_window_open
FROM public.global_settings
WHERE id = 1;

NOTIFY pgrst, 'reload schema';
