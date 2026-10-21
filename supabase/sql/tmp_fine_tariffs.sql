SELECT code, label, amount, auto_enabled, category
FROM public.competition_fine_tariff
WHERE direction = 'fine' OR direction IS NULL
ORDER BY code;

SELECT column_name FROM information_schema.columns
WHERE table_schema='public' AND table_name='competition_fine_applied'
ORDER BY ordinal_position;
