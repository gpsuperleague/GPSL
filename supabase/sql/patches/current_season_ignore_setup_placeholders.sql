-- =============================================================================
-- Current GPSL season: ignore WC "setup" placeholders
--
-- Problem: international_admin_ensure_seasons_through creates Season 1–5 with
--   status = 'setup'. current_gpsl_season_* / gpsl_season_id_for_locks fell
--   back to those shells, so the UI showed "GPSL Season 5" after a vanilla
--   reset (or whenever WC placeholders existed with no real season).
--
-- Fix: fall back only to real Create Pre-Season rows (status = 'preseason').
--   Pure setup placeholders are WC planning shells, not the live GPSL year.
--
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

  -- Real Create Pre-Season shell only (not WC status=setup placeholders)
  SELECT s.id
  INTO v_id
  FROM public.competition_seasons s
  WHERE s.status = 'preseason'
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
  WHERE s.status = 'preseason'
  ORDER BY s.id DESC
  LIMIT 1;

  RETURN NULLIF(v_label, '');
END;
$function$;

CREATE OR REPLACE FUNCTION public.gpsl_season_id_for_locks()
RETURNS bigint
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_id bigint;
BEGIN
  v_id := public.current_gpsl_season_id();
  IF v_id IS NOT NULL THEN
    RETURN v_id;
  END IF;

  -- Summer break / Create Pre-Season: newest real preseason only
  SELECT s.id
  INTO v_id
  FROM public.competition_seasons s
  WHERE s.status = 'preseason'
  ORDER BY s.id DESC
  LIMIT 1;

  IF v_id IS NOT NULL THEN
    RETURN v_id;
  END IF;

  -- Last real competition year (never WC setup-only shells)
  SELECT s.id
  INTO v_id
  FROM public.competition_seasons s
  WHERE s.status IN ('active', 'complete', 'summer_break', 'preseason')
     OR s.is_current IS TRUE
     OR s.started_at IS NOT NULL
  ORDER BY s.id DESC
  LIMIT 1;

  RETURN v_id;
END;
$function$;

COMMENT ON FUNCTION public.gpsl_season_id_for_locks() IS
  'Season id for foreign/paid-up locks: current, else newest preseason, else newest real season (excludes WC setup placeholders).';

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
GRANT EXECUTE ON FUNCTION public.gpsl_season_id_for_locks() TO authenticated;
GRANT EXECUTE ON FUNCTION public.player_signed_this_season(text) TO authenticated;

NOTIFY pgrst, 'reload schema';

SELECT
  public.current_gpsl_season_id() AS season_id,
  public.current_gpsl_season_label() AS season_label,
  public.gpsl_season_id_for_locks() AS lock_season_id;
