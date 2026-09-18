-- =============================================================================
-- Matchday pitch: push central CBs up + GK deeper (card overlap fix)
-- Safe re-run. Replaces earlier spacing nudge.
-- =============================================================================

-- Keeper deeper toward the goal line
UPDATE public.gpsl_formation_slots
SET y = 94.0
WHERE upper(slot_key) = 'GK'
  AND y >= 80
  AND y < 94;

-- Centre-backs further up the pitch (clears GK card)
UPDATE public.gpsl_formation_slots
SET y = 58.0
WHERE upper(coalesce(default_position, '')) = 'CB'
  AND y >= 58;

-- Full-backs / wing-backs slightly higher too if they were deep
UPDATE public.gpsl_formation_slots
SET y = 58.0
WHERE upper(coalesce(default_position, '')) IN ('LB', 'RB', 'LWB', 'RWB')
  AND y >= 60
  AND y < 85;

NOTIFY pgrst, 'reload schema';
