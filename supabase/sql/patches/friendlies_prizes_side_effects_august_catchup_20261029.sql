-- =============================================================================
-- Friendlies table prizes (top 2) → durable month-lock side effects
-- + August catch-up pay (2026-10-29)
--
-- Root cause (same as interest): soft-wire into competition_run_month_lock_jobs
-- was wiped. August locked without paying 1st ₿3,000 / 2nd ₿1,500.
--
-- Fix:
--   1) Hardcode friendlies into competition_run_month_lock_side_effects
--   2) Register hook as belt-and-suspenders
--   3) Pay any locked month still missing payouts (August+)
--
-- Safe re-run (pay is idempotent per place).
-- =============================================================================

-- Ensure catch-up helper exists (from friendlies_prizes_auto_catchup_20261027)
CREATE OR REPLACE FUNCTION public.gpsl_friendlies_pay_locked_months_catchup(
  p_season_id bigint DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season bigint := p_season_id;
  v_month text;
  v_lock timestamptz;
  v_result jsonb;
  v_paid jsonb := '[]'::jsonb;
  v_n int := 0;
BEGIN
  IF v_season IS NULL THEN
    SELECT id INTO v_season
    FROM public.competition_seasons
    WHERE is_current = true
    ORDER BY id DESC
    LIMIT 1;
  END IF;

  IF v_season IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_season');
  END IF;

  IF to_regprocedure('public.gpsl_friendlies_pay_month_prizes_internal(bigint,text)') IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'pay_fn_missing');
  END IF;

  FOREACH v_month IN ARRAY ARRAY[
    'june','july','august','september','october','november','december',
    'january','february','march','april','may'
  ]
  LOOP
    SELECT cal.lock_at INTO v_lock
    FROM public.competition_season_calendar cal
    WHERE cal.season_id = v_season
      AND lower(btrim(cal.gpsl_month)) = v_month
    LIMIT 1;

    IF v_lock IS NULL OR v_lock > now() THEN
      CONTINUE;
    END IF;

    IF EXISTS (
      SELECT 1
      FROM public.gpsl_friendlies_prize_payouts p
      WHERE p.season_id = v_season
        AND p.gpsl_month = v_month
    ) THEN
      CONTINUE;
    END IF;

    v_result := public.gpsl_friendlies_pay_month_prizes_internal(v_season, v_month);
    v_n := v_n + 1;
    v_paid := v_paid || jsonb_build_array(
      jsonb_build_object('gpsl_month', v_month, 'result', v_result)
    );
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true,
    'season_id', v_season,
    'months_attempted', v_n,
    'paid', v_paid
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.gpsl_friendlies_pay_locked_months_catchup(bigint)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.gpsl_friendlies_pay_locked_months_catchup(bigint)
  TO service_role;

-- Wrapper for registry hooks: (season, locked_month) → pay that month + catch-up gaps
CREATE OR REPLACE FUNCTION public.gpsl_friendlies_month_lock_side_effect(
  p_season_id bigint,
  p_gpsl_month text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_month text := lower(btrim(coalesce(p_gpsl_month, '')));
  v_locked jsonb := NULL;
  v_catchup jsonb := NULL;
BEGIN
  IF p_season_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'season_id required');
  END IF;

  IF v_month <> '' AND v_month <> 'playoffs'
     AND to_regprocedure('public.gpsl_friendlies_on_gpsl_month_lock(bigint,text)') IS NOT NULL
  THEN
    BEGIN
      v_locked := public.gpsl_friendlies_on_gpsl_month_lock(p_season_id, v_month);
    EXCEPTION WHEN OTHERS THEN
      v_locked := jsonb_build_object('ok', false, 'error', SQLERRM);
    END;
  END IF;

  BEGIN
    v_catchup := public.gpsl_friendlies_pay_locked_months_catchup(p_season_id);
  EXCEPTION WHEN OTHERS THEN
    v_catchup := jsonb_build_object('ok', false, 'error', SQLERRM);
  END;

  RETURN jsonb_build_object(
    'ok', true,
    'gpsl_month', nullif(v_month, ''),
    'locked_month', v_locked,
    'catchup', v_catchup
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.gpsl_friendlies_month_lock_side_effect(bigint, text)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.gpsl_friendlies_month_lock_side_effect(bigint, text)
  TO service_role;

-- Registry row (survives even if hardcoded block is rewritten — prefer both)
INSERT INTO public.competition_month_lock_hooks (hook_key, sort_order, enabled, proc_name, notes)
VALUES (
  'friendlies_prizes',
  40,
  true,
  'gpsl_friendlies_month_lock_side_effect',
  'Top-2 friendlies table prizes (₿3k / ₿1.5k) + locked-month catch-up'
)
ON CONFLICT (hook_key) DO UPDATE
SET enabled = true,
    proc_name = EXCLUDED.proc_name,
    sort_order = EXCLUDED.sort_order,
    notes = EXCLUDED.notes;

-- Durable side_effects: finance + scheduling + friendlies (hardcoded)
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

    -- Friendlies top-2: locked month + any earlier locked months still unpaid
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
  END IF;

  FOR r IN
    SELECT hook_key, proc_name
    FROM public.competition_month_lock_hooks
    WHERE enabled
      -- Skip duplicate if we already ran friendlies hardcoded above
      AND hook_key IS DISTINCT FROM 'friendlies_prizes'
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
-- Catch up NOW (August and any other locked month missing payouts)
-- ---------------------------------------------------------------------------
DO $pay$
DECLARE
  v_season bigint;
  v_result jsonb;
BEGIN
  SELECT id INTO v_season
  FROM public.competition_seasons
  WHERE is_current = true
  ORDER BY id DESC
  LIMIT 1;

  IF v_season IS NULL THEN
    RAISE NOTICE 'No current season — friendlies catch-up skipped';
    RETURN;
  END IF;

  v_result := public.gpsl_friendlies_pay_locked_months_catchup(v_season);
  RAISE NOTICE 'Friendlies locked-months catch-up: %', v_result;
END;
$pay$;

NOTIFY pgrst, 'reload schema';

-- Diagnose
SELECT
  cal.gpsl_month,
  cal.lock_at,
  cal.lock_at <= now() AS is_locked,
  (SELECT count(*) FROM public.gpsl_friendlies_prize_payouts p
   WHERE p.season_id = cal.season_id AND p.gpsl_month = lower(btrim(cal.gpsl_month))) AS payout_rows
FROM public.competition_season_calendar cal
WHERE cal.season_id = (
  SELECT id FROM public.competition_seasons WHERE is_current ORDER BY id DESC LIMIT 1
)
  AND lower(btrim(cal.gpsl_month)) IN ('june', 'july', 'august', 'september')
ORDER BY cal.unlock_at;

SELECT
  p.gpsl_month,
  p.place,
  p.club_short_name,
  p.amount,
  p.points,
  p.created_at
FROM public.gpsl_friendlies_prize_payouts p
WHERE p.season_id = (
  SELECT id FROM public.competition_seasons WHERE is_current ORDER BY id DESC LIMIT 1
)
  AND p.gpsl_month IN ('june', 'july', 'august')
ORDER BY p.gpsl_month, p.place;

SELECT
  (position('friendlies_prizes' IN pg_get_functiondef(
    'public.competition_run_month_lock_side_effects(bigint,text,text)'::regprocedure
  )) > 0) AS friendlies_in_side_effects,
  (SELECT enabled FROM public.competition_month_lock_hooks WHERE hook_key = 'friendlies_prizes')
    AS hook_enabled;
