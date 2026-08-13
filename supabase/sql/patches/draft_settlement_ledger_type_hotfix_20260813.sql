-- =============================================================================
-- HOTFIX 2026-08-13 — Draft settlement stuck (97 Active)
--
-- Diagnose error on every accept_draft_sale:
--   competition_finance_ledger_entry_type_check violated
--
-- Cause: Fan Favourite ledger allow-list rebuild used live rows + wage-only
--        types, dropping transfer_purchase (and related transfer types).
--
-- Run order:
--   1) This whole file
--   2) SELECT public.transferengine_diagnose_stuck_drafts(5);
--      → samples should show ok:true (dry_run)
--   3) SELECT public.transferengine_settle_player_draft_listings_report(50);
--      Repeat until active_remaining = 0
--   4) Deploy helpers in draft_settlement_incident_20260813.sql if not yet, then:
--      SELECT public.admin_repair_draft_missing_purchase_ledgers(true);
--      SELECT public.admin_repair_draft_missing_purchase_ledgers(false);
--      SELECT public.admin_enforce_all_squad_overflow(true);
--      SELECT public.admin_enforce_all_squad_overflow(false);
-- =============================================================================

DO $ledger_types$
DECLARE
  v_list text;
  v_unknown text;
BEGIN
  SELECT string_agg(t, ', ' ORDER BY t)
  INTO v_unknown
  FROM (
    SELECT DISTINCT entry_type AS t
    FROM public.competition_finance_ledger
    WHERE entry_type IS NOT NULL
      AND entry_type NOT IN (
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
        'medical_doctor_hire'
      )
  ) u;

  IF v_unknown IS NOT NULL THEN
    RAISE NOTICE 'Live ledger has extra entry_type(s) not in catalogue (still allowed): %', v_unknown;
  END IF;

  SELECT string_agg(quote_literal(t), ', ' ORDER BY t)
  INTO v_list
  FROM (
    SELECT DISTINCT entry_type AS t
    FROM public.competition_finance_ledger
    WHERE entry_type IS NOT NULL
    UNION
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
      'medical_doctor_hire'
    ])
  ) s;

  IF v_list IS NULL OR length(v_list) < 3 THEN
    RAISE EXCEPTION 'Could not build entry_type allow-list';
  END IF;

  ALTER TABLE public.competition_finance_ledger
    DROP CONSTRAINT IF EXISTS competition_finance_ledger_entry_type_check;

  EXECUTE format(
    'ALTER TABLE public.competition_finance_ledger
       ADD CONSTRAINT competition_finance_ledger_entry_type_check
       CHECK (entry_type IN (%s))',
    v_list
  );

  RAISE NOTICE 'competition_finance_ledger_entry_type_check rebuilt successfully';
END;
$ledger_types$;

-- Confirm transfer_purchase is allowed
SELECT
  pg_get_constraintdef(c.oid) LIKE '%transfer_purchase%' AS allows_transfer_purchase,
  pg_get_constraintdef(c.oid) LIKE '%transfer_overflow_release%' AS allows_overflow_release,
  pg_get_constraintdef(c.oid) LIKE '%wage_fan_favourite_subsidy%' AS allows_fan_favourite
FROM pg_constraint c
WHERE c.conname = 'competition_finance_ledger_entry_type_check';

NOTIFY pgrst, 'reload schema';
