-- =============================================================================
-- Monthly balance interest + overdraft (debt) interest (2026-10-12)
-- =============================================================================
-- Replaces the once-a-season interest at Close Finances with interest at every
-- GPSL month-end check-in (month lock):
--   * positive balance: +0.25% a month (paid by the central bank)
--   * overdrawn balance: −0.5% a month on the overdraft (to the central bank)
-- Rates live on gpsl_bank_account (monthly_balance_interest_pct /
-- monthly_debt_interest_pct). gpsl_bank_account.monthly_interest_enabled = true
-- switches the end-of-season balance + debt interest off (FFP unchanged).
-- Ledger rows reuse the eos_balance_interest / eos_debt_interest entry types
-- (metadata.monthly = true) so Finances pages group them as before.
-- One payment per club per GPSL month (club_monthly_interest). Safe re-run.
-- =============================================================================

ALTER TABLE public.gpsl_bank_account
  ADD COLUMN IF NOT EXISTS monthly_interest_enabled boolean NOT NULL DEFAULT true,
  ADD COLUMN IF NOT EXISTS monthly_balance_interest_pct numeric(5, 2) NOT NULL DEFAULT 0.25,
  ADD COLUMN IF NOT EXISTS monthly_debt_interest_pct numeric(5, 2) NOT NULL DEFAULT 0.50;

COMMENT ON COLUMN public.gpsl_bank_account.monthly_interest_enabled IS
  'true = balance/debt interest at each GPSL month lock; end-of-season balance/debt interest skipped.';

CREATE TABLE IF NOT EXISTS public.club_monthly_interest (
  season_id bigint NOT NULL REFERENCES public.competition_seasons (id) ON DELETE CASCADE,
  gpsl_month text NOT NULL,
  club_short_name text NOT NULL,
  kind text NOT NULL CHECK (kind IN ('balance', 'debt')),
  rate_pct numeric(5, 2) NOT NULL,
  balance_snapshot numeric(14, 2) NOT NULL,
  amount numeric(14, 2) NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (season_id, gpsl_month, club_short_name)
);

ALTER TABLE public.club_monthly_interest ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS club_monthly_interest_admin_select ON public.club_monthly_interest;
CREATE POLICY club_monthly_interest_admin_select
  ON public.club_monthly_interest
  FOR SELECT TO authenticated
  USING (public.is_gpsl_admin());

GRANT SELECT ON public.club_monthly_interest TO authenticated;
GRANT ALL ON public.club_monthly_interest TO service_role;

-- ---------------------------------------------------------------------------
-- Post one GPSL month's interest for every league club this season
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.competition_post_monthly_interest(
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
  v_label text;
  v_enabled boolean;
  v_credit_pct numeric;
  v_debt_pct numeric;
  v_amount numeric;
  v_credit_clubs int := 0;
  v_debt_clubs int := 0;
  r record;
BEGIN
  IF p_season_id IS NULL OR v_month = '' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'season_id and gpsl_month required');
  END IF;

  SELECT b.monthly_interest_enabled,
         greatest(coalesce(b.monthly_balance_interest_pct, 0), 0),
         greatest(coalesce(b.monthly_debt_interest_pct, 0), 0)
  INTO v_enabled, v_credit_pct, v_debt_pct
  FROM public.gpsl_bank_account b
  WHERE b.id = 1;

  IF NOT coalesce(v_enabled, false) THEN
    RETURN jsonb_build_object('ok', true, 'skipped', 'monthly_interest_disabled');
  END IF;

  BEGIN
    v_label := public.competition_gpsl_month_label(v_month);
  EXCEPTION WHEN OTHERS THEN
    v_label := initcap(v_month);
  END;

  FOR r IN
    SELECT f.club_name AS club, coalesce(f.balance, 0) AS balance
    FROM public."Club_Finances" f
    JOIN public.competition_club_seasons ccs
      ON ccs.club_short_name = f.club_name
     AND ccs.season_id = p_season_id
    WHERE f.club_name <> 'FOREIGN'
      AND coalesce(f.balance, 0) <> 0
      AND NOT EXISTS (
        SELECT 1 FROM public.club_monthly_interest m
        WHERE m.season_id = p_season_id
          AND m.gpsl_month = v_month
          AND m.club_short_name = f.club_name
      )
  LOOP
    IF r.balance > 0 THEN
      v_amount := round(r.balance * v_credit_pct / 100.0, 0);
      CONTINUE WHEN v_amount <= 0;

      PERFORM public.post_club_ledger(
        r.club,
        'eos_balance_interest',
        v_amount,
        format('%s balance interest — %s%% on ₿%s',
               v_label, to_char(v_credit_pct, 'FM990.00'),
               to_char(r.balance, 'FM999,999,999,999')),
        jsonb_build_object('monthly', true, 'gpsl_month', v_month,
                           'rate_pct', v_credit_pct, 'balance_snapshot', r.balance),
        p_season_id,
        NULL,
        true,
        true
      );

      INSERT INTO public.club_monthly_interest (
        season_id, gpsl_month, club_short_name, kind, rate_pct, balance_snapshot, amount
      )
      VALUES (p_season_id, v_month, r.club, 'balance', v_credit_pct, r.balance, v_amount);
      v_credit_clubs := v_credit_clubs + 1;
    ELSE
      v_amount := round(abs(r.balance) * v_debt_pct / 100.0, 0);
      CONTINUE WHEN v_amount <= 0;

      PERFORM public.post_club_ledger(
        r.club,
        'eos_debt_interest',
        -v_amount,
        format('%s overdraft interest — %s%% on ₿%s overdrawn',
               v_label, to_char(v_debt_pct, 'FM990.00'),
               to_char(abs(r.balance), 'FM999,999,999,999')),
        jsonb_build_object('monthly', true, 'gpsl_month', v_month,
                           'rate_pct', v_debt_pct, 'balance_snapshot', r.balance),
        p_season_id,
        NULL,
        public.finance_entry_via_central_bank('eos_debt_interest'),
        true
      );

      INSERT INTO public.club_monthly_interest (
        season_id, gpsl_month, club_short_name, kind, rate_pct, balance_snapshot, amount
      )
      VALUES (p_season_id, v_month, r.club, 'debt', v_debt_pct, r.balance, -v_amount);
      v_debt_clubs := v_debt_clubs + 1;
    END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true,
    'gpsl_month', v_month,
    'balance_interest_clubs', v_credit_clubs,
    'debt_interest_clubs', v_debt_clubs
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.competition_post_monthly_interest(bigint, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.competition_post_monthly_interest(bigint, text) TO service_role;

-- Admin: post a month by hand (catch-up / missed lock)
CREATE OR REPLACE FUNCTION public.admin_post_monthly_interest(
  p_gpsl_month text,
  p_season_id bigint DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season_id bigint := p_season_id;
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
  RETURN public.competition_post_monthly_interest(v_season_id, p_gpsl_month);
END;
$function$;

REVOKE ALL ON FUNCTION public.admin_post_monthly_interest(text, bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_post_monthly_interest(text, bigint) TO authenticated;

-- ---------------------------------------------------------------------------
-- Wire into month-lock jobs (after month-end balance snapshot if wired)
-- ---------------------------------------------------------------------------
DO $wire$
DECLARE
  v_def text;
  v_marker text := 'competition_post_monthly_interest';
  v_old text := E'  RETURN v_out;\nEND;';
  v_new text;
BEGIN
  IF to_regprocedure('public.competition_run_month_lock_jobs(bigint,boolean,text,text)') IS NULL THEN
    RAISE WARNING 'competition_run_month_lock_jobs(4-arg) missing — monthly interest not wired';
    RETURN;
  END IF;

  SELECT pg_get_functiondef(
    'public.competition_run_month_lock_jobs(bigint,boolean,text,text)'::regprocedure
  ) INTO v_def;

  IF position(v_marker IN v_def) > 0 THEN
    RAISE NOTICE 'Monthly interest already wired';
    RETURN;
  END IF;

  IF position(v_old IN v_def) = 0 THEN
    RAISE WARNING 'Could not find RETURN v_out in month-lock jobs — monthly interest not wired';
    RETURN;
  END IF;

  v_new :=
    E'  -- Monthly balance / overdraft interest\n'
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

  EXECUTE replace(v_def, v_old, v_new);
  RAISE NOTICE 'Wired monthly interest into competition_run_month_lock_jobs';
EXCEPTION
  WHEN OTHERS THEN
    RAISE WARNING 'Monthly interest wire failed: %', SQLERRM;
END;
$wire$;

-- ---------------------------------------------------------------------------
-- End-of-season balance / debt interest: skipped while monthly is on
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.competition_post_eos_balance_interest(p_season_id bigint)
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club record;
  v_interest numeric;
  v_paid int := 0;
  v_rate constant numeric := 0.005;
BEGIN
  IF p_season_id IS NULL THEN
    RETURN 0;
  END IF;

  IF coalesce((SELECT b.monthly_interest_enabled FROM public.gpsl_bank_account b WHERE b.id = 1), false) THEN
    RETURN 0;
  END IF;

  FOR v_club IN
    SELECT f.club_name AS club_short_name, f.balance
    FROM public."Club_Finances" f
    WHERE f.balance > 0
      AND f.club_name <> 'FOREIGN'
  LOOP
    IF EXISTS (
      SELECT 1 FROM public.competition_season_charge_paid
      WHERE season_id = p_season_id
        AND club_short_name = v_club.club_short_name
        AND charge_type = 'eos_balance_interest'
    ) THEN
      CONTINUE;
    END IF;

    v_interest := round(v_club.balance * v_rate, 0);
    IF v_interest <= 0 THEN
      CONTINUE;
    END IF;

    PERFORM public.post_club_ledger(
      v_club.club_short_name,
      'eos_balance_interest',
      v_interest,
      format(
        'End of season balance interest — 0.5%% on ₿%s',
        to_char(v_club.balance, 'FM999,999,999,999')
      ),
      jsonb_build_object(
        'balance_snapshot', v_club.balance,
        'rate_pct', v_rate * 100
      ),
      p_season_id,
      NULL,
      true,
      true
    );

    INSERT INTO public.competition_season_charge_paid (
      season_id, club_short_name, charge_type, amount, metadata
    )
    VALUES (
      p_season_id,
      v_club.club_short_name,
      'eos_balance_interest',
      v_interest,
      jsonb_build_object('balance_snapshot', v_club.balance)
    );

    v_paid := v_paid + 1;
  END LOOP;

  RETURN v_paid;
END;
$function$;

CREATE OR REPLACE FUNCTION public.competition_post_eos_debt_interest(p_season_id bigint)
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club record;
  v_interest numeric;
  v_paid int := 0;
  v_rate_pct numeric;
  v_debt numeric;
BEGIN
  IF p_season_id IS NULL THEN
    RETURN 0;
  END IF;

  IF coalesce((SELECT b.monthly_interest_enabled FROM public.gpsl_bank_account b WHERE b.id = 1), false) THEN
    RETURN 0;
  END IF;

  SELECT coalesce(nullif(b.eos_debt_interest_pct, 0), b.policy_interest_rate_pct, 5.00)
  INTO v_rate_pct
  FROM public.gpsl_bank_account b
  WHERE b.id = 1;

  v_rate_pct := greatest(coalesce(v_rate_pct, 5.00), 0);

  FOR v_club IN
    SELECT f.club_name AS club_short_name, f.balance
    FROM public."Club_Finances" f
    JOIN public.competition_club_seasons ccs
      ON ccs.club_short_name = f.club_name
     AND ccs.season_id = p_season_id
     AND ccs.division IN ('superleague', 'championship_a', 'championship_b')
    WHERE f.balance < 0
      AND f.club_name <> 'FOREIGN'
  LOOP
    IF EXISTS (
      SELECT 1 FROM public.competition_season_charge_paid
      WHERE season_id = p_season_id
        AND club_short_name = v_club.club_short_name
        AND charge_type = 'eos_debt_interest'
    ) THEN
      CONTINUE;
    END IF;

    v_debt := abs(v_club.balance);
    v_interest := round(v_debt * v_rate_pct / 100.0, 0);
    IF v_interest <= 0 THEN
      CONTINUE;
    END IF;

    IF public.competition_post_club_charge(
      p_season_id,
      v_club.club_short_name,
      'eos_debt_interest',
      v_interest,
      format(
        'End of season debt interest — %s%% on overdraft ₿%s',
        to_char(v_rate_pct, 'FM999990.###'),
        to_char(v_debt, 'FM999,999,999,999')
      ),
      jsonb_build_object(
        'balance_snapshot', v_club.balance,
        'rate_pct', v_rate_pct
      )
    ) THEN
      v_paid := v_paid + 1;
    END IF;
  END LOOP;

  RETURN v_paid;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_post_eos_balance_interest(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.competition_post_eos_debt_interest(bigint) TO authenticated;

-- Season Review forecast: no end-of-season debt interest while monthly is on
DO $sr$
DECLARE
  v_def text;
  v_old text := 'coalesce(nullif(b.eos_debt_interest_pct, 0), nullif(b.policy_interest_rate_pct, 0), 5),';
  v_new text := 'CASE WHEN coalesce(b.monthly_interest_enabled, false) THEN 0 ELSE coalesce(nullif(b.eos_debt_interest_pct, 0), nullif(b.policy_interest_rate_pct, 0), 5) END,';
BEGIN
  IF to_regprocedure('public.season_review_board()') IS NULL THEN
    RETURN;
  END IF;
  SELECT pg_get_functiondef('public.season_review_board()'::regprocedure) INTO v_def;
  IF position('monthly_interest_enabled' IN v_def) > 0 THEN
    RETURN;
  END IF;
  IF position(v_old IN v_def) = 0 THEN
    RAISE WARNING 'season_review_board: debt rate line not found — forecast still shows end-of-season debt interest';
    RETURN;
  END IF;
  EXECUTE replace(v_def, v_old, v_new);
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING 'season_review_board patch failed: %', SQLERRM;
END;
$sr$;

NOTIFY pgrst, 'reload schema';

SELECT
  b.monthly_interest_enabled,
  b.monthly_balance_interest_pct AS monthly_credit_pct,
  b.monthly_debt_interest_pct AS monthly_overdraft_pct,
  position('competition_post_monthly_interest' IN pg_get_functiondef(
    'public.competition_run_month_lock_jobs(bigint,boolean,text,text)'::regprocedure
  )) > 0 AS month_lock_wired,
  position('monthly_interest_enabled' IN pg_get_functiondef(
    'public.season_review_board()'::regprocedure
  )) > 0 AS season_review_forecast_updated,
  (SELECT count(*) FROM public.club_monthly_interest) AS monthly_interest_rows
FROM public.gpsl_bank_account b
WHERE b.id = 1;
