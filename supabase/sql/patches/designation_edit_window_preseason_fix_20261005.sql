-- =============================================================================
-- Fan Favourite / OooO edit window was closed for owners during pre-season.
-- Now open when ANY of:
--   • current season status is setup / preseason / summer_break
--   • the season calendar hasn't started yet (first month not unlocked / no calendar)
--   • active GPSL month is june, july or january
-- Run once in the Supabase SQL Editor. The first SELECT shows why it was shut.
-- =============================================================================

-- Diagnostic (before)
SELECT
  public.competition_finances_current_season_id() AS season_used,
  (SELECT s.status FROM public.competition_seasons s
    WHERE s.id = public.competition_finances_current_season_id()) AS season_status,
  public.competition_active_gpsl_month(public.competition_finances_current_season_id(), now()) AS active_month,
  (SELECT min(c.unlock_at) FROM public.competition_season_calendar c
    WHERE c.season_id = public.competition_finances_current_season_id()) AS calendar_first_unlock,
  (SELECT string_agg(s.id || ':' || s.status || CASE WHEN s.is_current THEN '*' ELSE '' END, ', ' ORDER BY s.id)
     FROM public.competition_seasons s) AS all_seasons;

CREATE OR REPLACE FUNCTION public.club_squad_designation_edit_window_open()
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
  v_first_unlock timestamptz;
BEGIN
  SELECT s.id, s.status INTO v_season_id, v_status
  FROM public.competition_seasons s
  WHERE s.is_current = true
  ORDER BY s.id DESC
  LIMIT 1;

  IF v_season_id IS NULL THEN
    IF to_regprocedure('public.competition_finances_current_season_id()') IS NOT NULL THEN
      v_season_id := public.competition_finances_current_season_id();
    END IF;
    IF v_season_id IS NULL THEN
      -- Between seasons (summer break with no current season)
      RETURN true;
    END IF;
    SELECT s.status INTO v_status FROM public.competition_seasons s WHERE s.id = v_season_id;
  END IF;

  IF v_status IN ('preseason', 'setup', 'summer_break') THEN
    RETURN true;
  END IF;

  SELECT min(c.unlock_at) INTO v_first_unlock
  FROM public.competition_season_calendar c
  WHERE c.season_id = v_season_id;

  IF v_first_unlock IS NULL OR v_first_unlock > now() THEN
    RETURN true;
  END IF;

  IF to_regprocedure('public.competition_active_gpsl_month(bigint, timestamptz)') IS NOT NULL THEN
    v_month := lower(btrim(coalesce(
      public.competition_active_gpsl_month(v_season_id, now()),
      ''
    )));
  END IF;

  RETURN coalesce(v_month, '') IN ('june', 'july', 'january');
END;
$function$;

COMMENT ON FUNCTION public.club_squad_designation_edit_window_open() IS
  'OooO / Fan Favourite editable in setup/preseason/summer break, before the season calendar starts, or GPSL june/july/january.';

GRANT EXECUTE ON FUNCTION public.club_squad_designation_edit_window_open() TO authenticated;

NOTIFY pgrst, 'reload schema';

-- After
SELECT public.club_squad_designation_edit_window_open() AS owner_edit_window_open;
