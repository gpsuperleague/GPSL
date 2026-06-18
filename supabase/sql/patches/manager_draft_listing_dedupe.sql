-- =============================================================================
-- Manager draft — one active listing per manager
-- Fixes duplicate rows on manager_draftauction.html (e.g. Fran Cudoreni x2).
-- =============================================================================

-- Close duplicate active draft listings (keep best: has leader, then highest bid, then oldest id).
WITH ranked AS (
  SELECT
    l.id,
    row_number() OVER (
      PARTITION BY l.manager_id
      ORDER BY
        CASE WHEN nullif(btrim(l.current_highest_bidder), '') IS NOT NULL THEN 0 ELSE 1 END,
        coalesce(l.current_highest_bid, 0) DESC,
        l.id ASC
    ) AS rn
  FROM public."Manager_Transfer_Listings" l
  WHERE l.listing_type = 'draft'
    AND l.status = 'Active'
)
UPDATE public."Manager_Transfer_Listings" l
SET
  status = 'Closed',
  transfer_completed = false,
  updated_at = now()
FROM ranked r
WHERE l.id = r.id
  AND r.rn > 1;

-- Prevent future duplicates (race on ensureManagerDraftListing + maybeSingle).
CREATE UNIQUE INDEX IF NOT EXISTS manager_draft_one_active_listing_per_manager
  ON public."Manager_Transfer_Listings" (manager_id)
  WHERE listing_type = 'draft' AND status = 'Active';

CREATE OR REPLACE FUNCTION public.manager_draft_ensure_listing(p_manager_id bigint)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_listing_id bigint;
  v_mv bigint;
  v_end timestamptz;
BEGIN
  SELECT l.id
  INTO v_listing_id
  FROM public."Manager_Transfer_Listings" l
  WHERE l.manager_id = p_manager_id
    AND l.listing_type = 'draft'
    AND l.status = 'Active'
  ORDER BY
    CASE WHEN nullif(btrim(l.current_highest_bidder), '') IS NOT NULL THEN 0 ELSE 1 END,
    coalesce(l.current_highest_bid, 0) DESC,
    l.id ASC
  LIMIT 1
  FOR UPDATE;

  IF v_listing_id IS NOT NULL THEN
    UPDATE public."Manager_Transfer_Listings" l
    SET status = 'Closed', updated_at = now()
    WHERE l.manager_id = p_manager_id
      AND l.listing_type = 'draft'
      AND l.status = 'Active'
      AND l.id <> v_listing_id;

    RETURN v_listing_id;
  END IF;

  SELECT coalesce(m.market_value, 0)
  INTO v_mv
  FROM public."Managers" m
  WHERE m.id = p_manager_id;

  v_end := date_trunc('day', now() AT TIME ZONE 'Europe/London')
    + interval '1 day 18 hours 50 minutes';

  INSERT INTO public."Manager_Transfer_Listings" (
    manager_id,
    seller_club_id,
    listing_type,
    status,
    end_time,
    market_value
  )
  VALUES (
    p_manager_id,
    NULL,
    'draft',
    'Active',
    v_end + (floor(random() * 600)) * interval '1 second',
    v_mv
  )
  RETURNING id INTO v_listing_id;

  RETURN v_listing_id;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.manager_draft_ensure_listing(bigint) TO authenticated;

NOTIFY pgrst, 'reload schema';

-- Verify Fran Cudoreni (slug fran-cudoreni):
-- SELECT l.id, l.manager_id, m.name, l.status, l.current_highest_bid, l.current_highest_bidder
-- FROM public."Manager_Transfer_Listings" l
-- JOIN public."Managers" m ON m.id = l.manager_id
-- WHERE m.slug = 'fran-cudoreni' AND l.listing_type = 'draft'
-- ORDER BY l.status, l.id;
