-- =============================================================================
-- Mid-season challenges stay open through Playoffs week
--
-- Mid window is still Jan–May for stats. Playoffs keeps the award window open
-- so late May results / confirmations can still complete mid challenges.
-- Start window (→ December) closes once we are past December (incl. Playoffs).
-- Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.competition_challenge_month_sort(p_month text)
RETURNS smallint
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE lower(btrim(coalesce(p_month, '')))
    WHEN 'june' THEN 0
    WHEN 'july' THEN 1
    WHEN 'august' THEN 2
    WHEN 'september' THEN 3
    WHEN 'october' THEN 4
    WHEN 'november' THEN 5
    WHEN 'december' THEN 6
    WHEN 'january' THEN 7
    WHEN 'february' THEN 8
    WHEN 'march' THEN 9
    WHEN 'april' THEN 10
    WHEN 'may' THEN 11
    WHEN 'playoffs' THEN 12
    ELSE NULL
  END;
$$;

CREATE OR REPLACE FUNCTION public.competition_challenge_window_open(
  p_season_id bigint,
  p_window_phase text,
  p_gpsl_month_to text
)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_active text;
  v_active_sort int;
  v_deadline_sort int;
  v_deadline text := lower(btrim(coalesce(p_gpsl_month_to, '')));
  v_phase text := lower(btrim(coalesce(p_window_phase, '')));
BEGIN
  v_active := public.competition_active_gpsl_month(p_season_id, now());
  v_deadline_sort := public.competition_challenge_month_sort(p_gpsl_month_to);

  -- Pre-season / between months / no calendar
  IF v_active IS NULL THEN
    RETURN true;
  END IF;

  v_active := lower(btrim(v_active));

  -- Mid-season (deadline May): remain open through Playoffs week
  IF v_active = 'playoffs'
     AND (
       v_phase = 'mid'
       OR v_deadline = 'may'
     ) THEN
    RETURN true;
  END IF;

  v_active_sort := public.competition_challenge_month_sort(v_active);
  IF v_active_sort IS NULL OR v_deadline_sort IS NULL THEN
    RETURN false;
  END IF;

  RETURN v_active_sort <= v_deadline_sort;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_challenge_month_sort(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.competition_challenge_window_open(bigint, text, text)
  TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';
