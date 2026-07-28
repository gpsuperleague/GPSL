-- =============================================================================
-- Manager list/sack window: June, July, August, and January
--
-- Reverses manager_list_sack_no_august.sql for August — owners may list/sack
-- in GPSL August as well as June/July and January (with transfer window).
--
-- Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.manager_list_sack_window_open()
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season_id bigint;
  v_status text;
  v_month text;
  v_tw boolean;
BEGIN
  SELECT s.id, s.status
  INTO v_season_id, v_status
  FROM public.competition_seasons s
  WHERE s.is_current = true
  ORDER BY s.id DESC
  LIMIT 1;

  IF v_season_id IS NULL THEN
    RETURN false;
  END IF;

  -- Pre-season / create-season window (before programme starts)
  IF lower(coalesce(v_status, '')) = 'preseason' THEN
    RETURN true;
  END IF;

  SELECT transfer_window_open INTO v_tw
  FROM public.global_settings WHERE id = 1;

  v_month := lower(coalesce(public.competition_active_gpsl_month(v_season_id, now()), ''));

  IF v_month = '' AND coalesce(v_tw, false) THEN
    RETURN true;
  END IF;

  -- Summer list/sack: June, July, August
  IF v_month IN ('june', 'july', 'august') THEN
    RETURN true;
  END IF;

  -- January requires transfer window flag
  IF v_month = 'january' AND coalesce(v_tw, false) THEN
    RETURN true;
  END IF;

  RETURN false;
END;
$function$;

CREATE OR REPLACE FUNCTION public.manager_sack_window_open()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT public.manager_list_sack_window_open();
$$;

COMMENT ON FUNCTION public.manager_list_sack_window_open() IS
  'True when managers may be listed or sacked: GPSL June/July/August, or January while transfer window is open (also preseason).';

GRANT EXECUTE ON FUNCTION public.manager_list_sack_window_open() TO authenticated;
GRANT EXECUTE ON FUNCTION public.manager_sack_window_open() TO authenticated;
