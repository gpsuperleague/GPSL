-- =============================================================================
-- Hide draft_random_finish_time from club owners (API + UI)
-- Run once in Supabase SQL Editor after transfer engine scripts.
-- =============================================================================

CREATE OR REPLACE VIEW public.global_settings_public AS
SELECT
  id,
  transfer_window_open,
  draft_auction_enabled,
  draft_auction_start_time,
  updated_at
FROM global_settings;

GRANT SELECT ON public.global_settings_public TO authenticated;
GRANT SELECT ON public.global_settings_public TO anon;

ALTER TABLE global_settings ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS global_settings_select_admin ON global_settings;
CREATE POLICY global_settings_select_admin ON global_settings
  FOR SELECT
  TO authenticated
  USING (auth.jwt() ->> 'email' = 'rotavator66@outlook.com');

-- Block direct SELECT on base table for non-admin (they use the view)
DROP POLICY IF EXISTS global_settings_select_authenticated ON global_settings;
DROP POLICY IF EXISTS global_settings_select_public ON global_settings;

-- Owners use the view only; base table SELECT is admin-only via RLS above
REVOKE ALL ON TABLE global_settings FROM anon, authenticated;
GRANT SELECT ON TABLE global_settings TO authenticated;

-- =============================================================================
-- Reject draft bids after the secret random finish (server-side only)
-- =============================================================================

CREATE OR REPLACE FUNCTION public.trg_player_transfer_bids_draft_guard()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_enabled boolean;
  v_start   timestamptz;
  v_finish  timestamptz;
  v_is_draft boolean;
BEGIN
  v_is_draft := (
    COALESCE(NEW.is_first_draft_bid, false)
    OR COALESCE(NEW.is_draft_join, false)
    OR (
      NEW.listing_id IS NOT NULL
      AND EXISTS (
        SELECT 1 FROM "Player_Transfer_Listings" l
        WHERE l.id = NEW.listing_id AND l.listing_type = 'draft'
      )
    )
    OR (COALESCE(NEW.is_direct, false) AND NEW.seller_club_id IS NULL)
  );

  IF NOT v_is_draft THEN
    RETURN NEW;
  END IF;

  SELECT draft_auction_enabled, draft_auction_start_time, draft_random_finish_time
  INTO v_enabled, v_start, v_finish
  FROM global_settings
  WHERE id = 1;

  IF NOT COALESCE(v_enabled, false) THEN
    RAISE EXCEPTION 'Draft auction is not enabled';
  END IF;

  IF v_start IS NOT NULL AND now() < v_start THEN
    RAISE EXCEPTION 'Draft auction has not started yet';
  END IF;

  IF v_finish IS NOT NULL AND now() >= v_finish THEN
    RAISE EXCEPTION 'Draft auction has ended';
  END IF;

  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS player_transfer_bids_draft_guard ON "Player_Transfer_Bids";

CREATE TRIGGER player_transfer_bids_draft_guard
  BEFORE INSERT ON "Player_Transfer_Bids"
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_player_transfer_bids_draft_guard();
