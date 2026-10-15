-- =============================================================================
-- Special auctions → Discord #gpsl-notifications (GPSL Calendar).
--
-- The live trigger function was the gpsl_discord_auction_type_labels.sql
-- version, which queued to #gpsl-news with key 'special_auction:<id>' (one
-- post ever per auction). This version posts to the calendar channel when an
-- auction becomes Upcoming and again when it goes Live, then backfills a post
-- for auctions already scheduled. Mystery snaps never mention the prize.
-- Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.gpsl_discord_feed_on_special_auction_row()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_title text;
  v_type_label text;
  v_status_label text;
  v_detail text;
  v_page text;
BEGIN
  IF NEW.status NOT IN ('scheduled', 'active') THEN
    RETURN NEW;
  END IF;

  IF TG_OP = 'UPDATE' AND OLD.status IS NOT DISTINCT FROM NEW.status THEN
    RETURN NEW;
  END IF;

  v_title := coalesce(nullif(btrim(NEW.title), ''), 'Special auction');
  v_type_label := CASE NEW.auction_type
    WHEN 'lowest_unique' THEN 'Lowest unique bid'
    WHEN 'snap' THEN 'Snap auction'
    WHEN 'blind_gauntlet' THEN 'Blind Gauntlet'
    ELSE 'Special auction'
  END;
  v_status_label := CASE NEW.status WHEN 'active' THEN '🟢 Live now' ELSE '📅 Upcoming' END;
  v_page := CASE WHEN NEW.auction_type = 'blind_gauntlet'
    THEN 'Special Auction → Blind Gauntlet' ELSE 'Special Auction' END;

  v_detail := concat_ws(
    E'\n',
    v_status_label || ' · ' || v_type_label,
    'Starts: ' || to_char(NEW.start_time AT TIME ZONE 'Europe/London', 'Dy DD Mon YYYY HH24:MI') || ' (UK)',
    CASE
      WHEN NEW.auction_type = 'snap' THEN 'Ends at a secret random moment in the final 10 minutes.'
      WHEN NEW.end_time IS NOT NULL THEN
        'Ends: ' || to_char(NEW.end_time AT TIME ZONE 'Europe/London', 'Dy DD Mon YYYY HH24:MI') || ' (UK)'
    END,
    CASE WHEN NEW.auction_type = 'snap' THEN '🎭 Mystery player — clues unlock during the auction.' END,
    'Open ' || v_page || ' on the GPSL site to take part (📅 Add to calendar there).'
  );

  PERFORM public.gpsl_discord_feed_enqueue_notification(
    'auction',
    format('🔨 SPECIAL AUCTION — %s', v_title),
    v_detail,
    22456,
    'special_auction_cal:' || NEW.id::text || ':' || NEW.status
      || ':' || to_char(NEW.start_time AT TIME ZONE 'UTC', 'YYYYMMDDHH24MI'),
    jsonb_build_object('auction_id', NEW.id, 'auction_type', NEW.auction_type, 'kind', 'special_auction')
  );

  RETURN NEW;
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING 'gpsl_discord_feed_on_special_auction_row: %', SQLERRM;
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_gpsl_discord_feed_special_auction ON public.special_auctions;
CREATE TRIGGER trg_gpsl_discord_feed_special_auction
  AFTER INSERT OR UPDATE OF status
  ON public.special_auctions
  FOR EACH ROW
  EXECUTE FUNCTION public.gpsl_discord_feed_on_special_auction_row();

-- Backfill: post the auctions that are already scheduled / live
-- (same text and dedupe key as the trigger, so re-running never double-posts)
DO $$
DECLARE
  r public.special_auctions;
BEGIN
  FOR r IN
    SELECT * FROM public.special_auctions
    WHERE status IN ('scheduled', 'active')
    ORDER BY start_time
  LOOP
    PERFORM public.gpsl_discord_feed_enqueue_notification(
      'auction',
      format('🔨 SPECIAL AUCTION — %s', coalesce(nullif(btrim(r.title), ''), 'Special auction')),
      concat_ws(
        E'\n',
        CASE r.status WHEN 'active' THEN '🟢 Live now' ELSE '📅 Upcoming' END || ' · ' ||
          CASE r.auction_type
            WHEN 'lowest_unique' THEN 'Lowest unique bid'
            WHEN 'snap' THEN 'Snap auction'
            WHEN 'blind_gauntlet' THEN 'Blind Gauntlet'
            ELSE 'Special auction'
          END,
        'Starts: ' || to_char(r.start_time AT TIME ZONE 'Europe/London', 'Dy DD Mon YYYY HH24:MI') || ' (UK)',
        CASE
          WHEN r.auction_type = 'snap' THEN 'Ends at a secret random moment in the final 10 minutes.'
          WHEN r.end_time IS NOT NULL THEN
            'Ends: ' || to_char(r.end_time AT TIME ZONE 'Europe/London', 'Dy DD Mon YYYY HH24:MI') || ' (UK)'
        END,
        CASE WHEN r.auction_type = 'snap' THEN '🎭 Mystery player — clues unlock during the auction.' END,
        'Open ' || CASE WHEN r.auction_type = 'blind_gauntlet'
          THEN 'Special Auction → Blind Gauntlet' ELSE 'Special Auction' END
          || ' on the GPSL site to take part (📅 Add to calendar there).'
      ),
      22456,
      'special_auction_cal:' || r.id::text || ':' || r.status
        || ':' || to_char(r.start_time AT TIME ZONE 'UTC', 'YYYYMMDDHH24MI'),
      jsonb_build_object('auction_id', r.id, 'auction_type', r.auction_type, 'kind', 'special_auction')
    );
  END LOOP;
END $$;

-- Report: queued calendar posts (posted by discord-sky-feed on its next run)
SELECT q.id, q.headline, q.status, q.dedupe_key, q.body
FROM public.gpsl_discord_feed_queue q
WHERE q.dedupe_key LIKE 'special_auction%'
ORDER BY q.id DESC
LIMIT 10;
