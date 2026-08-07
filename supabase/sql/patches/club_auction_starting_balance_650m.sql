-- =============================================================================
-- Club auction starting balance → ₿650,000,000
-- Updates global default (used by invites + test reset) and current pre-club
-- pending balances that still match the previous 600m default.
-- =============================================================================

ALTER TABLE public.global_settings
  ADD COLUMN IF NOT EXISTS club_auction_starting_balance numeric(14, 2) NOT NULL DEFAULT 650000000;

ALTER TABLE public.global_settings
  ALTER COLUMN club_auction_starting_balance SET DEFAULT 650000000;

UPDATE public.global_settings
SET club_auction_starting_balance = 650000000,
    updated_at = now()
WHERE id = 1;

CREATE OR REPLACE FUNCTION public.club_auction_default_starting_balance()
RETURNS numeric
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT coalesce(
    (SELECT g.club_auction_starting_balance FROM public.global_settings g WHERE g.id = 1),
    650000000::numeric
  );
$$;

GRANT EXECUTE ON FUNCTION public.club_auction_default_starting_balance() TO authenticated;

-- Pre-club owners still on the old 600m default → bring up to 650m
UPDATE public.gpsl_owner_registry
SET pending_starting_balance = 650000000
WHERE coalesce(pending_starting_balance, 0) IN (0, 600000000)
  AND status IN ('awaiting_club_auction', 'member', 'on_absence')
  AND NOT EXISTS (
    SELECT 1 FROM public."Clubs" c WHERE c.owner_id = gpsl_owner_registry.owner_id
  );

NOTIFY pgrst, 'reload schema';
