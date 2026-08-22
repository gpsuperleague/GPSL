-- =============================================================================
-- Fix draft settlement skipping purchase ledger + repair ALL clubs
--
-- Root cause:
--   transferengine_accept_draft_sale checked
--     to_regprocedure('post_transfer_ledger_for_history(bigint)')
--   but live DB only had
--     post_transfer_ledger_for_history(bigint, boolean DEFAULT true)
--   so the IF was false → Transfer_History written, player assigned, listing
--   closed, but NO competition_finance_ledger / NO Club_Finances debit.
--
-- This patch:
--   1) Hardens accept_draft_sale to always post ledger (fails loud if missing)
--   2) Summary RPC for every club with gaps
--
-- After apply (repair uses existing admin_repair_missing_purchase_ledgers):
--   SELECT * FROM public.admin_missing_purchase_ledgers_summary();
--   SELECT public.admin_repair_missing_purchase_ledgers(true,  NULL, true);  -- dry-run all
--   SELECT public.admin_repair_missing_purchase_ledgers(false, NULL, true); -- apply all
-- Safe re-run.
-- =============================================================================

-- Harden draft accept: never skip ledger after writing Transfer_History
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

  IF to_regprocedure('public.transferengine_normalize_club_short_name(text)') IS NOT NULL THEN
    v_buyer := public.transferengine_normalize_club_short_name(
      v_listing.current_highest_bidder::text
    );
  ELSE
    v_buyer := nullif(btrim(v_listing.current_highest_bidder::text), '');
  END IF;
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

    IF to_regprocedure('public.transferengine_normalize_club_short_name(text)') IS NOT NULL THEN
      v_buyer := public.transferengine_normalize_club_short_name(v_buyer);
    ELSE
      v_buyer := nullif(btrim(v_buyer), '');
    END IF;
  END IF;

  IF v_buyer IS NULL OR v_amount IS NULL OR v_amount <= 0 THEN
    PERFORM public.transferengine_close_listing_incomplete(v_listing.id);
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
    PERFORM public.transferengine_close_listing_incomplete(v_listing.id);
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

  IF to_regprocedure('public.gpdb_player_is_season_excluded(text)') IS NOT NULL
     AND public.gpdb_player_is_season_excluded(v_pid) THEN
    PERFORM public.transferengine_close_listing_incomplete(v_listing.id);
    RAISE NOTICE
      'Draft listing % skipped — player % (%) is season-excluded',
      p_listing_id, v_pid, coalesce(v_player."Name", '?');
    RETURN;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public."Club_Finances" f WHERE f.club_name = v_buyer
  ) THEN
    RAISE EXCEPTION 'Club_Finances missing for buyer % (listing %)', v_buyer, p_listing_id;
  END IF;

  BEGIN
    IF to_regprocedure('public.player_assign_to_club(text, text, numeric, boolean)') IS NOT NULL THEN
      PERFORM public.player_assign_to_club(v_pid, v_buyer, NULL::numeric, false);
    ELSIF to_regprocedure('public.player_assign_to_club(text, text, numeric)') IS NOT NULL THEN
      PERFORM public.player_assign_to_club(v_pid, v_buyer, NULL::numeric);
    ELSE
      PERFORM public.player_assign_to_club(v_pid, v_buyer);
    END IF;
  EXCEPTION WHEN OTHERS THEN
    IF to_regprocedure('public.transferengine_is_exclusion_error(text)') IS NOT NULL
       AND public.transferengine_is_exclusion_error(SQLERRM) THEN
      PERFORM public.transferengine_close_listing_incomplete(v_listing.id);
      RAISE NOTICE 'Draft listing % skipped after assign guard: %', p_listing_id, SQLERRM;
      RETURN;
    END IF;
    RAISE;
  END;

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

  -- ALWAYS post ledger + debit (was skipped when to_regprocedure looked for 1-arg only)
  IF to_regprocedure('public.post_transfer_ledger_for_history(bigint, boolean)') IS NOT NULL THEN
    PERFORM public.post_transfer_ledger_for_history(v_history_id, true);
  ELSIF to_regprocedure('public.post_transfer_ledger_for_history(bigint)') IS NOT NULL THEN
    PERFORM public.post_transfer_ledger_for_history(v_history_id);
  ELSE
    RAISE EXCEPTION
      'post_transfer_ledger_for_history missing — draft listing % cannot settle without ledger',
      p_listing_id;
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.competition_finance_ledger l
    WHERE l.metadata->>'transfer_history_id' = v_history_id::text
      AND l.entry_type = 'transfer_purchase'
  ) THEN
    RAISE EXCEPTION
      'Draft listing % settled history % but transfer_purchase ledger row missing',
      p_listing_id, v_history_id;
  END IF;

  UPDATE public."Player_Transfer_Listings"
  SET status = 'Closed',
      transfer_completed = true,
      winning_bid = v_amount,
      winning_club = v_buyer
  WHERE id = v_listing.id;
END;
$function$;

COMMENT ON FUNCTION public.transferengine_accept_draft_sale(bigint) IS
  'Settle GPDB draft win: assign player, Transfer_History, ALWAYS transfer_purchase ledger + debit.';

-- Per-club summary of gaps
CREATE OR REPLACE FUNCTION public.admin_missing_purchase_ledgers_summary()
RETURNS TABLE (
  buyer_club_id text,
  missing_rows int,
  missing_fees numeric,
  live_balance numeric
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.is_gpsl_admin()
     AND current_user NOT IN ('postgres', 'supabase_admin', 'service_role') THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  RETURN QUERY
  SELECT
    h.buyer_club_id::text,
    count(*)::int AS missing_rows,
    coalesce(sum(h.fee), 0)::numeric AS missing_fees,
    cf.balance::numeric AS live_balance
  FROM public."Transfer_History" h
  LEFT JOIN public."Club_Finances" cf ON cf.club_name = h.buyer_club_id
  WHERE h.buyer_club_id IS NOT NULL
    AND btrim(h.buyer_club_id::text) <> ''
    AND h.buyer_club_id <> 'FOREIGN'
    AND NOT EXISTS (
      SELECT 1
      FROM public.competition_finance_ledger l
      WHERE l.metadata->>'transfer_history_id' = h.id::text
        AND l.entry_type = 'transfer_purchase'
    )
  GROUP BY h.buyer_club_id, cf.balance
  ORDER BY missing_fees DESC, h.buyer_club_id;
END;
$function$;

COMMENT ON FUNCTION public.admin_missing_purchase_ledgers_summary() IS
  'Admin: clubs with Transfer_History buys missing transfer_purchase ledger rows.';

GRANT EXECUTE ON FUNCTION public.admin_missing_purchase_ledgers_summary() TO authenticated;

NOTIFY pgrst, 'reload schema';
