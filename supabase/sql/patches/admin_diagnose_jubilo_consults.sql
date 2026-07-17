-- =============================================================================
-- Diagnose / repair: Jubilo (JUB) medical consults showing 0
-- Run in Supabase SQL Editor.
-- =============================================================================

-- 1) Confirm identity patch applied
SELECT to_regclass('public.club_medical_consults') AS consults_table,
       to_regprocedure('public.medical_list_available_consults(text)') AS list_rpc,
       to_regprocedure('public.medical_sync_named_consults(text)') AS sync_rpc;

-- 2) Vault counter vs named rows
SELECT c.club_short_name,
       c.specialist_tokens AS vault_count,
       (SELECT count(*) FROM public.club_medical_consults x
         WHERE x.club_short_name = c.club_short_name
           AND x.status = 'available') AS named_available
FROM public.club_medical_centre c
WHERE c.club_short_name = 'JUB';

-- 3) If vault_count > 0 but named rows missing, sync creates them
SELECT public.medical_sync_named_consults('JUB') AS rows_created;

-- 4) If still zero vault chips, grant 2 (admin)
-- Uncomment if needed:
-- SELECT public.medical_grant_specialist_tokens('JUB', 2);

-- 5) What the UI should list
SELECT *
FROM jsonb_array_elements(public.medical_list_available_consults('JUB')) AS t;

NOTIFY pgrst, 'reload schema';
