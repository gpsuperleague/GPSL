-- =============================================================================
-- Matchday pitch: GK stays on the pitch; CBs clear with compact cards
-- Safe re-run.
-- =============================================================================

UPDATE public.gpsl_formation_slots
SET y = 88.0
WHERE upper(slot_key) = 'GK'
  AND y >= 80;

UPDATE public.gpsl_formation_slots
SET y = 70.0
WHERE upper(coalesce(default_position, '')) = 'CB'
  AND y >= 55;

UPDATE public.gpsl_formation_slots
SET y = 68.0
WHERE upper(coalesce(default_position, '')) IN ('LB', 'RB', 'LWB', 'RWB')
  AND y >= 58
  AND y < 85;

NOTIFY pgrst, 'reload schema';
