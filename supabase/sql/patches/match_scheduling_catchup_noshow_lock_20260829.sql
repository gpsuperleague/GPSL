-- =============================================================================
-- Catch-up no-show: same month-lock rule as play-month no-show
--
-- If a rolled-over (catch-up) fixture is later arranged and one side no-shows,
-- resolve at the next GPSL month lock: 3–0 + ₿5m (match_agreed_no_show).
-- Same as when the no-show happens in the original play month.
--
-- Includes the LIKE-key fix (sched_checkin_lock:{month}:{fixture_id}).
-- Safe re-run. Run after checkin_noshow_like_fix if that was applied, or alone.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.competition_enforce_scheduling_checkin_fines(
  p_season_id bigint,
  p_closed_gpsl_month text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_row record;
  v_lock timestamptz;
  v_results jsonb := '[]'::jsonb;
  v_count int := 0;
  v_skipped int := 0;
  v_note_prefix text;
  v_is_catch_up boolean;
BEGIN
  SELECT c.lock_at
  INTO v_lock
  FROM public.competition_season_calendar c
  WHERE c.season_id = p_season_id
    AND c.gpsl_month = p_closed_gpsl_month;

  IF v_lock IS NULL OR v_lock > now() THEN
    RETURN jsonb_build_object(
      'ok', false,
      'reason', 'month_not_closed',
      'closed_gpsl_month', p_closed_gpsl_month
    );
  END IF;

  FOR v_row IN
    SELECT
      f.id AS fixture_id,
      s.no_show_club_short_name AS loser,
      f.matchday,
      f.gpsl_month,
      s.no_show_kickoff_at
    FROM public.competition_fixtures f
    JOIN public.competition_fixture_schedule s ON s.fixture_id = f.id
    WHERE f.season_id = p_season_id
      AND (
        CASE
          WHEN to_regprocedure('public.match_schedule_uses_club_month_rules(text)') IS NOT NULL
          THEN public.match_schedule_uses_club_month_rules(f.competition_type)
          ELSE f.competition_type IN ('league', 'cup')
        END
      )
      AND f.status = 'scheduled'
      AND s.no_show_club_short_name IS NOT NULL
      -- Play-month fixtures closing now, OR catch-up (play month already closed)
      AND (
        f.gpsl_month = p_closed_gpsl_month
        OR public.match_schedule_fixture_is_catch_up(f.id)
      )
      -- No-show must have occurred before this lock
      AND (s.no_show_kickoff_at IS NULL OR s.no_show_kickoff_at < v_lock)
      AND EXISTS (
        SELECT 1
        FROM public."Clubs" c
        WHERE c."ShortName" = s.no_show_club_short_name
          AND c.owner_id IS NOT NULL
      )
  LOOP
    -- One no-show forfeit per fixture ever
    IF EXISTS (
      SELECT 1
      FROM public.competition_fine_applied fa
      WHERE fa.fixture_id = v_row.fixture_id
        AND fa.tariff_code = 'match_agreed_no_show'
    ) THEN
      v_skipped := v_skipped + 1;
      CONTINUE;
    END IF;

    v_note_prefix := format(
      'sched_checkin_lock:%s:%s',
      p_closed_gpsl_month,
      v_row.fixture_id
    );

    v_is_catch_up := public.match_schedule_fixture_is_catch_up(v_row.fixture_id)
      AND v_row.gpsl_month IS DISTINCT FROM p_closed_gpsl_month;

    PERFORM public.fixture_apply_forfeit(
      v_row.fixture_id,
      v_row.loser,
      'match_agreed_no_show',
      format(
        'sched_checkin_lock:%s:%s|No check-in at agreed kick-off · %s MD%s · assessed at month lock%s',
        p_closed_gpsl_month,
        v_row.fixture_id,
        public.competition_gpsl_month_label(v_row.gpsl_month),
        v_row.matchday,
        CASE WHEN v_is_catch_up THEN ' (catch-up)' ELSE '' END
      )
    );

    v_count := v_count + 1;
    v_results := v_results || jsonb_build_array(
      jsonb_build_object(
        'fixture_id', v_row.fixture_id,
        'loser', v_row.loser,
        'catch_up', v_is_catch_up
      )
    );
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true,
    'closed_gpsl_month', p_closed_gpsl_month,
    'forfeits_applied', v_count,
    'skipped', v_skipped,
    'forfeited', v_results
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_enforce_scheduling_checkin_fines(bigint, text)
  TO authenticated;

NOTIFY pgrst, 'reload schema';
