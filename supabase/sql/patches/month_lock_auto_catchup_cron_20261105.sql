-- =============================================================================
-- Month-lock auto catch-up (2026-11-05)
--
-- Root cause: GPSL calendar lock_at is just a timestamp. Interest, TV next-month
-- picks, awards (TOTM / OotM / MotM), friendlies prizes, and vacant walkovers
-- only run when competition_run_month_lock_jobs / side_effects are invoked
-- (admin End Month). September locked with none of those jobs run — same as
-- prior months when soft-wires were assumed to fire automatically.
--
-- This patch:
--   1) Vacant walkovers: skip bookies full reprice (was timing out every chunk)
--   2) gpsl_month_lock_auto_catchup_tick(): for each locked month still missing
--      interest / next-month TV / awards, run the dedicated catch-up helpers;
--      always drain a vacant-walkover chunk
--   3) Hourly cron so this cannot depend on admin clicking End Month
--
-- Safe re-run. Idempotent helpers.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1) Vacant walkover apply: skip bookies reprice (session-local)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.competition_apply_vacant_fixture_result_fast(
  p_fixture_id bigint
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_f public.competition_fixtures;
  v_home_inactive boolean;
  v_away_inactive boolean;
  v_loser text;
  v_winner text;
  v_low text;
  v_high text;
BEGIN
  -- Bookies trigger does a full odds recompute per fixture update — kills batches.
  PERFORM set_config('gpsl.skip_bookies_reprice', 'on', true);

  SELECT * INTO v_f
  FROM public.competition_fixtures
  WHERE id = p_fixture_id
  FOR UPDATE;

  IF NOT FOUND OR v_f.status IS DISTINCT FROM 'scheduled'
     OR v_f.competition_type NOT IN ('league', 'cup') THEN
    RETURN jsonb_build_object('ok', false, 'fixture_id', p_fixture_id, 'reason', 'not_applicable');
  END IF;

  v_home_inactive := public.competition_club_is_fixture_inactive(v_f.home_club_short_name, v_f.season_id);
  v_away_inactive := public.competition_club_is_fixture_inactive(v_f.away_club_short_name, v_f.season_id);

  IF NOT v_home_inactive AND NOT v_away_inactive THEN
    RETURN jsonb_build_object('ok', false, 'fixture_id', p_fixture_id, 'reason', 'both_active');
  END IF;

  UPDATE public.competition_result_submissions
  SET status = 'rejected',
      reject_reason = 'Superseded by vacant/absence walkover',
      responded_at = now()
  WHERE fixture_id = p_fixture_id
    AND status = 'pending';

  IF v_home_inactive AND v_away_inactive AND v_f.competition_type = 'league' THEN
    UPDATE public.competition_fixtures
    SET status = 'played',
        is_void = true,
        home_goals = NULL,
        away_goals = NULL
    WHERE id = p_fixture_id;

    RETURN jsonb_build_object(
      'ok', true, 'fixture_id', p_fixture_id, 'result', 'void',
      'division', v_f.division, 'season_id', v_f.season_id
    );
  END IF;

  IF v_home_inactive AND v_away_inactive THEN
    v_low := least(v_f.home_club_short_name, v_f.away_club_short_name);
    v_high := greatest(v_f.home_club_short_name, v_f.away_club_short_name);
    v_loser := CASE
      WHEN substr(md5(concat_ws(':', v_f.season_id, v_f.cup_code, v_low, v_high)), 1, 1) < '8'
      THEN v_low ELSE v_high
    END;
  ELSIF v_home_inactive THEN
    v_loser := v_f.home_club_short_name;
  ELSE
    v_loser := v_f.away_club_short_name;
  END IF;

  v_winner := CASE
    WHEN v_loser = v_f.home_club_short_name THEN v_f.away_club_short_name
    ELSE v_f.home_club_short_name
  END;

  UPDATE public.competition_fixtures
  SET home_goals = CASE WHEN v_winner = v_f.home_club_short_name THEN 3 ELSE 0 END,
      away_goals = CASE WHEN v_winner = v_f.away_club_short_name THEN 3 ELSE 0 END,
      status = 'played',
      is_forfeit = true,
      forfeit_loser_club = v_loser
  WHERE id = p_fixture_id;

  IF v_f.competition_type = 'cup'
     AND to_regprocedure('public.competition_cup_on_fixture_played(bigint)') IS NOT NULL THEN
    BEGIN
      PERFORM public.competition_cup_on_fixture_played(p_fixture_id);
    EXCEPTION WHEN OTHERS THEN
      RETURN jsonb_build_object(
        'ok', false, 'fixture_id', p_fixture_id, 'reason', 'cup_advance_failed',
        'error', SQLERRM, 'winner', v_winner, 'loser', v_loser
      );
    END;
  END IF;

  RETURN jsonb_build_object(
    'ok', true, 'fixture_id', p_fixture_id, 'result', 'walkover',
    'winner', v_winner, 'loser', v_loser,
    'division', v_f.division, 'season_id', v_f.season_id,
    'competition_type', v_f.competition_type
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.competition_apply_vacant_fixture_result_fast(bigint)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.competition_apply_vacant_fixture_result_fast(bigint)
  TO service_role;

-- Chunk wrapper: also set skip flag for any nested paths
CREATE OR REPLACE FUNCTION public.competition_process_vacant_walkovers_chunk(
  p_season_id bigint DEFAULT NULL,
  p_limit int DEFAULT 40
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
SET statement_timeout = '90s'
AS $function$
DECLARE
  v_season bigint := p_season_id;
  v_limit int := greatest(1, least(coalesce(p_limit, 40), 60));
  v_fx record;
  v_res jsonb;
  v_n int := 0;
  v_walkovers int := 0;
  v_voids int := 0;
  v_fail int := 0;
  v_div text;
  v_divs text[] := ARRAY[]::text[];
  v_month text;
  v_months text[] := ARRAY[]::text[];
BEGIN
  PERFORM set_config('gpsl.skip_bookies_reprice', 'on', true);

  IF v_season IS NULL THEN
    SELECT id INTO v_season
    FROM public.competition_seasons
    WHERE is_current = true AND status = 'active'
    ORDER BY id DESC
    LIMIT 1;
  END IF;

  IF v_season IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_season');
  END IF;

  IF to_regprocedure('public.competition_apply_vacant_fixture_result_fast(bigint)') IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'fast_apply_missing');
  END IF;

  FOR v_fx IN
    SELECT f.id, lower(btrim(f.gpsl_month)) AS gpsl_month
    FROM public.competition_fixtures f
    JOIN public.competition_season_calendar cal
      ON cal.season_id = f.season_id
     AND lower(btrim(cal.gpsl_month)) = lower(btrim(f.gpsl_month))
    WHERE f.season_id = v_season
      AND f.status = 'scheduled'
      AND f.competition_type IN ('league', 'cup')
      AND cal.lock_at IS NOT NULL
      AND cal.lock_at <= now()
      AND (
        public.competition_club_is_fixture_inactive(f.home_club_short_name, f.season_id)
        OR public.competition_club_is_fixture_inactive(f.away_club_short_name, f.season_id)
      )
    ORDER BY public.competition_gpsl_month_sort(f.gpsl_month), f.id
    LIMIT v_limit
  LOOP
    BEGIN
      v_res := public.competition_apply_vacant_fixture_result_fast(v_fx.id);
    EXCEPTION WHEN OTHERS THEN
      v_fail := v_fail + 1;
      v_n := v_n + 1;
      CONTINUE;
    END;

    v_n := v_n + 1;
    IF coalesce((v_res->>'ok')::boolean, false) THEN
      IF v_res->>'result' = 'void' THEN
        v_voids := v_voids + 1;
      ELSE
        v_walkovers := v_walkovers + 1;
      END IF;
      v_div := nullif(btrim(coalesce(v_res->>'division', '')), '');
      IF v_div IS NOT NULL AND NOT (v_div = ANY (v_divs)) THEN
        v_divs := v_divs || v_div;
      END IF;
      v_month := v_fx.gpsl_month;
      IF v_month IS NOT NULL AND NOT (v_month = ANY (v_months)) THEN
        v_months := v_months || v_month;
      END IF;
    END IF;
  END LOOP;

  IF to_regprocedure('public.competition_try_pay_league_division_prizes(bigint,text)') IS NOT NULL THEN
    FOREACH v_div IN ARRAY v_divs
    LOOP
      BEGIN
        PERFORM public.competition_try_pay_league_division_prizes(v_season, v_div);
      EXCEPTION WHEN OTHERS THEN
        NULL;
      END;
    END LOOP;
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'season_id', v_season,
    'processed', v_n,
    'walkovers', v_walkovers,
    'voids', v_voids,
    'failed', v_fail,
    'months', to_jsonb(v_months),
    'divisions', to_jsonb(v_divs)
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.competition_process_vacant_walkovers_chunk(bigint, int)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.competition_process_vacant_walkovers_chunk(bigint, int)
  TO service_role;

-- ---------------------------------------------------------------------------
-- 2) Hourly catch-up for locked months missing month-lock side effects
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.gpsl_month_lock_auto_catchup_tick()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
SET statement_timeout = '110s'
AS $function$
DECLARE
  v_season bigint;
  v_month text;
  v_next text;
  v_out jsonb := jsonb_build_object('ok', true);
  v_months jsonb := '[]'::jsonb;
  v_interest jsonb;
  v_tv jsonb;
  v_awards jsonb;
  v_friendlies jsonb;
  v_vacant jsonb;
  v_need_interest boolean;
  v_need_tv boolean;
  v_need_awards boolean;
  v_month_result jsonb;
BEGIN
  SELECT id INTO v_season
  FROM public.competition_seasons
  WHERE is_current = true AND status = 'active'
  ORDER BY id DESC
  LIMIT 1;

  IF v_season IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_season');
  END IF;

  FOR v_month IN
    SELECT lower(btrim(c.gpsl_month))
    FROM public.competition_season_calendar c
    WHERE c.season_id = v_season
      AND c.lock_at IS NOT NULL
      AND c.lock_at <= now()
      AND lower(btrim(c.gpsl_month)) <> 'playoffs'
    ORDER BY c.sort_order
  LOOP
    v_need_interest := NOT EXISTS (
      SELECT 1
      FROM public.competition_finance_ledger l
      WHERE l.entry_type IN ('eos_balance_interest', 'eos_debt_interest')
        AND lower(btrim(coalesce(l.metadata->>'gpsl_month', ''))) = v_month
        AND l.created_at > now() - interval '180 days'
      LIMIT 1
    );

    SELECT c2.gpsl_month INTO v_next
    FROM public.competition_season_calendar c2
    WHERE c2.season_id = v_season
      AND c2.sort_order > (
        SELECT c0.sort_order
        FROM public.competition_season_calendar c0
        WHERE c0.season_id = v_season
          AND lower(btrim(c0.gpsl_month)) = v_month
        LIMIT 1
      )
    ORDER BY c2.sort_order
    LIMIT 1;

    v_need_tv := v_next IS NOT NULL AND NOT EXISTS (
      SELECT 1
      FROM public.competition_tv_fixture_selection s
      WHERE s.season_id = v_season
        AND lower(btrim(s.gpsl_month)) = lower(btrim(v_next))
      LIMIT 1
    );

    v_need_awards :=
      NOT EXISTS (
        SELECT 1 FROM public.competition_period_team t
        WHERE t.season_id = v_season
          AND t.period_kind = 'month'
          AND lower(btrim(t.gpsl_month)) = v_month
      )
      OR (
        SELECT count(*) < 2
        FROM public.competition_owner_month_award a
        WHERE a.season_id = v_season
          AND lower(btrim(a.gpsl_month)) = v_month
      )
      OR NOT EXISTS (
        SELECT 1 FROM public.competition_manager_month_award m
        WHERE m.season_id = v_season
          AND lower(btrim(m.gpsl_month)) = v_month
      );

    v_interest := NULL;
    v_tv := NULL;
    v_awards := NULL;

    IF v_need_interest
       AND to_regprocedure('public.competition_post_monthly_interest(bigint,text)') IS NOT NULL THEN
      BEGIN
        v_interest := public.competition_post_monthly_interest(v_season, v_month);
      EXCEPTION WHEN OTHERS THEN
        v_interest := jsonb_build_object('ok', false, 'error', SQLERRM);
      END;
    END IF;

    IF v_need_tv
       AND to_regprocedure('public.competition_tv_process_month_lock_selections(bigint,text)') IS NOT NULL THEN
      BEGIN
        v_tv := public.competition_tv_process_month_lock_selections(v_season, v_month);
      EXCEPTION WHEN OTHERS THEN
        v_tv := jsonb_build_object('ok', false, 'error', SQLERRM);
      END;
    END IF;

    IF v_need_awards
       AND to_regprocedure('public.competition_catchup_month_awards(bigint,text[],boolean)') IS NOT NULL THEN
      BEGIN
        v_awards := public.competition_catchup_month_awards(
          v_season, ARRAY[v_month]::text[], false
        );
      EXCEPTION WHEN OTHERS THEN
        v_awards := jsonb_build_object('ok', false, 'error', SQLERRM);
      END;
    END IF;

    IF v_interest IS NOT NULL OR v_tv IS NOT NULL OR v_awards IS NOT NULL THEN
      v_month_result := jsonb_build_object(
        'gpsl_month', v_month,
        'interest', v_interest,
        'tv', v_tv,
        'awards', v_awards
      );
      v_months := v_months || jsonb_build_array(v_month_result);
    END IF;
  END LOOP;

  -- Friendlies top-2 (idempotent)
  IF to_regprocedure('public.gpsl_friendlies_pay_locked_months_catchup(bigint)') IS NOT NULL THEN
    BEGIN
      v_friendlies := public.gpsl_friendlies_pay_locked_months_catchup(v_season);
    EXCEPTION WHEN OTHERS THEN
      v_friendlies := jsonb_build_object('ok', false, 'error', SQLERRM);
    END;
  END IF;

  -- Drain vacant walkovers (chunk; cron also runs every 5m)
  IF to_regprocedure('public.competition_process_vacant_walkovers_chunk(bigint,integer)') IS NOT NULL THEN
    BEGIN
      v_vacant := public.competition_process_vacant_walkovers_chunk(v_season, 25);
    EXCEPTION WHEN OTHERS THEN
      v_vacant := jsonb_build_object('ok', false, 'error', SQLERRM);
    END;
  END IF;

  RETURN v_out || jsonb_build_object(
    'season_id', v_season,
    'months_touched', v_months,
    'friendlies', v_friendlies,
    'vacant_walkovers', v_vacant
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.gpsl_month_lock_auto_catchup_tick()
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.gpsl_month_lock_auto_catchup_tick()
  TO service_role;

COMMENT ON FUNCTION public.gpsl_month_lock_auto_catchup_tick() IS
  'Hourly: catch up interest / TV / awards / friendlies / vacant walkovers for locked months without admin End Month.';

DO $cron$
BEGIN
  BEGIN
    PERFORM cron.unschedule('gpsl-month-lock-auto-catchup');
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;

  PERFORM cron.schedule(
    'gpsl-month-lock-auto-catchup',
    '25 * * * *',
    $q$SELECT public.gpsl_month_lock_auto_catchup_tick();$q$
  );
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING 'Could not schedule month-lock auto catchup: %', SQLERRM;
END;
$cron$;

-- Drain vacant walkovers now (skip bookies)
SELECT public.competition_process_vacant_walkovers_chunk(NULL, 30) AS vacant_chunk_1;
SELECT public.competition_process_vacant_walkovers_chunk(NULL, 30) AS vacant_chunk_2;

SELECT jobid, jobname, schedule, active
FROM cron.job
WHERE jobname IN ('gpsl-month-lock-auto-catchup', 'gpsl-friendlies-prizes-catchup', 'gpsl-vacant-walkovers')
ORDER BY jobname;

NOTIFY pgrst, 'reload schema';
