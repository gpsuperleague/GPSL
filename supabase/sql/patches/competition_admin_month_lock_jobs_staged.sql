-- =============================================================================
-- Fix: May (and heavy months) month-lock jobs → statement timeout
--
-- End Month Early already locks the calendar; jobs run in a separate RPC.
-- May packs TOTM + Sport + TV + league tables + playoffs + clinches + fines
-- into one call and exceeds statement_timeout (nothing from that call commits).
--
-- Fix: stage the runner (awards | tables | scheduling | all) so each stage
-- gets its own timeout. Admin UI retries stages in sequence.
-- Safe re-run.
-- =============================================================================

DROP FUNCTION IF EXISTS public.competition_run_month_lock_jobs(bigint, boolean, text);
DROP FUNCTION IF EXISTS public.competition_run_month_lock_jobs(bigint, boolean, text, text);

CREATE OR REPLACE FUNCTION public.competition_run_month_lock_jobs(
  p_season_id bigint,
  p_force_scheduling boolean DEFAULT false,
  p_locked_gpsl_month text DEFAULT NULL,
  p_stage text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_stage text := lower(nullif(btrim(coalesce(p_stage, '')), ''));
  v_do_totm boolean;
  v_do_sport boolean;
  v_do_tv boolean;
  v_do_tables boolean;
  v_do_playoffs boolean;
  v_do_clinches boolean;
  v_do_scheduling boolean;
  v_out jsonb := jsonb_build_object('ok', true, 'season_id', p_season_id);
  v_totm jsonb;
  v_sport jsonb;
  v_tv jsonb;
  v_tables jsonb;
  v_playoffs jsonb;
  v_clinches jsonb;
  v_response_track jsonb;
  v_sched_fines jsonb;
  v_response_fines jsonb;
  v_checkin_fines jsonb;
  v_last_scheduling timestamptz;
  v_run_scheduling boolean := false;
  v_month text := nullif(lower(btrim(coalesce(p_locked_gpsl_month, ''))), '');
  v_month_label text;
  v_scope text;
  v_job_key text;
  v_res jsonb;
  v_id bigint;
  v_qid bigint;
  v_snap jsonb;
  v_totm_results jsonb := '[]'::jsonb;
  v_sport_results jsonb := '[]'::jsonb;
  v_stadium_clubs int;
BEGIN
  PERFORM set_config('statement_timeout', '240s', true);

  IF v_stage IS NULL OR v_stage = 'all' THEN
    v_do_totm := true;
    v_do_sport := true;
    v_do_tv := true;
    v_do_tables := true;
    v_do_playoffs := true;
    v_do_clinches := true;
    v_do_scheduling := true;
  ELSIF v_stage = 'awards' THEN
    -- Legacy bundle
    v_do_totm := true;
    v_do_sport := true;
    v_do_tv := true;
    v_do_tables := false;
    v_do_playoffs := false;
    v_do_clinches := false;
    v_do_scheduling := false;
  ELSIF v_stage = 'totm' THEN
    v_do_totm := true;
    v_do_sport := false;
    v_do_tv := false;
    v_do_tables := false;
    v_do_playoffs := false;
    v_do_clinches := false;
    v_do_scheduling := false;
  ELSIF v_stage = 'sport' THEN
    v_do_totm := false;
    v_do_sport := true;
    v_do_tv := false;
    v_do_tables := false;
    v_do_playoffs := false;
    v_do_clinches := false;
    v_do_scheduling := false;
  ELSIF v_stage = 'tv' THEN
    v_do_totm := false;
    v_do_sport := false;
    v_do_tv := true;
    v_do_tables := false;
    v_do_playoffs := false;
    v_do_clinches := false;
    v_do_scheduling := false;
  ELSIF v_stage IN ('tables', 'league_tables') THEN
    -- Discord standings only (no playoffs/clinches/flush)
    v_do_totm := false;
    v_do_sport := false;
    v_do_tv := false;
    v_do_tables := true;
    v_do_playoffs := false;
    v_do_clinches := false;
    v_do_scheduling := false;
  ELSIF v_stage = 'playoffs' THEN
    v_do_totm := false;
    v_do_sport := false;
    v_do_tv := false;
    v_do_tables := false;
    v_do_playoffs := true;
    v_do_clinches := false;
    v_do_scheduling := false;
  ELSIF v_stage = 'clinches' THEN
    v_do_totm := false;
    v_do_sport := false;
    v_do_tv := false;
    v_do_tables := false;
    v_do_playoffs := false;
    v_do_clinches := true;
    v_do_scheduling := false;
  ELSIF v_stage IN ('scheduling', 'fines') THEN
    v_do_totm := false;
    v_do_sport := false;
    v_do_tv := false;
    v_do_tables := false;
    v_do_playoffs := false;
    v_do_clinches := false;
    v_do_scheduling := true;
  ELSE
    RETURN jsonb_build_object(
      'ok', false,
      'reason', 'bad_stage',
      'hint', 'Use totm | sport | tv | tables | playoffs | clinches | scheduling | all'
    );
  END IF;

  v_out := v_out || jsonb_build_object('stage', coalesce(v_stage, 'all'));

  IF p_season_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_season');
  END IF;

  IF v_do_totm THEN
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
  END IF;

  IF v_do_sport THEN
    BEGIN
      IF v_month IS NOT NULL
         AND to_regprocedure('public.gpsl_sport_generate_edition(bigint,text)') IS NOT NULL THEN
        v_job_key := 'gpsl_sport:' || v_month;

        DELETE FROM public.competition_season_calendar_jobs j
        WHERE j.season_id = p_season_id
          AND j.job_key = v_job_key
          AND (
            j.result IS NULL
            OR coalesce((j.result->>'ok')::boolean, false) IS NOT TRUE
            OR (j.result->>'edition_id') IS NULL
          );

        IF NOT EXISTS (
          SELECT 1 FROM public.competition_season_calendar_jobs j
          WHERE j.season_id = p_season_id AND j.job_key = v_job_key
        ) THEN
          v_id := public.gpsl_sport_generate_edition(p_season_id, v_month);
          INSERT INTO public.competition_season_calendar_jobs (
            season_id, job_key, gpsl_month, result
          )
          VALUES (
            p_season_id, v_job_key, v_month,
            jsonb_build_object('edition_id', v_id, 'ok', v_id IS NOT NULL)
          )
          ON CONFLICT (season_id, job_key) DO UPDATE
            SET result = excluded.result,
                gpsl_month = excluded.gpsl_month,
                ran_at = now();
          v_sport_results := v_sport_results || jsonb_build_array(
            jsonb_build_object('gpsl_month', v_month, 'edition_id', v_id)
          );
        END IF;
        v_sport := jsonb_build_object('ok', true, 'processed', v_sport_results, 'scoped', true);
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
  END IF;

  IF v_do_tv THEN
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
  END IF;

  IF v_do_tables THEN
    -- Lightweight: one locked month → Discord queue only (no playoffs/clinches/flush)
    BEGIN
      IF v_month IS NULL THEN
        SELECT c.gpsl_month INTO v_month
        FROM public.competition_season_calendar c
        WHERE c.season_id = p_season_id
          AND c.gpsl_month IS NOT NULL
          AND c.gpsl_month <> 'playoffs'
          AND c.lock_at IS NOT NULL
          AND c.lock_at <= now()
        ORDER BY c.lock_at DESC
        LIMIT 1;
      END IF;

      IF v_month IS NULL THEN
        v_tables := jsonb_build_object('ok', false, 'reason', 'no_locked_month');
      ELSIF EXISTS (
        SELECT 1
        FROM public.competition_season_calendar_jobs j
        WHERE j.season_id = p_season_id
          AND j.job_key = 'league_tables:' || v_month
          AND coalesce((j.result->>'ok')::boolean, false) IS TRUE
      ) THEN
        v_tables := jsonb_build_object(
          'ok', true,
          'skipped', true,
          'reason', 'already_done',
          'gpsl_month', v_month
        );
      ELSIF to_regprocedure('public.competition_league_tables_snapshot(bigint)') IS NULL
            OR to_regprocedure('public.gpsl_discord_feed_enqueue(text,text,text,integer,text,jsonb)') IS NULL THEN
        v_tables := jsonb_build_object('ok', false, 'reason', 'tables_helpers_missing');
      ELSE
        BEGIN
          v_month_label := public.competition_gpsl_month_label(v_month);
        EXCEPTION WHEN OTHERS THEN
          v_month_label := initcap(v_month);
        END;

        v_snap := public.competition_league_tables_snapshot(p_season_id);
        v_qid := public.gpsl_discord_feed_enqueue(
          'tables',
          format('📊 LEAGUE TABLES — %s', coalesce(v_month_label, initcap(v_month))),
          format(
            'End of %s standings for SuperLeague, Championship A and Championship B.',
            coalesce(v_month_label, initcap(v_month))
          ),
          5793266,
          'league_tables:' || p_season_id::text || ':' || v_month,
          jsonb_build_object(
            'channel', 'tables',
            'render', true,
            'season_id', p_season_id,
            'gpsl_month', v_month,
            'month_label', v_month_label,
            'standings', coalesce(v_snap->'standings', '[]'::jsonb)
          )
        );

        INSERT INTO public.competition_season_calendar_jobs (
          season_id, job_key, gpsl_month, result
        )
        VALUES (
          p_season_id,
          'league_tables:' || v_month,
          v_month,
          jsonb_build_object(
            'ok', v_qid IS NOT NULL,
            'queue_id', v_qid,
            'enqueued_at', now(),
            'lite', true
          )
        )
        ON CONFLICT (season_id, job_key) DO UPDATE
          SET result = excluded.result,
              gpsl_month = excluded.gpsl_month,
              ran_at = now();

        v_tables := jsonb_build_object(
          'ok', v_qid IS NOT NULL,
          'gpsl_month', v_month,
          'queue_id', v_qid,
          'lite', true
        );
      END IF;

      v_out := v_out || jsonb_build_object('league_tables', v_tables);
    EXCEPTION
      WHEN OTHERS THEN
        v_out := v_out || jsonb_build_object(
          'league_tables', jsonb_build_object('ok', false, 'error', SQLERRM)
        );
    END;
  END IF;

  IF v_do_playoffs THEN
    BEGIN
      IF to_regprocedure('public.competition_generate_playoffs(bigint,boolean)') IS NOT NULL THEN
        v_playoffs := public.competition_generate_playoffs(p_season_id, false);
      ELSIF to_regprocedure('public.admin_competition_generate_playoffs(bigint,boolean)') IS NOT NULL THEN
        v_playoffs := public.admin_competition_generate_playoffs(p_season_id, false);
      ELSE
        v_playoffs := jsonb_build_object('skipped', true, 'reason', 'playoffs_rpc_missing');
      END IF;
      v_out := v_out || jsonb_build_object('playoffs', v_playoffs);
    EXCEPTION
      WHEN OTHERS THEN
        v_out := v_out || jsonb_build_object(
          'playoffs', jsonb_build_object('ok', false, 'error', SQLERRM)
        );
    END;
  END IF;

  IF v_do_clinches THEN
    BEGIN
      IF to_regprocedure('public.competition_process_league_clinches(bigint)') IS NOT NULL THEN
        v_clinches := public.competition_process_league_clinches(p_season_id);
      ELSE
        v_clinches := jsonb_build_object('skipped', true, 'reason', 'clinches_rpc_missing');
      END IF;
      v_out := v_out || jsonb_build_object('clinches', v_clinches);
    EXCEPTION
      WHEN OTHERS THEN
        v_out := v_out || jsonb_build_object(
          'clinches', jsonb_build_object('ok', false, 'error', SQLERRM)
        );
    END;
  END IF;

  IF v_do_scheduling THEN
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
  END IF;

  -- Monthly stadium fill drift once league tables stage runs (or full 'all' run).
  -- Safe to re-run: drift steps are 0 when fill_last_month already matches active month.
  IF v_do_tables THEN
    BEGIN
      IF to_regprocedure('public.competition_stadium_sync_all_clubs(bigint)') IS NOT NULL THEN
        v_stadium_clubs := public.competition_stadium_sync_all_clubs(p_season_id);
        v_out := v_out || jsonb_build_object(
          'stadium_fill_sync',
          jsonb_build_object('ok', true, 'clubs', v_stadium_clubs)
        );
      ELSE
        v_out := v_out || jsonb_build_object(
          'stadium_fill_sync',
          jsonb_build_object('skipped', true, 'reason', 'stadium_rpc_missing')
        );
      END IF;
    EXCEPTION
      WHEN OTHERS THEN
        v_out := v_out || jsonb_build_object(
          'stadium_fill_sync',
          jsonb_build_object('ok', false, 'error', SQLERRM)
        );
    END;
  END IF;

  RETURN v_out;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_run_month_lock_jobs(bigint, boolean, text, text)
  TO service_role;

-- Keep 3-arg alias for older callers / cron
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
BEGIN
  RETURN public.competition_run_month_lock_jobs(
    p_season_id,
    p_force_scheduling,
    p_locked_gpsl_month,
    NULL
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_run_month_lock_jobs(bigint, boolean, text)
  TO service_role;

DROP FUNCTION IF EXISTS public.competition_admin_run_month_lock_jobs(bigint, text, boolean);

CREATE OR REPLACE FUNCTION public.competition_admin_run_month_lock_jobs(
  p_season_id bigint DEFAULT NULL,
  p_gpsl_month text DEFAULT NULL,
  p_force_scheduling boolean DEFAULT true,
  p_stage text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season_id bigint;
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  PERFORM set_config('statement_timeout', '240s', true);

  IF p_season_id IS NULL THEN
    SELECT id INTO v_season_id
    FROM public.competition_seasons
    WHERE is_current = true AND status = 'active'
    ORDER BY id DESC
    LIMIT 1;
  ELSE
    v_season_id := p_season_id;
  END IF;

  IF v_season_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_active_season');
  END IF;

  RETURN public.competition_run_month_lock_jobs(
    v_season_id,
    coalesce(p_force_scheduling, true),
    p_gpsl_month,
    p_stage
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_admin_run_month_lock_jobs(bigint, text, boolean, text)
  TO authenticated;

NOTIFY pgrst, 'reload schema';
