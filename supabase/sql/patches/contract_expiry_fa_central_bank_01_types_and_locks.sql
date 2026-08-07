-- =============================================================================
-- PART 1/4 — Contract expiry FA → Central Bank (types + locks)
--
-- Run this first in Supabase SQL Editor.
-- Then: _02_assign_and_release.sql → _03_history_classify.sql → _04_backfill.sql
--
-- Safe re-run. If the editor says "Failed to fetch", run each part separately
-- (do not paste the combined monolith).
-- =============================================================================

SET statement_timeout = '120s';

-- Ledger entry type allow-list (union live + catalogue + new type)
DO $ledger_types$
DECLARE
  v_list text;
BEGIN
  SELECT string_agg(quote_literal(t), ', ' ORDER BY t)
  INTO v_list
  FROM (
    SELECT DISTINCT entry_type AS t
    FROM public.competition_finance_ledger
    WHERE entry_type IS NOT NULL
    UNION
    SELECT unnest(ARRAY[
      'gate_league_home', 'gate_cup_share', 'gate_friendlies',
      'prize', 'prize_league', 'prize_cup', 'prize_challenge',
      'tv_revenue',
      'gov_hg_subsidy', 'gov_youth_subsidy', 'gov_bnb_subsidy',
      'gov_fine_compensation', 'gov_emergency_tax', 'gov_income_tax',
      'wage_squad', 'wage_renewal_34plus', 'wage_star_tax',
      'adjustment', 'admin_one_off_injection', 'admin_purchase_payment',
      'transfer_sale', 'transfer_purchase', 'transfer_agent_fee',
      'transfer_foreign_sale', 'transfer_overflow_release',
      'loan_drawdown', 'loan_repayment_principal', 'loan_interest_payment',
      'infra_maintenance', 'infra_purchase', 'infra_expansion',
      'infra_expansion_refund', 'infra_expansion_penalty',
      'contract_release_comp', 'contract_release_comp_received',
      'contract_termination', 'contract_signing_offer',
      'contract_expiry_compensation',
      'staff_manager_salary',
      'eos_debt_interest', 'eos_ffp_charge', 'eos_balance_interest', 'eos_injection',
      'special_auction_fee', 'special_auction_prize',
      'season_loan_fee', 'season_loan_refund',
      'new_owner_release', 'voluntary_contract_release',
      'medical_physio_hire', 'medical_doctor_hire',
      'contract_expiry_champ_signing_fee'
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
END;
$ledger_types$;

CREATE OR REPLACE FUNCTION public.finance_entry_via_central_bank(p_entry_type text)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT coalesce(p_entry_type, '') = ANY(ARRAY[
    'gov_hg_subsidy',
    'gov_youth_subsidy',
    'gov_bnb_subsidy',
    'gov_emergency_tax',
    'gov_income_tax',
    'gov_fine_compensation',
    'wage_star_tax',
    'eos_debt_interest',
    'eos_ffp_charge',
    'eos_balance_interest',
    'eos_injection',
    'prize',
    'prize_league',
    'prize_cup',
    'prize_challenge',
    'prize_fee_discount_subsidy',
    'tv_revenue',
    'infra_purchase',
    'infra_expansion',
    'infra_expansion_refund',
    'infra_expansion_penalty',
    'loan_drawdown',
    'loan_repayment_principal',
    'loan_interest_payment',
    'admin_one_off_injection',
    'contract_release_comp_received',
    'contract_expiry_compensation',
    'special_auction_prize'
  ]);
$$;

COMMENT ON FUNCTION public.finance_entry_via_central_bank(text) IS
  'Model A: true when club ledger line should mirror a GPSL Central Bank leg. '
  'contract_expiry_compensation = Central Bank MV payout on uncontested contract ends.';

ALTER TABLE public."Players"
  DROP CONSTRAINT IF EXISTS players_foreign_contract_lock_kind_check;

ALTER TABLE public."Players"
  ADD CONSTRAINT players_foreign_contract_lock_kind_check
  CHECK (
    foreign_contract_lock_kind IS NULL
    OR foreign_contract_lock_kind IN ('foreign', 'paid_up', 'expiry_fa')
  );

COMMENT ON COLUMN public."Players".foreign_contract_lock_kind IS
  'foreign = sold abroad (all clubs blocked); paid_up = overflow release (all clubs blocked); '
  'expiry_fa = contract ended → FA for other clubs only (former club blocked).';

CREATE OR REPLACE FUNCTION public.player_foreign_contract_locked(p_player_id text)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public."Players" p
    WHERE p."Konami_ID"::text = btrim(p_player_id)
      AND p.foreign_contract_club IS NOT NULL
      AND btrim(p.foreign_contract_club) <> ''
      AND p.foreign_contract_sold_season_id IS NOT NULL
      AND p.foreign_contract_sold_season_id = public.current_gpsl_season_id()
      AND coalesce(nullif(btrim(p.foreign_contract_lock_kind), ''), 'foreign')
            IN ('foreign', 'paid_up')
  );
$$;

CREATE OR REPLACE FUNCTION public.player_expiry_fa_former_club(p_player_id text)
RETURNS text
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT nullif(btrim(p.foreign_contract_club), '')
  FROM public."Players" p
  WHERE p."Konami_ID"::text = btrim(p_player_id)
    AND coalesce(nullif(btrim(p.foreign_contract_lock_kind), ''), '') = 'expiry_fa'
    AND p."Contracted_Team" IS NULL
$$;

CREATE OR REPLACE FUNCTION public.assert_club_may_sign_expiry_fa_player(
  p_player_id text,
  p_club_short_name text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_former text;
  v_club text := btrim(p_club_short_name);
BEGIN
  v_former := public.player_expiry_fa_former_club(p_player_id);
  IF v_former IS NULL OR v_club IS NULL OR v_club = '' THEN
    RETURN;
  END IF;

  IF lower(v_former) = lower(v_club) THEN
    RAISE EXCEPTION
      'You cannot re-sign this player after their contract expired — they returned to the GPDB as a free agent for other clubs only';
  END IF;
END;
$function$;

CREATE OR REPLACE FUNCTION public.player_apply_expiry_fa_former_club_block(
  p_player_id text,
  p_former_club_short_name text,
  p_sold_season_id bigint DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_pid text := btrim(p_player_id);
  v_club text := btrim(p_former_club_short_name);
  v_sold_season_id bigint;
BEGIN
  IF v_pid = '' THEN
    RAISE EXCEPTION 'player_apply_expiry_fa_former_club_block: player_id required';
  END IF;
  IF v_club = '' THEN
    RAISE EXCEPTION 'player_apply_expiry_fa_former_club_block: former club required';
  END IF;

  v_sold_season_id := coalesce(p_sold_season_id, public.gpsl_season_id_for_locks());
  IF v_sold_season_id IS NULL THEN
    v_sold_season_id := public.current_gpsl_season_id();
  END IF;

  UPDATE public."Players"
  SET
    foreign_contract_club = v_club,
    foreign_contract_sold_season_id = v_sold_season_id,
    foreign_contract_unlock_season_label = 'when signed by another club',
    foreign_contract_lock_kind = 'expiry_fa'
  WHERE "Konami_ID"::text = v_pid;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.player_expiry_fa_former_club(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.assert_club_may_sign_expiry_fa_player(text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.player_apply_expiry_fa_former_club_block(text, text, bigint)
  TO authenticated;

SELECT 'PART 1 OK — types + locks' AS status;
