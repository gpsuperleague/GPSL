-- =============================================================================
-- Discord #gpsl-tables: league table images on GPSL month lock
--
-- YOUR SETUP CHECKLIST
-- --------------------
-- 1) Discord: create channel #gpsl-tables
--    → Channel settings → Integrations → Webhooks → New Webhook → Copy URL
-- 2) Supabase → Edge Functions → Secrets (project-wide):
--      DISCORD_TABLES_WEBHOOK_URL = that webhook URL
-- 3) Run THIS SQL patch in Supabase SQL Editor
-- 4) Redeploy edge function:
--      supabase functions deploy discord-sky-feed
-- 5) Test (admin Discord News page):
--      “Publish league tables now”  OR  SQL:
--      SELECT public.admin_discord_publish_league_tables(NULL, NULL);
-- 6) Push queue if auto-flush is off
--
-- Automatic: when a GPSL month locks (cron month tick or End Month Early),
-- competition_run_month_lock_jobs → competition_process_month_league_tables
-- enqueues one Discord job; the edge function renders 3 PNG tables and posts.
-- Safe re-run.
-- =============================================================================

-- Public storage for rendered table PNGs
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
  'league-tables',
  'league-tables',
  true,
  5242880,
  ARRAY['image/png', 'image/jpeg', 'image/webp']
)
ON CONFLICT (id) DO UPDATE
SET public = true,
    file_size_limit = EXCLUDED.file_size_limit;

DROP POLICY IF EXISTS league_tables_public_read ON storage.objects;
CREATE POLICY league_tables_public_read ON storage.objects
  FOR SELECT TO public
  USING (bucket_id = 'league-tables');

DROP POLICY IF EXISTS league_tables_service_write ON storage.objects;
CREATE POLICY league_tables_service_write ON storage.objects
  FOR ALL TO service_role
  USING (bucket_id = 'league-tables')
  WITH CHECK (bucket_id = 'league-tables');

-- Snapshot standings JSON for edge render (live table at publish time)
CREATE OR REPLACE FUNCTION public.competition_league_tables_snapshot(
  p_season_id bigint DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season_id bigint := p_season_id;
  v_rows jsonb;
BEGIN
  IF v_season_id IS NULL THEN
    SELECT id INTO v_season_id
    FROM public.competition_seasons
    WHERE is_current = true
    ORDER BY id DESC
    LIMIT 1;
  END IF;

  IF v_season_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_season');
  END IF;

  SELECT coalesce(jsonb_agg(to_jsonb(s) ORDER BY
    CASE s.division
      WHEN 'superleague' THEN 0
      WHEN 'championship_a' THEN 1
      WHEN 'championship_b' THEN 2
      ELSE 9
    END,
    s.table_position
  ), '[]'::jsonb)
  INTO v_rows
  FROM public.competition_standings_public s
  WHERE s.season_id = v_season_id;

  RETURN jsonb_build_object(
    'ok', true,
    'season_id', v_season_id,
    'standings', coalesce(v_rows, '[]'::jsonb)
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_league_tables_snapshot(bigint)
  TO authenticated, service_role;

-- Process locked months → enqueue Discord tables render job
CREATE OR REPLACE FUNCTION public.competition_process_month_league_tables(
  p_season_id bigint DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season_id bigint := p_season_id;
  v_cal record;
  v_job_key text;
  v_month_label text;
  v_qid bigint;
  v_snap jsonb;
  v_processed jsonb := '[]'::jsonb;
BEGIN
  IF v_season_id IS NULL THEN
    SELECT id INTO v_season_id
    FROM public.competition_seasons
    WHERE is_current = true
    ORDER BY id DESC
    LIMIT 1;
  END IF;

  IF v_season_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_season');
  END IF;

  FOR v_cal IN
    SELECT c.gpsl_month
    FROM public.competition_season_calendar c
    WHERE c.season_id = v_season_id
      AND c.gpsl_month IS NOT NULL
      AND c.lock_at IS NOT NULL
      AND c.lock_at <= now()
    ORDER BY public.competition_gpsl_month_sort(c.gpsl_month)
  LOOP
    v_job_key := 'league_tables:' || v_cal.gpsl_month;

    IF EXISTS (
      SELECT 1
      FROM public.competition_season_calendar_jobs j
      WHERE j.season_id = v_season_id
        AND j.job_key = v_job_key
        AND coalesce((j.result->>'ok')::boolean, false) IS TRUE
    ) THEN
      CONTINUE;
    END IF;

    BEGIN
      v_month_label := public.competition_gpsl_month_label(v_cal.gpsl_month);
    EXCEPTION WHEN OTHERS THEN
      v_month_label := initcap(v_cal.gpsl_month);
    END;

    v_snap := public.competition_league_tables_snapshot(v_season_id);

    v_qid := public.gpsl_discord_feed_enqueue(
      'tables',
      format('📊 LEAGUE TABLES — %s', coalesce(v_month_label, initcap(v_cal.gpsl_month))),
      format(
        'End of %s standings for SuperLeague, Championship A and Championship B.',
        coalesce(v_month_label, initcap(v_cal.gpsl_month))
      ),
      5793266,
      'league_tables:' || v_season_id::text || ':' || v_cal.gpsl_month,
      jsonb_build_object(
        'channel', 'tables',
        'render', true,
        'season_id', v_season_id,
        'gpsl_month', v_cal.gpsl_month,
        'month_label', v_month_label,
        'standings', coalesce(v_snap->'standings', '[]'::jsonb)
      )
    );

    INSERT INTO public.competition_season_calendar_jobs (
      season_id, job_key, gpsl_month, result
    )
    VALUES (
      v_season_id,
      v_job_key,
      v_cal.gpsl_month,
      jsonb_build_object(
        'ok', v_qid IS NOT NULL,
        'queue_id', v_qid,
        'enqueued_at', now()
      )
    )
    ON CONFLICT (season_id, job_key) DO UPDATE
      SET result = excluded.result,
          gpsl_month = excluded.gpsl_month,
          ran_at = now();

    v_processed := v_processed || jsonb_build_array(
      jsonb_build_object(
        'gpsl_month', v_cal.gpsl_month,
        'queue_id', v_qid
      )
    );
  END LOOP;

  BEGIN
    PERFORM public.gpsl_discord_feed_request_flush();
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;

  RETURN jsonb_build_object(
    'ok', true,
    'season_id', v_season_id,
    'processed', v_processed
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_process_month_league_tables(bigint)
  TO authenticated, service_role;

-- Admin: force publish (ignores prior job success — new dedupe with timestamp)
CREATE OR REPLACE FUNCTION public.admin_discord_publish_league_tables(
  p_gpsl_month text DEFAULT NULL,
  p_season_id bigint DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season_id bigint := p_season_id;
  v_month text := nullif(lower(btrim(coalesce(p_gpsl_month, ''))), '');
  v_month_label text;
  v_snap jsonb;
  v_qid bigint;
  v_ts text := to_char(clock_timestamp() AT TIME ZONE 'UTC', 'YYYYMMDDHH24MISSMS');
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF v_season_id IS NULL THEN
    SELECT id INTO v_season_id
    FROM public.competition_seasons
    WHERE is_current = true
    ORDER BY id DESC
    LIMIT 1;
  END IF;

  IF v_season_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_season');
  END IF;

  IF v_month IS NULL THEN
    -- Prefer most recently locked month
    SELECT c.gpsl_month INTO v_month
    FROM public.competition_season_calendar c
    WHERE c.season_id = v_season_id
      AND c.lock_at IS NOT NULL
      AND c.lock_at <= now()
    ORDER BY c.lock_at DESC
    LIMIT 1;
  END IF;

  IF v_month IS NULL THEN
    BEGIN
      v_month := public.competition_active_gpsl_month(v_season_id, now());
    EXCEPTION WHEN OTHERS THEN
      v_month := NULL;
    END;
  END IF;

  IF v_month IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_month');
  END IF;

  BEGIN
    v_month_label := public.competition_gpsl_month_label(v_month);
  EXCEPTION WHEN OTHERS THEN
    v_month_label := initcap(v_month);
  END;

  v_snap := public.competition_league_tables_snapshot(v_season_id);

  v_qid := public.gpsl_discord_feed_enqueue(
    'tables',
    format('📊 LEAGUE TABLES — %s', coalesce(v_month_label, initcap(v_month))),
    format(
      'Standings snapshot for SuperLeague, Championship A and Championship B (%s).',
      coalesce(v_month_label, initcap(v_month))
    ),
    5793266,
    'league_tables_manual:' || v_season_id::text || ':' || v_month || ':' || v_ts,
    jsonb_build_object(
      'channel', 'tables',
      'render', true,
      'season_id', v_season_id,
      'gpsl_month', v_month,
      'month_label', v_month_label,
      'standings', coalesce(v_snap->'standings', '[]'::jsonb),
      'manual', true
    )
  );

  BEGIN
    PERFORM public.gpsl_discord_feed_request_flush();
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;

  RETURN jsonb_build_object(
    'ok', v_qid IS NOT NULL,
    'queue_id', v_qid,
    'season_id', v_season_id,
    'gpsl_month', v_month,
    'hint', CASE
      WHEN v_qid IS NULL THEN 'Enqueue failed — check gpsl_discord_feed_enqueue'
      ELSE 'Queued. Push Discord queue if needed. Redeploy discord-sky-feed + set DISCORD_TABLES_WEBHOOK_URL.'
    END
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.admin_discord_publish_league_tables(text, bigint)
  TO authenticated;

-- Hook into month-lock jobs (additive call — redefines runner from timeout_fix + tables)
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
  v_tables jsonb;
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
    IF v_month IS NOT NULL
       AND to_regprocedure('public.gpsl_sport_generate_edition(bigint,text)') IS NOT NULL THEN
      v_job_key := 'gpsl_sport:' || v_month;
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

  -- League tables → #gpsl-tables
  BEGIN
    v_tables := public.competition_process_month_league_tables(p_season_id);
    v_out := v_out || jsonb_build_object('league_tables', v_tables);
  EXCEPTION
    WHEN OTHERS THEN
      v_out := v_out || jsonb_build_object(
        'league_tables', jsonb_build_object('ok', false, 'error', SQLERRM)
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

GRANT EXECUTE ON FUNCTION public.competition_run_month_lock_jobs(bigint, boolean, text)
  TO service_role;

NOTIFY pgrst, 'reload schema';
