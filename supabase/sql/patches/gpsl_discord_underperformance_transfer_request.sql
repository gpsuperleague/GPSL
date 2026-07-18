-- =============================================================================
-- Discord #gpsl-news: player transfer request (club underperformance)
--
-- When season archive forces a perpetual MV listing after a big/medium club
-- misses expectation, post a dedicated transfer-request headline instead of the
-- generic "LISTED" message.
--
-- Run after: gpsl_discord_sky_feed.sql, club_underperformance_transfer.sql
-- Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.gpsl_discord_feed_on_listing()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_name text;
  v_club text;
  v_club_full text;
  v_price text;
  v_headline text;
  v_body text;
  v_ask numeric;
  v_source text;
  v_tier text;
  v_age text;
  v_rating text;
BEGIN
  IF lower(coalesce(NEW.status::text, '')) IS DISTINCT FROM 'active' THEN
    RETURN NEW;
  END IF;

  IF lower(coalesce(NEW.listing_type::text, '')) = 'draft' THEN
    RETURN NEW;
  END IF;

  SELECT
    p."Name",
    nullif(btrim(p."Age"::text), ''),
    nullif(btrim(p."Rating"::text), '')
  INTO v_name, v_age, v_rating
  FROM public."Players" p
  WHERE p."Konami_ID"::text = NEW.player_id::text
  LIMIT 1;

  v_name := coalesce(nullif(btrim(v_name), ''), 'Player ' || NEW.player_id::text);
  v_club := coalesce(nullif(btrim(NEW.seller_club_id), ''), 'Unknown');

  BEGIN
    v_club_full := public.gpsl_discord_feed_club_name(v_club);
  EXCEPTION WHEN OTHERS THEN
    v_club_full := v_club;
  END;

  v_ask := coalesce(NEW.reserve_price, NEW.market_value, 0);

  BEGIN
    v_price := public.transfer_format_money(v_ask);
  EXCEPTION WHEN OTHERS THEN
    v_price := v_ask::text;
  END;

  v_source := lower(coalesce(NEW.special_rules ->> 'source', ''));
  v_tier := lower(coalesce(NEW.special_rules ->> 'tier', ''));

  IF v_source = 'underperformance' THEN
    v_headline := format('🚪 TRANSFER REQUEST — %s', v_name);
    v_body := format(
      E'%s has handed in a transfer request at %s.\nListed at market value: %s\n%s · Age %s · Rating %s\nPerpetual listing until sold.',
      v_name,
      v_club_full,
      v_price,
      CASE v_tier
        WHEN 'big' THEN 'Big club underperformance'
        WHEN 'medium' THEN 'Medium club underperformance'
        ELSE 'Club underperformance'
      END,
      coalesce(v_age, '?'),
      coalesce(v_rating, '?')
    );

    PERFORM public.gpsl_discord_feed_enqueue(
      'transfer_request',
      v_headline,
      v_body,
      15105570, -- 0xe67e22
      'transfer_request:' || NEW.id::text,
      jsonb_build_object(
        'listing_id', NEW.id,
        'player_id', NEW.player_id,
        'club', v_club,
        'source', 'underperformance',
        'tier', v_tier,
        'channel', 'news'
      )
    );

    RETURN NEW;
  END IF;

  v_headline := format('📋 LISTED — %s', v_name);
  v_body := format('Club: %s\nAsking: %s', v_club_full, v_price);

  PERFORM public.gpsl_discord_feed_enqueue(
    'listing',
    v_headline,
    v_body,
    16763904, -- 0xffcc00
    'listing:' || NEW.id::text,
    jsonb_build_object(
      'listing_id', NEW.id,
      'player_id', NEW.player_id,
      'channel', 'news'
    )
  );

  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_gpsl_discord_feed_listing ON public."Player_Transfer_Listings";
CREATE TRIGGER trg_gpsl_discord_feed_listing
  AFTER INSERT ON public."Player_Transfer_Listings"
  FOR EACH ROW
  EXECUTE FUNCTION public.gpsl_discord_feed_on_listing();

NOTIFY pgrst, 'reload schema';
