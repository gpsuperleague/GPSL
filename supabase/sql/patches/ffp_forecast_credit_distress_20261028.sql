-- =============================================================================
-- Soft credit distress from FFP-territory EOS forecast (2026-10-28)
-- =============================================================================
-- If a club's predicted end-of-season balance is at/below −eos_ffp_debt_threshold
-- (default −₿100M), credit rating steps down slightly and mild interest premiums
-- apply — but loans are NOT refused (unlike hard financial risk).
--
-- Forecast source (first hit):
--   1) club_finance_eos_forecast (published from Finances / season review)
--   2) season_review_finance_snapshot.pre_close (admin board publish)
--   3) live Club_Finances.balance
--
-- Defaults:
--   loan +1.00% on policy (e.g. 5% → 6%)
--   monthly overdraft 0.75% (between normal 0.50% and bad-credit 1.00%)
-- Safe re-run.
-- =============================================================================

ALTER TABLE public.gpsl_bank_account
  ADD COLUMN IF NOT EXISTS loan_interest_ffp_forecast_premium_pct numeric(5, 2)
    NOT NULL DEFAULT 1.00,
  ADD COLUMN IF NOT EXISTS monthly_debt_interest_ffp_forecast_pct numeric(5, 2)
    NOT NULL DEFAULT 0.75;

COMMENT ON COLUMN public.gpsl_bank_account.loan_interest_ffp_forecast_premium_pct IS
  'Added to policy_interest_rate_pct on new loans while EOS forecast is in FFP territory (soft distress).';
COMMENT ON COLUMN public.gpsl_bank_account.monthly_debt_interest_ffp_forecast_pct IS
  'Monthly overdraft interest %% while EOS forecast is in FFP territory (soft; below bad-credit rate).';

UPDATE public.gpsl_bank_account
SET loan_interest_ffp_forecast_premium_pct =
      coalesce(loan_interest_ffp_forecast_premium_pct, 1.00),
    monthly_debt_interest_ffp_forecast_pct =
      coalesce(monthly_debt_interest_ffp_forecast_pct, 0.75),
    updated_at = now()
WHERE id = 1;

-- ---------------------------------------------------------------------------
-- Per-club published EOS forecast (Finances page / season review)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.club_finance_eos_forecast (
  season_id bigint NOT NULL REFERENCES public.competition_seasons (id) ON DELETE CASCADE,
  club_short_name text NOT NULL,
  projected_balance numeric(16, 2) NOT NULL,
  source text NOT NULL DEFAULT 'finances',
  updated_at timestamptz NOT NULL DEFAULT now(),
  updated_by uuid,
  PRIMARY KEY (season_id, club_short_name)
);

CREATE INDEX IF NOT EXISTS club_finance_eos_forecast_club_idx
  ON public.club_finance_eos_forecast (club_short_name, season_id DESC);

COMMENT ON TABLE public.club_finance_eos_forecast IS
  'Latest predicted end-of-season balance per club (soft FFP credit distress).';

ALTER TABLE public.club_finance_eos_forecast ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS club_finance_eos_forecast_select_own ON public.club_finance_eos_forecast;
CREATE POLICY club_finance_eos_forecast_select_own
  ON public.club_finance_eos_forecast
  FOR SELECT TO authenticated
  USING (
    club_short_name = public.my_club_shortname()
    OR public.is_gpsl_admin()
  );

GRANT SELECT ON public.club_finance_eos_forecast TO authenticated;
GRANT ALL ON public.club_finance_eos_forecast TO service_role;

-- Owner (own club) / admin: publish predicted EOS balance from Finances UI
CREATE OR REPLACE FUNCTION public.club_publish_eos_forecast(
  p_projected_balance numeric,
  p_club text DEFAULT NULL,
  p_source text DEFAULT 'finances'
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := upper(btrim(coalesce(
    nullif(btrim(p_club), ''),
    public.my_club_shortname(),
    ''
  )));
  v_mine text := upper(btrim(coalesce(public.my_club_shortname(), '')));
  v_season_id bigint;
  v_source text := lower(btrim(coalesce(nullif(btrim(p_source), ''), 'finances')));
BEGIN
  IF v_club = '' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'no_club');
  END IF;

  IF auth.uid() IS NOT NULL
     AND v_club IS DISTINCT FROM v_mine
     AND NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Not your club';
  END IF;

  IF p_projected_balance IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'projected_balance required');
  END IF;

  SELECT id INTO v_season_id
  FROM public.competition_seasons
  WHERE is_current = true
  ORDER BY id DESC
  LIMIT 1;

  IF v_season_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'no_season');
  END IF;

  INSERT INTO public.club_finance_eos_forecast (
    season_id, club_short_name, projected_balance, source, updated_at, updated_by
  )
  VALUES (
    v_season_id, v_club, round(p_projected_balance, 2), v_source, now(), auth.uid()
  )
  ON CONFLICT (season_id, club_short_name) DO UPDATE SET
    projected_balance = excluded.projected_balance,
    source = excluded.source,
    updated_at = excluded.updated_at,
    updated_by = excluded.updated_by;

  RETURN jsonb_build_object(
    'ok', true,
    'season_id', v_season_id,
    'club', v_club,
    'projected_balance', round(p_projected_balance, 2),
    'source', v_source
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.club_publish_eos_forecast(numeric, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.club_publish_eos_forecast(numeric, text, text) TO authenticated;

-- ---------------------------------------------------------------------------
-- Resolve projected EOS + soft distress flag
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.club_ffp_forecast_status(p_club text)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := upper(btrim(coalesce(p_club, '')));
  v_mine text := upper(btrim(coalesce(public.my_club_shortname(), '')));
  v_season_id bigint;
  v_threshold numeric := 100000000;
  v_projected numeric;
  v_source text;
  v_balance_now numeric;
  v_snap numeric;
  v_pub numeric;
BEGIN
  IF v_club = '' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_club');
  END IF;

  -- Same visibility as credit risk: own club / admin / service (no uid)
  IF auth.uid() IS NOT NULL
     AND v_club IS DISTINCT FROM v_mine
     AND NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Not your club';
  END IF;

  SELECT id INTO v_season_id
  FROM public.competition_seasons
  WHERE is_current = true
  ORDER BY id DESC
  LIMIT 1;

  SELECT greatest(coalesce(b.eos_ffp_debt_threshold, 100000000), 0)
  INTO v_threshold
  FROM public.gpsl_bank_account b
  WHERE b.id = 1;

  SELECT coalesce(f.balance, 0)
  INTO v_balance_now
  FROM public."Club_Finances" f
  WHERE upper(f.club_name) = v_club;

  IF v_season_id IS NOT NULL THEN
    SELECT s.projected_balance
    INTO v_pub
    FROM public.club_finance_eos_forecast s
    WHERE s.season_id = v_season_id
      AND upper(s.club_short_name) = v_club;

    IF to_regclass('public.season_review_finance_snapshot') IS NOT NULL THEN
      SELECT s.pre_close
      INTO v_snap
      FROM public.season_review_finance_snapshot s
      WHERE s.season_id = v_season_id
        AND upper(s.club_short_name) = v_club;
    END IF;
  END IF;

  IF v_pub IS NOT NULL THEN
    v_projected := v_pub;
    v_source := 'finances_forecast';
  ELSIF v_snap IS NOT NULL THEN
    v_projected := v_snap;
    v_source := 'season_review_snapshot';
  ELSE
    v_projected := coalesce(v_balance_now, 0);
    v_source := 'live_balance';
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'club', v_club,
    'season_id', v_season_id,
    'projected_balance', v_projected,
    'balance_now', coalesce(v_balance_now, 0),
    'ffp_threshold', v_threshold,
    'source', v_source,
    'ffp_forecast_distress', v_projected <= -v_threshold
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.club_ffp_forecast_status(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.club_ffp_forecast_status(text) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.club_ffp_forecast_distress(p_club text)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v jsonb;
BEGIN
  v := public.club_ffp_forecast_status(p_club);
  RETURN coalesce((v->>'ffp_forecast_distress')::boolean, false);
EXCEPTION WHEN OTHERS THEN
  RETURN false;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.club_ffp_forecast_distress(text) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Loan / monthly rates: soft forecast premium (hard risk still wins)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.club_loan_effective_interest_rate(p_club text)
RETURNS numeric
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_base numeric;
  v_post_premium numeric;
  v_ffp_premium numeric;
  v_rate numeric;
BEGIN
  SELECT coalesce(policy_interest_rate_pct, 5),
         greatest(coalesce(loan_interest_post_risk_premium_pct, 0), 0),
         greatest(coalesce(loan_interest_ffp_forecast_premium_pct, 0), 0)
  INTO v_base, v_post_premium, v_ffp_premium
  FROM public.gpsl_bank_account
  WHERE id = 1;

  v_rate := v_base;

  IF public.club_loan_post_risk_active(p_club) THEN
    v_rate := greatest(v_rate, v_base + v_post_premium);
  END IF;

  IF public.club_ffp_forecast_distress(p_club) THEN
    v_rate := greatest(v_rate, v_base + v_ffp_premium);
  END IF;

  RETURN v_rate;
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
  v_ffp numeric;
BEGIN
  SELECT greatest(coalesce(monthly_debt_interest_pct, 0.50), 0),
         greatest(coalesce(monthly_debt_interest_bad_credit_pct, 1.00), 0),
         greatest(coalesce(monthly_debt_interest_ffp_forecast_pct, 0.75), 0)
  INTO v_normal, v_bad, v_ffp
  FROM public.gpsl_bank_account
  WHERE id = 1;

  IF public.club_is_financial_risk(p_club) THEN
    RETURN greatest(v_bad, v_normal);
  END IF;

  IF public.club_ffp_forecast_distress(p_club) THEN
    RETURN greatest(v_ffp, v_normal);
  END IF;

  RETURN v_normal;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.club_loan_effective_interest_rate(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.club_monthly_debt_interest_rate(text) TO authenticated;

-- ---------------------------------------------------------------------------
-- Credit check: soft distress fields + rate (loans still allowed)
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
  v_ffp jsonb;
  v_reasons text[] := ARRAY[]::text[];
  v_ffp_labels text;
  v_rate numeric;
  v_base numeric;
  v_post_premium numeric;
  v_ffp_premium numeric;
  v_post_risk boolean := false;
  v_forecast_distress boolean := false;
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
         greatest(coalesce(loan_interest_post_risk_premium_pct, 0), 0),
         greatest(coalesce(loan_interest_ffp_forecast_premium_pct, 0), 0)
  INTO v_base, v_post_premium, v_ffp_premium
  FROM public.gpsl_bank_account
  WHERE id = 1;

  BEGIN
    v_ffp := public.club_ffp_forecast_status(v_club);
    v_forecast_distress := coalesce((v_ffp->>'ffp_forecast_distress')::boolean, false);
  EXCEPTION WHEN OTHERS THEN
    v_ffp := jsonb_build_object('ok', false);
    v_forecast_distress := false;
  END;

  IF cardinality(v_reasons) = 0 THEN
    PERFORM public.club_credit_probation_sync(v_club);
    v_post_risk := public.club_loan_post_risk_active(v_club);
    v_rate := v_base;
    IF v_post_risk THEN
      v_rate := greatest(v_rate, v_base + v_post_premium);
    END IF;
    IF v_forecast_distress THEN
      v_rate := greatest(v_rate, v_base + v_ffp_premium);
    END IF;

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
      'post_risk_premium_pct', CASE WHEN v_post_risk THEN v_post_premium ELSE 0 END,
      'ffp_forecast_distress', v_forecast_distress,
      'ffp_forecast_premium', v_forecast_distress,
      'ffp_forecast_premium_pct', CASE WHEN v_forecast_distress THEN v_ffp_premium ELSE 0 END,
      'ffp_forecast_balance', (v_ffp->>'projected_balance')::numeric,
      'ffp_forecast_threshold', (v_ffp->>'ffp_threshold')::numeric,
      'ffp_forecast_source', v_ffp->>'source',
      'probation_until_season_id', v_until,
      'monthly_debt_interest_pct', public.club_monthly_debt_interest_rate(v_club),
      'message', NULL
    );
  END IF;

  PERFORM public.club_credit_probation_sync(v_club);

  RETURN jsonb_build_object(
    'ok', false,
    'financial_risk', true,
    'negative_seasons', (v_risk->>'negative_seasons')::int,
    'overdrawn_month_ends', (v_risk->>'overdrawn_month_ends')::int,
    'ffp_seasons', v_risk->'ffp_seasons',
    'ffp_forecast_distress', v_forecast_distress,
    'ffp_forecast_balance', (v_ffp->>'projected_balance')::numeric,
    'ffp_forecast_threshold', (v_ffp->>'ffp_threshold')::numeric,
    'ffp_forecast_source', v_ffp->>'source',
    'reasons', to_jsonb(v_reasons),
    'monthly_debt_interest_pct', public.club_monthly_debt_interest_rate(v_club),
    'message',
      'Application declined. The bank manager checked the club''s creditworthiness: the club is rated a financial risk and is not creditworthy ('
      || array_to_string(v_reasons, '; ')
      || '). No loans until the club is clean on all counts. Overdraft interest is charged at the bad-credit rate while this applies.'
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.club_loan_credit_check(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.club_loan_credit_check(text) TO authenticated, service_role;

-- Mirror season-review finance publish into club_finance_eos_forecast
CREATE OR REPLACE FUNCTION public.admin_season_review_publish_finance(p_rows jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season_id bigint;
  v_n int := 0;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  SELECT id INTO v_season_id
  FROM public.competition_seasons
  WHERE is_current = true
  ORDER BY id DESC
  LIMIT 1;

  IF v_season_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_season');
  END IF;

  INSERT INTO public.season_review_finance_snapshot (
    season_id, club_short_name, balance_now, pre_close, eos_posted, computed_at, computed_by
  )
  SELECT
    v_season_id,
    upper(btrim(x->>'club')),
    coalesce((x->>'balance_now')::numeric, 0),
    coalesce((x->>'pre_close')::numeric, 0),
    coalesce((x->>'eos_posted')::boolean, false),
    now(),
    auth.uid()
  FROM jsonb_array_elements(coalesce(p_rows, '[]'::jsonb)) x
  WHERE nullif(btrim(x->>'club'), '') IS NOT NULL
  ON CONFLICT (season_id, club_short_name) DO UPDATE SET
    balance_now = excluded.balance_now,
    pre_close = excluded.pre_close,
    eos_posted = excluded.eos_posted,
    computed_at = excluded.computed_at,
    computed_by = excluded.computed_by;

  GET DIAGNOSTICS v_n = ROW_COUNT;

  INSERT INTO public.club_finance_eos_forecast (
    season_id, club_short_name, projected_balance, source, updated_at, updated_by
  )
  SELECT
    v_season_id,
    upper(btrim(x->>'club')),
    coalesce((x->>'pre_close')::numeric, 0),
    'season_review',
    now(),
    auth.uid()
  FROM jsonb_array_elements(coalesce(p_rows, '[]'::jsonb)) x
  WHERE nullif(btrim(x->>'club'), '') IS NOT NULL
  ON CONFLICT (season_id, club_short_name) DO UPDATE SET
    projected_balance = excluded.projected_balance,
    source = excluded.source,
    updated_at = excluded.updated_at,
    updated_by = excluded.updated_by;

  RETURN jsonb_build_object('ok', true, 'season_id', v_season_id, 'rows', v_n);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.admin_season_review_publish_finance(jsonb) TO authenticated;

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
  monthly_debt_interest_ffp_forecast_pct,
  loan_interest_post_risk_premium_pct,
  loan_interest_ffp_forecast_premium_pct,
  loan_post_risk_probation_seasons,
  loans_enabled,
  loan_min_drawdown,
  loan_max_drawdown,
  loan_max_outstanding_per_club,
  eos_ffp_debt_threshold,
  updated_at
FROM public.gpsl_bank_account
WHERE id = 1;

GRANT SELECT ON public.gpsl_bank_public TO authenticated;
GRANT SELECT ON public.gpsl_bank_public TO anon;

NOTIFY pgrst, 'reload schema';

-- Quick check: clubs currently in soft distress (live/snapshot/forecast)
SELECT
  (s->>'club') AS club,
  (s->>'projected_balance')::numeric AS projected,
  (s->>'ffp_threshold')::numeric AS threshold,
  s->>'source' AS source,
  (s->>'ffp_forecast_distress')::boolean AS distress
FROM public.competition_club_seasons ccs
CROSS JOIN LATERAL public.club_ffp_forecast_status(ccs.club_short_name) s
WHERE ccs.season_id = (
  SELECT id FROM public.competition_seasons WHERE is_current = true ORDER BY id DESC LIMIT 1
)
  AND (s->>'ffp_forecast_distress')::boolean
ORDER BY (s->>'projected_balance')::numeric;
