-- Squad overflow forced MV release: ₿2.5m per incident.
-- The signing job already calls competition_apply_club_fine_tariff
-- with code squad_overflow_mv_release and no amount override, so this
-- row is what gets charged. breach_squad_28_max is not that job.
-- Do not re-run squad_overflow_paid_up_fine.sql from an old copy:
-- its INSERT used to write ₿10m back over this amount.

UPDATE public.competition_fine_tariff
SET amount = 2500000,
    updated_at = now()
WHERE code = 'squad_overflow_mv_release'
  AND amount IS DISTINCT FROM 2500000;
