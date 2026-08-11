-- =============================================================================
-- Fix: club_take_loan fails pre-season with
--   "Could not resolve GPSL month for installment 1"
--
-- Cause:
--   • Pre-season has no active league month → drawdown falls back to 'august'
--   • August loans use months_ahead = 0 for installment 1
--   • competition_resolve_gpsl_month_offset was re-hardened to require ahead >= 1
--     (regressed the Aug-same-month schedule), so installment 1 returns NULL
--   • June/July active months are not on the loan calendar (Aug–May)
--
-- Fix:
--   1) Resolve offsets with loan calendar sort; allow months_ahead >= 0
--   2) Normalize drawdown month (june/july/null/playoffs → august)
--   3) Allow take-loan in preseason (finances current season)
--
-- Run once in Supabase SQL Editor. Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.club_loan_calendar_month_sort(p_month text)
RETURNS smallint
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE lower(btrim(coalesce(p_month, '')))
    WHEN 'august' THEN 1
    WHEN 'aug' THEN 1
    WHEN 'september' THEN 2
    WHEN 'sep' THEN 2
    WHEN 'october' THEN 3
    WHEN 'november' THEN 4
    WHEN 'december' THEN 5
    WHEN 'january' THEN 6
    WHEN 'february' THEN 7
    WHEN 'march' THEN 8
    WHEN 'april' THEN 9
    WHEN 'may' THEN 10
    ELSE NULL
  END;
$$;

CREATE OR REPLACE FUNCTION public.club_loan_calendar_month_from_sort(p_sort smallint)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE p_sort
    WHEN 1 THEN 'august'
    WHEN 2 THEN 'september'
    WHEN 3 THEN 'october'
    WHEN 4 THEN 'november'
    WHEN 5 THEN 'december'
    WHEN 6 THEN 'january'
    WHEN 7 THEN 'february'
    WHEN 8 THEN 'march'
    WHEN 9 THEN 'april'
    WHEN 10 THEN 'may'
    ELSE NULL
  END;
$$;

-- Pre-season / June / July / playoffs → treat as August loan year start
CREATE OR REPLACE FUNCTION public.club_loan_normalize_drawdown_month(p_month text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE
    WHEN public.club_loan_calendar_month_sort(p_month) IS NOT NULL
      THEN lower(btrim(p_month))
    ELSE 'august'
  END;
$$;

CREATE OR REPLACE FUNCTION public.competition_resolve_gpsl_month_offset(
  p_base_season_id bigint,
  p_base_month text,
  p_months_ahead integer
)
RETURNS TABLE (
  due_season_id bigint,
  due_gpsl_month text,
  due_season_offset integer
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_base_month text;
  v_base_sort smallint;
  v_target_sort integer;
  v_season_shift integer;
  v_month_sort smallint;
  v_base_game integer;
BEGIN
  v_base_month := public.club_loan_normalize_drawdown_month(p_base_month);
  v_base_sort := public.club_loan_calendar_month_sort(v_base_month);

  -- months_ahead 0 = same GPSL month as drawdown (August loans)
  IF v_base_sort IS NULL OR p_months_ahead IS NULL OR p_months_ahead < 0 THEN
    RETURN;
  END IF;

  v_target_sort := v_base_sort + p_months_ahead;
  v_season_shift := (v_target_sort - 1) / 10;
  v_month_sort := ((v_target_sort - 1) % 10) + 1;
  due_season_offset := v_season_shift;
  due_gpsl_month := public.club_loan_calendar_month_from_sort(v_month_sort);

  IF due_gpsl_month IS NULL THEN
    RETURN;
  END IF;

  IF to_regprocedure('public.club_loan_game_season_number(bigint)') IS NOT NULL THEN
    v_base_game := public.club_loan_game_season_number(p_base_season_id);
    IF v_base_game IS NOT NULL THEN
      SELECT s.id
      INTO due_season_id
      FROM public.competition_seasons s
      WHERE public.club_loan_game_season_number(s.id) = v_base_game + v_season_shift
      ORDER BY s.id
      LIMIT 1;
    END IF;
  END IF;

  IF due_season_id IS NULL THEN
    SELECT s.id
    INTO due_season_id
    FROM public.competition_seasons s
    WHERE s.id >= p_base_season_id
    ORDER BY s.id
    OFFSET v_season_shift
    LIMIT 1;
  END IF;

  IF due_season_id IS NULL THEN
    due_season_id := p_base_season_id;
  END IF;

  RETURN NEXT;
END;
$function$;

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
  v_loan_id bigint;
  v_ledger_id bigint;
  v_desc text;
  v_drawdown_month text;
  v_months smallint := 20;
  v_rate numeric;
  v_credit jsonb;
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

  -- Pre-season + active (same as other finance posts)
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

  IF to_regprocedure('public.club_loan_taken_this_season(text,bigint)') IS NOT NULL
     AND public.club_loan_taken_this_season(v_club, v_season_id) THEN
    RAISE EXCEPTION
      'Maximum one loan per season. Your club has already taken a loan this season (repaying it does not allow another).';
  END IF;

  v_drawdown_month := public.club_loan_normalize_drawdown_month(
    public.competition_active_gpsl_month(v_season_id, now())
  );

  SELECT
    loans_enabled,
    loan_min_drawdown,
    loan_max_drawdown,
    loan_max_outstanding_per_club,
    policy_interest_rate_pct
  INTO v_bank
  FROM public.gpsl_bank_account
  WHERE id = 1
  FOR UPDATE;

  IF NOT coalesce(v_bank.loans_enabled, false) THEN
    RAISE EXCEPTION 'Bank loans are currently disabled';
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

  v_rate := v_bank.policy_interest_rate_pct;

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
    'Central bank loan drawdown (loan #%s) — %s GPSL months from %s at %s%% p.a.',
    v_loan_id,
    v_months,
    public.competition_gpsl_month_label(v_drawdown_month),
    trim(to_char(v_rate, 'FM999990.00'))
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

GRANT EXECUTE ON FUNCTION public.club_loan_calendar_month_sort(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.club_loan_calendar_month_from_sort(smallint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.club_loan_normalize_drawdown_month(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.competition_resolve_gpsl_month_offset(bigint, text, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.club_take_loan(numeric) TO authenticated;

NOTIFY pgrst, 'reload schema';
