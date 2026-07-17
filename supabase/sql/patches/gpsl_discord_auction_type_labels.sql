-- =============================================================================
-- Discord / inbox: label auction types correctly
-- LUB ("Lowest unique bid") only when auction_type = 'lowest_unique'
-- Snap / Blind Gauntlet / unknown get their own labels (not LUB).
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
  v_detail text;
  v_type_label text;
BEGIN
  IF NEW.status NOT IN ('scheduled', 'active') THEN
    RETURN NEW;
  END IF;

  IF TG_OP = 'UPDATE' AND OLD.status IN ('scheduled', 'active') THEN
    RETURN NEW;
  END IF;

  v_title := coalesce(nullif(btrim(NEW.title), ''), 'Special auction');
  v_type_label := CASE NEW.auction_type
    WHEN 'lowest_unique' THEN 'Lowest unique bid'
    WHEN 'snap' THEN 'Snap auction'
    WHEN 'blind_gauntlet' THEN 'Blind Gauntlet'
    ELSE 'Special auction'
  END;

  v_detail := concat_ws(
    E'\n',
    v_type_label,
    'Starts: ' || to_char(NEW.start_time AT TIME ZONE 'Europe/London', 'Dy DD Mon YYYY HH24:MI') || ' (UK)',
    CASE
      WHEN NEW.auction_type = 'snap' THEN NULL
      WHEN NEW.end_time IS NOT NULL THEN
        'Ends: ' || to_char(NEW.end_time AT TIME ZONE 'Europe/London', 'Dy DD Mon YYYY HH24:MI') || ' (UK)'
      ELSE NULL
    END
  );

  PERFORM public.gpsl_discord_feed_enqueue(
    'auction',
    format('🔨 AUCTION — %s', v_title),
    v_detail,
    22456, -- 0x0057b8
    'special_auction:' || NEW.id::text,
    jsonb_build_object('auction_id', NEW.id, 'auction_type', NEW.auction_type)
  );

  RETURN NEW;
EXCEPTION WHEN OTHERS THEN
  RETURN NEW;
END;
$function$;

DO $$
BEGIN
  IF to_regclass('public.special_auctions') IS NULL THEN
    RETURN;
  END IF;

  DROP TRIGGER IF EXISTS trg_gpsl_discord_feed_special_auction ON public.special_auctions;
  CREATE TRIGGER trg_gpsl_discord_feed_special_auction
    AFTER INSERT OR UPDATE OF status
    ON public.special_auctions
    FOR EACH ROW
    EXECUTE FUNCTION public.gpsl_discord_feed_on_special_auction_row();
END $$;

-- Owner inbox copy when an auction is scheduled / activated
CREATE OR REPLACE FUNCTION public.special_auction_notify_scheduled(
  p_auction_id bigint,
  p_force boolean DEFAULT false
)
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  a public.special_auctions%rowtype;
  v_start text;
  v_title text;
  v_body text;
  v_type_label text;
  v_count int := 0;
  v_dedupe text;
  v_name text;
BEGIN
  IF to_regprocedure('public.owner_inbox_notify_all_clubs(text,text,text,text,text,bigint)') IS NULL THEN
    RAISE EXCEPTION 'owner_inbox_notify_all_clubs missing — run owner_inbox_notifications.sql';
  END IF;

  SELECT * INTO a FROM public.special_auctions WHERE id = p_auction_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Auction not found';
  END IF;

  IF a.status NOT IN ('scheduled', 'active') THEN
    RAISE EXCEPTION 'Auction must be scheduled or active to notify (status=%)', a.status;
  END IF;

  v_start := to_char(a.start_time AT TIME ZONE 'Europe/London', 'Dy DD Mon YYYY HH24:MI');
  v_name := coalesce(nullif(btrim(a.title), ''), 'Special auction');
  v_type_label := CASE a.auction_type
    WHEN 'lowest_unique' THEN 'Lowest unique bid auction'
    WHEN 'snap' THEN 'Snap auction'
    WHEN 'blind_gauntlet' THEN 'Blind Gauntlet'
    ELSE 'Special auction'
  END;

  v_title := format('%s scheduled', v_type_label);

  IF a.auction_type = 'snap' THEN
    v_body := format(
      E'%s — %s\n\nOpens %s (UK).\nRuns about one hour; bidding ends at a secret random time in the final 10 minutes.\nClues unlock during the auction; the player identity is revealed when it ends.\n\nOpen Special Auction to take part.',
      v_type_label,
      v_name,
      v_start
    );
  ELSIF a.auction_type = 'blind_gauntlet' THEN
    v_body := format(
      E'%s — %s\n\nOpens %s (UK).\nTwo blind phases (Phase 1 → reveal → Phase 2). Check Special Auction / Blind Gauntlet for rules and fees.\n\nOpen Blind Gauntlet to take part.',
      v_type_label,
      v_name,
      v_start
    );
  ELSIF a.auction_type = 'lowest_unique' THEN
    v_body := format(
      E'%s — %s\n\nBidding window: %s (UK) until %s (UK).\nOne secret bid per club (nearest ₿1m). Lowest unique bid wins.\n\nOpen Special Auction to take part.',
      v_type_label,
      v_name,
      v_start,
      to_char(a.end_time AT TIME ZONE 'Europe/London', 'Dy DD Mon YYYY HH24:MI')
    );
  ELSE
    v_body := format(
      E'%s — %s\n\nOpens %s (UK)%s.\n\nOpen Special Auction to take part.',
      v_type_label,
      v_name,
      v_start,
      CASE
        WHEN a.end_time IS NOT NULL THEN
          ' until ' || to_char(a.end_time AT TIME ZONE 'Europe/London', 'Dy DD Mon YYYY HH24:MI') || ' (UK)'
        ELSE ''
      END
    );
  END IF;

  v_dedupe := 'special_auction_scheduled:' || a.id::text;
  IF p_force THEN
    v_dedupe := v_dedupe || ':resent:' || floor(extract(epoch FROM now()))::text;
  END IF;

  v_count := public.owner_inbox_notify_all_clubs(
    'special_auction_scheduled',
    v_title,
    v_body,
    CASE
      WHEN a.auction_type = 'blind_gauntlet' THEN 'special_auction_gauntlet.html'
      ELSE 'special_auction.html'
    END,
    v_dedupe,
    NULL
  );

  RETURN v_count;
END;
$function$;

NOTIFY pgrst, 'reload schema';
