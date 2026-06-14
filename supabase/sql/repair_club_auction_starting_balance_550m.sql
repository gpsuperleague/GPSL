-- Set club auction starting budget to ₿550m (run once after reset used wrong value)
-- Also run full patches/admin_prelaunch_test_reset.sql for permanent fix.

ALTER TABLE public.global_settings
  ADD COLUMN IF NOT EXISTS club_auction_starting_balance numeric(14, 2) NOT NULL DEFAULT 600000000;

CREATE OR REPLACE FUNCTION public.club_auction_default_starting_balance()
RETURNS numeric
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT coalesce(
    (SELECT g.club_auction_starting_balance FROM public.global_settings g WHERE g.id = 1),
    600000000::numeric
  );
$$;

UPDATE public.global_settings
SET club_auction_starting_balance = 550000000,
    updated_at = now()
WHERE id = 1;

UPDATE public.gpsl_owner_registry
SET pending_starting_balance = 550000000
WHERE status = 'awaiting_club_auction';

GRANT EXECUTE ON FUNCTION public.club_auction_default_starting_balance() TO authenticated;

NOTIFY pgrst, 'reload schema';
