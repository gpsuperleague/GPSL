-- =============================================================================
-- GPFL position flex (expanded)
--
--   GK  → GK only
--   RWF/LWF/CF/SS ↔ any of RWF, LWF, CF, SS
--   LMF/RMF/CMF/AMF ↔ any of LMF, RMF, CMF, AMF
--   LMF/RMF also → LB, RB
--   LB/RB/CB ↔ any of LB, RB, CB
--   CB ↔ DMF (both ways)
--   DMF → DMF, CB
--
-- Run after gpfl_formations_positions_20260817.sql (safe re-run).
-- =============================================================================

CREATE OR REPLACE FUNCTION public.gpfl_normalize_pos(p_pos text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE upper(btrim(coalesce(p_pos, '')))
    WHEN 'LW' THEN 'LWF'
    WHEN 'RW' THEN 'RWF'
    WHEN 'LM' THEN 'LMF'
    WHEN 'RM' THEN 'RMF'
    WHEN 'WG' THEN 'LWF'
    WHEN 'CB1' THEN 'CB'
    WHEN 'CB2' THEN 'CB'
    WHEN 'CB3' THEN 'CB'
    ELSE upper(btrim(coalesce(p_pos, '')))
  END;
$$;

CREATE OR REPLACE FUNCTION public.gpfl_pos_fits_slot(p_player_pos text, p_slot_required text)
RETURNS boolean
LANGUAGE plpgsql
IMMUTABLE
AS $function$
DECLARE
  v_p text := public.gpfl_normalize_pos(p_player_pos);
  v_s text := public.gpfl_normalize_pos(p_slot_required);
BEGIN
  IF v_p = '' OR v_s = '' THEN
    RETURN false;
  END IF;
  IF v_p = v_s THEN
    RETURN true;
  END IF;

  -- GK only as GK
  IF v_p = 'GK' OR v_s = 'GK' THEN
    RETURN false;
  END IF;

  -- Attackers interchange
  IF v_p IN ('RWF', 'LWF', 'CF', 'SS') AND v_s IN ('RWF', 'LWF', 'CF', 'SS') THEN
    RETURN true;
  END IF;

  -- Advanced / wide / central mids interchange
  IF v_p IN ('LMF', 'RMF', 'CMF', 'AMF') AND v_s IN ('LMF', 'RMF', 'CMF', 'AMF') THEN
    RETURN true;
  END IF;

  -- Full-backs + centre-backs interchange
  IF v_p IN ('LB', 'RB', 'CB') AND v_s IN ('LB', 'RB', 'CB') THEN
    RETURN true;
  END IF;

  -- DMF ↔ CB
  IF (v_p = 'DMF' AND v_s = 'CB') OR (v_p = 'CB' AND v_s = 'DMF') THEN
    RETURN true;
  END IF;

  -- Wide mids can cover full-back
  IF v_p IN ('LMF', 'RMF') AND v_s IN ('LB', 'RB') THEN
    RETURN true;
  END IF;

  RETURN false;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.gpfl_normalize_pos(text) TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.gpfl_pos_fits_slot(text, text) TO authenticated, anon;

NOTIFY pgrst, 'reload schema';
