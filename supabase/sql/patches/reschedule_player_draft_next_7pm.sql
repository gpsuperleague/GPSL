-- Reschedule player draft to next Day-1 19:00 UK (not late-start live).
-- Safe one-shot for when Save accidentally used late start after 19:00.

DO $fix$
DECLARE
  v_now_uk timestamp := timezone('Europe/London', now());
  v_day1_uk timestamp;
  v_start timestamptz;
  v_finish timestamptz;
  v_offset_sec int;
BEGIN
  IF (extract(hour from v_now_uk) > 19)
     OR (extract(hour from v_now_uk) = 19 AND (extract(minute from v_now_uk) > 0 OR extract(second from v_now_uk) > 0))
  THEN
    v_day1_uk := (v_now_uk::date + 1) + time '19:00';
  ELSE
    v_day1_uk := v_now_uk::date + time '19:00';
  END IF;

  v_start := v_day1_uk AT TIME ZONE 'Europe/London';
  -- Day-2 random window: Day-1 + 23h50m + 0..9m58s
  v_offset_sec := floor(random() * (9 * 60 + 58 + 1))::int;
  v_finish := (v_day1_uk + interval '23 hours 50 minutes' + make_interval(secs => v_offset_sec))
    AT TIME ZONE 'Europe/London';

  UPDATE public.global_settings
  SET
    draft_auction_enabled = true,
    draft_auction_start_time = v_start,
    draft_random_finish_time = v_finish
  WHERE id = 1;

  RAISE NOTICE 'Player draft → start % UK, finish % UK',
    v_start AT TIME ZONE 'Europe/London',
    v_finish AT TIME ZONE 'Europe/London';
END;
$fix$;

SELECT
  draft_auction_enabled,
  draft_auction_start_time AT TIME ZONE 'Europe/London' AS start_uk,
  draft_random_finish_time AT TIME ZONE 'Europe/London' AS finish_uk,
  now() AT TIME ZONE 'Europe/London' AS now_uk
FROM public.global_settings
WHERE id = 1;
