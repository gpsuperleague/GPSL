-- Fix 4-3-3 centre mid: CMF → DMF (matches eFootball 4-3-3)
-- Safe re-run.

UPDATE public.gpsl_formation_slots s
SET
  default_position = 'DMF',
  allowed_positions = ARRAY['DMF']::text[]
FROM public.gpsl_formations f
WHERE s.formation_id = f.id
  AND lower(btrim(f.code)) = '4-3-3'
  AND upper(btrim(s.slot_key)) = 'CMF'
  AND upper(btrim(s.default_position)) = 'CMF';
