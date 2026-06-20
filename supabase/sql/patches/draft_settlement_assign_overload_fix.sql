-- =============================================================================
-- Draft settlement — player_assign_to_club(text, text) overload ambiguity
--
-- Symptom: explain_draft_listing looks fine; probe/run settle 0; no SQL error.
-- Cause: (1) void player_assign_to_club(text,text) + jsonb 4-arg overload ambiguity
--        (2) updated_at column does not exist on Player_Transfer_Listings
--
-- Run in SQL Editor, then:
--   SELECT public.transferengine_try_accept_draft_sale(215);
--   SELECT public.transferengine_run_report();
-- =============================================================================

DROP FUNCTION IF EXISTS public.player_assign_to_club(text, text);

CREATE OR REPLACE FUNCTION public.transferengine_try_accept_draft_sale(p_listing_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_closed boolean;
BEGIN
  PERFORM public.transferengine_accept_draft_sale(p_listing_id);

  SELECT EXISTS (
    SELECT 1
    FROM public."Player_Transfer_Listings" l
    WHERE l.id = p_listing_id
      AND l.status = 'Closed'
      AND l.transfer_completed = true
  ) INTO v_closed;

  RETURN jsonb_build_object(
    'listing_id', p_listing_id,
    'ok', v_closed,
    'status', (SELECT l.status FROM public."Player_Transfer_Listings" l WHERE l.id = p_listing_id),
    'transfer_completed', (
      SELECT l.transfer_completed FROM public."Player_Transfer_Listings" l WHERE l.id = p_listing_id
    )
  );
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object(
    'listing_id', p_listing_id,
    'ok', false,
    'error', SQLERRM,
    'sqlstate', SQLSTATE
  );
END;
$function$;


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

  IF NOT EXISTS (
    SELECT 1 FROM public."Club_Finances" f WHERE f.club_name = v_buyer
  ) THEN
    RAISE EXCEPTION 'Club_Finances missing for buyer % (listing %)', v_buyer, p_listing_id;
  END IF;

  PERFORM public.assert_player_available_for_signing(v_pid);

  -- Pin 4-arg overload (NULL wage = auto; defer via transferengine_run config).
  PERFORM public.player_assign_to_club(v_pid, v_buyer, NULL::numeric, false);

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

  PERFORM public.post_transfer_ledger_for_history(v_history_id);

  UPDATE public."Player_Transfer_Listings"
  SET status = 'Closed',
      transfer_completed = true,
      winning_bid = v_amount,
      winning_club = v_buyer
  WHERE id = v_listing.id;
END;
$function$;


CREATE OR REPLACE FUNCTION public.transferengine_probe_draft_settlement(p_limit int DEFAULT 3)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_listing record;
  v_limit int := greatest(coalesce(p_limit, 3), 1);
  v_results jsonb := '[]'::jsonb;
  v_try jsonb;
  v_season record;
BEGIN
  SELECT s.id, s.label, s.status, s.is_current
  INTO v_season
  FROM public.competition_seasons s
  WHERE s.is_current = true
  ORDER BY s.id DESC
  LIMIT 1;

  FOR v_listing IN
    SELECT l.id
    FROM public."Player_Transfer_Listings" l
    WHERE l.listing_type = 'draft'
      AND l.status = 'Active'
      AND l.current_highest_bidder IS NOT NULL
    ORDER BY l.id
    LIMIT v_limit
  LOOP
    v_try := public.transferengine_try_accept_draft_sale(v_listing.id);
    v_results := v_results || jsonb_build_array(v_try);
  END LOOP;

  RETURN jsonb_build_object(
    'current_season', jsonb_build_object(
      'id', v_season.id,
      'label', v_season.label,
      'status', v_season.status,
      'is_current', v_season.is_current
    ),
    'probed', jsonb_array_length(v_results),
    'results', v_results
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.transferengine_try_accept_draft_sale(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.transferengine_try_accept_draft_sale(bigint) TO service_role;

NOTIFY pgrst, 'reload schema';
