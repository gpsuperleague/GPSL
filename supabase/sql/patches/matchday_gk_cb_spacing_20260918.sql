-- =============================================================================
-- Matchday pitch: separate GK from centre-backs (card overlap fix)
-- Safe re-run.
-- =============================================================================

-- Push keeper deeper toward the goal line
UPDATE public.gpsl_formation_slots
SET y = 92.0
WHERE upper(slot_key) = 'GK'
  AND y >= 80
  AND y < 92;

-- Ease defensive line forward so cards clear the GK
UPDATE public.gpsl_formation_slots
SET y = 65.0
WHERE upper(coalesce(default_position, '')) IN ('CB')
  AND y >= 70;

UPDATE public.gpsl_formation_slots
SET y = 62.0
WHERE upper(coalesce(default_position, '')) IN ('LB', 'RB', 'LWB', 'RWB')
  AND y >= 66
  AND y < 80;

NOTIFY pgrst, 'reload schema';
