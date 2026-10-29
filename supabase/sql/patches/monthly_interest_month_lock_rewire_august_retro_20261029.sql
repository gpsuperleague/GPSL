-- =============================================================================
-- Monthly interest: re-wire into month lock + August retro (2026-10-29)
--
-- Root cause: competition_post_monthly_interest exists and monthly_interest_enabled
-- is true, but soft-wire into competition_run_month_lock_jobs was wiped by a later
-- CREATE OR REPLACE of that function. June/July were retro-paid; August missed.
--
-- This patch:
--   1) Re-wires balance snapshot + monthly interest before RETURN v_out
--   2) Extends admin_retro_monthly_interest_from_snapshots to also treat a GPSL
--      month as locked when competition_season_calendar.lock_at <= now()
--      (so August can be rebuilt even if calendar_jobs rows are missing)
--   3) Dry-run then APPLY August only
--
-- Safe re-run.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1) Re-wire snapshot + interest into competition_run_month_lock_jobs
-- ---------------------------------------------------------------------------
DO $wire$
DECLARE
  v_def text;
  v_old text := E'  RETURN v_out;\nEND;';
  v_new text;
  v_oid oid;
BEGIN
  v_oid := to_regprocedure('public.competition_run_month_lock_jobs(bigint,boolean,text,text)');
  IF v_oid IS NULL THEN
    RAISE WARNING 'competition_run_month_lock_jobs(4-arg) missing — cannot wire interest';
    RETURN;
  END IF;

  SELECT pg_get_functiondef(v_oid) INTO v_def;

  -- Always strip prior copies of these blocks so re-run is clean
  v_def := regexp_replace(
    v_def,
    E'\\n  -- Month-end club balance snapshot.*?\\n  END;\\n',
    E'\n',
    'n'
  );
  v_def := regexp_replace(
    v_def,
    E'\\n  -- Monthly balance / overdraft interest.*?\\n  END;\\n',
    E'\n',
    'n'
  );

  IF position(v_old IN v_def) = 0 THEN
    -- Some builds use RETURN v_out; without newline before END
    v_old := E'  RETURN v_out;\r\nEND;';
  END IF;
  IF position(v_old IN v_def) = 0 THEN
    v_old := E'RETURN v_out;\nEND;';
  END IF;
  IF position(v_old IN v_def) = 0 THEN
    RAISE WARNING 'Could not find RETURN v_out in month-lock jobs — interest NOT wired. Def tail: %',
      right(v_def, 400);
    RETURN;
  END IF;

  v_new :=
    E'  -- Month-end club balance snapshot (loan credit / interest base)\n'
    || E'  BEGIN\n'
    || E'    IF v_month IS NOT NULL\n'
    || E'       AND to_regprocedure(''public.club_balance_snapshot_gpsl_month(bigint,text)'') IS NOT NULL THEN\n'
    || E'      v_out := v_out || jsonb_build_object(\n'
    || E'        ''balance_snapshot'',\n'
    || E'        public.club_balance_snapshot_gpsl_month(p_season_id, v_month)\n'
    || E'      );\n'
    || E'    END IF;\n'
    || E'  EXCEPTION\n'
    || E'    WHEN OTHERS THEN\n'
    || E'      v_out := v_out || jsonb_build_object(\n'
    || E'        ''balance_snapshot'',\n'
    || E'        jsonb_build_object(''ok'', false, ''error'', SQLERRM)\n'
    || E'      );\n'
    || E'  END;\n'
    || E'\n'
    || E'  -- Monthly balance / overdraft interest\n'
    || E'  BEGIN\n'
    || E'    IF v_month IS NOT NULL\n'
    || E'       AND to_regprocedure(''public.competition_post_monthly_interest(bigint,text)'') IS NOT NULL THEN\n'
    || E'      v_out := v_out || jsonb_build_object(\n'
    || E'        ''monthly_interest'',\n'
    || E'        public.competition_post_monthly_interest(p_season_id, v_month)\n'
    || E'      );\n'
    || E'    END IF;\n'
    || E'  EXCEPTION\n'
    || E'    WHEN OTHERS THEN\n'
    || E'      v_out := v_out || jsonb_build_object(\n'
    || E'        ''monthly_interest'',\n'
    || E'        jsonb_build_object(''ok'', false, ''error'', SQLERRM)\n'
    || E'      );\n'
    || E'  END;\n'
    || E'\n'
    || E'  RETURN v_out;\n'
    || E'END;';

  -- Prefer LF form for replace target
  IF position(E'  RETURN v_out;\nEND;' IN v_def) > 0 THEN
    EXECUTE replace(v_def, E'  RETURN v_out;\nEND;', v_new);
  ELSIF position(E'  RETURN v_out;\r\nEND;' IN v_def) > 0 THEN
    EXECUTE replace(v_def, E'  RETURN v_out;\r\nEND;', v_new);
  ELSE
    EXECUTE replace(v_def, E'RETURN v_out;\nEND;', v_new);
  END IF;

  RAISE NOTICE 'Wired balance snapshot + monthly interest into competition_run_month_lock_jobs';
EXCEPTION
  WHEN OTHERS THEN
    RAISE WARNING 'Interest rewire failed: %', SQLERRM;
END;
$wire$;

-- ---------------------------------------------------------------------------
-- 2) Retro helper: locked = calendar.lock_at <= now() OR legacy job markers
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_retro_monthly_interest_from_snapshots(
  p_season_id bigint DEFAULT NULL,
  p_dry_run boolean DEFAULT true,
  p_gpsl_months text[] DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season_id bigint := p_season_id;
  v_credit_pct numeric;
  v_debt_pct numeric;
  v_enabled boolean;
  v_label text;
  v_amount numeric;
  v_credit_n int := 0;
  v_debt_n int := 0;
  v_credit_sum numeric := 0;
  v_debt_sum numeric := 0;
  v_months text[] := ARRAY[]::text[];
  r record;
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.is_gpsl_admin() THEN
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
    RETURN jsonb_build_object('ok', false, 'error', 'no_season');
  END IF;

  SELECT b.monthly_interest_enabled,
         greatest(coalesce(b.monthly_balance_interest_pct, 0.25), 0),
         greatest(coalesce(b.monthly_debt_interest_pct, 0.50), 0)
  INTO v_enabled, v_credit_pct, v_debt_pct
  FROM public.gpsl_bank_account b
  WHERE b.id = 1;

  IF NOT coalesce(v_enabled, false) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'monthly_interest_disabled');
  END IF;

  -- Snapshots for locked months (calendar lock_at OR job markers)
  WITH locks AS (
    SELECT
      c.season_id,
      lower(btrim(c.gpsl_month)) AS gpsl_month,
      coalesce(
        (
          SELECT min(j.ran_at)
          FROM public.competition_season_calendar_jobs j
          WHERE j.season_id = c.season_id
            AND lower(j.gpsl_month) = lower(btrim(c.gpsl_month))
            AND (j.job_key LIKE 'team_of_month:%' OR j.job_key LIKE 'gpsl_sport:%')
        ),
        c.lock_at
      ) AS locked_at
    FROM public.competition_season_calendar c
    WHERE c.season_id = v_season_id
      AND c.lock_at IS NOT NULL
      AND c.lock_at <= now()
      AND (
        p_gpsl_months IS NULL
        OR lower(btrim(c.gpsl_month)) = ANY (
          SELECT lower(btrim(x)) FROM unnest(p_gpsl_months) x
        )
      )
  )
  INSERT INTO public.club_month_end_balances (
    season_id, gpsl_month, club_short_name, balance, source, checkpoint_at
  )
  SELECT
    lk.season_id,
    lk.gpsl_month,
    f.club_name,
    coalesce(f.balance, 0) - coalesce((
      SELECT sum(l.amount)
      FROM public.competition_finance_ledger l
      WHERE l.club_short_name = f.club_name
        AND l.created_at > lk.locked_at
    ), 0),
    'ledger_rebuild',
    lk.locked_at
  FROM locks lk
  JOIN public.competition_club_seasons ccs ON ccs.season_id = lk.season_id
  JOIN public."Club_Finances" f ON f.club_name = ccs.club_short_name
  WHERE f.club_name <> 'FOREIGN'
  ON CONFLICT (season_id, gpsl_month, club_short_name) DO NOTHING;

  FOR r IN
    SELECT
      b.gpsl_month,
      b.club_short_name AS club,
      b.balance
    FROM public.club_month_end_balances b
    WHERE b.season_id = v_season_id
      AND b.balance <> 0
      AND (
        p_gpsl_months IS NULL
        OR b.gpsl_month = ANY (
          SELECT lower(btrim(x)) FROM unnest(p_gpsl_months) x
        )
      )
      AND EXISTS (
        SELECT 1
        FROM public.competition_season_calendar c
        WHERE c.season_id = v_season_id
          AND lower(btrim(c.gpsl_month)) = b.gpsl_month
          AND c.lock_at IS NOT NULL
          AND c.lock_at <= now()
      )
      AND NOT EXISTS (
        SELECT 1 FROM public.club_monthly_interest m
        WHERE m.season_id = v_season_id
          AND m.gpsl_month = b.gpsl_month
          AND m.club_short_name = b.club_short_name
      )
    ORDER BY b.checkpoint_at, b.club_short_name
  LOOP
    BEGIN
      v_label := public.competition_gpsl_month_label(r.gpsl_month);
    EXCEPTION WHEN OTHERS THEN
      v_label := initcap(r.gpsl_month);
    END;

    IF NOT (r.gpsl_month = ANY (v_months)) THEN
      v_months := v_months || r.gpsl_month;
    END IF;

    IF r.balance > 0 THEN
      v_amount := round(r.balance * v_credit_pct / 100.0, 0);
      CONTINUE WHEN v_amount <= 0;

      IF NOT p_dry_run THEN
        PERFORM public.post_club_ledger(
          r.club,
          'eos_balance_interest',
          v_amount,
          format('%s balance interest (retro) — %s%% on ₿%s',
                 v_label, to_char(v_credit_pct, 'FM990.00'),
                 to_char(r.balance, 'FM999,999,999,999')),
          jsonb_build_object(
            'monthly', true,
            'gpsl_month', r.gpsl_month,
            'rate_pct', v_credit_pct,
            'balance_snapshot', r.balance,
            'retro', true,
            'source', 'month_end_snapshot'
          ),
          v_season_id,
          NULL,
          true,
          true
        );

        INSERT INTO public.club_monthly_interest (
          season_id, gpsl_month, club_short_name, kind, rate_pct, balance_snapshot, amount
        )
        VALUES (
          v_season_id, r.gpsl_month, r.club, 'balance', v_credit_pct, r.balance, v_amount
        );
      END IF;

      v_credit_n := v_credit_n + 1;
      v_credit_sum := v_credit_sum + v_amount;
    ELSE
      v_amount := round(abs(r.balance) * v_debt_pct / 100.0, 0);
      CONTINUE WHEN v_amount <= 0;

      IF NOT p_dry_run THEN
        PERFORM public.post_club_ledger(
          r.club,
          'eos_debt_interest',
          -v_amount,
          format('%s overdraft interest (retro) — %s%% on ₿%s overdrawn',
                 v_label, to_char(v_debt_pct, 'FM990.00'),
                 to_char(abs(r.balance), 'FM999,999,999,999')),
          jsonb_build_object(
            'monthly', true,
            'gpsl_month', r.gpsl_month,
            'rate_pct', v_debt_pct,
            'balance_snapshot', r.balance,
            'retro', true,
            'source', 'month_end_snapshot',
            'bad_credit_rate', false
          ),
          v_season_id,
          NULL,
          public.finance_entry_via_central_bank('eos_debt_interest'),
          true
        );

        INSERT INTO public.club_monthly_interest (
          season_id, gpsl_month, club_short_name, kind, rate_pct, balance_snapshot, amount
        )
        VALUES (
          v_season_id, r.gpsl_month, r.club, 'debt', v_debt_pct, r.balance, -v_amount
        );
      END IF;

      v_debt_n := v_debt_n + 1;
      v_debt_sum := v_debt_sum - v_amount;
    END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true,
    'dry_run', p_dry_run,
    'season_id', v_season_id,
    'months', to_jsonb(v_months),
    'credit_clubs', v_credit_n,
    'debt_clubs', v_debt_n,
    'credit_interest_total', v_credit_sum,
    'debt_interest_total', v_debt_sum,
    'credit_pct', v_credit_pct,
    'debt_pct', v_debt_pct,
    'interest_wired',
      position('competition_post_monthly_interest' IN pg_get_functiondef(
        'public.competition_run_month_lock_jobs(bigint,boolean,text,text)'::regprocedure
      )) > 0
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.admin_retro_monthly_interest_from_snapshots(bigint, boolean, text[])
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_retro_monthly_interest_from_snapshots(bigint, boolean, text[])
  TO authenticated;

NOTIFY pgrst, 'reload schema';

-- ---------------------------------------------------------------------------
-- 3) Verify wire + dry-run August + apply August
-- ---------------------------------------------------------------------------
SELECT
  (position('competition_post_monthly_interest' IN pg_get_functiondef(
    'public.competition_run_month_lock_jobs(bigint,boolean,text,text)'::regprocedure
  )) > 0) AS interest_wired,
  (position('club_balance_snapshot_gpsl_month' IN pg_get_functiondef(
    'public.competition_run_month_lock_jobs(bigint,boolean,text,text)'::regprocedure
  )) > 0) AS snapshot_wired;

SELECT public.admin_retro_monthly_interest_from_snapshots(NULL, true, ARRAY['august']) AS august_dry_run;

SELECT public.admin_retro_monthly_interest_from_snapshots(NULL, false, ARRAY['august']) AS august_applied;

SELECT
  m.gpsl_month,
  count(*) AS clubs,
  count(*) FILTER (WHERE m.kind IN ('balance','credit')) AS credit_n,
  count(*) FILTER (WHERE m.kind = 'debt') AS debt_n,
  round(sum(m.amount) FILTER (WHERE m.kind IN ('balance','credit')), 0) AS credit_total,
  round(sum(m.amount) FILTER (WHERE m.kind = 'debt'), 0) AS debt_total
FROM public.club_monthly_interest m
JOIN public.competition_seasons s ON s.id = m.season_id AND s.is_current
GROUP BY m.gpsl_month
ORDER BY m.gpsl_month;
