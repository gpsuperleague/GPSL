-- Fix 4-3-3 centre mid: starting role CMF → DMF (matches eFootball 4-3-3).
-- Slot id stays CMF (LMF/CMF/RMF holes). Left/right LMF+RMF stay starting CMF.
-- Locks centre so owners cannot re-role it. Safe re-run.

UPDATE public.gpsl_formation_slots s
SET
  default_position = 'DMF',
  allowed_positions = ARRAY['DMF']::text[],
  allow_relabel = false
FROM public.gpsl_formations f
WHERE s.formation_id = f.id
  AND lower(btrim(f.code)) = '4-3-3'
  AND upper(btrim(s.slot_key)) = 'CMF';
