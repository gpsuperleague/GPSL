-- =============================================================================
-- Discord: international group tables → #gpsl-intl-tables
--
-- Club league tables stay on #gpsl-tables.
-- WC qualifying / finals group standings post as PNG (or text fallback) to a
-- separate channel on GPSL month lock (same timing as club tables) + admin.
--
-- Setup:
-- 1) Discord → create #gpsl-intl-tables → Webhooks → copy URL
-- 2) Supabase → Edge Functions → Secrets:
--      DISCORD_INTL_TABLES_WEBHOOK_URL = that webhook
-- 3) Run this SQL
-- 4) Redeploy: supabase functions deploy discord-sky-feed
--
-- Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.gpsl_discord_feed_enqueue_intl_tables(
  p_event_type text,
  p_headline text,
  p_body text DEFAULT NULL,
  p_color integer DEFAULT 5793266,
  p_dedupe_key text DEFAULT NULL,
  p_metadata jsonb DEFAULT '{}'::jsonb
)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  RETURN public.gpsl_discord_feed_enqueue(
    coalesce(nullif(btrim(p_event_type), ''), 'intl_tables'),
    p_headline,
    p_body,
    p_color,
    p_dedupe_key,
    coalesce(p_metadata, '{}'::jsonb) || jsonb_build_object('channel', 'intl_tables')
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.gpsl_discord_feed_enqueue_intl_tables(text, text, text, integer, text, jsonb)
  TO authenticated, service_role;

-- Snapshot current WC group tables (qual + finals) for Discord render
CREATE OR REPLACE FUNCTION public.international_tables_snapshot()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_cycle_id bigint;
  v_cycle_no int;
  v_cycle_label text;
  v_groups jsonb := '[]'::jsonb;
  v_g record;
  v_pos int;
  v_r record;
  v_list jsonb;
BEGIN
  IF to_regclass('public.international_wc_cycles') IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_intl');
  END IF;

  SELECT c.id, c.cycle_no, c.label
  INTO v_cycle_id, v_cycle_no, v_cycle_label
  FROM public.international_wc_cycles c
  ORDER BY
    CASE lower(coalesce(c.status, ''))
      WHEN 'qualifying' THEN 0
      WHEN 'finals' THEN 0
      WHEN 'finals_group' THEN 0
      WHEN 'knockout' THEN 0
      WHEN 'active' THEN 0
      ELSE 1
    END,
    c.cycle_no DESC NULLS LAST,
    c.id DESC
  LIMIT 1;

  IF v_cycle_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_cycle');
  END IF;

  -- Qualifying groups
  IF to_regclass('public.international_qual_standings_public') IS NOT NULL THEN
    FOR v_g IN
      SELECT DISTINCT s.group_code
      FROM public.international_qual_standings_public s
      WHERE s.cycle_no = v_cycle_no
      ORDER BY s.group_code
    LOOP
      v_list := '[]'::jsonb;
      v_pos := 0;
      FOR v_r IN
        SELECT *
        FROM public.international_qual_standings_public s
        WHERE s.cycle_no = v_cycle_no
          AND s.group_code = v_g.group_code
        ORDER BY
          s.points DESC,
          s.goal_diff DESC,
          s.goals_for DESC,
          s.nation_code
      LOOP
        v_pos := v_pos + 1;
        v_list := v_list || jsonb_build_array(
          jsonb_build_object(
            'table_position', v_pos,
            'club_name', coalesce(nullif(btrim(v_r.nation_name), ''), v_r.nation_code),
            'club_short_name', v_r.nation_code,
            'mp', coalesce(v_r.played, 0),
            'w', coalesce(v_r.won, 0),
            'd', coalesce(v_r.drawn, 0),
            'l', coalesce(v_r.lost, 0),
            'gf', coalesce(v_r.goals_for, 0),
            'ga', coalesce(v_r.goals_against, 0),
            'gd', coalesce(v_r.goal_diff, 0),
            'pts', coalesce(v_r.points, 0),
            'qualified', coalesce(v_r.qualified, false)
          )
        );
      END LOOP;

      IF jsonb_array_length(v_list) > 0 THEN
        v_groups := v_groups || jsonb_build_array(
          jsonb_build_object(
            'table_key', 'qual:' || v_g.group_code,
            'phase', 'qualifying',
            'group_code', v_g.group_code,
            'title', 'WC Qualifying · Group ' || v_g.group_code,
            'standings', v_list
          )
        );
      END IF;
    END LOOP;
  END IF;

  -- Finals groups
  IF to_regclass('public.international_finals_standings_public') IS NOT NULL THEN
    FOR v_g IN
      SELECT DISTINCT s.group_code
      FROM public.international_finals_standings_public s
      WHERE s.cycle_no = v_cycle_no
      ORDER BY s.group_code
    LOOP
      v_list := '[]'::jsonb;
      v_pos := 0;
      FOR v_r IN
        SELECT *
        FROM public.international_finals_standings_public s
        WHERE s.cycle_no = v_cycle_no
          AND s.group_code = v_g.group_code
        ORDER BY
          s.points DESC,
          s.goal_diff DESC,
          s.goals_for DESC,
          s.nation_code
      LOOP
        v_pos := v_pos + 1;
        v_list := v_list || jsonb_build_array(
          jsonb_build_object(
            'table_position', v_pos,
            'club_name', coalesce(nullif(btrim(v_r.nation_name), ''), v_r.nation_code),
            'club_short_name', v_r.nation_code,
            'mp', coalesce(v_r.played, 0),
            'w', coalesce(v_r.won, 0),
            'd', coalesce(v_r.drawn, 0),
            'l', coalesce(v_r.lost, 0),
            'gf', coalesce(v_r.goals_for, 0),
            'ga', coalesce(v_r.goals_against, 0),
            'gd', coalesce(v_r.goal_diff, 0),
            'pts', coalesce(v_r.points, 0),
            'qualified', coalesce(v_r.qualified_knockout, false)
          )
        );
      END LOOP;

      IF jsonb_array_length(v_list) > 0 THEN
        v_groups := v_groups || jsonb_build_array(
          jsonb_build_object(
            'table_key', 'finals:' || v_g.group_code,
            'phase', 'finals_group',
            'group_code', v_g.group_code,
            'title', 'WC Finals · Group ' || v_g.group_code,
            'standings', v_list
          )
        );
      END IF;
    END LOOP;
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'cycle_id', v_cycle_id,
    'cycle_no', v_cycle_no,
    'cycle_label', coalesce(v_cycle_label, 'World Cup'),
    'groups', v_groups,
    'group_count', jsonb_array_length(v_groups)
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.international_tables_snapshot()
  TO authenticated, service_role;

-- Enqueue intl tables for a locked GPSL month (once per month via calendar jobs)
CREATE OR REPLACE FUNCTION public.competition_process_month_intl_tables(
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
  v_count int;
BEGIN
  IF to_regprocedure('public.international_tables_snapshot()') IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_snapshot_fn');
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

  v_snap := public.international_tables_snapshot();
  IF coalesce((v_snap->>'ok')::boolean, false) IS NOT TRUE THEN
    RETURN jsonb_build_object('ok', true, 'skipped', true, 'reason', v_snap->>'reason');
  END IF;

  v_count := coalesce((v_snap->>'group_count')::int, 0);
  IF v_count <= 0 THEN
    RETURN jsonb_build_object('ok', true, 'skipped', true, 'reason', 'no_groups');
  END IF;

  FOR v_cal IN
    SELECT c.gpsl_month
    FROM public.competition_season_calendar c
    WHERE c.season_id = v_season_id
      AND c.gpsl_month IS NOT NULL
      AND c.gpsl_month <> 'playoffs'
      AND c.lock_at IS NOT NULL
      AND c.lock_at <= now()
      AND (
        to_regprocedure('public.competition_gpsl_month_is_league_programme(text)') IS NULL
        OR public.competition_gpsl_month_is_league_programme(c.gpsl_month)
      )
    ORDER BY public.competition_gpsl_month_sort(c.gpsl_month)
  LOOP
    v_job_key := 'intl_tables:' || v_cal.gpsl_month;

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

    -- Fresh snapshot each month lock
    v_snap := public.international_tables_snapshot();

    v_qid := public.gpsl_discord_feed_enqueue_intl_tables(
      'intl_tables',
      format(
        '🌍 INTL TABLES — %s · %s',
        coalesce(v_snap->>'cycle_label', 'World Cup'),
        coalesce(v_month_label, initcap(v_cal.gpsl_month))
      ),
      format(
        'End of %s — %s World Cup group table(s).',
        coalesce(v_month_label, initcap(v_cal.gpsl_month)),
        coalesce(v_snap->>'group_count', '0')
      ),
      10181046,
      'intl_tables:' || v_season_id::text || ':' || v_cal.gpsl_month,
      jsonb_build_object(
        'render', true,
        'season_id', v_season_id,
        'gpsl_month', v_cal.gpsl_month,
        'month_label', v_month_label,
        'cycle_id', v_snap->'cycle_id',
        'cycle_label', v_snap->'cycle_label',
        'groups', coalesce(v_snap->'groups', '[]'::jsonb)
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

GRANT EXECUTE ON FUNCTION public.competition_process_month_intl_tables(bigint)
  TO authenticated, service_role;

-- Admin: force publish current intl tables
CREATE OR REPLACE FUNCTION public.admin_discord_publish_intl_tables(
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

  IF v_month IS NULL THEN
    SELECT lower(c.gpsl_month) INTO v_month
    FROM public.competition_season_calendar c
    WHERE c.season_id = v_season_id
      AND c.lock_at IS NOT NULL
      AND c.lock_at <= now()
    ORDER BY public.competition_gpsl_month_sort(c.gpsl_month) DESC
    LIMIT 1;
  END IF;

  IF v_month IS NULL THEN
    v_month := to_char((now() AT TIME ZONE 'Europe/London'), 'mon');
  END IF;

  BEGIN
    v_month_label := public.competition_gpsl_month_label(v_month);
  EXCEPTION WHEN OTHERS THEN
    v_month_label := initcap(v_month);
  END;

  v_snap := public.international_tables_snapshot();
  IF coalesce((v_snap->>'ok')::boolean, false) IS NOT TRUE THEN
    RETURN jsonb_build_object('ok', false, 'reason', coalesce(v_snap->>'reason', 'snapshot_failed'), 'snap', v_snap);
  END IF;

  IF coalesce((v_snap->>'group_count')::int, 0) <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_groups');
  END IF;

  v_qid := public.gpsl_discord_feed_enqueue_intl_tables(
    'intl_tables',
    format(
      '🌍 INTL TABLES — %s · %s',
      coalesce(v_snap->>'cycle_label', 'World Cup'),
      coalesce(v_month_label, initcap(v_month))
    ),
    format(
      'Manual publish — %s group table(s).',
      coalesce(v_snap->>'group_count', '0')
    ),
    10181046,
    'intl_tables_manual:' || coalesce(v_season_id::text, '0') || ':' || v_month || ':' || v_ts,
    jsonb_build_object(
      'render', true,
      'season_id', v_season_id,
      'gpsl_month', v_month,
      'month_label', v_month_label,
      'cycle_id', v_snap->'cycle_id',
      'cycle_label', v_snap->'cycle_label',
      'groups', coalesce(v_snap->'groups', '[]'::jsonb),
      'manual', true
    )
  );

  BEGIN
    PERFORM public.gpsl_discord_feed_request_flush();
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;

  RETURN jsonb_build_object(
    'ok', true,
    'queue_id', v_qid,
    'season_id', v_season_id,
    'gpsl_month', v_month,
    'group_count', v_snap->'group_count'
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.admin_discord_publish_intl_tables(text, bigint)
  TO authenticated, service_role;

-- Hook: after club league-table month processing, also queue intl tables
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
  v_clinches jsonb;
  v_intl jsonb;
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
      AND c.gpsl_month <> 'playoffs'
      AND (
        to_regprocedure('public.competition_gpsl_month_is_league_programme(text)') IS NULL
        OR public.competition_gpsl_month_is_league_programme(c.gpsl_month)
      )
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

    IF to_regprocedure('public.competition_league_tables_snapshot(bigint)') IS NULL THEN
      CONTINUE;
    END IF;

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

  IF to_regprocedure('public.competition_process_league_clinches(bigint)') IS NOT NULL THEN
    BEGIN
      v_clinches := public.competition_process_league_clinches(v_season_id);
    EXCEPTION WHEN OTHERS THEN
      v_clinches := jsonb_build_object('ok', false, 'error', SQLERRM);
    END;
  END IF;

  -- International group tables → #gpsl-intl-tables
  BEGIN
    v_intl := public.competition_process_month_intl_tables(v_season_id);
  EXCEPTION WHEN OTHERS THEN
    v_intl := jsonb_build_object('ok', false, 'error', SQLERRM);
  END;

  BEGIN
    PERFORM public.gpsl_discord_feed_request_flush();
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;

  RETURN jsonb_build_object(
    'ok', true,
    'season_id', v_season_id,
    'processed', v_processed,
    'clinches', v_clinches,
    'intl_tables', v_intl
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_process_month_league_tables(bigint)
  TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';
