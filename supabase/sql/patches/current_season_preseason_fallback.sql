-- =============================================================================
-- Fix: same-season sale lock broken in preseason / summer break
--
-- Symptom: Contested expiry signings (Season_Signed = new preseason label)
--   can be listed/sold immediately after Create Pre-Season tick.
--
-- Cause: current_gpsl_season_label() / current_gpsl_season_id() only look at
--   is_current. After End Season nothing is current, so the lock compares
--   Season_Signed='4' to '' and allows the sale.
--
-- Fix: fall back to newest preseason/setup (same idea as gpsl_season_id_for_locks).
-- Run in Supabase SQL Editor. Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.current_gpsl_season_id()
RETURNS bigint
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_id bigint;
BEGIN
  SELECT s.id
  INTO v_id
  FROM public.competition_seasons s
  WHERE s.is_current = true
    AND s.status = 'active'
  ORDER BY s.id DESC
  LIMIT 1;

  IF v_id IS NOT NULL THEN
    RETURN v_id;
  END IF;

  SELECT s.id
  INTO v_id
  FROM public.competition_seasons s
  WHERE s.is_current = true
  ORDER BY s.id DESC
  LIMIT 1;

  IF v_id IS NOT NULL THEN
    RETURN v_id;
  END IF;

  -- Preseason / summer break: newest setup shell is the "current" year for locks
  SELECT s.id
  INTO v_id
  FROM public.competition_seasons s
  WHERE s.status IN ('preseason', 'setup')
  ORDER BY s.id DESC
  LIMIT 1;

  RETURN v_id;
END;
$function$;

CREATE OR REPLACE FUNCTION public.current_gpsl_season_label()
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_label text;
BEGIN
  SELECT btrim(s.label)
  INTO v_label
  FROM public.competition_seasons s
  WHERE s.is_current = true
    AND s.status = 'active'
  ORDER BY s.id DESC
  LIMIT 1;

  IF v_label IS NOT NULL AND v_label <> '' THEN
    RETURN v_label;
  END IF;

  SELECT btrim(s.label)
  INTO v_label
  FROM public.competition_seasons s
  WHERE s.is_current = true
  ORDER BY s.id DESC
  LIMIT 1;

  IF v_label IS NOT NULL AND v_label <> '' THEN
    RETURN v_label;
  END IF;

  SELECT btrim(s.label)
  INTO v_label
  FROM public.competition_seasons s
  WHERE s.status IN ('preseason', 'setup')
  ORDER BY s.id DESC
  LIMIT 1;

  RETURN NULLIF(v_label, '');
END;
$function$;

-- Keep signed-this-season helper explicit (uses updated label fn)
CREATE OR REPLACE FUNCTION public.player_signed_this_season(p_season_signed text)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT btrim(coalesce(p_season_signed, '')) <> ''
    AND btrim(coalesce(p_season_signed, ''))
      = coalesce(public.current_gpsl_season_label(), '');
$$;

GRANT EXECUTE ON FUNCTION public.current_gpsl_season_id() TO authenticated;
GRANT EXECUTE ON FUNCTION public.current_gpsl_season_label() TO authenticated;
GRANT EXECUTE ON FUNCTION public.player_signed_this_season(text) TO authenticated;

NOTIFY pgrst, 'reload schema';

SELECT
  public.current_gpsl_season_id() AS season_id,
  public.current_gpsl_season_label() AS season_label;
