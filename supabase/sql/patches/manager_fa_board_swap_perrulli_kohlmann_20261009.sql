-- =============================================================================
-- Manager FA board: swap Anton Perrulli → G. Kohlmann (2026-10-09)
-- Cancels Perrulli's live board listing and lists Kohlmann with the same end
-- time. Stops (no changes) if Kohlmann is contracted or already listed.
-- Safe re-run.
-- =============================================================================

DROP TABLE IF EXISTS _gpsl_fa_swap;
CREATE TEMP TABLE _gpsl_fa_swap (step text, detail jsonb);

DO $swap$
DECLARE
  v_out_id bigint;
  v_in_id bigint;
  v_in_name text;
  v_in_club text;
  v_in_mv bigint;
  v_listing record;
  v_bids int := 0;
  v_new_id bigint;
BEGIN
  SELECT m.id, m.name, nullif(btrim(coalesce(m.contracted_club, '')), ''), coalesce(m.market_value, 0)
  INTO v_in_id, v_in_name, v_in_club, v_in_mv
  FROM public."Managers" m
  WHERE m.name ILIKE '%kohlmann%'
  ORDER BY m.id
  LIMIT 1;

  IF v_in_id IS NULL THEN
    INSERT INTO _gpsl_fa_swap VALUES ('stopped', jsonb_build_object('reason', 'Kohlmann not found in Managers'));
    RETURN;
  END IF;
  IF v_in_club IS NOT NULL THEN
    INSERT INTO _gpsl_fa_swap VALUES ('stopped', jsonb_build_object('reason', 'Kohlmann is contracted', 'club', v_in_club));
    RETURN;
  END IF;
  IF EXISTS (
    SELECT 1 FROM public."Manager_Transfer_Listings" l
    WHERE l.manager_id = v_in_id AND l.status = 'Active'
  ) THEN
    INSERT INTO _gpsl_fa_swap VALUES ('stopped', jsonb_build_object('reason', 'Kohlmann already has an active listing'));
    RETURN;
  END IF;

  SELECT l.* INTO v_listing
  FROM public."Manager_Transfer_Listings" l
  JOIN public."Managers" m ON m.id = l.manager_id
  WHERE m.name ILIKE '%perrull%'
    AND l.listing_type = 'window_fa'
    AND l.status = 'Active'
  ORDER BY l.id DESC
  LIMIT 1;

  IF v_listing.id IS NULL THEN
    INSERT INTO _gpsl_fa_swap VALUES ('stopped', jsonb_build_object('reason', 'No active FA-board listing for Perrulli'));
    RETURN;
  END IF;
  v_out_id := v_listing.manager_id;

  SELECT count(*) INTO v_bids
  FROM public."Manager_Transfer_Bids" b
  WHERE b.listing_id = v_listing.id;

  UPDATE public."Manager_Transfer_Listings"
  SET status = 'Cancelled',
      updated_at = now(),
      metadata = coalesce(metadata, '{}'::jsonb) || jsonb_build_object(
        'cancelled_reason', 'admin_swap',
        'replaced_by_manager_id', v_in_id,
        'cancelled_at', now()
      )
  WHERE id = v_listing.id;

  INSERT INTO _gpsl_fa_swap VALUES ('removed', jsonb_build_object(
    'listing_id', v_listing.id, 'manager_id', v_out_id, 'bids_on_it', v_bids,
    'high_bid', v_listing.current_highest_bid, 'high_bidder', v_listing.current_highest_bidder
  ));

  INSERT INTO public."Manager_Transfer_Listings" (
    manager_id, seller_club_id, listing_type, status, end_time, market_value, metadata
  )
  VALUES (
    v_in_id, NULL, 'window_fa', 'Active', v_listing.end_time, v_in_mv,
    coalesce(v_listing.metadata, '{}'::jsonb)
      - 'cancelled_reason' - 'replaced_by_manager_id' - 'cancelled_at'
      || jsonb_build_object('admin_swap_for_listing', v_listing.id)
  )
  RETURNING id INTO v_new_id;

  INSERT INTO _gpsl_fa_swap VALUES ('added', jsonb_build_object(
    'listing_id', v_new_id, 'manager', v_in_name, 'manager_id', v_in_id,
    'market_value', v_in_mv, 'ends', v_listing.end_time
  ));
END
$swap$;

SELECT
  s.step,
  s.detail,
  (
    SELECT jsonb_agg(m.name || ' (' || coalesce(m.rating::text, '?') || ')' ORDER BY m.rating DESC)
    FROM public."Manager_Transfer_Listings" l
    JOIN public."Managers" m ON m.id = l.manager_id
    WHERE l.listing_type = 'window_fa' AND l.status = 'Active' AND l.end_time > now()
  ) AS board_now
FROM _gpsl_fa_swap s;
