-- =============================================================================
-- Finance: income-type clawbacks (negative amounts) are costs, not income
--
-- Mirrors competition.js isFinanceIncomeEntry fix:
--   special_auction_prize / transfer_foreign_sale / etc. with amount < 0
--   are reversals → not income (Outgoing / cost totals).
-- Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.competition_finance_entry_is_income(
  p_entry_type text,
  p_amount numeric
)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT
    CASE
      WHEN p_entry_type = ANY (
        ARRAY[
          'gate_league_home',
          'gate_cup_share',
          'gate_friendlies',
          'gate_match_video',
          'prize',
          'prize_league',
          'prize_cup',
          'prize_challenge',
          'tv_revenue',
          'commercial_sponsorship',
          'commercial_advertising',
          'commercial_merchandise',
          'gov_hg_subsidy',
          'gov_youth_subsidy',
          'gov_bnb_subsidy',
          'adjustment',
          'admin_one_off_injection',
          'transfer_sale',
          'transfer_foreign_sale',
          'transfer_overflow_release',
          'contract_expiry_compensation',
          'loan_drawdown',
          'eos_balance_interest',
          'eos_injection',
          'contract_release_comp_received',
          'special_auction_prize',
          'bookies_income',
          'legacy_card_refund',
          'prize_fee_discount_subsidy',
          'season_loan_refund'
        ]::text[]
      ) THEN coalesce(p_amount, 0) > 0
      ELSE coalesce(p_amount, 0) > 0
    END;
$$;

COMMENT ON FUNCTION public.competition_finance_entry_is_income(text, numeric) IS
  'True when the ledger line counts as income. Income-type rows with amount <= 0 are clawbacks/reversals (costs).';

NOTIFY pgrst, 'reload schema';
