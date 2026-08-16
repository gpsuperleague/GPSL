-- Age confirmation (18+) at Discord-gated join.
-- Safe re-run.

ALTER TABLE public.gpsl_owner_registry
  ADD COLUMN IF NOT EXISTS age_confirmed_at timestamptz,
  ADD COLUMN IF NOT EXISTS age_confirmation_version text;

COMMENT ON COLUMN public.gpsl_owner_registry.age_confirmed_at IS
  'When the owner confirmed they are at least 18 at Discord-gated join.';
COMMENT ON COLUMN public.gpsl_owner_registry.age_confirmation_version IS
  'Version string of the age agreement accepted at join.';
