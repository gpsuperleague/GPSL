-- =============================================================================
-- Repair: widen competition_finance_ledger entry_type check (safe re-run)
-- Run if competition_wages_taxes.sql (or an older patch) failed with:
--   check constraint "competition_finance_ledger_entry_type_check" ... violated
-- =============================================================================

ALTER TABLE public.competition_finance_ledger
  DROP CONSTRAINT IF EXISTS competition_finance_ledger_entry_type_check;

ALTER TABLE public.competition_finance_ledger
  ADD CONSTRAINT competition_finance_ledger_entry_type_check
  CHECK (
    entry_type IN (
      'gate_league_home',
      'gate_cup_share',
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
      'staff_manager_salary',
      'eos_debt_interest',
      'eos_ffp_charge',
      'eos_balance_interest',
      'eos_injection',
      'special_auction_fee',
      'special_auction_prize',
      'season_loan_fee',
      'season_loan_refund'
    )
  );

NOTIFY pgrst, 'reload schema';
