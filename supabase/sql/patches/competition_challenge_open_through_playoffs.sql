-- =============================================================================
-- Mid-season challenges that end in May stay open through Playoffs.
-- Month-specific targets (e.g. January-only) still expire after that month.
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
BEGIN
  v_active := public.competition_active_gpsl_month(p_season_id, now());
  v_deadline_sort := public.competition_challenge_month_sort(p_gpsl_month_to);

  -- Pre-season / between months / no calendar
  IF v_active IS NULL THEN
    RETURN true;
  END IF;

  v_active := lower(btrim(v_active));

  -- Only May-deadline challenges stay open through Playoffs (not Jan/Feb/Mar-only)
  IF v_active = 'playoffs' AND v_deadline = 'may' THEN
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

-- Include month window on club progress (for Closed labels / UI)
CREATE OR REPLACE FUNCTION public.competition_challenge_club_progress(p_club_short_name text)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := btrim(p_club_short_name);
  v_me text := public.my_club_shortname();
  v_season_id bigint;
  v_challenges jsonb := '[]'::jsonb;
  v_row record;
  v_val int;
  v_awarded boolean;
BEGIN
  IF v_club IS NULL OR v_club = '' THEN
    RAISE EXCEPTION 'Club required';
  END IF;

  IF NOT public.is_gpsl_admin() AND (v_me IS NULL OR v_me <> v_club) THEN
    RAISE EXCEPTION 'Not allowed';
  END IF;

  SELECT id INTO v_season_id
  FROM public.competition_seasons
  WHERE is_current = true
  ORDER BY id DESC
  LIMIT 1;

  FOR v_row IN
    SELECT *
    FROM public.competition_challenge_config
    WHERE season_id = v_season_id
      AND is_active = true
    ORDER BY window_phase, sort_order, id
  LOOP
    v_val := public.competition_challenge_stat_value(
      v_season_id,
      v_club,
      v_row.stat_type,
      v_row.gpsl_month_from,
      v_row.gpsl_month_to,
      v_row.include_league,
      v_row.include_cup,
      v_row.stat_param
    );

    SELECT EXISTS (
      SELECT 1 FROM public.competition_challenge_awarded
      WHERE challenge_id = v_row.id AND club_short_name = v_club
    ) INTO v_awarded;

    v_challenges := v_challenges || jsonb_build_array(
      jsonb_build_object(
        'id', v_row.id,
        'title', v_row.title,
        'description', v_row.description,
        'window_phase', v_row.window_phase,
        'gpsl_month_from', v_row.gpsl_month_from,
        'gpsl_month_to', v_row.gpsl_month_to,
        'gpsl_month_from_label', public.competition_challenge_month_label(v_row.gpsl_month_from),
        'gpsl_month_to_label', public.competition_challenge_month_label(v_row.gpsl_month_to),
        'stat_type', v_row.stat_type,
        'stat_param', v_row.stat_param,
        'target_value', v_row.target_value,
        'current_value', v_val,
        'prize_amount', v_row.prize_amount,
        'awarded', v_awarded,
        'expired', NOT public.competition_challenge_window_open(
          v_season_id, v_row.window_phase, v_row.gpsl_month_to
        )
      )
    );
  END LOOP;

  RETURN jsonb_build_object(
    'season_id', v_season_id,
    'club_short_name', v_club,
    'challenges', v_challenges
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_challenge_club_progress(text) TO authenticated;

NOTIFY pgrst, 'reload schema';
