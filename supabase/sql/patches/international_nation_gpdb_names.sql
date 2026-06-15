-- =============================================================================
-- Align international nation display names with GPDB Players.Nation labels
-- Safe re-run. Run in Supabase SQL Editor after competition_international.sql
-- =============================================================================

UPDATE public.international_nations SET name = 'IR Iran' WHERE code = 'IRN';
UPDATE public.international_nations SET name = 'Korea Republic' WHERE code = 'KOR';
UPDATE public.international_nations SET name = 'Türkiye' WHERE code = 'TUR';
UPDATE public.international_nations SET name = 'Republic of Ireland' WHERE code = 'IRL';
UPDATE public.international_nations SET name = 'Czechia' WHERE code = 'CZE';
UPDATE public.international_nations SET name = 'China PR' WHERE code = 'CHN';

-- Optional: admin can re-run international_seed_nations() to refresh from seed (names match above)

NOTIFY pgrst, 'reload schema';
