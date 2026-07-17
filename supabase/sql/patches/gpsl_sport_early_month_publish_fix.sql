-- =============================================================================
-- Fix GPSL Sport after early month-end (March etc. never written)
--
-- Bugs:
-- 1) competition_admin_regenerate_gpsl_sport preferred refresh, which returns
--    NULL when no edition row exists yet — so first publish never happened.
-- 2) Month-lock jobs could mark gpsl_sport:<month> done even when edition_id
--    was null, blocking later retries.
--
-- Run in Supabase SQL Editor, then publish March from End Month Early page
-- (or Admin → Season → Rebuild GPSL Sport → march).
-- =============================================================================

CREATE OR REPLACE FUNCTION public.competition_admin_regenerate_gpsl_sport(
  p_gpsl_month text DEFAULT NULL,
  p_season_id bigint DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season_id bigint;
  v_month text;
  v_edition_id bigint;
  v_existing bigint;
  v_role text := coalesce(auth.jwt() ->> 'role', '');
  v_job_key text;
BEGIN
  PERFORM set_config('statement_timeout', '180s', true);

  IF public.is_gpsl_admin() IS NOT TRUE
     AND current_user NOT IN ('postgres', 'service_role')
     AND v_role <> 'service_role' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'admin_only');
  END IF;

  SELECT coalesce(
    p_season_id,
    (SELECT s.id FROM public.competition_seasons s WHERE s.is_current IS TRUE ORDER BY s.id DESC LIMIT 1)
  ) INTO v_season_id;

  IF v_season_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_season');
  END IF;

  v_month := lower(nullif(btrim(p_gpsl_month), ''));
  IF v_month IS NULL THEN
    SELECT c.gpsl_month INTO v_month
    FROM public.competition_season_calendar c
    WHERE c.season_id = v_season_id
      AND c.lock_at IS NOT NULL
      AND c.lock_at <= now()
    ORDER BY public.competition_gpsl_month_sort(c.gpsl_month) DESC
    LIMIT 1;
  END IF;

  IF v_month IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_month');
  END IF;

  SELECT e.id INTO v_existing
  FROM public.gpsl_sport_editions e
  WHERE e.season_id = v_season_id
    AND lower(e.gpsl_month) = v_month
  ORDER BY e.published_at DESC NULLS LAST, e.id DESC
  LIMIT 1;

  IF v_existing IS NULL THEN
    -- First publish for this month — must CREATE, not refresh
    v_edition_id := public.gpsl_sport_generate_edition(v_season_id, v_month);
  ELSIF to_regprocedure('public.gpsl_sport_refresh_inseason_edition(bigint, text)') IS NOT NULL
        AND v_month NOT IN ('may', 'june', 'july') THEN
    v_edition_id := public.gpsl_sport_refresh_inseason_edition(v_season_id, v_month);
    IF v_edition_id IS NULL THEN
      v_edition_id := public.gpsl_sport_regenerate_edition(v_season_id, v_month);
    END IF;
  ELSE
    v_edition_id := public.gpsl_sport_regenerate_edition(v_season_id, v_month);
  END IF;

  -- Clear stuck "done" job markers when we still have no edition
  v_job_key := 'gpsl_sport:' || v_month;
  IF v_edition_id IS NULL THEN
    DELETE FROM public.competition_season_calendar_jobs j
    WHERE j.season_id = v_season_id
      AND j.job_key = v_job_key;
  ELSE
    INSERT INTO public.competition_season_calendar_jobs (
      season_id, job_key, gpsl_month, result
    )
    VALUES (
      v_season_id,
      v_job_key,
      v_month,
      jsonb_build_object('edition_id', v_edition_id, 'ok', true, 'source', 'admin_regenerate')
    )
    ON CONFLICT (season_id, job_key) DO UPDATE
      SET result = excluded.result,
          gpsl_month = excluded.gpsl_month,
          ran_at = now();
  END IF;

  RETURN jsonb_build_object(
    'ok', v_edition_id IS NOT NULL,
    'edition_id', v_edition_id,
    'season_id', v_season_id,
    'gpsl_month', v_month,
    'edition_label', public.gpsl_sport_month_label(v_month),
    'created_new', v_existing IS NULL
  );
END;
$function$;

-- Only mark Sport job complete when an edition was actually created
CREATE OR REPLACE FUNCTION public.competition_run_month_lock_jobs(
  p_season_id bigint,
  p_force_scheduling boolean DEFAULT false,
  p_locked_gpsl_month text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_out jsonb := jsonb_build_object('ok', true, 'season_id', p_season_id);
  v_totm jsonb;
  v_sport jsonb;
  v_tv jsonb;
  v_response_track jsonb;
  v_sched_fines jsonb;
  v_response_fines jsonb;
  v_checkin_fines jsonb;
  v_last_scheduling timestamptz;
  v_run_scheduling boolean := false;
  v_month text := nullif(lower(btrim(coalesce(p_locked_gpsl_month, ''))), '');
  v_scope text;
  v_job_key text;
  v_res jsonb;
  v_id bigint;
  v_totm_results jsonb := '[]'::jsonb;
  v_sport_results jsonb := '[]'::jsonb;
BEGIN
  PERFORM set_config('statement_timeout', '180s', true);

  IF p_season_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_season');
  END IF;

  BEGIN
    IF v_month IS NOT NULL
       AND to_regprocedure('public.competition_compute_team_of_month(bigint,text,text)') IS NOT NULL THEN
      FOREACH v_scope IN ARRAY ARRAY['superleague', 'championship']::text[]
      LOOP
        v_job_key := 'team_of_month:' || v_scope || ':' || v_month;

        IF v_scope = 'superleague' AND EXISTS (
          SELECT 1 FROM public.competition_season_calendar_jobs j
          WHERE j.season_id = p_season_id
            AND j.job_key IN (v_job_key, 'team_of_month:' || v_month)
        ) THEN
          CONTINUE;
        ELSIF EXISTS (
          SELECT 1 FROM public.competition_season_calendar_jobs j
          WHERE j.season_id = p_season_id AND j.job_key = v_job_key
        ) THEN
          CONTINUE;
        END IF;

        v_res := public.competition_compute_team_of_month(p_season_id, v_month, v_scope);

        INSERT INTO public.competition_season_calendar_jobs (
          season_id, job_key, gpsl_month, result
        )
        VALUES (p_season_id, v_job_key, v_month, coalesce(v_res, '{}'::jsonb))
        ON CONFLICT (season_id, job_key) DO UPDATE
          SET result = excluded.result,
              gpsl_month = excluded.gpsl_month,
              ran_at = now();

        v_totm_results := v_totm_results || jsonb_build_array(
          jsonb_build_object(
            'gpsl_month', v_month,
            'division_scope', v_scope,
            'result', v_res
          )
        );
      END LOOP;
      v_totm := jsonb_build_object('ok', true, 'processed', v_totm_results, 'scoped', true);
    ELSIF to_regprocedure('public.competition_process_month_team_awards(bigint)') IS NOT NULL THEN
      v_totm := public.competition_process_month_team_awards(p_season_id);
    ELSE
      v_totm := jsonb_build_object('skipped', true, 'reason', 'totm_rpc_missing');
    END IF;
    v_out := v_out || jsonb_build_object('team_of_month', v_totm);
  EXCEPTION
    WHEN OTHERS THEN
      v_out := v_out || jsonb_build_object(
        'team_of_month', jsonb_build_object('ok', false, 'error', SQLERRM)
      );
  END;

  BEGIN
    IF v_month IS NOT NULL THEN
      v_job_key := 'gpsl_sport:' || v_month;

      -- Clear failed/empty prior markers so we can create the edition
      DELETE FROM public.competition_season_calendar_jobs j
      WHERE j.season_id = p_season_id
        AND j.job_key = v_job_key
        AND (
          j.result IS NULL
          OR coalesce((j.result->>'ok')::boolean, false) IS NOT TRUE
          OR (j.result->>'edition_id') IS NULL
        );

      IF NOT EXISTS (
        SELECT 1 FROM public.gpsl_sport_editions e
        WHERE e.season_id = p_season_id AND lower(e.gpsl_month) = v_month
      ) THEN
        IF to_regprocedure('public.gpsl_sport_generate_edition(bigint,text)') IS NOT NULL THEN
          v_id := public.gpsl_sport_generate_edition(p_season_id, v_month);
        END IF;
      ELSE
        SELECT e.id INTO v_id
        FROM public.gpsl_sport_editions e
        WHERE e.season_id = p_season_id AND lower(e.gpsl_month) = v_month
        ORDER BY e.id DESC
        LIMIT 1;
      END IF;

      IF v_id IS NOT NULL THEN
        INSERT INTO public.competition_season_calendar_jobs (
          season_id, job_key, gpsl_month, result
        )
        VALUES (
          p_season_id, v_job_key, v_month,
          jsonb_build_object('edition_id', v_id, 'ok', true)
        )
        ON CONFLICT (season_id, job_key) DO UPDATE
          SET result = excluded.result,
              gpsl_month = excluded.gpsl_month,
              ran_at = now();

        v_sport_results := v_sport_results || jsonb_build_array(
          jsonb_build_object('gpsl_month', v_month, 'edition_id', v_id)
        );
        v_sport := jsonb_build_object('ok', true, 'processed', v_sport_results, 'scoped', true);
      ELSE
        v_sport := jsonb_build_object(
          'ok', false,
          'error', 'edition_not_created',
          'gpsl_month', v_month,
          'hint', 'Call competition_admin_regenerate_gpsl_sport for this month'
        );
      END IF;
    ELSIF to_regprocedure('public.gpsl_sport_process_pending_editions(bigint)') IS NOT NULL THEN
      v_sport := public.gpsl_sport_process_pending_editions(p_season_id);
    ELSE
      v_sport := jsonb_build_object('skipped', true, 'reason', 'sport_rpc_missing');
    END IF;
    v_out := v_out || jsonb_build_object('gpsl_sport', v_sport);
  EXCEPTION
    WHEN OTHERS THEN
      v_out := v_out || jsonb_build_object(
        'gpsl_sport', jsonb_build_object('ok', false, 'error', SQLERRM)
      );
  END;

  BEGIN
    IF to_regprocedure('public.competition_tv_process_month_lock_selections(bigint,text)') IS NOT NULL THEN
      v_tv := public.competition_tv_process_month_lock_selections(p_season_id, p_locked_gpsl_month);
      v_out := v_out || jsonb_build_object('tv_selection', v_tv);
    END IF;
  EXCEPTION
    WHEN OTHERS THEN
      v_out := v_out || jsonb_build_object(
        'tv_selection', jsonb_build_object('ok', false, 'error', SQLERRM)
      );
  END;

  IF p_force_scheduling THEN
    v_run_scheduling := true;
  ELSE
    SELECT j.ran_at
    INTO v_last_scheduling
    FROM public.competition_season_calendar_jobs j
    WHERE j.season_id = p_season_id
      AND j.job_key = 'scheduling_enforcement_throttle'
    LIMIT 1;

    v_run_scheduling :=
      v_last_scheduling IS NULL
      OR v_last_scheduling < now() - interval '5 minutes';
  END IF;

  IF v_run_scheduling THEN
    BEGIN
      IF to_regprocedure('public.competition_process_scheduling_response_deadlines(bigint)') IS NOT NULL THEN
        v_response_track := public.competition_process_scheduling_response_deadlines(p_season_id);
        v_out := v_out || jsonb_build_object('scheduling_response_deadlines', v_response_track);
      END IF;
    EXCEPTION
      WHEN OTHERS THEN
        v_out := v_out || jsonb_build_object(
          'scheduling_response_deadlines', jsonb_build_object('ok', false, 'error', SQLERRM)
        );
    END;

    BEGIN
      IF to_regprocedure('public.competition_process_scheduling_arrangement_fines(bigint)') IS NOT NULL THEN
        v_sched_fines := public.competition_process_scheduling_arrangement_fines(p_season_id);
        v_out := v_out || jsonb_build_object('scheduling_arrangement_fines', v_sched_fines);
      END IF;
    EXCEPTION
      WHEN OTHERS THEN
        v_out := v_out || jsonb_build_object(
          'scheduling_arrangement_fines', jsonb_build_object('ok', false, 'error', SQLERRM)
        );
    END;

    BEGIN
      IF to_regprocedure('public.competition_process_scheduling_response_fines(bigint)') IS NOT NULL THEN
        v_response_fines := public.competition_process_scheduling_response_fines(p_season_id);
        v_out := v_out || jsonb_build_object('scheduling_response_fines', v_response_fines);
      END IF;
    EXCEPTION
      WHEN OTHERS THEN
        v_out := v_out || jsonb_build_object(
          'scheduling_response_fines', jsonb_build_object('ok', false, 'error', SQLERRM)
        );
    END;

    BEGIN
      IF to_regprocedure('public.competition_process_scheduling_checkin_fines(bigint)') IS NOT NULL THEN
        v_checkin_fines := public.competition_process_scheduling_checkin_fines(p_season_id);
        v_out := v_out || jsonb_build_object('scheduling_checkin_fines', v_checkin_fines);
      END IF;
    EXCEPTION
      WHEN OTHERS THEN
        v_out := v_out || jsonb_build_object(
          'scheduling_checkin_fines', jsonb_build_object('ok', false, 'error', SQLERRM)
        );
    END;

    INSERT INTO public.competition_season_calendar_jobs (
      season_id, job_key, gpsl_month, result
    )
    VALUES (
      p_season_id,
      'scheduling_enforcement_throttle',
      coalesce(v_month, public.competition_active_gpsl_month(p_season_id, now()), 'none'),
      jsonb_build_object('ok', true, 'ran_at', now(), 'forced', p_force_scheduling)
    )
    ON CONFLICT (season_id, job_key) DO UPDATE
      SET result = excluded.result,
          gpsl_month = excluded.gpsl_month,
          ran_at = now();
  ELSE
    v_out := v_out || jsonb_build_object(
      'scheduling', jsonb_build_object('skipped', true, 'reason', 'throttled')
    );
  END IF;

  RETURN v_out;
END;
$function$;

-- One-shot: clear stuck March job marker if edition missing (safe if already fine)
DO $$
DECLARE
  v_season_id bigint;
BEGIN
  SELECT id INTO v_season_id
  FROM public.competition_seasons
  WHERE is_current = true
  ORDER BY id DESC
  LIMIT 1;

  IF v_season_id IS NULL THEN
    RETURN;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.gpsl_sport_editions e
    WHERE e.season_id = v_season_id AND lower(e.gpsl_month) = 'march'
  ) THEN
    DELETE FROM public.competition_season_calendar_jobs j
    WHERE j.season_id = v_season_id
      AND j.job_key = 'gpsl_sport:march';
  END IF;
END $$;

GRANT EXECUTE ON FUNCTION public.competition_admin_regenerate_gpsl_sport(text, bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.competition_run_month_lock_jobs(bigint, boolean, text) TO service_role;

NOTIFY pgrst, 'reload schema';
