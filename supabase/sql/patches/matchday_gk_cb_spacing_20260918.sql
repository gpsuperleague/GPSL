-- =============================================================================
-- Matchday pitch: taller pitch fit — GK fully on green, CBs clear
-- Safe re-run.
-- =============================================================================

UPDATE public.gpsl_formation_slots
SET y = 80.0
WHERE upper(slot_key) = 'GK'
  AND y >= 78;

UPDATE public.gpsl_formation_slots
SET y = 66.0
WHERE upper(coalesce(default_position, '')) = 'CB'
  AND y >= 55;

UPDATE public.gpsl_formation_slots
SET y = 64.0
WHERE upper(coalesce(default_position, '')) IN ('LB', 'RB', 'LWB', 'RWB')
  AND y >= 58
  AND y < 85;

NOTIFY pgrst, 'reload schema';
