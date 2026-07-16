-- Contract release → Discord Sky News
-- Safe re-run. Requires gpsl_discord_sky_feed.sql (+ events_auto helpers).

CREATE OR REPLACE FUNCTION public.gpsl_discord_feed_on_transfer()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_name text;
  v_seller text;
  v_buyer text;
  v_fee text;
  v_listing_type text;
  v_method text;
  v_note text := lower(coalesce(btrim(NEW.transfer_sale_note), ''));
BEGIN
  SELECT p."Name" INTO v_name
  FROM public."Players" p
  WHERE p."Konami_ID"::text = NEW.player_id::text
  LIMIT 1;

  v_name := coalesce(nullif(btrim(v_name), ''), 'Player ' || NEW.player_id::text);
  v_seller := public.gpsl_discord_feed_club_name(NEW.seller_club_id);

  -- Voluntary contract release (no listing)
  IF v_note = 'voluntary_contract_release' THEN
    PERFORM public.gpsl_discord_feed_enqueue(
      'release',
      format('📋 CONTRACT RELEASE — %s', v_name),
      format('%s left %s.', v_name, v_seller),
      12370112, -- 0xbcbc80
      'transfer:' || NEW.id::text,
      jsonb_build_object(
        'transfer_history_id', NEW.id,
        'transfer_sale_note', NEW.transfer_sale_note
      )
    );
    RETURN NEW;
  END IF;

  IF NEW.listing_id IS NULL THEN
    RETURN NEW;
  END IF;

  SELECT l.listing_type INTO v_listing_type
  FROM public."Player_Transfer_Listings" l
  WHERE l.id = NEW.listing_id;

  -- Only direct offer (transfer market). Exclude draft + transfer-list auctions.
  IF lower(coalesce(v_listing_type, '')) IS DISTINCT FROM 'direct' THEN
    RETURN NEW;
  END IF;

  v_buyer := CASE
    WHEN NEW.buyer_club_id = 'FOREIGN' THEN coalesce(nullif(btrim(NEW.foreign_buyer_name), ''), 'Foreign club')
    ELSE public.gpsl_discord_feed_club_name(NEW.buyer_club_id)
  END;

  BEGIN
    v_fee := public.transfer_format_money(coalesce(NEW.fee, 0));
  EXCEPTION WHEN OTHERS THEN
    v_fee := coalesce(NEW.fee, 0)::text;
  END;

  BEGIN
    v_method := public.transfer_classify_method(
      NEW.seller_club_id, NEW.buyer_club_id, NEW.listing_id,
      NEW.transfer_sale_note, NEW.foreign_buyer_name, NULL
    );
  EXCEPTION WHEN OTHERS THEN
    v_method := 'Direct offer (transfer market)';
  END;

  PERFORM public.gpsl_discord_feed_enqueue(
    'transfer',
    format('🔨 DONE DEAL — %s', v_name),
    format('%s → %s\nFee: %s\n%s', v_seller, v_buyer, v_fee, v_method),
    42641,
    'transfer:' || NEW.id::text,
    jsonb_build_object('transfer_history_id', NEW.id, 'listing_type', v_listing_type)
  );

  RETURN NEW;
END;
$function$;

NOTIFY pgrst, 'reload schema';
