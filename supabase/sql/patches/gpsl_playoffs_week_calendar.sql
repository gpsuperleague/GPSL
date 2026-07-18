-- =============================================================================
-- GPSL Playoffs week (Option A) — Week 11 after May
--
-- May (Week 10) = finish league MD 36–38 + League Cup final
-- Playoffs (Week 11) = all end-of-season ties:
--   • SuperLeague 16v17 (relegation playoff)
--   • Championship A/B 3–6 (promotion playoffs) → finals → SL playoff final
--   • Championship A/B 16v17 (Shield/Bowl prestige playoff)
-- End-of-season archive/rollover runs after Playoffs locks
--
-- Season length: 11 UK weeks (anchor + 77 days), was 10 weeks / 70 days.
-- Safe re-run. Does not generate playoff fixtures (Phase 7).
-- =============================================================================

-- Calendar CHECK: allow playoffs
ALTER TABLE public.competition_season_calendar
  DROP CONSTRAINT IF EXISTS competition_season_calendar_gpsl_month_check;

ALTER TABLE public.competition_season_calendar
  ADD CONSTRAINT competition_season_calendar_gpsl_month_check
  CHECK (
    gpsl_month IN (
      'august', 'september', 'october', 'november', 'december',
      'january', 'february', 'march', 'april', 'may', 'playoffs'
    )
  );

ALTER TABLE public.competition_season_calendar
  DROP CONSTRAINT IF EXISTS competition_season_calendar_sort_order_check;

ALTER TABLE public.competition_season_calendar
  ADD CONSTRAINT competition_season_calendar_sort_order_check
  CHECK (sort_order >= 1 AND sort_order <= 11);

-- Fixtures may be scheduled in playoffs week (Phase 7 will insert them)
DO $$
BEGIN
  ALTER TABLE public.competition_fixtures
    DROP CONSTRAINT IF EXISTS competition_fixtures_gpsl_month_check;
EXCEPTION WHEN undefined_object THEN
  NULL;
END $$;

ALTER TABLE public.competition_fixtures
  DROP CONSTRAINT IF EXISTS competition_fixtures_gpsl_month_check;

ALTER TABLE public.competition_fixtures
  ADD CONSTRAINT competition_fixtures_gpsl_month_check
  CHECK (
    gpsl_month IN (
      'august', 'september', 'october', 'november', 'december',
      'january', 'february', 'march', 'april', 'may', 'playoffs'
    )
  );

-- Cup schedule table (if present)
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.tables
    WHERE table_schema = 'public' AND table_name = 'competition_cup_round_schedule'
  ) THEN
    ALTER TABLE public.competition_cup_round_schedule
      DROP CONSTRAINT IF EXISTS competition_cup_round_schedule_gpsl_month_check;
    ALTER TABLE public.competition_cup_round_schedule
      ADD CONSTRAINT competition_cup_round_schedule_gpsl_month_check
      CHECK (
        gpsl_month IN (
          'august', 'september', 'october', 'november', 'december',
          'january', 'february', 'march', 'april', 'may', 'playoffs'
        )
      );
  END IF;
EXCEPTION WHEN OTHERS THEN
  NULL;
END $$;

CREATE OR REPLACE FUNCTION public.competition_gpsl_month_sort(p_month text)
RETURNS smallint
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE lower(btrim(coalesce(p_month, '')))
    WHEN 'august' THEN 1
    WHEN 'september' THEN 2
    WHEN 'october' THEN 3
    WHEN 'november' THEN 4
    WHEN 'december' THEN 5
    WHEN 'january' THEN 6
    WHEN 'february' THEN 7
    WHEN 'march' THEN 8
    WHEN 'april' THEN 9
    WHEN 'may' THEN 10
    WHEN 'playoffs' THEN 11
    ELSE NULL
  END;
$$;

CREATE OR REPLACE FUNCTION public.competition_gpsl_month_label(p_month text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE lower(btrim(coalesce(p_month, '')))
    WHEN 'playoffs' THEN 'Playoffs'
    ELSE initcap(lower(btrim(coalesce(p_month, ''))))
  END;
$$;

-- League programme months (Aug–May). Playoffs is post-league.
CREATE OR REPLACE FUNCTION public.competition_gpsl_month_is_league_programme(p_month text)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT lower(btrim(coalesce(p_month, ''))) IN (
    'august', 'september', 'october', 'november', 'december',
    'january', 'february', 'march', 'april', 'may'
  );
$$;

CREATE OR REPLACE FUNCTION public.competition_admin_set_season_calendar(
  p_season_id bigint,
  p_anchor_local timestamp without time zone
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season public.competition_seasons;
  v_anchor timestamptz;
  v_months text[] := ARRAY[
    'august', 'september', 'october', 'november', 'december',
    'january', 'february', 'march', 'april', 'may', 'playoffs'
  ];
  v_month text;
  v_i int;
  v_unlock timestamptz;
  v_lock timestamptz;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  SELECT * INTO v_season
  FROM public.competition_seasons
  WHERE id = p_season_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Season not found';
  END IF;

  IF p_anchor_local IS NULL THEN
    RAISE EXCEPTION 'Anchor date/time required';
  END IF;

  v_anchor := (p_anchor_local AT TIME ZONE 'Europe/London');

  IF extract(dow FROM (v_anchor AT TIME ZONE 'Europe/London'))::int <> 5 THEN
    RAISE EXCEPTION 'Anchor must be a Friday in UK time (got %)',
      to_char(v_anchor AT TIME ZONE 'Europe/London', 'Dy DD Mon YYYY');
  END IF;

  IF extract(hour FROM (v_anchor AT TIME ZONE 'Europe/London'))::int <> 19 THEN
    RAISE EXCEPTION 'Anchor must be 19:00 UK time (7pm)';
  END IF;

  DELETE FROM public.competition_season_calendar WHERE season_id = p_season_id;
  DELETE FROM public.competition_season_calendar_config WHERE season_id = p_season_id;

  INSERT INTO public.competition_season_calendar_config (season_id, anchor_unlock_at)
  VALUES (p_season_id, v_anchor);

  FOR v_i IN 1..array_length(v_months, 1) LOOP
    v_month := v_months[v_i];
    v_unlock := v_anchor + ((v_i - 1) * interval '7 days');
    v_lock := v_unlock + interval '7 days';

    INSERT INTO public.competition_season_calendar (
      season_id, gpsl_month, sort_order, unlock_at, lock_at
    )
    VALUES (p_season_id, v_month, v_i::smallint, v_unlock, v_lock);
  END LOOP;

  RETURN jsonb_build_object(
    'season_id', p_season_id,
    'anchor_uk',
    to_char(v_anchor AT TIME ZONE 'Europe/London', 'YYYY-MM-DD HH24:MI'),
    'months', 11,
    'season_ends_uk',
    to_char((v_anchor + interval '77 days') AT TIME ZONE 'Europe/London', 'YYYY-MM-DD HH24:MI'),
    'note', 'Week 11 is Playoffs (after May league/cup programme).'
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_admin_set_season_calendar(bigint, timestamp)
  TO authenticated;

-- Add Playoffs week to seasons that already have Aug–May calendar
CREATE OR REPLACE FUNCTION public.competition_admin_ensure_playoffs_week(
  p_season_id bigint DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season_id bigint := p_season_id;
  v_may record;
  v_unlock timestamptz;
  v_lock timestamptz;
  v_existing record;
  v_out jsonb := '[]'::jsonb;
  r record;
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  FOR r IN
    SELECT s.id AS season_id
    FROM public.competition_seasons s
    WHERE (v_season_id IS NULL AND s.is_current = true)
       OR s.id = v_season_id
  LOOP
    SELECT m.unlock_at, m.lock_at, m.sort_order
    INTO v_may
    FROM public.competition_season_calendar m
    WHERE m.season_id = r.season_id
      AND m.gpsl_month = 'may'
    LIMIT 1;

    IF v_may.lock_at IS NULL THEN
      v_out := v_out || jsonb_build_array(
        jsonb_build_object('season_id', r.season_id, 'ok', false, 'reason', 'no_may_row')
      );
      CONTINUE;
    END IF;

    SELECT m.unlock_at, m.lock_at
    INTO v_existing
    FROM public.competition_season_calendar m
    WHERE m.season_id = r.season_id
      AND m.gpsl_month = 'playoffs'
    LIMIT 1;

    IF v_existing.unlock_at IS NOT NULL THEN
      v_out := v_out || jsonb_build_array(
        jsonb_build_object(
          'season_id', r.season_id,
          'ok', true,
          'gpsl_month', 'playoffs',
          'already', true,
          'unlock_at', v_existing.unlock_at,
          'lock_at', v_existing.lock_at
        )
      );
      CONTINUE;
    END IF;

    v_unlock := v_may.lock_at;
    v_lock := v_unlock + interval '7 days';

    -- If that window is already fully past, open a fresh 7-day playoffs from now
    IF v_lock <= now() THEN
      v_unlock := now();
      v_lock := v_unlock + interval '7 days';
    END IF;

    INSERT INTO public.competition_season_calendar (
      season_id, gpsl_month, sort_order, unlock_at, lock_at
    )
    VALUES (r.season_id, 'playoffs', 11, v_unlock, v_lock);

    v_out := v_out || jsonb_build_array(
      jsonb_build_object(
        'season_id', r.season_id,
        'ok', true,
        'gpsl_month', 'playoffs',
        'already', false,
        'unlock_at', v_unlock,
        'lock_at', v_lock
      )
    );
  END LOOP;

  RETURN jsonb_build_object('ok', true, 'seasons', v_out);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_admin_ensure_playoffs_week(bigint)
  TO authenticated, service_role;

-- Apply to current season(s) now
SELECT public.competition_admin_ensure_playoffs_week(NULL);

-- Skip league-table Discord job for playoffs week (no league MD programme)
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
      AND public.competition_gpsl_month_is_league_programme(c.gpsl_month)
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

  BEGIN
    PERFORM public.gpsl_discord_feed_request_flush();
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;

  RETURN jsonb_build_object(
    'ok', true,
    'season_id', v_season_id,
    'processed', v_processed,
    'clinches', v_clinches
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_process_month_league_tables(bigint)
  TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';
