-- Bad-credit overdraft interest + post-recovery loan interest premium.
-- Settings on gpsl_bank_account (defaults below). Safe re-run.
--
-- While financial risk (same rules as loan refuse):
--   monthly overdraft interest uses monthly_debt_interest_bad_credit_pct
--   (default 1.00% vs normal 0.50%).
-- After clearing risk:
--   new loans use policy_interest_rate_pct + loan_interest_post_risk_premium_pct
--   for loan_post_risk_probation_seasons seasons (default +2.50% for 2 seasons).

ALTER TABLE public.gpsl_bank_account
  ADD COLUMN IF NOT EXISTS monthly_debt_interest_bad_credit_pct numeric(5, 2)
    NOT NULL DEFAULT 1.00,
  ADD COLUMN IF NOT EXISTS loan_interest_post_risk_premium_pct numeric(5, 2)
    NOT NULL DEFAULT 2.50,
  ADD COLUMN IF NOT EXISTS loan_post_risk_probation_seasons int
    NOT NULL DEFAULT 2;

COMMENT ON COLUMN public.gpsl_bank_account.monthly_debt_interest_bad_credit_pct IS
  'Monthly overdraft interest %% charged while the club is a financial risk (loan refuse).';
COMMENT ON COLUMN public.gpsl_bank_account.loan_interest_post_risk_premium_pct IS
  'Added to policy_interest_rate_pct on new loans during post-risk probation.';
COMMENT ON COLUMN public.gpsl_bank_account.loan_post_risk_probation_seasons IS
  'Seasons (including the clear season) that post-risk loan premium applies.';

UPDATE public.gpsl_bank_account
SET monthly_debt_interest_bad_credit_pct = coalesce(monthly_debt_interest_bad_credit_pct, 1.00),
    loan_interest_post_risk_premium_pct = coalesce(loan_interest_post_risk_premium_pct, 2.50),
    loan_post_risk_probation_seasons = greatest(coalesce(loan_post_risk_probation_seasons, 2), 0),
    updated_at = now()
WHERE id = 1;

-- ---------------------------------------------------------------------------
-- Probation tracking (cleared financial risk → higher loan rate for N seasons)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.club_credit_probation (
  club_short_name text PRIMARY KEY,
  was_at_risk boolean NOT NULL DEFAULT false,
  last_risk_at timestamptz,
  cleared_at timestamptz,
  probation_until_season_id bigint
    REFERENCES public.competition_seasons (id) ON DELETE SET NULL,
  updated_at timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.club_credit_probation IS
  'Tracks financial-risk → clear transitions for post-risk loan interest premium.';

ALTER TABLE public.club_credit_probation ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS club_credit_probation_select_own ON public.club_credit_probation;
CREATE POLICY club_credit_probation_select_own
  ON public.club_credit_probation
  FOR SELECT TO authenticated
  USING (
    club_short_name = public.my_club_shortname()
    OR public.is_gpsl_admin()
  );

GRANT SELECT ON public.club_credit_probation TO authenticated;
GRANT ALL ON public.club_credit_probation TO service_role;

CREATE OR REPLACE FUNCTION public.club_is_financial_risk(p_club text)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_risk jsonb;
BEGIN
  IF to_regprocedure('public.club_credit_risk_status(text)') IS NULL THEN
    RETURN false;
  END IF;
  v_risk := public.club_credit_risk_status(p_club);
  RETURN coalesce((v_risk->>'overdrawn_risk')::boolean, false)
      OR coalesce((v_risk->>'ffp_risk')::boolean, false)
      OR coalesce((v_risk->>'negative_seasons_risk')::boolean, false);
END;
$function$;

CREATE OR REPLACE FUNCTION public.club_credit_probation_sync(p_club text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := btrim(coalesce(p_club, ''));
  v_at_risk boolean;
  v_row public.club_credit_probation%rowtype;
  v_season_id bigint;
  v_prob_seasons int;
  v_until bigint;
BEGIN
  IF v_club = '' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_club');
  END IF;

  v_at_risk := public.club_is_financial_risk(v_club);

  SELECT * INTO v_row
  FROM public.club_credit_probation
  WHERE club_short_name = v_club;

  SELECT id INTO v_season_id
  FROM public.competition_seasons
  WHERE is_current = true
  ORDER BY id DESC
  LIMIT 1;

  SELECT greatest(coalesce(loan_post_risk_probation_seasons, 2), 0)
  INTO v_prob_seasons
  FROM public.gpsl_bank_account
  WHERE id = 1;

  IF v_at_risk THEN
    INSERT INTO public.club_credit_probation AS c (
      club_short_name, was_at_risk, last_risk_at, updated_at
    )
    VALUES (v_club, true, now(), now())
    ON CONFLICT (club_short_name) DO UPDATE
    SET was_at_risk = true,
        last_risk_at = now(),
        updated_at = now();

    RETURN jsonb_build_object('ok', true, 'at_risk', true, 'club', v_club);
  END IF;

  -- Cleared: if we were tracking risk (or just cleared), open / refresh probation
  IF v_row.club_short_name IS NULL THEN
    -- Never flagged — no probation
    RETURN jsonb_build_object('ok', true, 'at_risk', false, 'probation', false);
  END IF;

  IF coalesce(v_row.was_at_risk, false) THEN
    -- Fresh clear (or re-clear after another risk spell): restart probation clock
    v_until := CASE
      WHEN v_season_id IS NULL OR v_prob_seasons <= 0 THEN NULL
      ELSE v_season_id + (v_prob_seasons - 1)
    END;

    UPDATE public.club_credit_probation
    SET was_at_risk = false,
        cleared_at = now(),
        probation_until_season_id = v_until,
        updated_at = now()
    WHERE club_short_name = v_club
    RETURNING * INTO v_row;
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'at_risk', false,
    'probation', (
      v_season_id IS NOT NULL
      AND v_row.probation_until_season_id IS NOT NULL
      AND v_row.probation_until_season_id >= v_season_id
    ),
    'probation_until_season_id', v_row.probation_until_season_id,
    'club', v_club
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.club_loan_post_risk_active(p_club text)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := btrim(coalesce(p_club, ''));
  v_season_id bigint;
  v_until bigint;
BEGIN
  IF v_club = '' THEN
    RETURN false;
  END IF;
  IF public.club_is_financial_risk(v_club) THEN
    RETURN false;
  END IF;

  SELECT id INTO v_season_id
  FROM public.competition_seasons
  WHERE is_current = true
  ORDER BY id DESC
  LIMIT 1;

  SELECT probation_until_season_id INTO v_until
  FROM public.club_credit_probation
  WHERE club_short_name = v_club;

  RETURN v_season_id IS NOT NULL
     AND v_until IS NOT NULL
     AND v_until >= v_season_id;
END;
$function$;

CREATE OR REPLACE FUNCTION public.club_loan_effective_interest_rate(p_club text)
RETURNS numeric
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_base numeric;
  v_premium numeric;
BEGIN
  SELECT coalesce(policy_interest_rate_pct, 5),
         greatest(coalesce(loan_interest_post_risk_premium_pct, 0), 0)
  INTO v_base, v_premium
  FROM public.gpsl_bank_account
  WHERE id = 1;

  IF public.club_loan_post_risk_active(p_club) THEN
    RETURN v_base + v_premium;
  END IF;
  RETURN v_base;
END;
$function$;

CREATE OR REPLACE FUNCTION public.club_monthly_debt_interest_rate(p_club text)
RETURNS numeric
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_normal numeric;
  v_bad numeric;
BEGIN
  SELECT greatest(coalesce(monthly_debt_interest_pct, 0.50), 0),
         greatest(coalesce(monthly_debt_interest_bad_credit_pct, 1.00), 0)
  INTO v_normal, v_bad
  FROM public.gpsl_bank_account
  WHERE id = 1;

  IF public.club_is_financial_risk(p_club) THEN
    RETURN greatest(v_bad, v_normal);
  END IF;
  RETURN v_normal;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.club_is_financial_risk(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.club_credit_probation_sync(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.club_loan_post_risk_active(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.club_loan_effective_interest_rate(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.club_monthly_debt_interest_rate(text) TO authenticated;

-- ---------------------------------------------------------------------------
-- Month-lock: sync probation for all season clubs
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.club_credit_probation_tick(p_season_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_n int := 0;
  r record;
BEGIN
  IF p_season_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'season_id required');
  END IF;

  FOR r IN
    SELECT ccs.club_short_name
    FROM public.competition_club_seasons ccs
    WHERE ccs.season_id = p_season_id
  LOOP
    PERFORM public.club_credit_probation_sync(r.club_short_name);
    v_n := v_n + 1;
  END LOOP;

  RETURN jsonb_build_object('ok', true, 'clubs', v_n);
END;
$function$;

REVOKE ALL ON FUNCTION public.club_credit_probation_tick(bigint) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.club_credit_probation_tick(bigint) TO service_role;

DO $wire$
DECLARE
  v_def text;
  v_marker text := 'club_credit_probation_tick';
  v_old text := E'  RETURN v_out;\nEND;';
  v_new text;
BEGIN
  IF to_regprocedure('public.competition_run_month_lock_jobs(bigint,boolean,text,text)') IS NULL THEN
    RAISE WARNING 'month-lock jobs missing — credit probation tick not wired';
    RETURN;
  END IF;

  SELECT pg_get_functiondef(
    'public.competition_run_month_lock_jobs(bigint,boolean,text,text)'::regprocedure
  ) INTO v_def;

  IF position(v_marker IN v_def) > 0 THEN
    RAISE NOTICE 'Credit probation tick already wired';
    RETURN;
  END IF;

  IF position(v_old IN v_def) = 0 THEN
    RAISE WARNING 'Could not find RETURN v_out in month-lock jobs — probation tick not wired';
    RETURN;
  END IF;

  v_new :=
    E'  BEGIN\n'
    || E'    IF to_regprocedure(''public.club_credit_probation_tick(bigint)'') IS NOT NULL THEN\n'
    || E'      v_out := v_out || jsonb_build_object(\n'
    || E'        ''credit_probation'',\n'
    || E'        public.club_credit_probation_tick(p_season_id)\n'
    || E'      );\n'
    || E'    END IF;\n'
    || E'  EXCEPTION\n'
    || E'    WHEN OTHERS THEN\n'
    || E'      v_out := v_out || jsonb_build_object(\n'
    || E'        ''credit_probation'',\n'
    || E'        jsonb_build_object(''ok'', false, ''error'', SQLERRM)\n'
    || E'      );\n'
    || E'  END;\n'
    || E'\n'
    || E'  RETURN v_out;\n'
    || E'END;';

  EXECUTE replace(v_def, v_old, v_new);
  RAISE NOTICE 'Wired credit probation tick into competition_run_month_lock_jobs';
EXCEPTION
  WHEN OTHERS THEN
    RAISE WARNING 'Credit probation wire failed: %', SQLERRM;
END;
$wire$;

-- ---------------------------------------------------------------------------
-- Monthly interest: per-club debt rate when at financial risk
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
  v_debt_pct_club numeric;
  v_amount numeric;
  v_credit_clubs int := 0;
  v_debt_clubs int := 0;
  v_bad_debt_clubs int := 0;
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
      BEGIN
        v_debt_pct_club := public.club_monthly_debt_interest_rate(r.club);
      EXCEPTION WHEN OTHERS THEN
        v_debt_pct_club := v_debt_pct;
      END;

      v_amount := round(abs(r.balance) * v_debt_pct_club / 100.0, 0);
      CONTINUE WHEN v_amount <= 0;

      PERFORM public.post_club_ledger(
        r.club,
        'eos_debt_interest',
        -v_amount,
        format('%s overdraft interest — %s%% on ₿%s overdrawn%s',
               v_label, to_char(v_debt_pct_club, 'FM990.00'),
               to_char(abs(r.balance), 'FM999,999,999,999'),
               CASE WHEN v_debt_pct_club > v_debt_pct
                 THEN ' (bad credit rate)' ELSE '' END),
        jsonb_build_object(
          'monthly', true,
          'gpsl_month', v_month,
          'rate_pct', v_debt_pct_club,
          'base_rate_pct', v_debt_pct,
          'bad_credit_rate', v_debt_pct_club > v_debt_pct,
          'balance_snapshot', r.balance
        ),
        p_season_id,
        NULL,
        public.finance_entry_via_central_bank('eos_debt_interest'),
        true
      );

      INSERT INTO public.club_monthly_interest (
        season_id, gpsl_month, club_short_name, kind, rate_pct, balance_snapshot, amount
      )
      VALUES (p_season_id, v_month, r.club, 'debt', v_debt_pct_club, r.balance, -v_amount);
      v_debt_clubs := v_debt_clubs + 1;
      IF v_debt_pct_club > v_debt_pct THEN
        v_bad_debt_clubs := v_bad_debt_clubs + 1;
      END IF;
    END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true,
    'gpsl_month', v_month,
    'balance_interest_clubs', v_credit_clubs,
    'debt_interest_clubs', v_debt_clubs,
    'bad_credit_debt_interest_clubs', v_bad_debt_clubs
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.competition_post_monthly_interest(bigint, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.competition_post_monthly_interest(bigint, text) TO service_role;

-- ---------------------------------------------------------------------------
-- Loan take: post-risk premium on rate
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.club_take_loan(p_amount numeric)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := public.my_club_shortname();
  v_amount numeric;
  v_season_id bigint;
  v_bank record;
  v_outstanding numeric;
  v_active int;
  v_loan_id bigint;
  v_ledger_id bigint;
  v_desc text;
  v_drawdown_month text;
  v_months smallint := 20;
  v_rate numeric;
  v_base_rate numeric;
  v_credit jsonb;
  v_post_risk boolean := false;
BEGIN
  IF v_club IS NULL OR v_club = '' THEN
    RAISE EXCEPTION 'No club linked to your account';
  END IF;

  IF to_regprocedure('public.club_loan_credit_check(text)') IS NOT NULL THEN
    v_credit := public.club_loan_credit_check(v_club);
    IF NOT coalesce((v_credit->>'ok')::boolean, false) THEN
      RAISE EXCEPTION '%', coalesce(
        v_credit->>'message',
        'Application declined. Unfavourable creditworthiness report.'
      );
    END IF;
  END IF;

  v_amount := round(coalesce(p_amount, 0)::numeric, 2);
  IF v_amount <= 0 THEN
    RAISE EXCEPTION 'Loan amount must be positive';
  END IF;

  IF to_regprocedure('public.competition_finances_current_season_id()') IS NOT NULL THEN
    v_season_id := public.competition_finances_current_season_id();
  END IF;

  IF v_season_id IS NULL THEN
    SELECT id INTO v_season_id
    FROM public.competition_seasons
    WHERE is_current = true
      AND status IN ('active', 'preseason')
    ORDER BY CASE status WHEN 'active' THEN 0 ELSE 1 END, id DESC
    LIMIT 1;
  END IF;

  IF v_season_id IS NULL THEN
    RAISE EXCEPTION 'No active competition season';
  END IF;

  v_drawdown_month := public.club_loan_normalize_drawdown_month(
    public.competition_active_gpsl_month(v_season_id, now())
  );

  SELECT
    loans_enabled,
    loan_min_drawdown,
    loan_max_drawdown,
    loan_max_outstanding_per_club,
    policy_interest_rate_pct,
    loan_interest_post_risk_premium_pct,
    loan_post_risk_probation_seasons
  INTO v_bank
  FROM public.gpsl_bank_account
  WHERE id = 1
  FOR UPDATE;

  IF NOT coalesce(v_bank.loans_enabled, false) THEN
    RAISE EXCEPTION 'Bank loans are currently disabled';
  END IF;

  SELECT count(*)::int INTO v_active
  FROM public.club_loans l
  WHERE l.club_short_name = v_club AND l.status = 'active';

  IF v_active >= public.club_loan_max_active() THEN
    RAISE EXCEPTION
      'Maximum % active loans. Pay off one of your loans before taking another.',
      public.club_loan_max_active();
  END IF;

  IF v_amount < v_bank.loan_min_drawdown THEN
    RAISE EXCEPTION 'Minimum loan is %', v_bank.loan_min_drawdown;
  END IF;

  IF v_amount > v_bank.loan_max_drawdown THEN
    RAISE EXCEPTION 'Maximum per loan is %', v_bank.loan_max_drawdown;
  END IF;

  v_outstanding := public.club_loan_outstanding_for(v_club);

  IF v_outstanding + v_amount > v_bank.loan_max_outstanding_per_club THEN
    RAISE EXCEPTION 'Would exceed max outstanding loan (%) for your club',
      v_bank.loan_max_outstanding_per_club;
  END IF;

  PERFORM public.club_credit_probation_sync(v_club);

  v_base_rate := v_bank.policy_interest_rate_pct;
  v_post_risk := public.club_loan_post_risk_active(v_club);
  v_rate := CASE
    WHEN v_post_risk THEN
      v_base_rate + greatest(coalesce(v_bank.loan_interest_post_risk_premium_pct, 0), 0)
    ELSE v_base_rate
  END;

  INSERT INTO public.club_loans (
    club_short_name,
    season_id,
    principal_drawn,
    outstanding_principal,
    interest_rate_pct,
    status,
    repayment_months,
    drawdown_gpsl_month,
    installments_paid
  )
  VALUES (
    v_club,
    v_season_id,
    v_amount,
    v_amount,
    v_rate,
    'active',
    v_months,
    v_drawdown_month,
    0
  )
  RETURNING id INTO v_loan_id;

  PERFORM public.club_loan_generate_installments(
    v_loan_id,
    v_amount,
    v_season_id,
    v_drawdown_month,
    v_months,
    v_rate
  );

  v_desc := format(
    'Central bank loan drawdown (loan #%s) — %s GPSL months from %s at %s%% p.a.%s',
    v_loan_id,
    v_months,
    public.competition_gpsl_month_label(v_drawdown_month),
    trim(to_char(v_rate, 'FM999990.00')),
    CASE WHEN v_post_risk THEN ' (post-risk premium)' ELSE '' END
  );

  v_ledger_id := public.post_club_ledger(
    v_club,
    'loan_drawdown',
    v_amount,
    v_desc,
    jsonb_build_object(
      'loan_id', v_loan_id,
      'repayment_months', v_months,
      'interest_rate_pct', v_rate,
      'base_interest_rate_pct', v_base_rate,
      'post_risk_premium', v_post_risk,
      'drawdown_gpsl_month', v_drawdown_month
    ),
    v_season_id,
    NULL,
    true,
    true
  );

  UPDATE public.gpsl_bank_account
  SET loan_book_outstanding = loan_book_outstanding + v_amount,
      updated_at = now()
  WHERE id = 1;

  RETURN v_loan_id;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.club_take_loan(numeric) TO authenticated;

-- ---------------------------------------------------------------------------
-- Credit check: expose effective loan rate + probation
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.club_loan_credit_check(p_club text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := coalesce(nullif(btrim(p_club), ''), public.my_club_shortname());
  v_risk jsonb;
  v_reasons text[] := ARRAY[]::text[];
  v_ffp_labels text;
  v_rate numeric;
  v_base numeric;
  v_premium numeric;
  v_post_risk boolean := false;
  v_until bigint;
BEGIN
  IF v_club IS NULL OR v_club = '' THEN
    RETURN jsonb_build_object(
      'ok', false,
      'negative_seasons', 0,
      'message', 'No club linked to your account.'
    );
  END IF;

  IF p_club IS NOT NULL
     AND btrim(p_club) <> ''
     AND btrim(p_club) IS DISTINCT FROM public.my_club_shortname()
     AND NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Not your club';
  END IF;

  v_risk := public.club_credit_risk_status(v_club);

  IF (v_risk->>'overdrawn_risk')::boolean THEN
    v_reasons := v_reasons || format(
      'overdrawn at each of the last %s month-end check-ins — loans return once a month-end check-in shows the club in credit',
      v_risk->>'overdrawn_month_ends_limit'
    );
  END IF;

  IF (v_risk->>'ffp_risk')::boolean THEN
    SELECT string_agg(coalesce(x->>'season_label', 'season ' || (x->>'season_id')), ', ')
    INTO v_ffp_labels
    FROM jsonb_array_elements(v_risk->'ffp_seasons') x;
    v_reasons := v_reasons || format(
      'FFP penalty in %s — FFP penalties count against the club for %s seasons',
      v_ffp_labels,
      v_risk->>'ffp_lookback_seasons'
    );
  END IF;

  IF (v_risk->>'negative_seasons_risk')::boolean THEN
    v_reasons := v_reasons || 'overdrawn at the end of two seasons'::text;
  END IF;

  SELECT coalesce(policy_interest_rate_pct, 5),
         greatest(coalesce(loan_interest_post_risk_premium_pct, 0), 0)
  INTO v_base, v_premium
  FROM public.gpsl_bank_account
  WHERE id = 1;

  IF cardinality(v_reasons) = 0 THEN
    PERFORM public.club_credit_probation_sync(v_club);
    v_post_risk := public.club_loan_post_risk_active(v_club);
    v_rate := CASE WHEN v_post_risk THEN v_base + v_premium ELSE v_base END;

    SELECT probation_until_season_id INTO v_until
    FROM public.club_credit_probation
    WHERE club_short_name = v_club;

    RETURN jsonb_build_object(
      'ok', true,
      'negative_seasons', (v_risk->>'negative_seasons')::int,
      'overdrawn_month_ends', (v_risk->>'overdrawn_month_ends')::int,
      'ffp_seasons', v_risk->'ffp_seasons',
      'interest_rate_pct', v_rate,
      'policy_interest_rate_pct', v_base,
      'post_risk_premium', v_post_risk,
      'post_risk_premium_pct', CASE WHEN v_post_risk THEN v_premium ELSE 0 END,
      'probation_until_season_id', v_until,
      'message', NULL
    );
  END IF;

  -- Still at risk: keep probation row marked so clear starts the clock later
  PERFORM public.club_credit_probation_sync(v_club);

  RETURN jsonb_build_object(
    'ok', false,
    'financial_risk', true,
    'negative_seasons', (v_risk->>'negative_seasons')::int,
    'overdrawn_month_ends', (v_risk->>'overdrawn_month_ends')::int,
    'ffp_seasons', v_risk->'ffp_seasons',
    'reasons', to_jsonb(v_reasons),
    'monthly_debt_interest_pct', public.club_monthly_debt_interest_rate(v_club),
    'message',
      'Application declined. The bank manager checked the club''s creditworthiness: the club is rated a financial risk and is not creditworthy ('
      || array_to_string(v_reasons, '; ')
      || '). No loans until the club is clean on all counts. Overdraft interest is charged at the bad-credit rate while this applies.'
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.club_loan_credit_check(text) TO authenticated;

-- Public bank view: expose new settings
DROP VIEW IF EXISTS public.gpsl_bank_public;
CREATE VIEW public.gpsl_bank_public
WITH (security_invoker = false)
AS
SELECT
  display_name,
  reserves,
  loan_book_outstanding,
  policy_interest_rate_pct,
  monthly_debt_interest_pct,
  monthly_debt_interest_bad_credit_pct,
  loan_interest_post_risk_premium_pct,
  loan_post_risk_probation_seasons,
  loans_enabled,
  loan_min_drawdown,
  loan_max_drawdown,
  loan_max_outstanding_per_club,
  updated_at
FROM public.gpsl_bank_account
WHERE id = 1;

GRANT SELECT ON public.gpsl_bank_public TO authenticated;
GRANT SELECT ON public.gpsl_bank_public TO anon;

NOTIFY pgrst, 'reload schema';
