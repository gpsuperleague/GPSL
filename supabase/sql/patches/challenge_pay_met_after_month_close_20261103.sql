-- =============================================================================
-- Challenge cash: still pay when target already met after month window closes
-- =============================================================================
-- Bug: month-scoped challenges (e.g. August's Iron Run, gpsl_month_to=august)
-- set competition_challenge_window_open=false once the GPSL calendar moves past
-- that month. try_award / award then skipped entirely — board showed 1/6 done
-- (stat met) but Prizes won stayed "—" (no competition_challenge_awarded row).
--
-- Fix: if the club already meets target_value, award with ignore_window so cash
-- still posts. Window close only blocks unfinished challenges from being worked.
-- Also catch-up any currently met-but-unpaid rows. Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.competition_try_award_challenges(
  p_season_id bigint,
  p_club_short_name text,
  p_ignore_window boolean DEFAULT false
)
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_row public.competition_challenge_config;
  v_val int;
  v_awarded int := 0;
  v_window_open boolean;
  v_force boolean;
BEGIN
  IF p_season_id IS NULL OR p_club_short_name IS NULL OR btrim(p_club_short_name) = '' THEN
    RETURN 0;
  END IF;

  FOR v_row IN
    SELECT *
    FROM public.competition_challenge_config
    WHERE season_id = p_season_id
      AND is_active = true
    ORDER BY sort_order, id
  LOOP
    IF EXISTS (
      SELECT 1 FROM public.competition_challenge_awarded
      WHERE challenge_id = v_row.id
        AND club_short_name = p_club_short_name
    ) THEN
      CONTINUE;
    END IF;

    v_val := public.competition_challenge_stat_value(
      p_season_id,
      p_club_short_name,
      v_row.stat_type,
      v_row.gpsl_month_from,
      v_row.gpsl_month_to,
      v_row.include_league,
      v_row.include_cup,
      v_row.stat_param
    );

    IF coalesce(v_val, 0) < v_row.target_value THEN
      CONTINUE;
    END IF;

    v_window_open := public.competition_challenge_window_open(
      p_season_id, v_row.window_phase, v_row.gpsl_month_to
    );
    -- Target already met: pay even if the month window has closed.
    v_force := coalesce(p_ignore_window, false) OR (NOT coalesce(v_window_open, false));

    IF public.competition_award_challenge(
      v_row.id, p_club_short_name, v_val, v_force
    ) THEN
      v_awarded := v_awarded + 1;
      PERFORM public.competition_try_award_period_bonus(
        p_season_id,
        p_club_short_name,
        v_row.window_phase,
        v_force
      );
    END IF;
  END LOOP;

  RETURN v_awarded;
END;
$function$;

REVOKE ALL ON FUNCTION public.competition_try_award_challenges(bigint, text, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.competition_try_award_challenges(bigint, text, boolean)
  TO authenticated, service_role;

-- Catch-up current season: met target, no award row yet
DO $$
DECLARE
  r record;
  v_ok boolean;
  v_n int := 0;
  v_season bigint;
BEGIN
  SELECT id INTO v_season
  FROM public.competition_seasons
  WHERE is_current = true
  ORDER BY id DESC
  LIMIT 1;

  IF v_season IS NULL THEN
    RAISE NOTICE 'challenge catch-up: no current season';
    RETURN;
  END IF;

  FOR r IN
    SELECT c.id AS challenge_id,
           ccs.club_short_name AS club,
           public.competition_challenge_stat_value(
             v_season, ccs.club_short_name, c.stat_type, c.gpsl_month_from, c.gpsl_month_to,
             c.include_league, c.include_cup, c.stat_param
           ) AS stat_val
    FROM public.competition_challenge_config c
    JOIN public.competition_club_seasons ccs
      ON ccs.season_id = v_season
     AND ccs.division IN ('superleague', 'championship_a', 'championship_b')
    WHERE c.season_id = v_season
      AND c.is_active
      AND public.competition_challenge_stat_value(
             v_season, ccs.club_short_name, c.stat_type, c.gpsl_month_from, c.gpsl_month_to,
             c.include_league, c.include_cup, c.stat_param
           ) >= c.target_value
      AND NOT EXISTS (
        SELECT 1
        FROM public.competition_challenge_awarded a
        WHERE a.challenge_id = c.id
          AND a.club_short_name = ccs.club_short_name
      )
  LOOP
    v_ok := public.competition_award_challenge(
      r.challenge_id, r.club, r.stat_val, true
    );
    IF v_ok THEN
      v_n := v_n + 1;
    END IF;
  END LOOP;

  RAISE NOTICE 'challenge catch-up awarded % row(s)', v_n;
END $$;
