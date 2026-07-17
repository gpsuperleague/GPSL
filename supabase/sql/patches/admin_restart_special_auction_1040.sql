-- =============================================================================
-- Restart the forgotten special auction from 10:00 UK today → 10:40 UK today
--
-- Finds the auction whose start was today 10:00 (UK), clears bids, republishes.
-- Run in Supabase SQL Editor.
-- =============================================================================

DO $$
DECLARE
  v_id bigint;
  v_type text;
  v_old_start timestamptz;
  v_start timestamptz;
  v_end timestamptz;
  v_dur interval;
  v_status text;
  v_bid_n int := 0;
  v_g_n int := 0;
  v_random_end timestamptz;
  v_notified int := 0;
  v_today_uk date := (current_timestamp AT TIME ZONE 'Europe/London')::date;
  v_ten_am timestamptz;
BEGIN
  v_ten_am := (v_today_uk + time '10:00') AT TIME ZONE 'Europe/London';

  -- Prefer exact 10:00 UK start today; else nearest start on today UK morning (09:00–11:00)
  SELECT a.id, a.auction_type, a.start_time, a.end_time - a.start_time
  INTO v_id, v_type, v_old_start, v_dur
  FROM public.special_auctions a
  WHERE a.status IS DISTINCT FROM 'cancelled'
    AND a.start_time = v_ten_am
  ORDER BY a.id DESC
  LIMIT 1;

  IF v_id IS NULL THEN
    SELECT a.id, a.auction_type, a.start_time, a.end_time - a.start_time
    INTO v_id, v_type, v_old_start, v_dur
    FROM public.special_auctions a
    WHERE a.status IS DISTINCT FROM 'cancelled'
      AND (a.start_time AT TIME ZONE 'Europe/London')::date = v_today_uk
      AND (a.start_time AT TIME ZONE 'Europe/London')::time >= time '09:00'
      AND (a.start_time AT TIME ZONE 'Europe/London')::time < time '11:00'
    ORDER BY abs(extract(epoch FROM (a.start_time - v_ten_am))), a.id DESC
    LIMIT 1;
  END IF;

  IF v_id IS NULL THEN
    RAISE EXCEPTION
      'No special auction found for ~10:00 UK today (%). Check: SELECT id, title, status, start_time AT TIME ZONE ''Europe/London'' FROM special_auctions ORDER BY id DESC LIMIT 10;',
      v_today_uk;
  END IF;

  v_start := (v_today_uk + time '10:40') AT TIME ZONE 'Europe/London';

  IF v_type = 'snap' THEN
    v_end := v_start + interval '60 minutes';
    v_random_end := v_start + interval '50 minutes' + (random() * interval '10 minutes');
  ELSIF v_type = 'blind_gauntlet' THEN
    v_end := v_start + interval '30 minutes';
    v_random_end := NULL;
  ELSE
    v_end := v_start + coalesce(nullif(v_dur, interval '0'), interval '60 minutes');
    v_random_end := NULL;
  END IF;

  UPDATE public.special_auctions
  SET status = 'draft', updated_at = now()
  WHERE status IN ('scheduled', 'active')
    AND id IS DISTINCT FROM v_id;

  DELETE FROM public.special_auction_bids WHERE auction_id = v_id;
  GET DIAGNOSTICS v_bid_n = ROW_COUNT;

  IF to_regclass('public.special_auction_gauntlet_bids') IS NOT NULL THEN
    EXECUTE 'DELETE FROM public.special_auction_gauntlet_bids WHERE auction_id = $1'
      USING v_id;
    GET DIAGNOSTICS v_g_n = ROW_COUNT;
  END IF;

  UPDATE public.special_auctions
  SET start_time = v_start,
      end_time = v_end,
      snap_random_end_at = CASE
        WHEN auction_type = 'snap' THEN v_random_end
        ELSE snap_random_end_at
      END,
      winning_club_id = NULL,
      winning_amount = NULL,
      gauntlet_phase = CASE
        WHEN auction_type = 'blind_gauntlet' THEN 'phase1'
        ELSE gauntlet_phase
      END,
      status = CASE WHEN now() < v_start THEN 'scheduled' ELSE 'active' END,
      updated_at = now()
  WHERE id = v_id;

  IF v_type = 'blind_gauntlet'
     AND to_regprocedure('public.special_auction_gauntlet_prepare(bigint)') IS NOT NULL THEN
    PERFORM public.special_auction_gauntlet_prepare(v_id);
  END IF;

  IF to_regprocedure('public.special_auction_notify_scheduled(bigint,boolean)') IS NOT NULL THEN
    v_notified := public.special_auction_notify_scheduled(v_id, true);
  ELSIF to_regprocedure('public.special_auction_notify_scheduled(bigint)') IS NOT NULL THEN
    v_notified := public.special_auction_notify_scheduled(v_id);
  END IF;

  SELECT status INTO v_status FROM public.special_auctions WHERE id = v_id;

  RAISE NOTICE
    'Restarted forgotten 10:00 auction #% (was % UK) → type=% status=% start_uk=% end_uk=% cleared_bids=% gauntlet_bids=% inbox=%',
    v_id,
    to_char(v_old_start AT TIME ZONE 'Europe/London', 'YYYY-MM-DD HH24:MI'),
    v_type,
    v_status,
    to_char(v_start AT TIME ZONE 'Europe/London', 'YYYY-MM-DD HH24:MI'),
    to_char(v_end AT TIME ZONE 'Europe/London', 'YYYY-MM-DD HH24:MI'),
    v_bid_n,
    v_g_n,
    v_notified;
END $$;

SELECT id,
       title,
       auction_type,
       status,
       start_time AT TIME ZONE 'Europe/London' AS start_uk,
       end_time AT TIME ZONE 'Europe/London' AS end_uk,
       snap_random_end_at AT TIME ZONE 'Europe/London' AS snap_close_uk
FROM public.special_auctions
WHERE status IN ('scheduled', 'active')
ORDER BY id DESC;
