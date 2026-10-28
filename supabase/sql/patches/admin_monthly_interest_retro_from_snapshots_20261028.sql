-- =============================================================================
-- Monthly balance / overdraft interest — diagnose + retro from month-end snaps
-- (2026-10-28)
--
-- Context: monthly interest (0.25% credit / 0.50% overdraft) was added 2026-10-12
-- and wired into month lock. GPSL months that locked before that (June, July,
-- and any later month that missed the wire) have club_month_end_balances rows
-- (or can be rebuilt from the ledger) but no club_monthly_interest / ledger
-- interest lines.
--
-- admin_post_monthly_interest() uses *today's* Club_Finances balances — do NOT
-- use it for catch-up. This patch posts from club_month_end_balances instead.
--
-- Debt rate for retro = normal monthly_debt_interest_pct (not bad-credit).
-- Safe re-run (skips clubs/months already in club_monthly_interest).
--
-- Run: 1) DIAGNOSE → 2) APPLY → 3) VERIFY
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 0) Ensure month-end snapshots exist for every locked GPSL month
--    (same ledger_rebuild as loan_credit_risk_overdrawn_ffp_20261012)
-- ---------------------------------------------------------------------------
WITH locks AS (
  SELECT j.season_id, lower(j.gpsl_month) AS gpsl_month, min(j.ran_at) AS locked_at
  FROM public.competition_season_calendar_jobs j
  WHERE j.gpsl_month IS NOT NULL
    AND (j.job_key LIKE 'team_of_month:%' OR j.job_key LIKE 'gpsl_sport:%')
  GROUP BY j.season_id, lower(j.gpsl_month)
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

-- ---------------------------------------------------------------------------
-- 1) DIAGNOSE — locked months: snapshots vs interest posted
-- ---------------------------------------------------------------------------
WITH cur AS (
  SELECT id AS season_id, label
  FROM public.competition_seasons
  WHERE is_current = true
  ORDER BY id DESC
  LIMIT 1
),
locks AS (
  SELECT j.season_id, lower(j.gpsl_month) AS gpsl_month, min(j.ran_at) AS locked_at
  FROM public.competition_season_calendar_jobs j
  JOIN cur c ON c.season_id = j.season_id
  WHERE j.gpsl_month IS NOT NULL
    AND (j.job_key LIKE 'team_of_month:%' OR j.job_key LIKE 'gpsl_sport:%')
  GROUP BY j.season_id, lower(j.gpsl_month)
),
snap AS (
  SELECT
    b.season_id,
    b.gpsl_month,
    count(*) AS clubs,
    count(*) FILTER (WHERE b.balance > 0) AS credit_clubs,
    count(*) FILTER (WHERE b.balance < 0) AS debt_clubs,
    count(*) FILTER (WHERE b.balance = 0) AS zero_clubs,
    round(sum(b.balance) FILTER (WHERE b.balance > 0), 0) AS credit_balance_sum,
    round(sum(b.balance) FILTER (WHERE b.balance < 0), 0) AS debt_balance_sum
  FROM public.club_month_end_balances b
  JOIN cur c ON c.season_id = b.season_id
  GROUP BY b.season_id, b.gpsl_month
),
paid AS (
  SELECT
    m.season_id,
    m.gpsl_month,
    count(*) AS interest_rows,
    count(*) FILTER (WHERE m.kind = 'balance') AS credit_paid,
    count(*) FILTER (WHERE m.kind = 'debt') AS debt_paid,
    round(sum(m.amount) FILTER (WHERE m.kind = 'balance'), 0) AS credit_paid_sum,
    round(sum(m.amount) FILTER (WHERE m.kind = 'debt'), 0) AS debt_paid_sum
  FROM public.club_monthly_interest m
  JOIN cur c ON c.season_id = m.season_id
  GROUP BY m.season_id, m.gpsl_month
),
rates AS (
  SELECT
    greatest(coalesce(b.monthly_balance_interest_pct, 0.25), 0) AS credit_pct,
    greatest(coalesce(b.monthly_debt_interest_pct, 0.50), 0) AS debt_pct,
    coalesce(b.monthly_interest_enabled, false) AS enabled
  FROM public.gpsl_bank_account b
  WHERE b.id = 1
)
SELECT
  c.label AS season,
  lk.gpsl_month,
  lk.locked_at,
  r.enabled AS monthly_interest_enabled,
  coalesce(s.clubs, 0) AS snapshot_clubs,
  coalesce(s.credit_clubs, 0) AS snapshot_credit_clubs,
  coalesce(s.debt_clubs, 0) AS snapshot_debt_clubs,
  coalesce(p.interest_rows, 0) AS interest_rows_posted,
  coalesce(p.credit_paid, 0) AS credit_interest_posted,
  coalesce(p.debt_paid, 0) AS debt_interest_posted,
  -- Expected interest if retro uses snapshots × current rates
  round(coalesce(s.credit_balance_sum, 0) * r.credit_pct / 100.0, 0) AS expected_credit_interest,
  -round(abs(coalesce(s.debt_balance_sum, 0)) * r.debt_pct / 100.0, 0) AS expected_debt_interest,
  coalesce(p.credit_paid_sum, 0) AS posted_credit_interest,
  coalesce(p.debt_paid_sum, 0) AS posted_debt_interest,
  CASE
    WHEN coalesce(s.clubs, 0) = 0 THEN 'no_snapshots'
    WHEN coalesce(p.interest_rows, 0) = 0
         AND (coalesce(s.credit_clubs, 0) + coalesce(s.debt_clubs, 0)) > 0
      THEN 'MISSING_ALL'
    WHEN coalesce(p.interest_rows, 0) < (coalesce(s.credit_clubs, 0) + coalesce(s.debt_clubs, 0))
      THEN 'MISSING_SOME'
    ELSE 'ok'
  END AS status
FROM locks lk
CROSS JOIN cur c
CROSS JOIN rates r
LEFT JOIN snap s
  ON s.season_id = lk.season_id AND s.gpsl_month = lk.gpsl_month
LEFT JOIN paid p
  ON p.season_id = lk.season_id AND p.gpsl_month = lk.gpsl_month
ORDER BY lk.locked_at;

-- Per-club gaps for locked months (what retro would post)
WITH cur AS (
  SELECT id AS season_id
  FROM public.competition_seasons
  WHERE is_current = true
  ORDER BY id DESC
  LIMIT 1
),
locks AS (
  SELECT j.season_id, lower(j.gpsl_month) AS gpsl_month
  FROM public.competition_season_calendar_jobs j
  JOIN cur c ON c.season_id = j.season_id
  WHERE j.gpsl_month IS NOT NULL
    AND (j.job_key LIKE 'team_of_month:%' OR j.job_key LIKE 'gpsl_sport:%')
  GROUP BY j.season_id, lower(j.gpsl_month)
),
rates AS (
  SELECT
    greatest(coalesce(b.monthly_balance_interest_pct, 0.25), 0) AS credit_pct,
    greatest(coalesce(b.monthly_debt_interest_pct, 0.50), 0) AS debt_pct
  FROM public.gpsl_bank_account b
  WHERE b.id = 1
)
SELECT
  b.gpsl_month,
  count(*) FILTER (
    WHERE b.balance <> 0
      AND NOT EXISTS (
        SELECT 1 FROM public.club_monthly_interest m
        WHERE m.season_id = b.season_id
          AND m.gpsl_month = b.gpsl_month
          AND m.club_short_name = b.club_short_name
      )
  ) AS clubs_missing_interest,
  round(sum(
    CASE
      WHEN b.balance > 0
           AND NOT EXISTS (
             SELECT 1 FROM public.club_monthly_interest m
             WHERE m.season_id = b.season_id
               AND m.gpsl_month = b.gpsl_month
               AND m.club_short_name = b.club_short_name
           )
        THEN round(b.balance * r.credit_pct / 100.0, 0)
      ELSE 0
    END
  ), 0) AS pending_credit_interest_total,
  round(sum(
    CASE
      WHEN b.balance < 0
           AND NOT EXISTS (
             SELECT 1 FROM public.club_monthly_interest m
             WHERE m.season_id = b.season_id
               AND m.gpsl_month = b.gpsl_month
               AND m.club_short_name = b.club_short_name
           )
        THEN -round(abs(b.balance) * r.debt_pct / 100.0, 0)
      ELSE 0
    END
  ), 0) AS pending_debt_interest_total
FROM public.club_month_end_balances b
JOIN locks lk ON lk.season_id = b.season_id AND lk.gpsl_month = b.gpsl_month
CROSS JOIN rates r
GROUP BY b.gpsl_month
ORDER BY min(b.checkpoint_at);

-- Own-club / pick-a-club month-end balances (edit the short name)
-- Shows snapshot balance + whether interest was posted.
WITH cur AS (
  SELECT id AS season_id
  FROM public.competition_seasons
  WHERE is_current = true
  ORDER BY id DESC
  LIMIT 1
),
pick AS (
  SELECT upper(btrim(coalesce(
    public.my_club_shortname(),
    ''  -- or hard-code e.g. 'FLA'
  ))) AS club
)
SELECT
  b.gpsl_month,
  b.checkpoint_at,
  b.source,
  b.balance AS month_end_balance,
  m.kind AS interest_kind,
  m.rate_pct,
  m.amount AS interest_posted,
  m.created_at AS interest_posted_at,
  CASE
    WHEN b.balance = 0 THEN 'zero_skip'
    WHEN m.club_short_name IS NOT NULL THEN 'paid'
    WHEN b.balance > 0 THEN 'MISSING_credit'
    ELSE 'MISSING_debt'
  END AS status
FROM public.club_month_end_balances b
JOIN cur c ON c.season_id = b.season_id
CROSS JOIN pick p
LEFT JOIN public.club_monthly_interest m
  ON m.season_id = b.season_id
 AND m.gpsl_month = b.gpsl_month
 AND m.club_short_name = b.club_short_name
WHERE b.club_short_name = p.club
  AND p.club <> ''
ORDER BY b.checkpoint_at;

-- ---------------------------------------------------------------------------
-- 2) APPLY — post missed months from snapshots (admin RPC)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_retro_monthly_interest_from_snapshots(
  p_season_id bigint DEFAULT NULL,
  p_dry_run boolean DEFAULT true,
  p_gpsl_months text[] DEFAULT NULL  -- NULL = every locked month missing interest
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

  -- Fill any missing snapshots for locked months before posting
  WITH locks AS (
    SELECT j.season_id, lower(j.gpsl_month) AS gpsl_month, min(j.ran_at) AS locked_at
    FROM public.competition_season_calendar_jobs j
    WHERE j.season_id = v_season_id
      AND j.gpsl_month IS NOT NULL
      AND (j.job_key LIKE 'team_of_month:%' OR j.job_key LIKE 'gpsl_sport:%')
    GROUP BY j.season_id, lower(j.gpsl_month)
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
    AND (
      p_gpsl_months IS NULL
      OR lk.gpsl_month = ANY (
        SELECT lower(btrim(x)) FROM unnest(p_gpsl_months) x
      )
    )
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
      -- Only months that have actually locked
      AND EXISTS (
        SELECT 1
        FROM public.competition_season_calendar_jobs j
        WHERE j.season_id = v_season_id
          AND lower(j.gpsl_month) = b.gpsl_month
          AND (j.job_key LIKE 'team_of_month:%' OR j.job_key LIKE 'gpsl_sport:%')
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
    'debt_pct', v_debt_pct
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.admin_retro_monthly_interest_from_snapshots(bigint, boolean, text[])
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_retro_monthly_interest_from_snapshots(bigint, boolean, text[])
  TO authenticated;

NOTIFY pgrst, 'reload schema';

-- Dry-run first (no ledger writes)
SELECT public.admin_retro_monthly_interest_from_snapshots(NULL, true, NULL) AS dry_run_all_locked_months;

-- Optional: only June + July
-- SELECT public.admin_retro_monthly_interest_from_snapshots(NULL, true, ARRAY['june','july']);

-- Apply for real (uncomment after dry-run looks right):
-- SELECT public.admin_retro_monthly_interest_from_snapshots(NULL, false, NULL);

-- Or June + July only:
-- SELECT public.admin_retro_monthly_interest_from_snapshots(NULL, false, ARRAY['june','july']);

-- ---------------------------------------------------------------------------
-- 3) VERIFY — after apply: no missing interest on locked months; wipe = 0 rows
-- ---------------------------------------------------------------------------
WITH cur AS (
  SELECT id AS season_id
  FROM public.competition_seasons
  WHERE is_current = true
  ORDER BY id DESC
  LIMIT 1
),
locks AS (
  SELECT j.season_id, lower(j.gpsl_month) AS gpsl_month
  FROM public.competition_season_calendar_jobs j
  JOIN cur c ON c.season_id = j.season_id
  WHERE j.gpsl_month IS NOT NULL
    AND (j.job_key LIKE 'team_of_month:%' OR j.job_key LIKE 'gpsl_sport:%')
  GROUP BY j.season_id, lower(j.gpsl_month)
)
SELECT
  b.gpsl_month,
  b.club_short_name,
  b.balance AS month_end_balance,
  'MISSING'::text AS problem
FROM public.club_month_end_balances b
JOIN locks lk ON lk.season_id = b.season_id AND lk.gpsl_month = b.gpsl_month
WHERE b.balance <> 0
  AND NOT EXISTS (
    SELECT 1 FROM public.club_monthly_interest m
    WHERE m.season_id = b.season_id
      AND m.gpsl_month = b.gpsl_month
      AND m.club_short_name = b.club_short_name
  )
ORDER BY b.gpsl_month, b.club_short_name;
-- Expect 0 rows after successful apply.

-- Retro ledger lines summary
WITH cur AS (
  SELECT id AS season_id
  FROM public.competition_seasons
  WHERE is_current = true
  ORDER BY id DESC
  LIMIT 1
)
SELECT
  l.metadata->>'gpsl_month' AS gpsl_month,
  l.entry_type,
  count(*) AS rows,
  round(sum(l.amount), 0) AS total
FROM public.competition_finance_ledger l
JOIN cur c ON c.season_id = l.season_id
WHERE coalesce((l.metadata->>'retro')::boolean, false)
  AND coalesce((l.metadata->>'monthly')::boolean, false)
  AND l.entry_type IN ('eos_balance_interest', 'eos_debt_interest')
GROUP BY 1, 2
ORDER BY 1, 2;
