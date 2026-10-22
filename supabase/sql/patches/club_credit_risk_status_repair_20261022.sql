-- =============================================================================
-- Repair: club_credit_risk_status missing / not callable on loan take (2026-10-22)
-- =============================================================================
-- club_take_loan → club_loan_credit_check → club_credit_risk_status.
-- Earlier patch revoked EXECUTE from authenticated and only granted service_role;
-- if the function was never applied (or DEFINER can't execute it), take-loan fails
-- with function public.club_credit_risk_status(text).
-- Safe re-run. Recreates helpers + status + credit_check grant chain.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.club_credit_overdrawn_months_limit()
RETURNS int LANGUAGE sql IMMUTABLE AS $$ SELECT 6 $$;

CREATE OR REPLACE FUNCTION public.club_credit_ffp_lookback_seasons()
RETURNS int LANGUAGE sql IMMUTABLE AS $$ SELECT 5 $$;

CREATE TABLE IF NOT EXISTS public.club_month_end_balances (
  season_id bigint NOT NULL REFERENCES public.competition_seasons (id) ON DELETE CASCADE,
  gpsl_month text NOT NULL,
  club_short_name text NOT NULL,
  balance numeric(14, 2) NOT NULL,
  source text NOT NULL DEFAULT 'month_lock'
    CHECK (source IN ('month_lock', 'ledger_rebuild', 'admin')),
  checkpoint_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (season_id, gpsl_month, club_short_name)
);

CREATE INDEX IF NOT EXISTS club_month_end_balances_club_idx
  ON public.club_month_end_balances (club_short_name, checkpoint_at DESC);

ALTER TABLE public.club_month_end_balances ENABLE ROW LEVEL SECURITY;

CREATE OR REPLACE FUNCTION public.club_credit_risk_status(p_club text)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := btrim(coalesce(p_club, ''));
  v_limit int := public.club_credit_overdrawn_months_limit();
  v_lookback int := public.club_credit_ffp_lookback_seasons();
  v_streak int := 0;
  v_checked int := 0;
  v_ffp_seasons jsonb;
  v_negative_seasons int := 0;
  r record;
BEGIN
  IF v_club = '' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_club');
  END IF;

  FOR r IN
    SELECT b.balance
    FROM public.club_month_end_balances b
    WHERE b.club_short_name = v_club
    ORDER BY b.checkpoint_at DESC
    LIMIT v_limit
  LOOP
    v_checked := v_checked + 1;
    EXIT WHEN r.balance >= 0;
    v_streak := v_streak + 1;
  END LOOP;

  SELECT coalesce(jsonb_agg(
           jsonb_build_object('season_id', s.id, 'season_label', s.label)
           ORDER BY s.id DESC
         ), '[]'::jsonb)
  INTO v_ffp_seasons
  FROM (
    SELECT id, label FROM public.competition_seasons ORDER BY id DESC LIMIT v_lookback
  ) s
  WHERE EXISTS (
    SELECT 1 FROM public.competition_season_charge_paid cp
    WHERE cp.season_id = s.id
      AND cp.club_short_name = v_club
      AND cp.charge_type = 'eos_ffp_charge'
  );

  IF to_regprocedure('public.club_loan_negative_season_count(text)') IS NOT NULL THEN
    v_negative_seasons := public.club_loan_negative_season_count(v_club);
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'club', v_club,
    'overdrawn_month_ends', v_streak,
    'overdrawn_month_ends_limit', v_limit,
    'overdrawn_risk', v_streak >= v_limit,
    'ffp_seasons', v_ffp_seasons,
    'ffp_lookback_seasons', v_lookback,
    'ffp_risk', jsonb_array_length(v_ffp_seasons) > 0,
    'negative_seasons', v_negative_seasons,
    'negative_seasons_risk', v_negative_seasons >= 2
  );
END;
$function$;

-- Callable by loan credit-check DEFINER + PostgREST (read-only risk summary)
REVOKE ALL ON FUNCTION public.club_credit_risk_status(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.club_credit_risk_status(text) TO authenticated, service_role;

-- Ensure club_loan_credit_check exists and can call status (minimal if premiums body already live)
CREATE OR REPLACE FUNCTION public.club_loan_credit_check(p_club text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
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

  -- Optional post-risk premium fields (credit_risk_interest_premiums)
  IF to_regclass('public.gpsl_bank_account') IS NOT NULL THEN
    BEGIN
      SELECT coalesce(policy_interest_rate_pct, 5),
             greatest(coalesce(loan_interest_post_risk_premium_pct, 0), 0)
      INTO v_base, v_premium
      FROM public.gpsl_bank_account
      WHERE id = 1;
    EXCEPTION WHEN undefined_column THEN
      v_base := 5;
      v_premium := 0;
    END;
  END IF;

  IF cardinality(v_reasons) = 0 THEN
    IF to_regprocedure('public.club_credit_probation_sync(text)') IS NOT NULL THEN
      PERFORM public.club_credit_probation_sync(v_club);
    END IF;
    IF to_regprocedure('public.club_loan_post_risk_active(text)') IS NOT NULL THEN
      v_post_risk := public.club_loan_post_risk_active(v_club);
    END IF;
    v_rate := CASE
      WHEN v_post_risk AND v_base IS NOT NULL THEN v_base + coalesce(v_premium, 0)
      WHEN v_base IS NOT NULL THEN v_base
      ELSE NULL
    END;

    IF to_regclass('public.club_credit_probation') IS NOT NULL THEN
      SELECT probation_until_season_id INTO v_until
      FROM public.club_credit_probation
      WHERE club_short_name = v_club;
    END IF;

    RETURN jsonb_build_object(
      'ok', true,
      'negative_seasons', (v_risk->>'negative_seasons')::int,
      'overdrawn_month_ends', (v_risk->>'overdrawn_month_ends')::int,
      'ffp_seasons', v_risk->'ffp_seasons',
      'interest_rate_pct', v_rate,
      'policy_interest_rate_pct', v_base,
      'post_risk_premium', v_post_risk,
      'post_risk_premium_pct', CASE WHEN v_post_risk THEN coalesce(v_premium, 0) ELSE 0 END,
      'probation_until_season_id', v_until,
      'message', NULL
    );
  END IF;

  RETURN jsonb_build_object(
    'ok', false,
    'financial_risk', true,
    'negative_seasons', (v_risk->>'negative_seasons')::int,
    'overdrawn_month_ends', (v_risk->>'overdrawn_month_ends')::int,
    'ffp_seasons', v_risk->'ffp_seasons',
    'reasons', to_jsonb(v_reasons),
    'message',
      'Application declined. The bank manager checked the club''s creditworthiness: the club is rated a financial risk and is not creditworthy ('
      || array_to_string(v_reasons, '; ')
      || '). No loans until the club is clean on all counts.'
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.club_loan_credit_check(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.club_loan_credit_check(text) TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';

DO $$
BEGIN
  RAISE NOTICE 'club_credit_risk_status + club_loan_credit_check ready — retry take loan.';
END $$;
