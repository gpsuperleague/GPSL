-- =============================================================================
-- Hotfix: Close Finances — competition_season_charge_paid charge_type check
--
-- Error:
--   new row for relation "competition_season_charge_paid" violates check constraint
--   "competition_season_charge_paid_charge_type_check"
--
-- Cause:
--   competition_post_club_wage_bill (fan_favourite_designation.sql) inserts
--   charge_type = 'wage_fan_favourite_subsidy'. No charge_paid CHECK rewrite
--   ever allowed that type. Stadium added infra_maintenance only;
--   ffp_50m_mv_release_embargo.sql does not touch this CHECK.
--
-- Fix:
--   Widen CHECK to live ∪ full known catalogue (never drop types already used).
--   Also allow amount >= 0 so FFP zero-amount idempotency markers can insert.
--
-- Safe re-run. After apply, retry Admin → Close Finances.
-- =============================================================================

DO $charge_paid_types$
DECLARE
  v_list text;
BEGIN
  SELECT string_agg(quote_literal(t), ', ' ORDER BY t)
  INTO v_list
  FROM (
    SELECT DISTINCT charge_type AS t
    FROM public.competition_season_charge_paid
    WHERE charge_type IS NOT NULL
    UNION
    SELECT unnest(ARRAY[
      'wage_squad',
      'wage_renewal_34plus',
      'wage_star_tax',
      'wage_fan_favourite_subsidy',
      'staff_manager_salary',
      'gov_emergency_tax',
      'gov_income_tax',
      'eos_ffp_charge',
      'eos_debt_interest',
      'eos_balance_interest',
      'infra_maintenance'
    ])
  ) s;

  IF v_list IS NULL OR btrim(v_list) = '' THEN
    RAISE EXCEPTION 'season_charge_paid_types_hotfix: empty allow-list';
  END IF;

  ALTER TABLE public.competition_season_charge_paid
    DROP CONSTRAINT IF EXISTS competition_season_charge_paid_charge_type_check;

  EXECUTE format(
    'ALTER TABLE public.competition_season_charge_paid
       ADD CONSTRAINT competition_season_charge_paid_charge_type_check
       CHECK (charge_type IN (%s))',
    v_list
  );
END;
$charge_paid_types$;

-- FFP path may insert amount=0 markers; column was created as amount > 0.
DO $charge_paid_amount$
BEGIN
  ALTER TABLE public.competition_season_charge_paid
    DROP CONSTRAINT IF EXISTS competition_season_charge_paid_amount_check;

  ALTER TABLE public.competition_season_charge_paid
    ADD CONSTRAINT competition_season_charge_paid_amount_check
    CHECK (amount >= 0);
EXCEPTION
  WHEN duplicate_object THEN
    NULL;
  WHEN undefined_object THEN
    -- No prior amount check — add fresh
    ALTER TABLE public.competition_season_charge_paid
      ADD CONSTRAINT competition_season_charge_paid_amount_check
      CHECK (amount >= 0);
END;
$charge_paid_amount$;
