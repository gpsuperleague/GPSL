-- Atalanta (ATA) still in admin handpick intake with no owner and no
-- submissions — clear so it leaves Handpick approvals dropdown.
-- Safe re-run.

UPDATE public."Clubs"
SET handpick_intake = false
WHERE "ShortName" = 'ATA'
  AND coalesce(handpick_intake, false);

NOTIFY pgrst, 'reload schema';

SELECT c."ShortName", c."Club", c.handpick_intake, c.owner
FROM public."Clubs" c
WHERE c."ShortName" = 'ATA';
