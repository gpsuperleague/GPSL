-- A max bid or leading bid from an earlier manager draft must not stay live
-- in the next window. Unsold history stays on the closed listing; it is not
-- the current auction.
CREATE TEMP TABLE IF NOT EXISTS _mgr_draft_clear (max_n int, listing_n int);
TRUNCATE _mgr_draft_clear;

DO $clear$
DECLARE
  v_start timestamptz;
  v_end timestamptz;
  v_max int := 0;
  v_listings int := 0;
BEGIN
  SELECT w.draft_start, w.draft_window_end
  INTO v_start, v_end
  FROM public.manager_draft_auction_window_bounds() w;

  IF v_start IS NOT NULL THEN
    DELETE FROM public.manager_draft_max_bids m
    WHERE m.updated_at < v_start;
    GET DIAGNOSTICS v_max = ROW_COUNT;

    UPDATE public."Manager_Transfer_Listings" l
    SET current_highest_bid = NULL,
        current_highest_bidder = NULL,
        updated_at = now()
    WHERE l.listing_type = 'draft'
      AND l.status = 'Active'
      AND l.current_highest_bidder IS NOT NULL
      AND NOT EXISTS (
        SELECT 1
        FROM public."Manager_Transfer_Bids" b
        WHERE b.listing_id = l.id
          AND b.is_direct IS TRUE
          AND b.bid_time >= v_start
          AND (v_end IS NULL OR b.bid_time < v_end)
      );
    GET DIAGNOSTICS v_listings = ROW_COUNT;
  END IF;

  INSERT INTO _mgr_draft_clear VALUES (v_max, v_listings);
END;
$clear$;

CREATE OR REPLACE FUNCTION public.manager_draft_get_my_max_bid(p_manager_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := public.my_club_shortname();
  v_row public.manager_draft_max_bids%rowtype;
  v_bounds record;
BEGIN
  IF v_club IS NULL THEN
    RETURN jsonb_build_object('max_amount', NULL);
  END IF;

  SELECT * INTO v_bounds FROM public.manager_draft_auction_window_bounds();

  SELECT * INTO v_row
  FROM public.manager_draft_max_bids
  WHERE club_short_name = v_club
    AND manager_id = p_manager_id
    AND (
      v_bounds.draft_start IS NULL
      OR updated_at >= v_bounds.draft_start
    );
  IF NOT FOUND THEN
    RETURN jsonb_build_object('max_amount', NULL);
  END IF;
  RETURN jsonb_build_object('max_amount', v_row.max_amount, 'updated_at', v_row.updated_at);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.manager_draft_get_my_max_bid(bigint) TO authenticated;

NOTIFY pgrst, 'reload schema';

SELECT jsonb_build_object(
  'cleared_old_max_bids', (SELECT max_n FROM _mgr_draft_clear),
  'cleared_stale_active_leaders', (SELECT listing_n FROM _mgr_draft_clear),
  'slb', (
    SELECT jsonb_build_object(
      'manager_id', c.manager_id,
      'manager', m.name
    )
    FROM public."Clubs" c
    LEFT JOIN public."Managers" m ON m.id = c.manager_id
    WHERE c."ShortName" = 'SLB'
  ),
  'valbuena_max_left', (
    SELECT count(*)
    FROM public.manager_draft_max_bids x
    WHERE x.manager_id = 99 AND x.club_short_name = 'SLB'
  )
) AS result;
