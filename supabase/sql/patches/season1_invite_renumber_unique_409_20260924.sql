-- =============================================================================
-- Fix Season 1 queue clear 409 (unique collision on renumber)
-- =============================================================================
-- Symptom: first S1# clear works; clearing another (with people below) returns
-- POST .../admin_season1_invite_clear_number 409 Conflict.
--
-- Cause: UNIQUE (season1_invite_queue_num) + single UPDATE that does n → n-1
-- collides mid-statement (e.g. #3→#2 while #2 still exists).
--
-- Fix: two-pass renumber (shift to negative temp keys, then to final).
-- Run once in Supabase SQL Editor.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.season1_invite_renumber_from(p_cleared_num integer)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_count integer := 0;
BEGIN
  IF p_cleared_num IS NULL OR p_cleared_num < 1 THEN
    RETURN 0;
  END IF;

  -- Pass 1: move affected rows onto unique negative temps (no clash with 1..n)
  UPDATE public.gpsl_owner_registry r
  SET season1_invite_queue_num = -r.season1_invite_queue_num
  WHERE r.season1_invite_queue_num IS NOT NULL
    AND r.season1_invite_queue_num > p_cleared_num;

  GET DIAGNOSTICS v_count = ROW_COUNT;

  -- Pass 2: -k → k-1 (final contiguous queue)
  UPDATE public.gpsl_owner_registry r
  SET season1_invite_queue_num = (-r.season1_invite_queue_num) - 1
  WHERE r.season1_invite_queue_num IS NOT NULL
    AND r.season1_invite_queue_num < 0;

  RETURN coalesce(v_count, 0);
END;
$fn$;

COMMENT ON FUNCTION public.season1_invite_renumber_from(integer) IS
  'After clearing S1#N, bump N+1… down by 1 (two-pass to avoid unique 409).';

NOTIFY pgrst, 'reload schema';
