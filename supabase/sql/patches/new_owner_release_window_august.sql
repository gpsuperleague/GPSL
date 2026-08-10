-- =============================================================================
-- New Owner release/list window — include GPSL August
-- Transfer window runs through August; first-season slots should stay available.
-- Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.club_new_owner_release_window_open()
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

  -- Full pre-season status (before calendar months unlock)
  IF lower(coalesce(v_status, '')) = 'preseason' THEN
    RETURN true;
  END IF;

  SELECT transfer_window_open INTO v_tw
  FROM public.global_settings
  WHERE id = 1;

  v_month := lower(coalesce(public.competition_active_gpsl_month(v_season_id, now()), ''));

  -- Between activate and first GPSL month (no live month yet) while TW open
  IF v_month = '' AND coalesce(v_tw, false) THEN
    RETURN true;
  END IF;

  -- GPSL pre-season / opening window months (June–August)
  IF v_month IN ('june', 'july', 'august') THEN
    RETURN true;
  END IF;

  -- January transfer window
  IF v_month = 'january' AND coalesce(v_tw, false) THEN
    RETURN true;
  END IF;

  RETURN false;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.club_new_owner_release_window_open() TO authenticated;

NOTIFY pgrst, 'reload schema';
