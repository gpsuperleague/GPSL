-- Fix: Supabase blocks DELETE/UPDATE without WHERE
-- Run full patches/admin_prelaunch_test_reset.sql in SQL Editor, then retry Execute.
--
-- Known fixes included in that file:
--   DELETE ... WHERE true
--   UPDATE Club_Finances ... WHERE true
--   UPDATE Clubs counters ... WHERE "ShortName" IS NOT NULL
--   Clear Clubs.stadium_fill_season_id before DELETE competition_seasons

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
