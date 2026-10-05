-- =============================================================================
-- Manager draft: server-side "lead only one auction at a time"
-- =============================================================================
-- The rule was only checked in the browser (manager_draft_engine.js) before a
-- direct INSERT into Manager_Transfer_Bids, and in the max-bid functions using
-- the listing's current_highest_bidder column (which manual bids don't update
-- immediately). Stale pages, quick double bids, or withdrawn rival bids let a
-- club end up leading several managers.
--
-- Fix: BEFORE INSERT trigger on draft bids — reject the bid if the club
-- already holds the highest current-window bid on another active draft listing
-- (leader computed from bid rows, not the cached column).
-- Bottom: report of clubs currently leading more than one manager.
-- Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.manager_draft_club_leading_other(
  p_club_short_name text,
  p_manager_id bigint
)
RETURNS bigint
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := upper(btrim(coalesce(p_club_short_name, '')));
  v_mid bigint;
BEGIN
  IF v_club = '' THEN
    RETURN NULL;
  END IF;

  SELECT l.manager_id INTO v_mid
  FROM public."Manager_Transfer_Listings" l
  WHERE l.listing_type = 'draft'
    AND l.status = 'Active'
    AND l.manager_id IS DISTINCT FROM p_manager_id
    AND upper(btrim(coalesce(public.manager_draft_current_leader(l.manager_id), ''))) = v_club
  ORDER BY l.id
  LIMIT 1;

  RETURN v_mid;
END;
$function$;

CREATE OR REPLACE FUNCTION public.trg_manager_draft_bid_one_lead()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_type text;
  v_other bigint;
  v_other_name text;
BEGIN
  IF coalesce(NEW.is_direct, false) IS NOT TRUE OR NEW.listing_id IS NULL THEN
    RETURN NEW;
  END IF;

  SELECT l.listing_type INTO v_type
  FROM public."Manager_Transfer_Listings" l
  WHERE l.id = NEW.listing_id;

  IF v_type IS DISTINCT FROM 'draft' THEN
    RETURN NEW;
  END IF;

  v_other := public.manager_draft_club_leading_other(NEW.bidder_club_id, NEW.manager_id);
  IF v_other IS NOT NULL THEN
    SELECT m.name INTO v_other_name FROM public."Managers" m WHERE m.id = v_other;
    RAISE EXCEPTION
      'You already hold the highest bid on another manager draft auction (%). You may only lead one auction at a time.',
      coalesce(v_other_name, v_other::text);
  END IF;

  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS manager_draft_bid_one_lead ON public."Manager_Transfer_Bids";
CREATE TRIGGER manager_draft_bid_one_lead
  BEFORE INSERT ON public."Manager_Transfer_Bids"
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_manager_draft_bid_one_lead();

GRANT EXECUTE ON FUNCTION public.manager_draft_club_leading_other(text, bigint) TO authenticated;

NOTIFY pgrst, 'reload schema';

-- Report: clubs currently leading more than one manager draft auction
WITH leads AS (
  SELECT
    l.id AS listing_id,
    l.manager_id,
    m.name AS manager_name,
    public.manager_draft_current_leader(l.manager_id) AS leader
  FROM public."Manager_Transfer_Listings" l
  JOIN public."Managers" m ON m.id = l.manager_id
  WHERE l.listing_type = 'draft'
    AND l.status = 'Active'
)
SELECT
  ld.leader AS club,
  ld.manager_name,
  ld.listing_id,
  (SELECT max(b.bid_amount) FROM public."Manager_Transfer_Bids" b
    WHERE b.listing_id = ld.listing_id AND b.bidder_club_id = ld.leader) AS lead_bid,
  (SELECT max(b.bid_time) FROM public."Manager_Transfer_Bids" b
    WHERE b.listing_id = ld.listing_id AND b.bidder_club_id = ld.leader) AS lead_bid_time
FROM leads ld
WHERE ld.leader IS NOT NULL
  AND ld.leader IN (
    SELECT leader FROM leads WHERE leader IS NOT NULL GROUP BY leader HAVING count(*) > 1
  )
ORDER BY ld.leader, lead_bid_time;
