-- =============================================================================
-- Friendlies: first 15 paid friendlies per GPSL month earn ₿5,000 (was 10)
-- Season cap ₿750,000 (was ₿500,000). Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.gpsl_friendlies_month_cap()
RETURNS int
LANGUAGE sql
IMMUTABLE
AS $$ SELECT 15; $$;

CREATE OR REPLACE FUNCTION public.gpsl_friendlies_season_cap()
RETURNS numeric
LANGUAGE sql
IMMUTABLE
AS $$ SELECT 750000::numeric; $$;

NOTIFY pgrst, 'reload schema';

SELECT public.gpsl_friendlies_month_cap() AS paid_friendlies_per_month,
       public.gpsl_friendlies_payout_amount() AS payout_each,
       public.gpsl_friendlies_season_cap() AS season_cap;
