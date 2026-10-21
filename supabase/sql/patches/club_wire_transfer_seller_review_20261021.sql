-- =============================================================================
-- Club Wire — transfer-market outbid harden + seller-review status (both sides)
--
-- 1) Outbid on normal transfer listings: classify via listing_type (not only
--    is_direct), subject_key = listing id, href → all_listings.
-- 2) When a listing enters Review / Seller Review:
--      seller  → review_needed
--      leader  → under_review
-- 3) When that review resolves (Closed):
--      both sides → review_accepted (transfer_completed) or review_declined
--
-- Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.club_wire_clear_kinds(
  p_owner uuid,
  p_market text,
  p_subject_key text,
  p_kinds text[]
)
RETURNS void
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  DELETE FROM public.club_wire_alerts a
  WHERE a.owner_id = p_owner
    AND a.market = p_market
    AND a.subject_key = p_subject_key
    AND a.kind = ANY (p_kinds)
    AND a.dismissed_at IS NULL;
$$;

REVOKE ALL ON FUNCTION public.club_wire_clear_kinds(uuid, text, text, text[])
  FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 1) Player draft + transfer-list bids (hardened)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.trg_club_wire_player_bid()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_top_id bigint;
  v_prev record;
  v_market text;
  v_listing_type text;
  v_pid text;
  v_key text;
  v_name text;
  v_href text;
BEGIN
  BEGIN
    IF NEW.listing_id IS NULL THEN
      RETURN NULL;
    END IF;

    -- Direct club-to-club offers: handled by offer trigger (accepted/rejected)
    IF NEW.is_direct AND NEW.seller_club_id IS NOT NULL THEN
      RETURN NULL;
    END IF;

    SELECT b.bid_id INTO v_top_id
    FROM public."Player_Transfer_Bids" b
    WHERE b.listing_id = NEW.listing_id
      AND b.bidder_club_id IS DISTINCT FROM b.seller_club_id
    ORDER BY b.bid_amount DESC, b.bid_time ASC, b.bid_id ASC
    LIMIT 1;

    IF v_top_id IS DISTINCT FROM NEW.bid_id THEN
      RETURN NULL;
    END IF;

    SELECT lower(btrim(coalesce(l.listing_type::text, '')))
    INTO v_listing_type
    FROM public."Player_Transfer_Listings" l
    WHERE l.id = NEW.listing_id;

    v_pid := coalesce(NEW.player_id, NEW.direct_bid_id::text);

    IF v_listing_type = 'draft'
       OR (NEW.is_direct AND NEW.seller_club_id IS NULL) THEN
      v_market := 'player_draft';
      v_key := v_pid;
      v_href := 'draftauction_player.html?player=' || v_pid;
    ELSE
      v_market := 'transfer_list';
      v_key := 'listing:' || NEW.listing_id::text;
      v_href := 'all_listings.html';
    END IF;

    PERFORM public.club_wire_clear_outbid(
      public.club_wire_owner_of(NEW.bidder_club_id), v_market, v_key
    );

    SELECT b.bidder_club_id, b.bid_amount INTO v_prev
    FROM public."Player_Transfer_Bids" b
    WHERE b.listing_id = NEW.listing_id
      AND b.bid_id <> NEW.bid_id
      AND b.bidder_club_id IS DISTINCT FROM b.seller_club_id
    ORDER BY b.bid_amount DESC, b.bid_time ASC, b.bid_id ASC
    LIMIT 1;

    IF v_prev.bidder_club_id IS NULL OR v_prev.bidder_club_id = NEW.bidder_club_id THEN
      RETURN NULL;
    END IF;

    SELECT p."Name" INTO v_name FROM public."Players" p WHERE p."Konami_ID"::text = v_pid;

    PERFORM public.club_wire_push(
      public.club_wire_owner_of(v_prev.bidder_club_id),
      v_prev.bidder_club_id,
      v_market,
      'outbid',
      v_key,
      coalesce(v_name, 'Player ' || coalesce(v_pid, '')),
      NEW.bid_amount,
      public.club_wire_club_name(NEW.bidder_club_id),
      v_href
    );
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'club wire (player bid): %', SQLERRM;
  END;
  RETURN NULL;
END;
$function$;

DROP TRIGGER IF EXISTS player_transfer_bids_zz_club_wire ON public."Player_Transfer_Bids";
CREATE TRIGGER player_transfer_bids_zz_club_wire
  AFTER INSERT ON public."Player_Transfer_Bids"
  FOR EACH ROW EXECUTE FUNCTION public.trg_club_wire_player_bid();

-- ---------------------------------------------------------------------------
-- 2) Seller review enter / resolve (listing status)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.trg_club_wire_listing_seller_review()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_was_review boolean;
  v_now_review boolean;
  v_pid text;
  v_name text;
  v_key text;
  v_buyer text;
  v_seller text;
  v_amt numeric;
  v_seller_owner uuid;
  v_buyer_owner uuid;
BEGIN
  BEGIN
    -- Draft / free-agent board: no seller review UX
    IF lower(btrim(coalesce(NEW.listing_type::text, ''))) = 'draft' THEN
      RETURN NULL;
    END IF;

    v_was_review := lower(btrim(coalesce(OLD.status::text, ''))) IN ('review', 'seller review');
    v_now_review := lower(btrim(coalesce(NEW.status::text, ''))) IN ('review', 'seller review');

    IF NOT v_was_review AND NOT v_now_review THEN
      RETURN NULL;
    END IF;
    IF OLD.status IS NOT DISTINCT FROM NEW.status
       AND OLD.transfer_completed IS NOT DISTINCT FROM NEW.transfer_completed THEN
      RETURN NULL;
    END IF;

    v_pid := nullif(btrim(coalesce(NEW.player_id::text, '')), '');
    v_key := 'listing:' || NEW.id::text;
    v_seller := upper(btrim(coalesce(NEW.seller_club_id::text, '')));
    v_buyer := upper(btrim(coalesce(
      NEW.current_highest_bidder::text,
      NEW.winning_club::text,
      ''
    )));
    v_amt := coalesce(NEW.current_highest_bid, NEW.winning_bid);

    SELECT p."Name" INTO v_name
    FROM public."Players" p
    WHERE p."Konami_ID"::text = v_pid;

    v_seller_owner := public.club_wire_owner_of(v_seller);
    v_buyer_owner := public.club_wire_owner_of(nullif(v_buyer, ''));

    -- Entering seller review
    IF v_now_review AND NOT v_was_review THEN
      IF v_seller_owner IS NOT NULL THEN
        PERFORM public.club_wire_push(
          v_seller_owner,
          v_seller,
          'transfer_list',
          'review_needed',
          v_key,
          coalesce(v_name, 'Player'),
          v_amt,
          CASE WHEN v_buyer <> '' THEN public.club_wire_club_name(v_buyer) ELSE NULL END,
          'transfer_center.html'
        );
      END IF;

      IF v_buyer_owner IS NOT NULL AND v_buyer IS DISTINCT FROM v_seller THEN
        -- Leading bidder is waiting on the seller, not "outbid"
        PERFORM public.club_wire_clear_outbid(v_buyer_owner, 'transfer_list', v_key);
        PERFORM public.club_wire_push(
          v_buyer_owner,
          v_buyer,
          'transfer_list',
          'under_review',
          v_key,
          coalesce(v_name, 'Player'),
          v_amt,
          public.club_wire_club_name(v_seller),
          'transfer_center.html'
        );
      END IF;

      RETURN NULL;
    END IF;

    -- Leaving seller review → accepted or declined
    IF v_was_review AND NOT v_now_review THEN
      IF v_seller_owner IS NOT NULL THEN
        PERFORM public.club_wire_clear_kinds(
          v_seller_owner, 'transfer_list', v_key,
          ARRAY['review_needed', 'under_review']
        );
      END IF;
      IF v_buyer_owner IS NOT NULL THEN
        PERFORM public.club_wire_clear_kinds(
          v_buyer_owner, 'transfer_list', v_key,
          ARRAY['review_needed', 'under_review', 'outbid']
        );
      END IF;

      IF coalesce(NEW.transfer_completed, false) THEN
        IF v_seller_owner IS NOT NULL THEN
          PERFORM public.club_wire_push(
            v_seller_owner,
            v_seller,
            'transfer_list',
            'review_accepted',
            v_key,
            coalesce(v_name, 'Player'),
            v_amt,
            CASE WHEN v_buyer <> '' THEN public.club_wire_club_name(v_buyer) ELSE NULL END,
            'transfer_center.html'
          );
        END IF;
        IF v_buyer_owner IS NOT NULL AND v_buyer IS DISTINCT FROM v_seller THEN
          PERFORM public.club_wire_push(
            v_buyer_owner,
            v_buyer,
            'transfer_list',
            'review_accepted',
            v_key,
            coalesce(v_name, 'Player'),
            v_amt,
            public.club_wire_club_name(v_seller),
            'squad.html'
          );
        END IF;
      ELSE
        IF v_seller_owner IS NOT NULL THEN
          PERFORM public.club_wire_push(
            v_seller_owner,
            v_seller,
            'transfer_list',
            'review_declined',
            v_key,
            coalesce(v_name, 'Player'),
            v_amt,
            CASE WHEN v_buyer <> '' THEN public.club_wire_club_name(v_buyer) ELSE NULL END,
            'transfer_center.html'
          );
        END IF;
        IF v_buyer_owner IS NOT NULL AND v_buyer IS DISTINCT FROM v_seller THEN
          PERFORM public.club_wire_push(
            v_buyer_owner,
            v_buyer,
            'transfer_list',
            'review_declined',
            v_key,
            coalesce(v_name, 'Player'),
            v_amt,
            public.club_wire_club_name(v_seller),
            'all_listings.html'
          );
        END IF;
      END IF;
    END IF;
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'club wire (seller review): %', SQLERRM;
  END;
  RETURN NULL;
END;
$function$;

DROP TRIGGER IF EXISTS player_transfer_listings_zz_club_wire_review
  ON public."Player_Transfer_Listings";
CREATE TRIGGER player_transfer_listings_zz_club_wire_review
  AFTER UPDATE OF status, transfer_completed ON public."Player_Transfer_Listings"
  FOR EACH ROW EXECUTE FUNCTION public.trg_club_wire_listing_seller_review();

NOTIFY pgrst, 'reload schema';

SELECT jsonb_build_object(
  'player_bid_fn', to_regprocedure('public.trg_club_wire_player_bid()') IS NOT NULL,
  'review_fn', to_regprocedure('public.trg_club_wire_listing_seller_review()') IS NOT NULL,
  'review_trigger', EXISTS (
    SELECT 1 FROM pg_trigger t
    JOIN pg_class c ON c.oid = t.tgrelid
    WHERE c.relname = 'Player_Transfer_Listings'
      AND t.tgname = 'player_transfer_listings_zz_club_wire_review'
      AND NOT t.tgisinternal
  )
) AS ok;
