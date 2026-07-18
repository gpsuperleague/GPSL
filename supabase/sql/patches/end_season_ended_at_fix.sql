-- competition_end_season used updated_at, but competition_seasons has ended_at.
-- Safe to re-run.

CREATE OR REPLACE FUNCTION public.competition_end_season()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season public.competition_seasons;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  SELECT * INTO v_season
  FROM public.competition_seasons
  WHERE is_current = true
    AND status = 'active'
  LIMIT 1;

  IF NOT FOUND THEN
    SELECT * INTO v_season
    FROM public.competition_seasons
    WHERE status = 'active'
    ORDER BY id DESC
    LIMIT 1;
  END IF;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'No active current season to end';
  END IF;

  UPDATE public.competition_seasons
  SET
    status = 'complete',
    is_current = false,
    ended_at = coalesce(ended_at, now())
  WHERE id = v_season.id;

  UPDATE public.global_settings
  SET league_phase = 'summer_break', updated_at = now()
  WHERE id = 1;

  RETURN jsonb_build_object(
    'season_id', v_season.id,
    'label', v_season.label,
    'league_phase', 'summer_break'
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_end_season() TO authenticated;
