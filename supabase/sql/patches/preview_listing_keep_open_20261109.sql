-- =============================================================================
-- Keep preview listings on the market
--
-- contract_close_locked_listings() runs every 15 minutes and was closing
-- Pending Window rows for players who are still sell-locked. That is the
-- preview case: listed now, sellable at the next window.
--
-- A Pending Window listing stays up when player_preview_listable is true.
-- Active listings for a locked player are still closed.
--
-- Also puts back preview rows closed in the last 36 hours (null auction
-- clock, no bids, still preview-listable, no newer open listing).
--
-- Run once in the Supabase SQL editor. Safe re-run.
-- Requires list_preview_next_window_20261109.sql
-- =============================================================================

CREATE OR REPLACE FUNCTION public.contract_close_locked_listings()
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_n int;
BEGIN
  UPDATE public."Player_Transfer_Listings" l
  SET status = 'Closed',
      transfer_completed = false,
      winning_bid = NULL,
      winning_club = NULL
  WHERE l.status IN ('Active', 'Pending Window')
    AND lower(coalesce(l.listing_type::text, '')) <> 'draft'
    AND nullif(btrim(coalesce(l.seller_club_id::text, '')), '') IS NOT NULL
    AND NOT coalesce(l.new_owner_slot, false)
    AND NOT coalesce(l.perpetual_renew, false)
    AND l.current_highest_bid IS NULL
    AND public.player_contract_sell_lock_reason(l.player_id::text) IS NOT NULL
    AND NOT (
      l.status = 'Pending Window'
      AND to_regprocedure('public.player_preview_listable(text)') IS NOT NULL
      AND public.player_preview_listable(l.player_id::text)
    );

  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END;
$function$;

UPDATE public."Player_Transfer_Listings" l
SET status = 'Pending Window'
WHERE l.status = 'Closed'
  AND l.created_at > now() - interval '36 hours'
  AND l.start_time IS NULL
  AND l.end_time IS NULL
  AND coalesce(l.transfer_completed, false) = false
  AND l.current_highest_bid IS NULL
  AND l.winning_bid IS NULL
  AND lower(coalesce(l.listing_type::text, '')) NOT IN ('draft', 'direct')
  AND NOT coalesce(l.new_owner_slot, false)
  AND NOT coalesce(l.perpetual_renew, false)
  AND public.player_preview_listable(l.player_id::text)
  AND NOT EXISTS (
    SELECT 1
    FROM public."Player_Transfer_Listings" o
    WHERE o.player_id = l.player_id
      AND o.id <> l.id
      AND o.status IN ('Pending Window', 'Active', 'Review', 'Seller Review')
      AND coalesce(o.transfer_completed, false) = false
  );

NOTIFY pgrst, 'reload schema';
