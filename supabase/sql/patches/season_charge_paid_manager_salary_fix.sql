-- Allow staff_manager_salary on competition_season_charge_paid
-- (needed by Close Finances / Post season wage bills).
-- Safe to re-run.

ALTER TABLE public.competition_season_charge_paid
  DROP CONSTRAINT IF EXISTS competition_season_charge_paid_charge_type_check;

ALTER TABLE public.competition_season_charge_paid
  ADD CONSTRAINT competition_season_charge_paid_charge_type_check
  CHECK (
    charge_type IN (
      'wage_squad',
      'wage_renewal_34plus',
      'wage_star_tax',
      'staff_manager_salary',
      'gov_emergency_tax',
      'gov_income_tax',
      'eos_ffp_charge',
      'eos_debt_interest',
      'eos_balance_interest'
    )
  );
