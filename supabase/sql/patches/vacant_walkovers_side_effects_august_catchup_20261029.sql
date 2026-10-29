-- =============================================================================
-- Vacant / season-absence walkovers → durable month-lock + August catch-up
-- 2026-10-29
--
-- Expected at each locked GPSL month:
--   • Owned vs vacant/absent → 3–0 walkover to the owned/active club
--   • Vacant/absent vs vacant/absent (league) → played + is_void (MP +1 each,
--     no W/D/L/goals — “dual forfeit” on the table)
--   • Cup both inactive → deterministic 3–0 (same side both legs)
--
-- Why August missed:
--   1) Processor relied on pg_cron soft schedule, not durable side_effects
--   2) Job key vacant_walkovers:<month> skipped forever once inserted — even
--      if fixtures were still scheduled / clubs went absent later
--
-- Fix: durable side_effects hook + re-process locked months that still have
-- pending inactive fixtures. Safe re-run.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Re-process locked months that still need walkovers (do not skip forever)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.competition_process_vacant_walkovers(
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
  v_fx record;
  v_job_key text;
  v_month_sort smallint;
  v_res jsonb;
  v_month_results jsonb;
  v_walkovers int;
  v_voids int;
  v_pending int;
  v_out jsonb := '[]'::jsonb;
BEGIN
  IF v_season_id IS NULL THEN
    SELECT id INTO v_season_id
    FROM public.competition_seasons
    WHERE is_current = true AND status = 'active'
    ORDER BY id DESC
    LIMIT 1;
  END IF;

  IF v_season_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_active_season');
  END IF;

  IF to_regprocedure('public.competition_apply_vacant_fixture_result(bigint)') IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'apply_fn_missing');
  END IF;

  FOR v_cal IN
    SELECT c.gpsl_month
    FROM public.competition_season_calendar c
    WHERE c.season_id = v_season_id
      AND c.lock_at IS NOT NULL
      AND c.lock_at <= now()
    ORDER BY public.competition_gpsl_month_sort(c.gpsl_month)
  LOOP
    v_job_key := 'vacant_walkovers:' || v_cal.gpsl_month;
    v_month_sort := public.competition_gpsl_month_sort(v_cal.gpsl_month);

    SELECT count(*)::int INTO v_pending
    FROM public.competition_fixtures f
    WHERE f.season_id = v_season_id
      AND f.status = 'scheduled'
      AND f.competition_type IN ('league', 'cup')
      AND f.gpsl_month IS NOT NULL
      AND public.competition_gpsl_month_sort(f.gpsl_month) <= v_month_sort
      AND (
        public.competition_club_is_fixture_inactive(f.home_club_short_name, f.season_id)
        OR public.competition_club_is_fixture_inactive(f.away_club_short_name, f.season_id)
      );

    -- Nothing left for this locked month (and earlier) — keep/refresh job stamp
    IF coalesce(v_pending, 0) = 0 THEN
      INSERT INTO public.competition_season_calendar_jobs (season_id, job_key, gpsl_month, result)
      VALUES (
        v_season_id, v_job_key, v_cal.gpsl_month,
        jsonb_build_object('ok', true, 'walkovers', 0, 'voids', 0, 'pending', 0, 'note', 'nothing_pending')
      )
      ON CONFLICT (season_id, job_key) DO UPDATE
        SET result = excluded.result, gpsl_month = excluded.gpsl_month, ran_at = now()
      WHERE coalesce((public.competition_season_calendar_jobs.result->>'pending')::int, -1) IS DISTINCT FROM 0;
      CONTINUE;
    END IF;

    v_month_results := '[]'::jsonb;
    v_walkovers := 0;
    v_voids := 0;

    FOR v_fx IN
      SELECT f.id
      FROM public.competition_fixtures f
      WHERE f.season_id = v_season_id
        AND f.status = 'scheduled'
        AND f.competition_type IN ('league', 'cup')
        AND f.gpsl_month IS NOT NULL
        AND public.competition_gpsl_month_sort(f.gpsl_month) <= v_month_sort
        AND (
          public.competition_club_is_fixture_inactive(f.home_club_short_name, f.season_id)
          OR public.competition_club_is_fixture_inactive(f.away_club_short_name, f.season_id)
        )
      ORDER BY public.competition_gpsl_month_sort(f.gpsl_month), f.matchday NULLS LAST, f.id
    LOOP
      v_res := public.competition_apply_vacant_fixture_result(v_fx.id);
      IF coalesce((v_res->>'ok')::boolean, false) THEN
        IF v_res->>'result' = 'void' THEN
          v_voids := v_voids + 1;
        ELSE
          v_walkovers := v_walkovers + 1;
        END IF;
        v_month_results := v_month_results || jsonb_build_array(v_res);
      END IF;
    END LOOP;

    INSERT INTO public.competition_season_calendar_jobs (season_id, job_key, gpsl_month, result)
    VALUES (
      v_season_id, v_job_key, v_cal.gpsl_month,
      jsonb_build_object(
        'ok', true,
        'walkovers', v_walkovers,
        'voids', v_voids,
        'pending_before', v_pending,
        'fixtures', v_month_results
      )
    )
    ON CONFLICT (season_id, job_key) DO UPDATE
      SET result = excluded.result, gpsl_month = excluded.gpsl_month, ran_at = now();

    v_out := v_out || jsonb_build_array(jsonb_build_object(
      'gpsl_month', v_cal.gpsl_month,
      'walkovers', v_walkovers,
      'voids', v_voids,
      'pending_before', v_pending
    ));
  END LOOP;

  RETURN jsonb_build_object('ok', true, 'season_id', v_season_id, 'processed', v_out);
END;
$function$;

REVOKE ALL ON FUNCTION public.competition_process_vacant_walkovers(bigint)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.competition_process_vacant_walkovers(bigint)
  TO service_role;

CREATE OR REPLACE FUNCTION public.admin_vacant_walkovers_run_now()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;
  RETURN public.competition_process_vacant_walkovers(NULL);
END;
$function$;

REVOKE ALL ON FUNCTION public.admin_vacant_walkovers_run_now() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_vacant_walkovers_run_now() TO authenticated;

-- Hook signature for side_effects registry: (season, locked_month)
CREATE OR REPLACE FUNCTION public.competition_vacant_walkovers_month_lock_side_effect(
  p_season_id bigint,
  p_gpsl_month text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  -- Month arg unused: processor walks all locked months with pending fixtures
  RETURN public.competition_process_vacant_walkovers(p_season_id);
END;
$function$;

REVOKE ALL ON FUNCTION public.competition_vacant_walkovers_month_lock_side_effect(bigint, text)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.competition_vacant_walkovers_month_lock_side_effect(bigint, text)
  TO service_role;

INSERT INTO public.competition_month_lock_hooks (hook_key, sort_order, enabled, proc_name, notes)
VALUES (
  'vacant_walkovers',
  30,
  true,
  'competition_vacant_walkovers_month_lock_side_effect',
  'Owned vs vacant/absent 3–0; both inactive league → void (+1 MP)'
)
ON CONFLICT (hook_key) DO UPDATE
SET enabled = true,
    proc_name = EXCLUDED.proc_name,
    sort_order = EXCLUDED.sort_order,
    notes = EXCLUDED.notes;

-- Durable side_effects: keep finance/scheduling/friendlies + vacant walkovers
CREATE OR REPLACE FUNCTION public.competition_run_month_lock_side_effects(
  p_season_id bigint,
  p_gpsl_month text,
  p_stage text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_month text := lower(btrim(coalesce(p_gpsl_month, '')));
  v_stage text := lower(btrim(coalesce(p_stage, 'all')));
  v_out jsonb := jsonb_build_object('ok', true, 'gpsl_month', nullif(v_month, ''));
  v_res jsonb;
  r record;
  v_reg text;
BEGIN
  IF p_season_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'season_id required');
  END IF;

  IF v_month = '' THEN
    BEGIN
      v_month := lower(coalesce(
        public.competition_active_gpsl_month(p_season_id, now()), ''
      ));
    EXCEPTION WHEN OTHERS THEN
      v_month := '';
    END;
  END IF;
  v_out := v_out || jsonb_build_object('gpsl_month', nullif(v_month, ''));

  IF v_month <> '' THEN
    BEGIN
      IF to_regprocedure('public.club_balance_snapshot_gpsl_month(bigint,text)') IS NOT NULL THEN
        v_res := public.club_balance_snapshot_gpsl_month(p_season_id, v_month);
        v_out := v_out || jsonb_build_object('balance_snapshot', v_res);
      END IF;
    EXCEPTION WHEN OTHERS THEN
      v_out := v_out || jsonb_build_object(
        'balance_snapshot', jsonb_build_object('ok', false, 'error', SQLERRM)
      );
    END;

    BEGIN
      IF to_regprocedure('public.competition_post_monthly_interest(bigint,text)') IS NOT NULL THEN
        v_res := public.competition_post_monthly_interest(p_season_id, v_month);
        v_out := v_out || jsonb_build_object('monthly_interest', v_res);
      END IF;
    EXCEPTION WHEN OTHERS THEN
      v_out := v_out || jsonb_build_object(
        'monthly_interest', jsonb_build_object('ok', false, 'error', SQLERRM)
      );
    END;

    BEGIN
      IF to_regprocedure('public.club_credit_probation_tick(bigint)') IS NOT NULL THEN
        PERFORM public.club_credit_probation_tick(p_season_id);
        v_out := v_out || jsonb_build_object('credit_probation', jsonb_build_object('ok', true));
      END IF;
    EXCEPTION WHEN OTHERS THEN
      v_out := v_out || jsonb_build_object(
        'credit_probation', jsonb_build_object('ok', false, 'error', SQLERRM)
      );
    END;

    BEGIN
      IF to_regprocedure('public.competition_month_lock_scheduling_effects(bigint,text)') IS NOT NULL THEN
        v_res := public.competition_month_lock_scheduling_effects(p_season_id, v_month);
        v_out := v_out || jsonb_build_object('scheduling', v_res);
      END IF;
    EXCEPTION WHEN OTHERS THEN
      v_out := v_out || jsonb_build_object(
        'scheduling', jsonb_build_object('ok', false, 'error', SQLERRM)
      );
    END;

    BEGIN
      IF to_regprocedure('public.gpsl_friendlies_month_lock_side_effect(bigint,text)') IS NOT NULL THEN
        v_res := public.gpsl_friendlies_month_lock_side_effect(p_season_id, v_month);
        v_out := v_out || jsonb_build_object('friendlies_prizes', v_res);
      ELSIF to_regprocedure('public.gpsl_friendlies_pay_locked_months_catchup(bigint)') IS NOT NULL THEN
        v_res := public.gpsl_friendlies_pay_locked_months_catchup(p_season_id);
        v_out := v_out || jsonb_build_object('friendlies_prizes_catchup', v_res);
      END IF;
    EXCEPTION WHEN OTHERS THEN
      v_out := v_out || jsonb_build_object(
        'friendlies_prizes', jsonb_build_object('ok', false, 'error', SQLERRM)
      );
    END;

    -- Vacant / season-absence walkovers (owned win 3–0; both inactive → void)
    BEGIN
      IF to_regprocedure('public.competition_process_vacant_walkovers(bigint)') IS NOT NULL THEN
        v_res := public.competition_process_vacant_walkovers(p_season_id);
        v_out := v_out || jsonb_build_object('vacant_walkovers', v_res);
      END IF;
    EXCEPTION WHEN OTHERS THEN
      v_out := v_out || jsonb_build_object(
        'vacant_walkovers', jsonb_build_object('ok', false, 'error', SQLERRM)
      );
    END;
  END IF;

  FOR r IN
    SELECT hook_key, proc_name
    FROM public.competition_month_lock_hooks
    WHERE enabled
      AND hook_key NOT IN ('friendlies_prizes', 'vacant_walkovers')
    ORDER BY sort_order, hook_key
  LOOP
    BEGIN
      v_reg := format('public.%I(bigint,text)', r.proc_name);
      IF to_regprocedure(v_reg) IS NULL OR v_month = '' THEN
        CONTINUE;
      END IF;
      EXECUTE format('SELECT public.%I($1, $2)', r.proc_name)
        INTO v_res
        USING p_season_id, v_month;
      v_out := v_out || jsonb_build_object(r.hook_key, v_res);
    EXCEPTION WHEN OTHERS THEN
      v_out := v_out || jsonb_build_object(
        r.hook_key, jsonb_build_object('ok', false, 'error', SQLERRM)
      );
    END;
  END LOOP;

  v_out := v_out || jsonb_build_object('stage', v_stage);
  RETURN v_out;
END;
$function$;

REVOKE ALL ON FUNCTION public.competition_run_month_lock_side_effects(bigint, text, text)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.competition_run_month_lock_side_effects(bigint, text, text)
  TO service_role, authenticated;

-- ---------------------------------------------------------------------------
-- Diagnose pending (before) + catch up now
-- ---------------------------------------------------------------------------
SELECT
  f.id AS fixture_id,
  f.gpsl_month,
  f.matchday,
  f.division,
  f.competition_type,
  f.home_club_short_name AS home,
  f.away_club_short_name AS away,
  public.competition_club_is_fixture_inactive(f.home_club_short_name, f.season_id) AS home_inactive,
  public.competition_club_is_fixture_inactive(f.away_club_short_name, f.season_id) AS away_inactive,
  public.competition_club_is_vacant(f.home_club_short_name) AS home_vacant,
  public.competition_club_is_vacant(f.away_club_short_name) AS away_vacant,
  public.club_is_season_absent(f.home_club_short_name, f.season_id) AS home_absent,
  public.club_is_season_absent(f.away_club_short_name, f.season_id) AS away_absent
FROM public.competition_fixtures f
WHERE f.season_id = (
    SELECT id FROM public.competition_seasons WHERE is_current ORDER BY id DESC LIMIT 1
  )
  AND f.status = 'scheduled'
  AND f.competition_type IN ('league', 'cup')
  AND lower(btrim(f.gpsl_month)) = 'august'
  AND (
    public.competition_club_is_fixture_inactive(f.home_club_short_name, f.season_id)
    OR public.competition_club_is_fixture_inactive(f.away_club_short_name, f.season_id)
  )
ORDER BY f.division, f.matchday, f.id;

SELECT job_key, gpsl_month, ran_at, result
FROM public.competition_season_calendar_jobs
WHERE season_id = (
  SELECT id FROM public.competition_seasons WHERE is_current ORDER BY id DESC LIMIT 1
)
  AND job_key LIKE 'vacant_walkovers:%'
ORDER BY ran_at;

SELECT public.competition_process_vacant_walkovers(NULL) AS catchup_result;

-- Remaining August inactive fixtures (should be empty / far fewer)
SELECT count(*) AS august_inactive_still_scheduled
FROM public.competition_fixtures f
WHERE f.season_id = (
    SELECT id FROM public.competition_seasons WHERE is_current ORDER BY id DESC LIMIT 1
  )
  AND f.status = 'scheduled'
  AND lower(btrim(f.gpsl_month)) = 'august'
  AND (
    public.competition_club_is_fixture_inactive(f.home_club_short_name, f.season_id)
    OR public.competition_club_is_fixture_inactive(f.away_club_short_name, f.season_id)
  );

SELECT
  (position('vacant_walkovers' IN pg_get_functiondef(
    'public.competition_run_month_lock_side_effects(bigint,text,text)'::regprocedure
  )) > 0) AS vacant_in_side_effects,
  (SELECT enabled FROM public.competition_month_lock_hooks WHERE hook_key = 'vacant_walkovers')
    AS hook_enabled;

NOTIFY pgrst, 'reload schema';
