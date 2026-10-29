-- =============================================================================
-- Loan repayments → durable month-lock + catch-up (2026-10-29)
--
-- Live: 11 active loans, only JUB/WOL have 1 scheduled payment; 9 are behind
-- (expected 2 paid by current as-of). Same soft-wire wipe as TV/friendlies.
--
-- This patch:
--   1) Registers loan collect on competition_month_lock_hooks / side_effects
--   2) Preview of catch-up amounts
--   3) Apply catch-up for all active loans as-of current loan month
--
-- Safe re-run (idempotent once installments are paid). Debits Club_Finances.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.competition_loan_month_lock_side_effect(
  p_season_id bigint,
  p_gpsl_month text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
SET statement_timeout = '90s'
AS $function$
DECLARE
  v_month text := lower(btrim(coalesce(p_gpsl_month, '')));
BEGIN
  IF v_month = 'playoffs' THEN
    v_month := 'may';
  END IF;

  IF to_regprocedure('public.competition_admin_process_loan_installments(bigint,text)') IS NOT NULL THEN
    RETURN public.competition_admin_process_loan_installments(p_season_id, nullif(v_month, ''));
  END IF;

  RETURN jsonb_build_object('ok', false, 'reason', 'process_fn_missing');
END;
$function$;

REVOKE ALL ON FUNCTION public.competition_loan_month_lock_side_effect(bigint, text)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.competition_loan_month_lock_side_effect(bigint, text)
  TO service_role;

INSERT INTO public.competition_month_lock_hooks (hook_key, sort_order, enabled, proc_name, notes)
VALUES (
  'loan_repayments',
  25,
  true,
  'competition_loan_month_lock_side_effect',
  'Collect due central-bank loan installments for all active borrowers'
)
ON CONFLICT (hook_key) DO UPDATE
SET enabled = true,
    proc_name = EXCLUDED.proc_name,
    notes = EXCLUDED.notes;

-- Inject into durable side_effects
DO $side$
DECLARE
  v_oid oid;
  v_def text;
  v_insert text;
BEGIN
  v_oid := to_regprocedure('public.competition_run_month_lock_side_effects(bigint,text,text)');
  IF v_oid IS NULL THEN
    RAISE NOTICE 'side_effects missing — loan hook registered only';
    RETURN;
  END IF;

  v_def := replace(replace(pg_get_functiondef(v_oid), E'\r\n', E'\n'), E'\r', E'\n');

  IF position('competition_loan_month_lock_side_effect' IN v_def) > 0
     OR position('competition_admin_process_loan_installments' IN v_def) > 0 THEN
    RAISE NOTICE 'loans already in side_effects';
    RETURN;
  END IF;

  v_insert :=
    E'\n    BEGIN\n'
    || E'      IF to_regprocedure(''public.competition_loan_month_lock_side_effect(bigint,text)'') IS NOT NULL THEN\n'
    || E'        v_res := public.competition_loan_month_lock_side_effect(p_season_id, v_month);\n'
    || E'        v_out := v_out || jsonb_build_object(''loan_repayments'', v_res);\n'
    || E'      END IF;\n'
    || E'    EXCEPTION WHEN OTHERS THEN\n'
    || E'      v_out := v_out || jsonb_build_object(\n'
    || E'        ''loan_repayments'', jsonb_build_object(''ok'', false, ''error'', SQLERRM)\n'
    || E'      );\n'
    || E'    END;\n';

  IF position(E'FOR r IN\n    SELECT hook_key, proc_name\n    FROM public.competition_month_lock_hooks' IN v_def) > 0 THEN
    v_def := replace(
      v_def,
      E'FOR r IN\n    SELECT hook_key, proc_name\n    FROM public.competition_month_lock_hooks',
      v_insert || E'\n  FOR r IN\n    SELECT hook_key, proc_name\n    FROM public.competition_month_lock_hooks'
    );
  ELSIF position(E'v_out := v_out || jsonb_build_object(''stage'', v_stage);' IN v_def) > 0 THEN
    v_def := replace(
      v_def,
      E'v_out := v_out || jsonb_build_object(''stage'', v_stage);',
      v_insert || E'\n  v_out := v_out || jsonb_build_object(''stage'', v_stage);'
    );
  ELSE
    RAISE NOTICE 'Could not inject loans into side_effects — hook remains';
    RETURN;
  END IF;

  IF position('''loan_repayments''' IN coalesce(
       substring(v_def from position('hook_key NOT IN' in v_def) for 250), ''
     )) = 0
     AND position('hook_key NOT IN' IN v_def) > 0 THEN
    v_def := replace(
      v_def,
      E'AND hook_key NOT IN (''friendlies_prizes'', ''vacant_walkovers'', ''tv_revenue'')',
      E'AND hook_key NOT IN (''friendlies_prizes'', ''vacant_walkovers'', ''tv_revenue'', ''loan_repayments'')'
    );
    v_def := replace(
      v_def,
      E'AND hook_key NOT IN (''friendlies_prizes'', ''vacant_walkovers'')',
      E'AND hook_key NOT IN (''friendlies_prizes'', ''vacant_walkovers'', ''loan_repayments'')'
    );
  ELSIF position('hook_key NOT IN' IN v_def) = 0 THEN
    v_def := replace(
      v_def,
      E'WHERE enabled\n    ORDER BY sort_order, hook_key',
      E'WHERE enabled\n      AND hook_key NOT IN (''friendlies_prizes'', ''vacant_walkovers'', ''tv_revenue'', ''loan_repayments'')\n    ORDER BY sort_order, hook_key'
    );
  END IF;

  EXECUTE v_def;
  RAISE NOTICE 'loan repayments hardcoded into side_effects';
END;
$side$;

NOTIFY pgrst, 'reload schema';

-- Preview (no cash movement)
SELECT public.competition_admin_loan_catchup_preview(NULL, NULL) AS catchup_preview;

-- Apply catch-up (debits clubs that can afford due installments)
SELECT public.competition_admin_loan_catchup_apply(NULL, NULL) AS catchup_apply;

-- Quick re-check
SELECT
  count(*) FILTER (WHERE l.status = 'active') AS active_loans,
  count(*) FILTER (
    WHERE l.status = 'active'
      AND EXISTS (
        SELECT 1 FROM public.club_loan_installments i
        WHERE i.loan_id = l.id AND i.status = 'paid'
      )
  ) AS active_with_repayments_started,
  count(*) FILTER (
    WHERE l.status = 'active'
      AND NOT EXISTS (
        SELECT 1 FROM public.club_loan_installments i
        WHERE i.loan_id = l.id AND i.status = 'paid'
      )
      AND public.club_loan_expected_paid_count(
        l.season_id, l.drawdown_gpsl_month, coalesce(l.repayment_months, 20),
        (SELECT id FROM public.competition_seasons WHERE is_current ORDER BY id DESC LIMIT 1),
        public.club_loan_as_of_gpsl_month(
          (SELECT id FROM public.competition_seasons WHERE is_current ORDER BY id DESC LIMIT 1)
        )
      ) > 0
  ) AS active_behind_schedule
FROM public.club_loans l;

SELECT
  (position('loan_repayments' IN pg_get_functiondef(
    'public.competition_run_month_lock_side_effects(bigint,text,text)'::regprocedure
  )) > 0
  OR position('competition_loan_month_lock_side_effect' IN pg_get_functiondef(
    'public.competition_run_month_lock_side_effects(bigint,text,text)'::regprocedure
  )) > 0) AS loans_in_side_effects,
  (SELECT enabled FROM public.competition_month_lock_hooks WHERE hook_key = 'loan_repayments')
    AS hook_enabled;
