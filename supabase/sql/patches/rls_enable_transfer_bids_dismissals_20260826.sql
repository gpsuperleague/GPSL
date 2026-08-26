-- =============================================================================
-- RLS: enable on Player_Transfer_Bids + User_Dismissed_Listings
-- Safe re-run.
--
-- Why this stays working:
-- - Browser/PostgREST roles (authenticated/anon) are subject to RLS.
-- - SECURITY DEFINER RPCs/triggers (accept_direct_offer, draft settlement,
--   max-bid resolve, etc.) run as the table owner and bypass RLS unless
--   FORCE ROW LEVEL SECURITY is set — we do NOT force it.
-- - Policies below match current UI: authenticated clients already SELECT
--   other clubs' bids for auction boards, INSERT as their own club, and
--   UPDATE to reject as seller (transfer_center.js / gpdb_v2.js).
--
-- User_Dismissed_Listings: current transfer centre uses localStorage for
-- dismissals; this table is legacy/unused in JS. RLS is enabled tightly so
-- it cannot be an open PostgREST surface.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Helper: own club (already used widely; grant if missing)
-- ---------------------------------------------------------------------------
GRANT EXECUTE ON FUNCTION public.my_club_shortname() TO authenticated;

-- ---------------------------------------------------------------------------
-- 1) Player_Transfer_Bids
-- ---------------------------------------------------------------------------
ALTER TABLE public."Player_Transfer_Bids" ENABLE ROW LEVEL SECURITY;

-- Drop lint-named / legacy policies if present, then recreate clean set
DO $$
DECLARE
  r record;
BEGIN
  FOR r IN
    SELECT policyname
    FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'Player_Transfer_Bids'
  LOOP
    EXECUTE format(
      'DROP POLICY IF EXISTS %I ON public."Player_Transfer_Bids"',
      r.policyname
    );
  END LOOP;
END
$$;

-- Auction boards need to see competing bids (existing product behaviour)
CREATE POLICY player_transfer_bids_select_authenticated
  ON public."Player_Transfer_Bids"
  FOR SELECT
  TO authenticated
  USING (true);

-- Place bids / direct offers only as your own club (trigger also enforces)
CREATE POLICY player_transfer_bids_insert_own_club
  ON public."Player_Transfer_Bids"
  FOR INSERT
  TO authenticated
  WITH CHECK (
    public.is_gpsl_admin()
    OR (
      nullif(btrim(coalesce(public.my_club_shortname(), '')), '') IS NOT NULL
      AND upper(btrim(coalesce(bidder_club_id::text, '')))
          = upper(btrim(public.my_club_shortname()))
    )
  );

-- Seller reject / bidder maintenance; admins full update
CREATE POLICY player_transfer_bids_update_party_or_admin
  ON public."Player_Transfer_Bids"
  FOR UPDATE
  TO authenticated
  USING (
    public.is_gpsl_admin()
    OR (
      nullif(btrim(coalesce(public.my_club_shortname(), '')), '') IS NOT NULL
      AND (
        upper(btrim(coalesce(seller_club_id::text, '')))
          = upper(btrim(public.my_club_shortname()))
        OR upper(btrim(coalesce(bidder_club_id::text, '')))
          = upper(btrim(public.my_club_shortname()))
      )
    )
  )
  WITH CHECK (
    public.is_gpsl_admin()
    OR (
      nullif(btrim(coalesce(public.my_club_shortname(), '')), '') IS NOT NULL
      AND (
        upper(btrim(coalesce(seller_club_id::text, '')))
          = upper(btrim(public.my_club_shortname()))
        OR upper(btrim(coalesce(bidder_club_id::text, '')))
          = upper(btrim(public.my_club_shortname()))
      )
    )
  );

-- No direct deletes from the client (settlement RPCs bypass RLS as owner)
CREATE POLICY player_transfer_bids_delete_admin
  ON public."Player_Transfer_Bids"
  FOR DELETE
  TO authenticated
  USING (public.is_gpsl_admin());

REVOKE ALL ON TABLE public."Player_Transfer_Bids" FROM anon;
GRANT SELECT, INSERT, UPDATE ON TABLE public."Player_Transfer_Bids" TO authenticated;
-- DELETE only via admin policy / definer RPCs
GRANT DELETE ON TABLE public."Player_Transfer_Bids" TO authenticated;

-- ---------------------------------------------------------------------------
-- 2) User_Dismissed_Listings
-- ---------------------------------------------------------------------------
ALTER TABLE public."User_Dismissed_Listings" ENABLE ROW LEVEL SECURITY;

DO $$
DECLARE
  r record;
BEGIN
  FOR r IN
    SELECT policyname
    FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'User_Dismissed_Listings'
  LOOP
    EXECUTE format(
      'DROP POLICY IF EXISTS %I ON public."User_Dismissed_Listings"',
      r.policyname
    );
  END LOOP;
END
$$;

DO $$
DECLARE
  has_user boolean;
  has_owner boolean;
  has_club boolean;
BEGIN
  SELECT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'User_Dismissed_Listings'
      AND column_name IN ('user_id', 'owner_id')
  ) INTO has_user;

  SELECT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'User_Dismissed_Listings'
      AND column_name = 'owner_id'
  ) INTO has_owner;

  SELECT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'User_Dismissed_Listings'
      AND column_name IN ('club_short_name', 'club_id', 'short_name')
  ) INTO has_club;

  IF has_owner THEN
    EXECUTE $p$
      CREATE POLICY user_dismissed_listings_own
        ON public."User_Dismissed_Listings"
        FOR ALL
        TO authenticated
        USING (owner_id::text = auth.uid()::text OR public.is_gpsl_admin())
        WITH CHECK (owner_id::text = auth.uid()::text OR public.is_gpsl_admin())
    $p$;
  ELSIF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'User_Dismissed_Listings'
      AND column_name = 'user_id'
  ) THEN
    EXECUTE $p$
      CREATE POLICY user_dismissed_listings_own
        ON public."User_Dismissed_Listings"
        FOR ALL
        TO authenticated
        USING (user_id = auth.uid()::text OR public.is_gpsl_admin())
        WITH CHECK (user_id = auth.uid()::text OR public.is_gpsl_admin())
    $p$;
  ELSIF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'User_Dismissed_Listings'
      AND column_name = 'club_short_name'
  ) THEN
    EXECUTE $p$
      CREATE POLICY user_dismissed_listings_own_club
        ON public."User_Dismissed_Listings"
        FOR ALL
        TO authenticated
        USING (
          public.is_gpsl_admin()
          OR (
            nullif(btrim(coalesce(public.my_club_shortname(), '')), '') IS NOT NULL
            AND upper(btrim(club_short_name))
                = upper(btrim(public.my_club_shortname()))
          )
        )
        WITH CHECK (
          public.is_gpsl_admin()
          OR (
            nullif(btrim(coalesce(public.my_club_shortname(), '')), '') IS NOT NULL
            AND upper(btrim(club_short_name))
                = upper(btrim(public.my_club_shortname()))
          )
        )
    $p$;
  ELSE
    -- Unknown shape: lock down; admin-only (app uses localStorage anyway)
    EXECUTE $p$
      CREATE POLICY user_dismissed_listings_admin_only
        ON public."User_Dismissed_Listings"
        FOR ALL
        TO authenticated
        USING (public.is_gpsl_admin())
        WITH CHECK (public.is_gpsl_admin())
    $p$;
  END IF;
END
$$;

REVOKE ALL ON TABLE public."User_Dismissed_Listings" FROM anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public."User_Dismissed_Listings" TO authenticated;

NOTIFY pgrst, 'reload schema';

-- =============================================================================
-- FOLLOW-UP (finance / transfer blast radius) — do in later patches, test UI
-- after each batch. Prefer: ENABLE RLS + no anon grants + RPC/view access.
--
-- High priority next:
--   Player_Transfer_Listings
--   Transfer_History
--   bank_ledger
--   gpsl_bank_account
--   Club_Finances
--   Club_Finance_Transactions
--
-- Also: drop or move public.Players_backup_20260820 out of exposed API.
-- =============================================================================
