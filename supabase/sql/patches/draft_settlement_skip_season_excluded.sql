-- =============================================================================
-- Draft settlement — skip season-excluded players (do not abort the whole run)
--
-- Symptom:
--   Admin → Run transfer engine fails with:
--   "This player is excluded from GPSL for the current season (admin season exclusion)."
--   All finished draft winners stay Active (none settle).
--
-- Cause:
--   transferengine_accept_draft_sale → assert_player_available_for_signing
--   RAISE EXCEPTION aborts the transferengine_run() transaction.
--
-- Fix:
--   If the player is season-excluded, close the draft listing as incomplete
--   (no debit / no assign) and continue settling other winners.
--
-- Run in Supabase SQL Editor, then:
--   SELECT public.admin_transferengine_run();
--   -- or --
--   SELECT public.transferengine_run_report();
--
-- Diagnose which listing(s) are excluded (optional):
--   SELECT l.id, l.player_id, p."Name", l.current_highest_bidder, l.current_highest_bid
--   FROM public."Player_Transfer_Listings" l
--   JOIN public."Players" p ON p."Konami_ID"::text = btrim(l.player_id::text)
--   WHERE l.listing_type = 'draft' AND l.status = 'Active'
--     AND public.gpdb_player_is_season_excluded(btrim(l.player_id::text));
-- =============================================================================

CREATE OR REPLACE FUNCTION public.transferengine_accept_draft_sale(p_listing_id bigint)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_listing public."Player_Transfer_Listings"%rowtype;
  v_amount  numeric;
  v_buyer   text;
  v_player  public."Players"%rowtype;
  v_history_id bigint;
  v_draft_start timestamptz;
  v_pid     text;
BEGIN
  SELECT draft_auction_start_time INTO v_draft_start
  FROM public.global_settings WHERE id = 1;

  SELECT *
  INTO v_listing
  FROM public."Player_Transfer_Listings"
  WHERE id = p_listing_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN;
  END IF;

  IF v_listing.listing_type IS DISTINCT FROM 'draft' THEN
    RETURN;
  END IF;

  IF v_listing.status NOT IN ('Active', 'Review') THEN
    RETURN;
  END IF;

  -- THIS auction's leader (sync trigger) wins — not all-time max bid on player_id
  v_buyer := public.transferengine_normalize_club_short_name(
    v_listing.current_highest_bidder::text
  );
  v_amount := v_listing.current_highest_bid;

  IF v_buyer IS NULL OR v_amount IS NULL OR v_amount <= 0 THEN
    SELECT b.bid_amount, b.bidder_club_id
    INTO v_amount, v_buyer
    FROM public."Player_Transfer_Bids" b
    WHERE b.is_direct = true
      AND b.listing_id = v_listing.id
      AND (v_draft_start IS NULL OR b.bid_time >= v_draft_start)
    ORDER BY b.bid_amount DESC, b.bid_time ASC
    LIMIT 1;

    v_buyer := public.transferengine_normalize_club_short_name(v_buyer);
  END IF;

  IF v_buyer IS NULL OR v_amount IS NULL OR v_amount <= 0 THEN
    UPDATE public."Player_Transfer_Listings"
    SET status = 'Closed',
        transfer_completed = false
    WHERE id = v_listing.id;
    RETURN;
  END IF;

  UPDATE public."Player_Transfer_Listings"
  SET current_highest_bid = v_amount,
      current_highest_bidder = v_buyer
  WHERE id = v_listing.id;

  v_pid := btrim(v_listing.player_id::text);

  SELECT *
  INTO v_player
  FROM public."Players"
  WHERE "Konami_ID"::text = v_pid
  FOR UPDATE;

  IF NOT FOUND THEN
    UPDATE public."Player_Transfer_Listings"
    SET status = 'Closed',
        transfer_completed = false
    WHERE id = v_listing.id;
    RETURN;
  END IF;

  IF v_player."Contracted_Team" IS NOT NULL
     AND btrim(v_player."Contracted_Team"::text) <> '' THEN
    UPDATE public."Player_Transfer_Listings"
    SET status = 'Closed',
        transfer_completed = (btrim(v_player."Contracted_Team"::text) = v_buyer),
        winning_bid = CASE WHEN btrim(v_player."Contracted_Team"::text) = v_buyer THEN v_amount ELSE winning_bid END,
        winning_club = CASE WHEN btrim(v_player."Contracted_Team"::text) = v_buyer THEN v_buyer ELSE winning_club END
    WHERE id = v_listing.id;
    RETURN;
  END IF;

  -- Season exclusion: close without assigning (do NOT RAISE — that aborts the whole engine)
  IF public.gpdb_player_is_season_excluded(v_pid) THEN
    UPDATE public."Player_Transfer_Listings"
    SET status = 'Closed',
        transfer_completed = false
    WHERE id = v_listing.id;
    RAISE NOTICE
      'Draft listing % skipped — player % is season-excluded (admin GPDB exclusion)',
      p_listing_id, v_pid;
    RETURN;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public."Club_Finances" f WHERE f.club_name = v_buyer
  ) THEN
    RAISE EXCEPTION 'Club_Finances missing for buyer % (listing %)', v_buyer, p_listing_id;
  END IF;

  -- Foreign-contract / other availability (still hard-fail if not exclusion)
  IF to_regprocedure('public.assert_player_available_for_signing(text)') IS NOT NULL THEN
    BEGIN
      PERFORM public.assert_player_available_for_signing(v_pid);
    EXCEPTION
      WHEN OTHERS THEN
        IF SQLERRM ILIKE '%excluded from GPSL%'
           OR SQLERRM ILIKE '%season exclusion%' THEN
          UPDATE public."Player_Transfer_Listings"
          SET status = 'Closed',
              transfer_completed = false
          WHERE id = v_listing.id;
          RAISE NOTICE
            'Draft listing % skipped — %',
            p_listing_id, SQLERRM;
          RETURN;
        END IF;
        RAISE;
    END;
  END IF;

  -- Prefer 4-arg overload when present (wage NULL = auto; defer overflow in batch)
  IF to_regprocedure('public.player_assign_to_club(text, text, numeric, boolean)') IS NOT NULL THEN
    PERFORM public.player_assign_to_club(v_pid, v_buyer, NULL::numeric, false);
  ELSE
    PERFORM public.player_assign_to_club(v_pid, v_buyer, NULL::numeric);
  END IF;

  INSERT INTO public."Transfer_History" (
    player_id,
    seller_club_id,
    buyer_club_id,
    fee,
    agent_fee,
    transfer_time,
    listing_id
  )
  VALUES (
    v_pid,
    NULL,
    v_buyer,
    v_amount,
    0,
    now(),
    v_listing.id
  )
  RETURNING id INTO v_history_id;

  IF to_regprocedure('public.post_transfer_ledger_for_history(bigint)') IS NOT NULL THEN
    PERFORM public.post_transfer_ledger_for_history(v_history_id);
  END IF;

  UPDATE public."Player_Transfer_Listings"
  SET status = 'Closed',
      transfer_completed = true,
      winning_bid = v_amount,
      winning_club = v_buyer
  WHERE id = v_listing.id;
END;
$function$;


-- Ensure per-listing errors cannot abort the batch (belt and braces)
CREATE OR REPLACE FUNCTION public.transferengine_settle_player_draft_listings(
  p_batch_limit int DEFAULT 100
)
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_listing public."Player_Transfer_Listings"%rowtype;
  v_settled int := 0;
  v_limit int := greatest(coalesce(p_batch_limit, 100), 1);
BEGIN
  FOR v_listing IN
    SELECT *
    FROM public."Player_Transfer_Listings"
    WHERE listing_type = 'draft'
      AND status = 'Active'
    ORDER BY id
    LIMIT v_limit
  LOOP
    BEGIN
      PERFORM public.transferengine_accept_draft_sale(v_listing.id);
      IF EXISTS (
        SELECT 1
        FROM public."Player_Transfer_Listings" l
        WHERE l.id = v_listing.id
          AND l.status = 'Closed'
          AND l.transfer_completed = true
      ) THEN
        v_settled := v_settled + 1;
      END IF;
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'transferengine_accept_draft_sale listing % failed: %',
        v_listing.id, SQLERRM;
    END;
  END LOOP;

  RETURN v_settled;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.transferengine_accept_draft_sale(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.transferengine_accept_draft_sale(bigint) TO service_role;
GRANT EXECUTE ON FUNCTION public.transferengine_settle_player_draft_listings(int) TO authenticated;
GRANT EXECUTE ON FUNCTION public.transferengine_settle_player_draft_listings(int) TO service_role;
