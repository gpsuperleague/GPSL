-- Fix: Supabase blocks DELETE/UPDATE without WHERE ("DELETE requires a WHERE clause")
-- Run once in SQL Editor, then retry Execute on admin_test_reset.html
--
-- Option A: run this file (minimal)
-- Option B: re-run full patches/admin_prelaunch_test_reset.sql + admin_club_auction_reset in club_auction.sql

CREATE OR REPLACE FUNCTION public.admin_club_auction_reset()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_listings int;
  v_bids int;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  SELECT count(*)::int INTO v_bids FROM public."Club_Auction_Bids";
  SELECT count(*)::int INTO v_listings FROM public."Club_Auction_Listings";

  DELETE FROM public."Club_Auction_Bids" WHERE true;
  DELETE FROM public."Club_Auction_Listings" WHERE true;

  RETURN jsonb_build_object(
    'ok', true,
    'deleted_listings', v_listings,
    'deleted_bids', v_bids
  );
END;
$function$;

-- admin_test_reset_execute: re-deploy from patches/admin_prelaunch_test_reset.sql (full file)
-- or paste the CREATE OR REPLACE FUNCTION admin_test_reset_execute block from that file after this.

NOTIFY pgrst, 'reload schema';
