-- =============================================================================
-- Admin health check — read only
--
-- Installs admin_mechanism_health(). The admin page calls this and nothing else.
-- It does not start a month, end a season, run the transfer engine, or post a fine.
-- It only looks up functions, schedules, triggers, and the last success stamp.
--
-- Run once in the SQL editor. The SELECT at the bottom is the same read the page uses.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.admin_health_cron_row(
  p_job jsonb,
  p_cron_error text,
  p_fn_ok boolean,
  p_fn_label text,
  p_job_label text,
  p_gap_minutes integer,
  p_group text,
  p_label text
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SET search_path = public
AS $row$
DECLARE
  v_wired boolean := false;
  v_fired boolean := false;
  v_state text := 'miss';
  v_active boolean := false;
  v_status text := '';
  v_start timestamptz;
  v_sched text := '';
  v_msg text := '';
  v_mins integer;
  v_when text := '';
  v_fn_bit text;
  v_fire_bit text := '';
BEGIN
  v_fn_bit := CASE
    WHEN coalesce(p_fn_ok, false) THEN p_fn_label || ' is installed.'
    ELSE p_fn_label || ' is not installed.'
  END;

  IF p_cron_error IS NOT NULL THEN
    v_wired := coalesce(p_fn_ok, false);
    v_fire_bit := 'The schedule list could not be read. ' || left(p_cron_error, 140);
  ELSIF p_job IS NULL THEN
    v_fire_bit := 'No schedule named ' || p_job_label || '.';
  ELSE
    v_active := coalesce((p_job->>'active')::boolean, false);
    v_status := coalesce(p_job->>'status', '');
    v_sched := coalesce(p_job->>'schedule', '');
    v_msg := left(coalesce(p_job->>'message', ''), 140);
    BEGIN
      IF coalesce(p_job->>'start_time', '') <> '' THEN
        v_start := (p_job->>'start_time')::timestamptz;
      END IF;
    EXCEPTION WHEN OTHERS THEN
      v_start := NULL;
    END;

    IF v_start IS NOT NULL THEN
      v_when := to_char(v_start AT TIME ZONE 'Europe/London', 'DD Mon HH24:MI') || ' UK';
      v_mins := floor(extract(epoch FROM (now() - v_start)) / 60.0)::integer;
    END IF;

    IF NOT v_active THEN
      v_fire_bit := 'Schedule ' || coalesce(nullif(v_sched, ''), p_job_label) || ' is switched off.';
      IF v_status = 'succeeded' AND v_when <> '' THEN
        v_fire_bit := v_fire_bit || ' Last success was ' || greatest(v_mins, 0) || ' min ago (' || v_when || ').';
      END IF;
    ELSE
      v_wired := coalesce(p_fn_ok, false);
      IF v_status = 'succeeded' AND v_start IS NOT NULL
         AND v_start >= now() - make_interval(mins => p_gap_minutes) THEN
        v_fired := true;
        v_state := 'ok';
        v_fire_bit := 'Last success ' || greatest(v_mins, 0) || ' min ago (' || v_when || ').';
      ELSIF v_status = 'running' AND v_start IS NOT NULL
            AND v_start >= now() - interval '6 minutes' THEN
        v_fired := true;
        v_state := 'ok';
        v_fire_bit := 'A run is in progress (started ' || v_when || ').';
      ELSIF v_status = 'failed' THEN
        v_fire_bit := 'Last run failed'
          || CASE WHEN v_when <> '' THEN ' at ' || v_when ELSE '' END
          || CASE WHEN v_msg <> '' THEN '. ' || v_msg ELSE '.' END;
      ELSIF v_start IS NULL THEN
        v_fire_bit := 'The schedule is on and no run is recorded yet.';
      ELSE
        v_fire_bit := 'Last '
          || CASE WHEN v_status = 'succeeded' THEN 'success' ELSE 'run' END
          || ' was ' || greatest(coalesce(v_mins, 0), 0) || ' min ago'
          || CASE WHEN v_when <> '' THEN ' (' || v_when || ')' ELSE '' END
          || '. Expected within ' || p_gap_minutes || ' min.';
      END IF;
      IF v_wired THEN
        v_fn_bit := p_fn_label || ' is installed. Schedule ' || v_sched || ' is on.';
      ELSE
        v_fn_bit := 'Schedule ' || v_sched || ' is on. ' || p_fn_label || ' is not installed.';
      END IF;
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'group', p_group,
    'label', p_label,
    'wired', v_wired,
    'fired', v_fired,
    'fire_state', v_state,
    'tone', CASE
      WHEN v_wired AND v_fired THEN 'green'
      WHEN v_wired OR v_fired THEN 'amber'
      ELSE 'red'
    END,
    'detail', btrim(v_fn_bit || ' ' || v_fire_bit)
  );
END;
$row$;

CREATE OR REPLACE FUNCTION public.admin_health_stamp_row(
  p_stamp jsonb,
  p_fn_ok boolean,
  p_fn_label text,
  p_due boolean,
  p_month text,
  p_not_due text,
  p_miss_note text,
  p_block text,
  p_group text,
  p_label text
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SET search_path = public
AS $row$
DECLARE
  v_wired boolean := coalesce(p_fn_ok, false);
  v_fired boolean := false;
  v_state text := 'miss';
  v_month text;
  v_when text := '';
  v_fn_bit text;
  v_fire_bit text;
  v_ok boolean := false;
BEGIN
  v_month := initcap(replace(coalesce(p_month, ''), '_', ' '));
  v_fn_bit := CASE
    WHEN v_wired THEN p_fn_label || ' is installed.'
    ELSE p_fn_label || ' is not installed.'
  END;

  IF p_stamp IS NOT NULL AND coalesce(p_stamp->>'ran_at', '') <> '' THEN
    BEGIN
      v_when := to_char((p_stamp->>'ran_at')::timestamptz AT TIME ZONE 'Europe/London', 'DD Mon HH24:MI') || ' UK';
    EXCEPTION WHEN OTHERS THEN
      v_when := '';
    END;
  END IF;

  IF p_block IS NOT NULL THEN
    v_fire_bit := p_block;
  ELSIF NOT coalesce(p_due, false) THEN
    v_fired := true;
    v_state := 'not_due';
    v_fire_bit := coalesce(p_not_due, 'Not due yet.');
  ELSE
    v_ok := p_stamp IS NOT NULL AND (p_stamp->>'ok') = 'true';
    IF v_ok THEN
      v_fired := true;
      v_state := 'ok';
      v_fire_bit := v_month || ' is recorded'
        || CASE WHEN v_when <> '' THEN ' at ' || v_when ELSE '' END
        || '.';
    ELSIF p_stamp IS NOT NULL THEN
      v_fire_bit := v_month || ' has a stamp that did not succeed.';
      IF coalesce(p_miss_note, '') <> '' THEN
        v_fire_bit := v_fire_bit || ' ' || p_miss_note;
      END IF;
    ELSE
      v_fire_bit := v_month || ' has locked and there is no success stamp.';
      IF coalesce(p_miss_note, '') <> '' THEN
        v_fire_bit := v_fire_bit || ' ' || p_miss_note;
      END IF;
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'group', p_group,
    'label', p_label,
    'wired', v_wired,
    'fired', v_fired,
    'fire_state', v_state,
    'tone', CASE
      WHEN v_wired AND v_fired THEN 'green'
      WHEN v_wired OR v_fired THEN 'amber'
      ELSE 'red'
    END,
    'detail', btrim(v_fn_bit || ' ' || v_fire_bit)
  );
END;
$row$;

CREATE OR REPLACE FUNCTION public.admin_health_hook_row(
  p_triggers jsonb,
  p_read_error text,
  p_name text,
  p_what text,
  p_group text,
  p_label text
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SET search_path = public
AS $row$
DECLARE
  v_wired boolean := false;
  v_fired boolean := false;
  v_state text := 'miss';
  v_on boolean := false;
  v_detail text;
BEGIN
  IF p_read_error IS NOT NULL THEN
    v_detail := 'The trigger list could not be read. ' || left(p_read_error, 140);
  ELSIF p_triggers IS NULL OR NOT (p_triggers ? p_name) THEN
    v_detail := 'Trigger ' || p_name || ' is not installed.';
  ELSE
    v_on := coalesce((p_triggers->>p_name) = 'true', false);
    IF NOT v_on THEN
      v_detail := 'Trigger ' || p_name || ' is switched off.';
    ELSE
      v_wired := true;
      v_state := 'no_log';
      v_detail := p_what || ' It is switched on. Each firing is not written down, so the last call cannot be confirmed.';
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'group', p_group,
    'label', p_label,
    'wired', v_wired,
    'fired', v_fired,
    'fire_state', v_state,
    'tone', CASE
      WHEN v_wired AND v_fired THEN 'green'
      WHEN v_wired OR v_fired THEN 'amber'
      ELSE 'red'
    END,
    'detail', v_detail
  );
END;
$row$;

REVOKE ALL ON FUNCTION public.admin_health_cron_row(jsonb, text, boolean, text, text, integer, text, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.admin_health_stamp_row(jsonb, boolean, text, boolean, text, text, text, text, text, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.admin_health_hook_row(jsonb, text, text, text, text, text) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.admin_mechanism_health()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_fn jsonb := '{}'::jsonb;
  v_jobs jsonb := '{}'::jsonb;
  v_stamps jsonb := '{}'::jsonb;
  v_triggers jsonb := '{}'::jsonb;
  v_checks jsonb := '[]'::jsonb;
  v_cron_error text;
  v_stamp_error text;
  v_trigger_error text;
  v_season_error text;
  v_cal_error text;
  v_block text;
  v_season bigint;
  v_label text;
  v_status text;
  v_ended timestamptz;
  v_month text;
  v_lock_at timestamptz;
  v_month_due boolean := false;
  v_intl_on boolean := false;
  v_not_due text := 'Not due yet. No GPSL month has reached its lock.';
  v_hour integer;
  v_pick jsonb;
  v_pick_label text;
  v_gap integer;
  v_sl jsonb;
  v_ch jsonb;
  v_leg jsonb;
  v_synth jsonb;
  v_totm_note text;
  v_totm_fn boolean;
  v_totm_name text;
  v_wired boolean;
  v_fired boolean;
  v_state text;
  v_detail text;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  SELECT coalesce(jsonb_object_agg(s.proname, true), '{}'::jsonb)
  INTO v_fn
  FROM (
    SELECT DISTINCT p.proname
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname = ANY (ARRAY[
        'gpsl_month_lock_on_calendar_tick',
        'competition_run_month_lock_jobs_complete',
        'competition_run_month_lock_jobs',
        'competition_compute_team_of_month',
        'competition_process_month_team_awards',
        'competition_league_tables_snapshot',
        'gpsl_sport_generate_edition',
        'gpsl_sport_process_pending_editions',
        'competition_tv_process_month_lock_selections',
        'competition_process_month_intl_tables',
        'competition_end_season',
        'contract_tick_season_rollover',
        'contract_half_switch_tick',
        'gpsl_transferengine_cron_tick',
        'transferengine_run_report',
        'competition_enforce_scheduling_arrangement_fines',
        'competition_enforce_scheduling_response_fines',
        'competition_enforce_scheduling_checkin_fines',
        'competition_enforce_manual_black_box_forfeits',
        'competition_enforce_scheduling_window_awards',
        'match_schedule_process_due_checkin_notices',
        'competition_process_vacant_walkovers',
        'club_commercial_tick'
      ]::text[])
  ) s;

  BEGIN
    SELECT coalesce(jsonb_object_agg(s.jobname, s.payload), '{}'::jsonb)
    INTO v_jobs
    FROM (
      SELECT j.jobname,
        jsonb_build_object(
          'active', j.active,
          'schedule', j.schedule,
          'status', d.status,
          'start_time', d.start_time,
          'message', left(coalesce(d.return_message, ''), 180)
        ) AS payload
      FROM cron.job j
      LEFT JOIN LATERAL (
        SELECT r.status, r.start_time, r.return_message
        FROM cron.job_run_details r
        WHERE r.jobid = j.jobid
        ORDER BY r.start_time DESC NULLS LAST
        LIMIT 1
      ) d ON true
      WHERE j.jobname = ANY (ARRAY[
        'gpsl-month-lock-on-calendar',
        'gpsl-transfer-engine-5min',
        'gpsl-transfer-engine-evening-1min',
        'gpsl-contract-half-switch',
        'gpsl-match-checkin-notices',
        'gpsl-vacant-walkovers',
        'gpsl-club-commercial'
      ]::text[])
    ) s;
  EXCEPTION WHEN OTHERS THEN
    v_cron_error := SQLERRM;
    v_jobs := '{}'::jsonb;
  END;

  BEGIN
    SELECT s.id, s.label, s.status, s.ended_at
    INTO v_season, v_label, v_status, v_ended
    FROM public.competition_seasons s
    WHERE s.is_current IS TRUE
    ORDER BY s.id DESC
    LIMIT 1;

    IF v_season IS NULL THEN
      SELECT s.id, s.label, s.status, s.ended_at
      INTO v_season, v_label, v_status, v_ended
      FROM public.competition_seasons s
      ORDER BY s.id DESC
      LIMIT 1;
    END IF;
  EXCEPTION WHEN OTHERS THEN
    v_season_error := SQLERRM;
  END;

  IF v_season IS NOT NULL THEN
    BEGIN
      SELECT lower(btrim(c.gpsl_month)), c.lock_at
      INTO v_month, v_lock_at
      FROM public.competition_season_calendar c
      WHERE c.season_id = v_season
        AND c.gpsl_month IS NOT NULL
        AND lower(btrim(c.gpsl_month)) <> 'playoffs'
        AND c.lock_at IS NOT NULL
        AND c.lock_at <= now()
      ORDER BY c.lock_at DESC
      LIMIT 1;
    EXCEPTION WHEN OTHERS THEN
      v_cal_error := SQLERRM;
    END;

    BEGIN
      SELECT coalesce(jsonb_object_agg(j.job_key, jsonb_build_object(
        'ok', CASE WHEN j.result->>'ok' IN ('true', 't', '1') THEN true ELSE false END,
        'ran_at', j.ran_at
      )), '{}'::jsonb)
      INTO v_stamps
      FROM public.competition_season_calendar_jobs j
      WHERE j.season_id = v_season
        AND (
          j.job_key LIKE 'month_lock_on_calendar:%'
          OR j.job_key LIKE 'team_of_month:%'
          OR j.job_key LIKE 'gpsl_sport:%'
          OR j.job_key LIKE 'league_tables:%'
          OR j.job_key LIKE 'tv_select_next:%'
          OR j.job_key LIKE 'intl_tables:%'
          OR j.job_key LIKE 'scheduling_%'
          OR j.job_key LIKE 'manual_black_box_forfeits:%'
        );
    EXCEPTION WHEN OTHERS THEN
      v_stamp_error := SQLERRM;
      v_stamps := '{}'::jsonb;
    END;
  END IF;

  BEGIN
    SELECT EXISTS (
      SELECT 1
      FROM public.international_wc_cycles c
      WHERE lower(coalesce(c.status, '')) IN (
        'qualifying', 'finals', 'finals_group', 'knockout', 'active'
      )
    )
    INTO v_intl_on;
  EXCEPTION WHEN OTHERS THEN
    v_intl_on := false;
  END;

  BEGIN
    SELECT coalesce(jsonb_object_agg(s.tgname, s.enabled), '{}'::jsonb)
    INTO v_triggers
    FROM (
      SELECT t.tgname,
        bool_or(t.tgenabled::text IN ('O', 'A')) AS enabled
      FROM pg_trigger t
      JOIN pg_class c ON c.oid = t.tgrelid
      JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE n.nspname = 'public'
        AND NOT t.tgisinternal
        AND t.tgname = ANY (ARRAY[
          'player_transfer_bids_min_increment',
          'trg_gpsl_discord_feed_transfer_window',
          'transfer_history_inbox_notify'
        ]::text[])
      GROUP BY t.tgname
    ) s;
  EXCEPTION WHEN OTHERS THEN
    v_trigger_error := SQLERRM;
    v_triggers := '{}'::jsonb;
  END;

  v_month_due := v_cal_error IS NULL AND v_month IS NOT NULL;
  IF v_cal_error IS NOT NULL THEN
    v_block := 'The calendar could not be read, so the last due month is unknown. ' || left(v_cal_error, 140);
  ELSIF v_stamp_error IS NOT NULL THEN
    v_block := 'The job diary could not be read, so the last run cannot be confirmed. ' || left(v_stamp_error, 140);
  ELSE
    v_block := NULL;
  END IF;

  v_checks := v_checks || jsonb_build_array(public.admin_health_cron_row(
    CASE WHEN v_cron_error IS NULL THEN v_jobs -> 'gpsl-month-lock-on-calendar' ELSE NULL END,
    v_cron_error,
    v_fn ? 'gpsl_month_lock_on_calendar_tick',
    'gpsl_month_lock_on_calendar_tick',
    'gpsl-month-lock-on-calendar',
    20,
    'Month',
    'End of month watcher'
  ));

  v_checks := v_checks || jsonb_build_array(public.admin_health_stamp_row(
    v_stamps -> ('month_lock_on_calendar:' || coalesce(v_month, '')),
    (v_fn ? 'competition_run_month_lock_jobs_complete') OR (v_fn ? 'competition_run_month_lock_jobs'),
    CASE
      WHEN v_fn ? 'competition_run_month_lock_jobs_complete' THEN 'competition_run_month_lock_jobs_complete'
      ELSE 'competition_run_month_lock_jobs'
    END,
    v_month_due,
    v_month,
    v_not_due,
    NULL,
    v_block,
    'Month',
    'End of month jobs'
  ));

  v_totm_fn := (v_fn ? 'competition_compute_team_of_month')
    OR (v_fn ? 'competition_process_month_team_awards');
  v_totm_name := CASE
    WHEN v_fn ? 'competition_compute_team_of_month' THEN 'competition_compute_team_of_month'
    ELSE 'competition_process_month_team_awards'
  END;
  v_sl := v_stamps -> ('team_of_month:superleague:' || coalesce(v_month, ''));
  v_ch := v_stamps -> ('team_of_month:championship:' || coalesce(v_month, ''));
  v_leg := v_stamps -> ('team_of_month:' || coalesce(v_month, ''));
  v_totm_note := NULL;
  v_synth := NULL;
  IF (v_leg->>'ok') = 'true'
     OR ((v_sl->>'ok') = 'true' AND (v_ch->>'ok') = 'true') THEN
    v_synth := jsonb_build_object(
      'ok', true,
      'ran_at', coalesce(v_sl->>'ran_at', v_ch->>'ran_at', v_leg->>'ran_at')
    );
  ELSIF v_sl IS NOT NULL OR v_ch IS NOT NULL OR v_leg IS NOT NULL THEN
    v_synth := jsonb_build_object(
      'ok', false,
      'ran_at', coalesce(v_sl->>'ran_at', v_ch->>'ran_at', v_leg->>'ran_at')
    );
    IF (v_sl->>'ok') IS DISTINCT FROM 'true' THEN
      v_totm_note := 'Super League stamp is missing or failed.';
    ELSIF (v_ch->>'ok') IS DISTINCT FROM 'true' THEN
      v_totm_note := 'Championship stamp is missing or failed.';
    END IF;
  ELSE
    v_totm_note := 'Expected a Super League stamp and a Championship stamp.';
  END IF;

  v_checks := v_checks || jsonb_build_array(public.admin_health_stamp_row(
    v_synth, v_totm_fn, v_totm_name, v_month_due, v_month, v_not_due, v_totm_note, v_block,
    'Month', 'Team of the month'
  ));

  v_checks := v_checks || jsonb_build_array(public.admin_health_stamp_row(
    v_stamps -> ('league_tables:' || coalesce(v_month, '')),
    v_fn ? 'competition_league_tables_snapshot',
    'competition_league_tables_snapshot',
    v_month_due, v_month, v_not_due, NULL, v_block,
    'Month', 'League tables'
  ));

  v_checks := v_checks || jsonb_build_array(public.admin_health_stamp_row(
    v_stamps -> ('gpsl_sport:' || coalesce(v_month, '')),
    (v_fn ? 'gpsl_sport_generate_edition') OR (v_fn ? 'gpsl_sport_process_pending_editions'),
    CASE
      WHEN v_fn ? 'gpsl_sport_generate_edition' THEN 'gpsl_sport_generate_edition'
      ELSE 'gpsl_sport_process_pending_editions'
    END,
    v_month_due, v_month, v_not_due, NULL, v_block,
    'Month', 'GPSL Sport'
  ));

  v_checks := v_checks || jsonb_build_array(public.admin_health_stamp_row(
    v_stamps -> ('tv_select_next:' || coalesce(v_month, '')),
    v_fn ? 'competition_tv_process_month_lock_selections',
    'competition_tv_process_month_lock_selections',
    v_month_due, v_month, v_not_due, NULL, v_block,
    'Month', 'TV pick for next month'
  ));

  v_checks := v_checks || jsonb_build_array(public.admin_health_stamp_row(
    v_stamps -> ('intl_tables:' || coalesce(v_month, '')),
    v_fn ? 'competition_process_month_intl_tables',
    'competition_process_month_intl_tables',
    v_month_due AND v_intl_on,
    v_month,
    CASE
      WHEN NOT v_month_due THEN v_not_due
      ELSE 'Not due. No international competition is running.'
    END,
    'Internationals only stamp a month while a World Cup cycle is running.',
    v_block,
    'Month',
    'International tables'
  ));

  v_wired := v_fn ? 'competition_end_season';
  v_fired := false;
  v_state := 'miss';
  IF v_season_error IS NOT NULL THEN
    v_detail := CASE WHEN v_wired THEN 'competition_end_season is installed. ' ELSE 'competition_end_season is not installed. ' END
      || 'The season row could not be read. ' || left(v_season_error, 140);
  ELSIF v_status IN ('setup', 'preseason', 'active') OR v_season IS NULL THEN
    v_fired := true;
    v_state := 'not_due';
    v_detail := CASE WHEN v_wired THEN 'competition_end_season is installed. ' ELSE 'competition_end_season is not installed. ' END
      || 'Not due yet. End of season is an admin step, and this season is still '
      || coalesce(v_status, 'unopened') || '.';
  ELSIF v_status IN ('complete', 'summer_break') AND v_ended IS NOT NULL THEN
    v_fired := true;
    v_state := 'ok';
    v_detail := CASE WHEN v_wired THEN 'competition_end_season is installed. ' ELSE 'competition_end_season is not installed. ' END
      || 'Last season closed '
      || to_char(v_ended AT TIME ZONE 'Europe/London', 'DD Mon YYYY HH24:MI') || ' UK.';
  ELSE
    v_detail := CASE WHEN v_wired THEN 'competition_end_season is installed. ' ELSE 'competition_end_season is not installed. ' END
      || 'Season status ' || coalesce(v_status, 'unknown') || ' has no close time.';
  END IF;
  v_checks := v_checks || jsonb_build_array(jsonb_build_object(
    'group', 'Season',
    'label', 'End of season',
    'wired', v_wired,
    'fired', v_fired,
    'fire_state', v_state,
    'tone', CASE WHEN v_wired AND v_fired THEN 'green' WHEN v_wired OR v_fired THEN 'amber' ELSE 'red' END,
    'detail', btrim(v_detail)
  ));

  v_wired := v_fn ? 'contract_tick_season_rollover';
  v_checks := v_checks || jsonb_build_array(jsonb_build_object(
    'group', 'Season',
    'label', 'Contract rollover',
    'wired', v_wired,
    'fired', true,
    'fire_state', 'not_due',
    'tone', CASE WHEN v_wired THEN 'green' ELSE 'amber' END,
    'detail', CASE
      WHEN v_wired THEN 'contract_tick_season_rollover is installed. '
      ELSE 'contract_tick_season_rollover is not installed. '
    END || 'It runs when the next season is created, not on a clock. Not due right now.'
  ));

  v_checks := v_checks || jsonb_build_array(public.admin_health_cron_row(
    CASE WHEN v_cron_error IS NULL THEN v_jobs -> 'gpsl-contract-half-switch' ELSE NULL END,
    v_cron_error,
    v_fn ? 'contract_half_switch_tick',
    'contract_half_switch_tick',
    'gpsl-contract-half-switch',
    45,
    'Season',
    'Half-season contracts'
  ));

  v_hour := extract(hour FROM (now() AT TIME ZONE 'utc'))::integer;
  v_pick := NULL;
  v_pick_label := 'gpsl-transfer-engine-5min';
  v_gap := 20;
  IF v_cron_error IS NULL THEN
    IF v_hour BETWEEN 17 AND 21
       AND v_jobs ? 'gpsl-transfer-engine-evening-1min'
       AND coalesce((v_jobs -> 'gpsl-transfer-engine-evening-1min' ->> 'active')::boolean, false) THEN
      v_pick := v_jobs -> 'gpsl-transfer-engine-evening-1min';
      v_pick_label := 'gpsl-transfer-engine-evening-1min';
      v_gap := 4;
    ELSIF v_jobs ? 'gpsl-transfer-engine-5min' THEN
      v_pick := v_jobs -> 'gpsl-transfer-engine-5min';
      v_pick_label := 'gpsl-transfer-engine-5min';
      v_gap := 20;
    ELSIF v_jobs ? 'gpsl-transfer-engine-evening-1min' THEN
      v_pick := v_jobs -> 'gpsl-transfer-engine-evening-1min';
      v_pick_label := 'gpsl-transfer-engine-evening-1min';
      v_gap := 4;
    END IF;
  END IF;

  v_checks := v_checks || jsonb_build_array(public.admin_health_cron_row(
    v_pick,
    v_cron_error,
    (v_fn ? 'gpsl_transferengine_cron_tick') AND (v_fn ? 'transferengine_run_report'),
    'gpsl_transferengine_cron_tick',
    v_pick_label,
    v_gap,
    'Transfers',
    'Transfer engine'
  ));

  v_checks := v_checks || jsonb_build_array(public.admin_health_hook_row(
    v_triggers, v_trigger_error, 'player_transfer_bids_min_increment',
    'Keeps a bid on the minimum step.',
    'Transfers', 'Bid step hook'
  ));
  v_checks := v_checks || jsonb_build_array(public.admin_health_hook_row(
    v_triggers, v_trigger_error, 'trg_gpsl_discord_feed_transfer_window',
    'Watches the transfer window flag.',
    'Transfers', 'Transfer window hook'
  ));
  v_checks := v_checks || jsonb_build_array(public.admin_health_hook_row(
    v_triggers, v_trigger_error, 'transfer_history_inbox_notify',
    'Writes an inbox note when a transfer is completed.',
    'Transfers', 'Transfer inbox hook'
  ));

  v_checks := v_checks || jsonb_build_array(public.admin_health_stamp_row(
    v_stamps -> ('scheduling_arrangement_fines:' || coalesce(v_month, '')),
    v_fn ? 'competition_enforce_scheduling_arrangement_fines',
    'competition_enforce_scheduling_arrangement_fines',
    v_month_due, v_month, v_not_due, NULL, v_block,
    'Fines', 'Arrangement fines'
  ));
  v_checks := v_checks || jsonb_build_array(public.admin_health_stamp_row(
    v_stamps -> ('scheduling_response_fines:' || coalesce(v_month, '')),
    v_fn ? 'competition_enforce_scheduling_response_fines',
    'competition_enforce_scheduling_response_fines',
    v_month_due, v_month, v_not_due, NULL, v_block,
    'Fines', 'Reply deadline fines'
  ));
  v_checks := v_checks || jsonb_build_array(public.admin_health_stamp_row(
    v_stamps -> ('scheduling_checkin_fines:' || coalesce(v_month, '')),
    v_fn ? 'competition_enforce_scheduling_checkin_fines',
    'competition_enforce_scheduling_checkin_fines',
    v_month_due, v_month, v_not_due, NULL, v_block,
    'Fines', 'Check-in fines'
  ));
  v_checks := v_checks || jsonb_build_array(public.admin_health_stamp_row(
    v_stamps -> ('manual_black_box_forfeits:' || coalesce(v_month, '')),
    v_fn ? 'competition_enforce_manual_black_box_forfeits',
    'competition_enforce_manual_black_box_forfeits',
    v_month_due, v_month, v_not_due, NULL, v_block,
    'Fines', 'Black box forfeits'
  ));

  v_checks := v_checks || jsonb_build_array(public.admin_health_stamp_row(
    v_stamps -> ('scheduling_window_awards:' || coalesce(v_month, '')),
    v_fn ? 'competition_enforce_scheduling_window_awards',
    'competition_enforce_scheduling_window_awards',
    v_month_due, v_month, v_not_due, NULL, v_block,
    'Fixture scheduling', 'Early arrangement awards'
  ));
  v_checks := v_checks || jsonb_build_array(public.admin_health_cron_row(
    CASE WHEN v_cron_error IS NULL THEN v_jobs -> 'gpsl-match-checkin-notices' ELSE NULL END,
    v_cron_error,
    v_fn ? 'match_schedule_process_due_checkin_notices',
    'match_schedule_process_due_checkin_notices',
    'gpsl-match-checkin-notices',
    5,
    'Fixture scheduling',
    'Check-in notices'
  ));
  v_checks := v_checks || jsonb_build_array(public.admin_health_cron_row(
    CASE WHEN v_cron_error IS NULL THEN v_jobs -> 'gpsl-vacant-walkovers' ELSE NULL END,
    v_cron_error,
    v_fn ? 'competition_process_vacant_walkovers',
    'competition_process_vacant_walkovers',
    'gpsl-vacant-walkovers',
    20,
    'Fixture scheduling',
    'Vacant club walkovers'
  ));

  v_checks := v_checks || jsonb_build_array(public.admin_health_cron_row(
    CASE WHEN v_cron_error IS NULL THEN v_jobs -> 'gpsl-club-commercial' ELSE NULL END,
    v_cron_error,
    v_fn ? 'club_commercial_tick',
    'club_commercial_tick',
    'gpsl-club-commercial',
    30,
    'Other',
    'Commercial income'
  ));

  RETURN jsonb_build_object(
    'ok', true,
    'checked_at', now(),
    'season_id', v_season,
    'season_label', v_label,
    'season_status', v_status,
    'due_month', v_month,
    'due_lock_at', v_lock_at,
    'checks', v_checks
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.admin_mechanism_health() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.admin_mechanism_health() TO authenticated;

COMMENT ON FUNCTION public.admin_mechanism_health() IS
  'Admin read-only health. Does not call month lock, season end, the transfer engine, or fine enforcers.';

NOTIFY pgrst, 'reload schema';

SELECT public.admin_mechanism_health();
