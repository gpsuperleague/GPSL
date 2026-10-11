-- =============================================================================
-- READ-ONLY: ledger entry types posted this season vs what the finance pages map
-- "on_finance_sheet = false" → rows land in "Unmapped ledger" on club Finances.
-- Keep the list below in sync with LEDGER_TYPE_TO_LINE in finance_ui.js.
-- =============================================================================

WITH season AS (
  SELECT id FROM public.competition_seasons WHERE is_current = true ORDER BY id DESC LIMIT 1
),
mapped(t) AS (
  VALUES
    ('transfer_sale'), ('transfer_foreign_sale'), ('transfer_overflow_release'),
    ('contract_expiry_compensation'), ('new_owner_release'), ('prize_fee_discount_subsidy'),
    ('special_auction_fee'), ('contract_expiry_champ_signing_fee'),
    ('season_loan_fee'), ('season_loan_refund'), ('emergency_loan_fee'),
    ('special_auction_prize'), ('transfer_purchase'), ('transfer_agent_fee'), ('legacy_card_refund'),
    ('gate_league_home'), ('gate_cup_share'), ('gate_friendlies'), ('gate_match_video'),
    ('prize'), ('prize_league'), ('prize_cup'), ('prize_challenge'), ('tv_revenue'),
    ('commercial_sponsorship'), ('commercial_advertising'), ('commercial_merchandise'),
    ('infra_maintenance'), ('infra_purchase'), ('infra_expansion'), ('infra_expansion_refund'),
    ('infra_expansion_penalty'), ('gov_fine_compensation'), ('gov_hg_subsidy'),
    ('gov_youth_subsidy'), ('gov_bnb_subsidy'), ('gov_emergency_tax'), ('gov_income_tax'),
    ('wage_squad'), ('wage_fan_favourite_subsidy'), ('wage_renewal_34plus'), ('wage_star_tax'),
    ('staff_manager_salary'), ('medical_doctor_hire'), ('medical_physio_hire'),
    ('contract_signing_offer'), ('contract_release_comp'), ('contract_release_comp_received'),
    ('contract_termination'), ('eos_debt_interest'), ('eos_ffp_charge'), ('eos_balance_interest'),
    ('eos_injection'), ('admin_one_off_injection'), ('adjustment'), ('admin_purchase_payment'),
    ('loan_drawdown'), ('loan_repayment_principal'), ('loan_interest_payment')
)
SELECT
  l.entry_type,
  EXISTS (SELECT 1 FROM mapped m WHERE m.t = l.entry_type) AS on_finance_sheet,
  count(*) AS rows,
  count(DISTINCT l.club_short_name) AS clubs,
  sum(l.amount) AS total,
  max(l.created_at) AT TIME ZONE 'Europe/London' AS latest_uk
FROM public.competition_finance_ledger l
JOIN season s ON s.id = l.season_id
GROUP BY l.entry_type
ORDER BY on_finance_sheet, rows DESC;
