-- =============================================================================
-- Manager FA board: remove signed managers (e.g. Sarri @ Palmeiras) + guards
--
-- Cause: the monthly FA board only checks "is a free agent" when it PICKS the
-- 10 managers. Nothing closes a window_fa listing if the manager is signed
-- some other way afterwards (manager draft auction, admin assign, etc.).
-- The picker also ignores managers sitting in a live manager-draft auction,
-- so a manager could be on the FA board and in the draft at the same time.
--
-- This patch:
--   1. Records evidence for Sarri (listings, bids, signing) before changes
--   2. Cancels every Active window_fa listing whose manager is now contracted
--   3. Guard: signing a manager cancels his other FA-board listings
--   4. Guard: FA board never lists a contracted manager or one in a live draft
--   5. Tops the board back up to 10
--
-- Safe re-run. Last SELECT shows what happened.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. Evidence (before any change)
-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS _gpsl_sarri_evidence;
CREATE TEMP TABLE _gpsl_sarri_evidence AS
SELECT
  m.id AS manager_id,
  m.name,
  m.contracted_club,
  (
    SELECT jsonb_agg(jsonb_build_object(
      'listing_id', l.id,
      'type', l.listing_type,
      'status', l.status,
      'listed_at', l.created_at,
      'ends', l.end_time,
      'high_bid', l.current_highest_bid,
      'high_bidder', l.current_highest_bidder,
      'bids', (SELECT count(*) FROM public."Manager_Transfer_Bids" b WHERE b.listing_id = l.id),
      'how_listed', CASE
        WHEN l.metadata ? 'batch_job' THEN 'monthly FA board (batch)'
        WHEN coalesce((l.metadata->>'top_up')::boolean, false) THEN 'FA board top-up'
        ELSE coalesce(l.listing_type, '?')
      END
    ) ORDER BY l.created_at)
    FROM public."Manager_Transfer_Listings" l
    WHERE l.manager_id = m.id
      AND l.created_at > now() - interval '120 days'
  ) AS listings,
  (
    SELECT jsonb_agg(jsonb_build_object(
      'club', s.club_short_name,
      'how_signed', s.start_kind,
      'signed_at', s.started_at,
      'fee', s.start_fee,
      'ended_at', s.ended_at
    ) ORDER BY s.started_at)
    FROM public.manager_club_stints s
    WHERE s.manager_id = m.id
      AND s.started_at > now() - interval '120 days'
  ) AS signings
FROM public."Managers" m
WHERE m.name ILIKE '%sarri%';

-- ---------------------------------------------------------------------------
-- 2. Cancel FA-board listings for managers who are already signed
-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS _gpsl_fa_cancelled;
CREATE TEMP TABLE _gpsl_fa_cancelled AS
WITH c AS (
  UPDATE public."Manager_Transfer_Listings" l
  SET status = 'Cancelled',
      updated_at = now(),
      metadata = coalesce(l.metadata, '{}'::jsonb) || jsonb_build_object(
        'cancelled_reason', 'manager_already_signed',
        'cancelled_at', now(),
        'signed_club', m.contracted_club
      )
  FROM public."Managers" m
  WHERE m.id = l.manager_id
    AND l.listing_type = 'window_fa'
    AND l.status = 'Active'
    AND nullif(btrim(coalesce(m.contracted_club, '')), '') IS NOT NULL
  RETURNING l.id, l.manager_id, m.name, m.contracted_club
)
SELECT * FROM c;

-- ---------------------------------------------------------------------------
-- 3. Guard: when a manager signs, cancel his other live FA-board listings
--    (the listing he is being signed FROM — winner = new club — is left alone
--    so normal FA settlement still closes it itself)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.trg_managers_signed_cancel_fa_listings()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := nullif(btrim(coalesce(NEW.contracted_club, '')), '');
BEGIN
  IF v_club IS NULL
     OR v_club IS NOT DISTINCT FROM nullif(btrim(coalesce(OLD.contracted_club, '')), '') THEN
    RETURN NULL;
  END IF;

  BEGIN
    UPDATE public."Manager_Transfer_Listings" l
    SET status = 'Cancelled',
        updated_at = now(),
        metadata = coalesce(l.metadata, '{}'::jsonb) || jsonb_build_object(
          'cancelled_reason', 'manager_signed_elsewhere',
          'cancelled_at', now(),
          'signed_club', v_club
        )
    WHERE l.manager_id = NEW.id
      AND l.listing_type = 'window_fa'
      AND l.status = 'Active'
      AND l.current_highest_bidder IS DISTINCT FROM v_club;
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'FA listing cleanup on sign failed: %', SQLERRM;
  END;

  RETURN NULL;
END;
$function$;

DROP TRIGGER IF EXISTS managers_signed_cancel_fa_listings ON public."Managers";
CREATE TRIGGER managers_signed_cancel_fa_listings
  AFTER UPDATE OF contracted_club ON public."Managers"
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_managers_signed_cancel_fa_listings();

-- ---------------------------------------------------------------------------
-- 4. Guard: FA board never lists a contracted manager or one in a live draft
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.trg_manager_listings_fa_board_guard()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF NEW.listing_type = 'window_fa' AND (
    EXISTS (
      SELECT 1 FROM public."Managers" m
      WHERE m.id = NEW.manager_id
        AND nullif(btrim(coalesce(m.contracted_club, '')), '') IS NOT NULL
    )
    OR EXISTS (
      SELECT 1 FROM public."Manager_Transfer_Listings" l
      WHERE l.manager_id = NEW.manager_id
        AND l.status = 'Active'
        AND l.listing_type IN ('draft', 'window_fa', 'standard', 'direct')
    )
  ) THEN
    RETURN NULL;
  END IF;
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS manager_listings_fa_board_guard ON public."Manager_Transfer_Listings";
CREATE TRIGGER manager_listings_fa_board_guard
  BEFORE INSERT ON public."Manager_Transfer_Listings"
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_manager_listings_fa_board_guard();

-- ---------------------------------------------------------------------------
-- 5. Replace the removed listing(s): top the board back up to 10
-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS _gpsl_fa_topup;
CREATE TEMP TABLE _gpsl_fa_topup AS
SELECT public.manager_window_fa_ensure_board(NULL, NULL, 10) AS result;

NOTIFY pgrst, 'reload schema';

-- ---------------------------------------------------------------------------
-- Result
-- ---------------------------------------------------------------------------
SELECT
  e.name,
  e.contracted_club AS signed_by,
  e.signings,
  e.listings,
  (SELECT jsonb_agg(jsonb_build_object('listing_id', id, 'manager', name, 'club', contracted_club))
     FROM _gpsl_fa_cancelled) AS listings_cancelled,
  (SELECT result FROM _gpsl_fa_topup) AS board_topup,
  (
    SELECT jsonb_agg(m.name || ' (' || coalesce(m.rating::text, '?') || ')' ORDER BY m.rating DESC)
    FROM public."Manager_Transfer_Listings" l
    JOIN public."Managers" m ON m.id = l.manager_id
    WHERE l.listing_type = 'window_fa' AND l.status = 'Active' AND l.end_time > now()
  ) AS board_now
FROM (SELECT 1) one
LEFT JOIN _gpsl_sarri_evidence e ON true;
