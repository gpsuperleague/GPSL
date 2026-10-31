SELECT c."ShortName", c."Club", c.handpick_intake, c.owner_id IS NOT NULL AS has_owner
FROM public."Clubs" c
WHERE c."ShortName" = 'MAR';
