-- =============================================================================
-- GPSL finance ledger entry_type allow-list — durable helper + hotfix
--
-- Problem: many patches rebuild competition_finance_ledger_entry_type_check as
--   (live distinct types) UNION (only the new type being added)
-- If a type has never been posted yet (e.g. special_auction_fee), it is DROPPED
-- from the CHECK and the next settle fails with:
--   violates check constraint "competition_finance_ledger_entry_type_check"
--
-- Fix going forward: ALWAYS call
--   SELECT public.gpsl_ledger_ensure_entry_types(ARRAY['my_new_type']);
-- which unions: live rows + full GPSL catalogue + any extras you pass.
--
-- Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.gpsl_ledger_ensure_entry_types(
  p_extra text[] DEFAULT '{}'::text[]
)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_list text;
  v_def text;
BEGIN
  SELECT string_agg(quote_literal(t), ', ' ORDER BY t)
  INTO v_list
  FROM (
    -- Everything already on the ledger (never drop a live type)
    SELECT DISTINCT entry_type AS t
    FROM public.competition_finance_ledger
    WHERE entry_type IS NOT NULL

    UNION

    -- Full known GPSL catalogue (types may not have been posted yet)
    SELECT unnest(ARRAY[
      'gate_league_home',
      'gate_cup_share',
      'gate_friendlies',
      'prize',
      'prize_league',
      'prize_cup',
      'prize_challenge',
      'tv_revenue',
      'gov_hg_subsidy',
      'gov_youth_subsidy',
      'gov_bnb_subsidy',
      'gov_fine_compensation',
      'gov_emergency_tax',
      'gov_income_tax',
      'wage_squad',
      'wage_renewal_34plus',
      'wage_star_tax',
      'wage_fan_favourite_subsidy',
      'adjustment',
      'admin_one_off_injection',
      'admin_purchase_payment',
      'transfer_sale',
      'transfer_purchase',
      'transfer_agent_fee',
      'transfer_foreign_sale',
      'transfer_overflow_release',
      'loan_drawdown',
      'loan_repayment_principal',
      'loan_interest_payment',
      'infra_maintenance',
      'infra_purchase',
      'infra_expansion',
      'infra_expansion_refund',
      'infra_expansion_penalty',
      'contract_release_comp',
      'contract_release_comp_received',
      'contract_termination',
      'contract_signing_offer',
      'contract_expiry_compensation',
      'contract_expiry_champ_signing_fee',
      'staff_manager_salary',
      'eos_debt_interest',
      'eos_ffp_charge',
      'eos_balance_interest',
      'eos_injection',
      'special_auction_fee',
      'special_auction_prize',
      'season_loan_fee',
      'season_loan_refund',
      'new_owner_release',
      'voluntary_contract_release',
      'medical_physio_hire',
      'medical_doctor_hire',
      'bookies_expenditure',
      'bookies_income',
      'draft_purchase',
      'draft_sale'
    ])

    UNION

    SELECT unnest(coalesce(p_extra, '{}'::text[]))
  ) s
  WHERE t IS NOT NULL AND btrim(t) <> '';

  IF v_list IS NULL OR length(v_list) < 3 THEN
    RAISE EXCEPTION 'gpsl_ledger_ensure_entry_types: could not build allow-list';
  END IF;

  ALTER TABLE public.competition_finance_ledger
    DROP CONSTRAINT IF EXISTS competition_finance_ledger_entry_type_check;

  EXECUTE format(
    'ALTER TABLE public.competition_finance_ledger
       ADD CONSTRAINT competition_finance_ledger_entry_type_check
       CHECK (entry_type IN (%s))',
    v_list
  );

  SELECT pg_get_constraintdef(c.oid)
  INTO v_def
  FROM pg_constraint c
  WHERE c.conname = 'competition_finance_ledger_entry_type_check'
    AND c.conrelid = 'public.competition_finance_ledger'::regclass;

  IF v_def IS NULL
     OR position('special_auction_fee' IN v_def) = 0
     OR position('special_auction_prize' IN v_def) = 0 THEN
    RAISE EXCEPTION
      'gpsl_ledger_ensure_entry_types: special_auction types missing after rebuild. def=%',
      coalesce(v_def, '(null)');
  END IF;

  RETURN v_def;
END;
$function$;

COMMENT ON FUNCTION public.gpsl_ledger_ensure_entry_types(text[]) IS
  'Rebuild competition_finance_ledger_entry_type_check from live rows + full GPSL catalogue + optional extras. Use this in every patch that adds a ledger type — never rebuild from live+new-only.';

GRANT EXECUTE ON FUNCTION public.gpsl_ledger_ensure_entry_types(text[]) TO authenticated;

-- Apply now (includes special_auction_fee / prize + bookies + full catalogue)
SELECT public.gpsl_ledger_ensure_entry_types();

-- Prove the types are allowed (read-only check)
DO $verify$
DECLARE
  v_def text;
BEGIN
  SELECT pg_get_constraintdef(c.oid)
  INTO v_def
  FROM pg_constraint c
  WHERE c.conname = 'competition_finance_ledger_entry_type_check'
    AND c.conrelid = 'public.competition_finance_ledger'::regclass;

  RAISE NOTICE 'Ledger entry_type check OK. Contains special_auction_fee=% prize=% bookies_income=%',
    position('special_auction_fee' IN v_def) > 0,
    position('special_auction_prize' IN v_def) > 0,
    position('bookies_income' IN v_def) > 0;
END;
$verify$;

NOTIFY pgrst, 'reload schema';
