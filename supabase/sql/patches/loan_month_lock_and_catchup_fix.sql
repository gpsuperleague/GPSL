-- =============================================================================
-- Loan collection: month-lock discovery fix + catch-up for underpaid schedules
--
-- Problems:
--   1) competition_admin_process_loan_installments only looked at clubs with a
--      pending row where due_season_id = locked season AND due_gpsl_month =
--      locked month. That missed:
--        • prior-season arrears (S1 dues while locking S2)
--        • playoffs locks (dues are 'may', not 'playoffs')
--        • wrongly pinned due_season_id when Season N+1 did not exist yet
--      Early month-end was often the ONLY collector; with a bad club filter it
--      no-op'd. Ending months early made this worse (fewer successful passes).
--   2) Visit auto-collect was paused after over-collection; month lock must be
--      the reliable path.
--
-- This patch:
--   A) process_due_for_club(club, as_of optional) — month lock can pass the
--      month being locked (playoffs → may)
--   B) admin_process_loan_installments — ALL active-loan clubs, not month filter
--   C) admin_loan_catchup_preview / admin_loan_catchup_apply — dry-run + settle
--
-- Run in Supabase SQL Editor. Safe re-run.
-- Catch-up APPLY debits Club_Finances — preview first.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- A) Process due instalments (optional as-of override for month lock)
-- ---------------------------------------------------------------------------

DROP FUNCTION IF EXISTS public.club_loan_process_due_for_club(text);
DROP FUNCTION IF EXISTS public.club_loan_process_due_for_club(text, text);

CREATE OR REPLACE FUNCTION public.club_loan_process_due_for_club(
  p_club text,
  p_as_of_month text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season_id bigint;
  v_active_month text;
  v_inst record;
  v_paid numeric := 0;
  v_count int := 0;
  v_skipped int := 0;
  v_errors int := 0;
  v_err text;
BEGIN
  IF p_club IS NULL OR btrim(p_club) = '' THEN
    RETURN jsonb_build_object('processed', 0, 'total_paid', 0);
  END IF;

  SELECT id INTO v_season_id
  FROM public.competition_seasons
  WHERE is_current = true AND status = 'active'
  ORDER BY id DESC
  LIMIT 1;

  IF v_season_id IS NULL THEN
    RETURN jsonb_build_object('processed', 0, 'total_paid', 0, 'reason', 'no_active_season');
  END IF;

  v_active_month := nullif(lower(btrim(coalesce(p_as_of_month, ''))), '');
  IF v_active_month = 'playoffs' THEN
    v_active_month := 'may';
  END IF;
  IF v_active_month IS NULL THEN
    v_active_month := public.club_loan_as_of_gpsl_month(v_season_id);
  END IF;

  IF v_active_month IS NULL THEN
    RETURN jsonb_build_object('processed', 0, 'total_paid', 0, 'reason', 'no_as_of_month');
  END IF;

  FOR v_inst IN
    SELECT i.*, l.season_id AS loan_season_id, l.drawdown_gpsl_month, l.repayment_months
    FROM public.club_loan_installments i
    JOIN public.club_loans l ON l.id = i.loan_id
    WHERE l.club_short_name = btrim(p_club)
      AND l.status = 'active'
      AND i.status = 'pending'
      AND l.drawdown_gpsl_month IS NOT NULL
      AND public.club_loan_installment_is_due_by_no(
        l.season_id,
        l.drawdown_gpsl_month,
        coalesce(l.repayment_months, 20),
        i.installment_no,
        v_season_id,
        v_active_month
      )
    ORDER BY i.installment_no
  LOOP
    BEGIN
      v_paid := v_paid + public.club_loan_settle_scheduled_installment(v_inst.id);
      v_count := v_count + 1;
    EXCEPTION
      WHEN OTHERS THEN
        v_err := SQLERRM;
        IF v_err ILIKE '%Insufficient balance%' THEN
          v_skipped := v_skipped + 1;
          EXIT;
        END IF;
        v_errors := v_errors + 1;
    END;
  END LOOP;

  RETURN jsonb_build_object(
    'club', btrim(p_club),
    'processed', v_count,
    'total_paid', v_paid,
    'skipped_insufficient', v_skipped,
    'errors', v_errors,
    'active_gpsl_month', v_active_month,
    'game_season_number', public.club_loan_game_season_number(v_season_id)
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.club_loan_process_my_due_installments()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := public.my_club_shortname();
BEGIN
  IF v_club IS NULL OR v_club = '' THEN
    RAISE EXCEPTION 'No club linked to your account';
  END IF;
  RETURN public.club_loan_process_due_for_club(v_club, NULL);
END;
$function$;

-- ---------------------------------------------------------------------------
-- B) Month lock / admin: every club with an active loan (arrears + this month)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.competition_admin_process_loan_installments(
  p_season_id bigint,
  p_gpsl_month text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text;
  v_as_of text;
  v_clubs int := 0;
  v_processed int := 0;
  v_paid numeric := 0;
  v_skipped int := 0;
  v_errors int := 0;
  v_res jsonb;
  v_details jsonb := '[]'::jsonb;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  v_as_of := lower(btrim(coalesce(p_gpsl_month, '')));
  IF v_as_of = '' THEN
    v_as_of := NULL;
  ELSIF v_as_of = 'playoffs' THEN
    v_as_of := 'may';
  END IF;

  FOR v_club IN
    SELECT DISTINCT l.club_short_name
    FROM public.club_loans l
    WHERE l.status = 'active'
      AND EXISTS (
        SELECT 1
        FROM public.club_loan_installments i
        WHERE i.loan_id = l.id
          AND i.status = 'pending'
      )
    ORDER BY 1
  LOOP
    v_res := public.club_loan_process_due_for_club(v_club, v_as_of);
    v_clubs := v_clubs + 1;
    v_processed := v_processed + coalesce((v_res ->> 'processed')::int, 0);
    v_paid := v_paid + coalesce((v_res ->> 'total_paid')::numeric, 0);
    v_skipped := v_skipped + coalesce((v_res ->> 'skipped_insufficient')::int, 0);
    v_errors := v_errors + coalesce((v_res ->> 'errors')::int, 0);
    IF coalesce((v_res ->> 'processed')::int, 0) > 0
       OR coalesce((v_res ->> 'skipped_insufficient')::int, 0) > 0
       OR coalesce((v_res ->> 'errors')::int, 0) > 0 THEN
      v_details := v_details || jsonb_build_array(v_res);
    END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true,
    'season_id', p_season_id,
    'as_of_month', v_as_of,
    'clubs_checked', v_clubs,
    'installments_processed', v_processed,
    'total_paid', v_paid,
    'skipped_insufficient', v_skipped,
    'errors', v_errors,
    'details', v_details
  );
END;
$function$;

-- ---------------------------------------------------------------------------
-- C) Catch-up preview (no cash movement) + apply (settles due instalments)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.competition_admin_loan_catchup_preview(
  p_club_short_name text DEFAULT NULL,
  p_as_of_month text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season_id bigint;
  v_as_of text;
  v_loan record;
  v_expected int;
  v_paid_count int;
  v_due_count int;
  v_prin numeric;
  v_int numeric;
  v_balance numeric;
  v_rows jsonb := '[]'::jsonb;
  v_total_prin numeric := 0;
  v_total_int numeric := 0;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  SELECT id INTO v_season_id
  FROM public.competition_seasons
  WHERE is_current = true AND status = 'active'
  ORDER BY id DESC
  LIMIT 1;

  IF v_season_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_active_season');
  END IF;

  v_as_of := nullif(lower(btrim(coalesce(p_as_of_month, ''))), '');
  IF v_as_of = 'playoffs' THEN
    v_as_of := 'may';
  END IF;
  IF v_as_of IS NULL THEN
    v_as_of := public.club_loan_as_of_gpsl_month(v_season_id);
  END IF;

  FOR v_loan IN
    SELECT l.*
    FROM public.club_loans l
    WHERE l.status = 'active'
      AND (p_club_short_name IS NULL OR l.club_short_name = btrim(p_club_short_name))
    ORDER BY l.club_short_name, l.id
  LOOP
    v_expected := public.club_loan_expected_paid_count(
      v_loan.season_id,
      v_loan.drawdown_gpsl_month,
      coalesce(v_loan.repayment_months, 20),
      v_season_id,
      v_as_of
    );

    SELECT count(*)::int INTO v_paid_count
    FROM public.club_loan_installments i
    WHERE i.loan_id = v_loan.id
      AND i.status = 'paid';

    SELECT
      count(*)::int,
      coalesce(sum(i.principal_due - coalesce(i.paid_amount, 0)), 0),
      coalesce(sum(greatest(0, coalesce(i.interest_due, 0) - coalesce(i.interest_paid, 0))), 0)
    INTO v_due_count, v_prin, v_int
    FROM public.club_loan_installments i
    WHERE i.loan_id = v_loan.id
      AND i.status = 'pending'
      AND public.club_loan_installment_is_due_by_no(
        v_loan.season_id,
        v_loan.drawdown_gpsl_month,
        coalesce(v_loan.repayment_months, 20),
        i.installment_no,
        v_season_id,
        v_as_of
      );

    SELECT coalesce(cf.balance, 0) INTO v_balance
    FROM public."Club_Finances" cf
    WHERE cf.club_name = v_loan.club_short_name;

    IF v_due_count > 0 THEN
      v_total_prin := v_total_prin + v_prin;
      v_total_int := v_total_int + v_int;
      v_rows := v_rows || jsonb_build_array(jsonb_build_object(
        'loan_id', v_loan.id,
        'club', v_loan.club_short_name,
        'principal_drawn', v_loan.principal_drawn,
        'outstanding_principal', v_loan.outstanding_principal,
        'drawdown_month', v_loan.drawdown_gpsl_month,
        'loan_season_id', v_loan.season_id,
        'expected_paid_count', v_expected,
        'actual_paid_count', v_paid_count,
        'due_unpaid_count', v_due_count,
        'due_principal', round(v_prin, 2),
        'due_interest', round(v_int, 2),
        'due_total', round(v_prin + v_int, 2),
        'club_balance', round(coalesce(v_balance, 0), 2),
        'can_afford_full', coalesce(v_balance, 0) >= (v_prin + v_int) - 0.005
      ));
    END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true,
    'as_of_month', v_as_of,
    'current_season_id', v_season_id,
    'game_season_number', public.club_loan_game_season_number(v_season_id),
    'loans_with_arrears', jsonb_array_length(v_rows),
    'total_due_principal', round(v_total_prin, 2),
    'total_due_interest', round(v_total_int, 2),
    'total_due', round(v_total_prin + v_total_int, 2),
    'loans', v_rows
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.competition_admin_loan_catchup_apply(
  p_club_short_name text DEFAULT NULL,
  p_as_of_month text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text;
  v_as_of text;
  v_clubs int := 0;
  v_processed int := 0;
  v_paid numeric := 0;
  v_skipped int := 0;
  v_res jsonb;
  v_details jsonb := '[]'::jsonb;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  v_as_of := nullif(lower(btrim(coalesce(p_as_of_month, ''))), '');
  IF v_as_of = 'playoffs' THEN
    v_as_of := 'may';
  END IF;

  FOR v_club IN
    SELECT DISTINCT l.club_short_name
    FROM public.club_loans l
    WHERE l.status = 'active'
      AND (p_club_short_name IS NULL OR l.club_short_name = btrim(p_club_short_name))
      AND EXISTS (
        SELECT 1 FROM public.club_loan_installments i
        WHERE i.loan_id = l.id AND i.status = 'pending'
      )
    ORDER BY 1
  LOOP
    v_res := public.club_loan_process_due_for_club(v_club, v_as_of);
    v_clubs := v_clubs + 1;
    v_processed := v_processed + coalesce((v_res ->> 'processed')::int, 0);
    v_paid := v_paid + coalesce((v_res ->> 'total_paid')::numeric, 0);
    v_skipped := v_skipped + coalesce((v_res ->> 'skipped_insufficient')::int, 0);
    v_details := v_details || jsonb_build_array(v_res);
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true,
    'as_of_month', v_as_of,
    'clubs', v_clubs,
    'installments_processed', v_processed,
    'total_paid', v_paid,
    'skipped_insufficient', v_skipped,
    'details', v_details,
    'note', 'Ledger rows posted as loan_repayment_principal / loan_interest_payment on each instalment due_season_id'
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.club_loan_process_due_for_club(text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.club_loan_process_my_due_installments() TO authenticated;
GRANT EXECUTE ON FUNCTION public.competition_admin_process_loan_installments(bigint, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.competition_admin_loan_catchup_preview(text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.competition_admin_loan_catchup_apply(text, text) TO authenticated;

-- ---------------------------------------------------------------------------
-- How to use (run as admin in SQL editor)
-- ---------------------------------------------------------------------------
-- 1) Preview all clubs (uses current loan as-of month):
--    SELECT public.competition_admin_loan_catchup_preview(NULL, NULL);
--
-- 2) Preview one club at end-of-season May (forces full S1+S2 dues for Aug draws):
--    SELECT public.competition_admin_loan_catchup_preview('YOURCLUB', 'may');
--
-- 3) Apply for one club after reviewing totals (DEBITS BALANCE):
--    SELECT public.competition_admin_loan_catchup_apply('YOURCLUB', 'may');
--
-- 4) Apply league-wide only after preview looks right:
--    SELECT public.competition_admin_loan_catchup_apply(NULL, 'may');
-- =============================================================================
