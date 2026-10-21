-- Identify clubs + timezones
SELECT c."ShortName", c."Club", c.owner, c.owner_timezone AS club_tz,
       r.owner_tag, r.owner_timezone AS reg_tz, c.owner_id
FROM public."Clubs" c
LEFT JOIN public.gpsl_owner_registry r ON r.owner_id = c.owner_id
WHERE upper(c."ShortName") IN ('PLA', 'CRV', 'CZV', 'ZVE')
   OR c."Club" ILIKE '%platense%'
   OR c."Club" ILIKE '%crvena%'
   OR c."Club" ILIKE '%zvezda%'
   OR c.owner ILIKE '%vardy%'
   OR c.owner ILIKE '%matjaz%'
   OR r.owner_tag ILIKE '%vardy%'
   OR r.owner_tag ILIKE '%matjaz%';
