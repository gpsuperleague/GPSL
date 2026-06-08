-- =============================================================================
-- Voluntary "Release from contract" — up to 3 per club per season
-- Cost = contract_wage × contract_seasons_remaining (debit, no MV credit)
-- Player: paid-up lock until next season (same as squad MV overflow)
-- Run after: squad_overflow_paid_up_fine.sql, foreign_interest_teams.sql
-- =============================================================================

ALTER TABLE public."Clubs"
  ADD COLUMN IF NOT EXISTS voluntary_contract_releases_remaining smallint NOT NULL DEFAULT 3;

ALTER TABLE public."Clubs"
  DROP CONSTRAINT IF EXISTS clubs_voluntary_contract_releases_remaining_check;

ALTER TABLE public."Clubs"
  ADD CONSTRAINT clubs_voluntary_contract_releases_remaining_check
  CHECK (
    voluntary_contract_releases_remaining >= 0
    AND voluntary_contract_releases_remaining <= 3
  );

COMMENT ON COLUMN public."Clubs".voluntary_contract_releases_remaining IS
  'Squad action: release from contract (pay remaining wages). Max 3 per season; resets on season activate.';

-- Ledger type (Finances → Contract releases)
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
      'eos_injection',
      'special_auction_fee',
      'special_auction_prize'
    )
  );

CREATE OR REPLACE FUNCTION public.calculate_voluntary_contract_release_cost(
  p_contract_wage numeric,
  p_seasons_remaining int
)
RETURNS numeric
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT round(
    greatest(coalesce(p_contract_wage, 0), 0)
    * greatest(coalesce(p_seasons_remaining, 0), 0),
    0
  );
$$;

CREATE OR REPLACE FUNCTION public.club_reset_voluntary_contract_releases()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  UPDATE public."Clubs" c
  SET voluntary_contract_releases_remaining = 3
  WHERE c."ShortName" <> 'FOREIGN';
END;
$function$;

CREATE OR REPLACE FUNCTION public.club_voluntary_contract_release_state()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text;
  v_remaining int;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  v_club := public.my_club_shortname();
  IF v_club IS NULL OR btrim(v_club) = '' THEN
    RAISE EXCEPTION 'No club linked to this account';
  END IF;

  SELECT greatest(coalesce(c.voluntary_contract_releases_remaining, 0), 0)
  INTO v_remaining
  FROM public."Clubs" c
  WHERE c."ShortName" = v_club;

  RETURN jsonb_build_object(
    'club_shortname', v_club,
    'voluntary_contract_releases_remaining', coalesce(v_remaining, 0),
    'max_per_season', 3
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.player_voluntary_contract_release(p_player_id text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club           text;
  v_pid            text := btrim(p_player_id);
  v_player         public."Players"%rowtype;
  v_remaining      int;
  v_cost           numeric;
  v_balance        numeric;
  v_seasons        int;
  v_wage           numeric;
  v_unlock         text;
  v_ledger_id      bigint;
  v_desc           text;
  v_season_id      bigint;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  v_club := public.my_club_shortname();
  IF v_club IS NULL OR btrim(v_club) = '' THEN
    RAISE EXCEPTION 'No club linked to this account';
  END IF;

  SELECT greatest(coalesce(c.voluntary_contract_releases_remaining, 0), 0)
  INTO v_remaining
  FROM public."Clubs" c
  WHERE c."ShortName" = v_club
  FOR UPDATE;

  IF coalesce(v_remaining, 0) <= 0 THEN
    RAISE EXCEPTION
      'No voluntary contract releases remaining this season (maximum 3).';
  END IF;

  SELECT *
  INTO v_player
  FROM public."Players"
  WHERE "Konami_ID"::text = v_pid
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Player not found';
  END IF;

  IF public.player_contracted_club_key(v_player."Contracted_Team") IS DISTINCT FROM v_club THEN
    RAISE EXCEPTION 'Player is not at your club';
  END IF;

  v_seasons := coalesce(v_player.contract_seasons_remaining, 0);
  IF v_seasons < 1 THEN
    RAISE EXCEPTION 'Player has no active contract seasons remaining';
  END IF;

  v_wage := greatest(coalesce(v_player.contract_wage, 0), 0);
  v_cost := public.calculate_voluntary_contract_release_cost(v_wage, v_seasons);

  IF v_cost <= 0 THEN
    RAISE EXCEPTION 'Could not calculate contract buy-out cost for this player';
  END IF;

  SELECT balance
  INTO v_balance
  FROM public."Club_Finances"
  WHERE club_name = v_club
  FOR UPDATE;

  IF v_balance IS NULL THEN
    RAISE EXCEPTION 'Club finances not found for %', v_club;
  END IF;

  IF v_balance < v_cost THEN
    RAISE EXCEPTION
      'Insufficient balance. Contract buy-out costs ₿ % (balance ₿ %).',
      to_char(v_cost, 'FM999999999999'),
      to_char(v_balance, 'FM999999999999');
  END IF;

  UPDATE public."Player_Transfer_Listings" l
  SET status = 'Closed',
      transfer_completed = false,
      winning_bid = null,
      winning_club = null
  WHERE l.player_id::text = v_pid
    AND l.seller_club_id = v_club
    AND l.status IN ('Active', 'Review');

  UPDATE public."Player_Transfer_Bids" b
  SET status = 'rejected'
  WHERE b.is_direct = true
    AND b.listing_id IS NULL
    AND lower(coalesce(b.status::text, '')) = 'active'
    AND (
      (b.player_id IS NOT NULL AND btrim(b.player_id::text) = v_pid)
      OR (b.direct_bid_id IS NOT NULL AND btrim(b.direct_bid_id::text) = v_pid)
    );

  PERFORM public.player_release_from_club(v_pid);
  PERFORM public.player_apply_overflow_paid_up_lock(v_pid, v_club);

  v_unlock := public.next_gpsl_season_label(public.current_gpsl_season_id());

  UPDATE public."Club_Finances"
  SET balance = v_balance - v_cost
  WHERE club_name = v_club;

  UPDATE public."Clubs" c
  SET voluntary_contract_releases_remaining = voluntary_contract_releases_remaining - 1
  WHERE c."ShortName" = v_club
  RETURNING c.voluntary_contract_releases_remaining INTO v_remaining;

  v_season_id := public.current_gpsl_season_id();
  v_desc := format(
    'Contract release buy-out: %s (%s seasons × wage)',
    v_player."Name",
    v_seasons
  );

  v_ledger_id := public.post_club_ledger(
    v_club,
    'contract_release_comp',
    -abs(v_cost),
    v_desc,
    jsonb_build_object(
      'player_id', v_pid,
      'player_name', v_player."Name",
      'contract_wage', v_wage,
      'contract_seasons_remaining', v_seasons,
      'voluntary_contract_release', true
    ),
    v_season_id,
    NULL,
    false,
    false
  );

  INSERT INTO public."Transfer_History" (
    player_id,
    seller_club_id,
    buyer_club_id,
    fee,
    agent_fee,
    transfer_time,
    listing_id,
    foreign_buyer_name,
    transfer_sale_note
  )
  VALUES (
    v_player."Konami_ID",
    v_club,
    NULL,
    0,
    0,
    now(),
    NULL,
    format('Voluntary release (₿ %s buy-out)', to_char(v_cost, 'FM999999999999')),
    'voluntary_contract_release'
  );

  RETURN jsonb_build_object(
    'ok', true,
    'player_id', v_pid,
    'player_name', v_player."Name",
    'buyout_cost', v_cost,
    'contract_wage', v_wage,
    'contract_seasons_remaining', v_seasons,
    'new_balance', v_balance - v_cost,
    'voluntary_contract_releases_remaining', v_remaining,
    'unavailable_until_season', v_unlock,
    'ledger_id', v_ledger_id
  );
END;
$function$;

-- Reset voluntary release slots when a new season goes active
CREATE OR REPLACE FUNCTION public.competition_activate_season(p_season_id bigint)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_sl bigint;
  v_a bigint;
  v_b bigint;
  v_bad bigint;
BEGIN
  PERFORM public.competition_assert_setup_season(p_season_id);

  SELECT count(*) INTO v_sl
  FROM public.competition_club_seasons
  WHERE season_id = p_season_id AND division = 'superleague';

  SELECT count(*) INTO v_a
  FROM public.competition_club_seasons
  WHERE season_id = p_season_id AND division = 'championship_a';

  SELECT count(*) INTO v_b
  FROM public.competition_club_seasons
  WHERE season_id = p_season_id AND division = 'championship_b';

  SELECT count(*) INTO v_bad
  FROM public.competition_club_seasons
  WHERE season_id = p_season_id
    AND division IN ('unassigned', 'championship_pool');

  IF v_sl <> 20 OR v_a <> 20 OR v_b <> 20 THEN
    RAISE EXCEPTION 'Need 20 SuperLeague + 20 CH A + 20 CH B (have % / % / %)',
      v_sl, v_a, v_b;
  END IF;

  IF v_bad > 0 THEN
    RAISE EXCEPTION '% clubs still unassigned or in championship pool', v_bad;
  END IF;

  UPDATE public.competition_seasons
  SET is_current = false
  WHERE is_current = true;

  UPDATE public.competition_seasons
  SET status = 'active',
      is_current = true,
      started_at = coalesce(started_at, now())
  WHERE id = p_season_id;

  PERFORM public.club_reset_voluntary_contract_releases();
END;
$function$;

GRANT EXECUTE ON FUNCTION public.calculate_voluntary_contract_release_cost(numeric, int) TO authenticated;
GRANT EXECUTE ON FUNCTION public.club_voluntary_contract_release_state() TO authenticated;
GRANT EXECUTE ON FUNCTION public.player_voluntary_contract_release(text) TO authenticated;

NOTIFY pgrst, 'reload schema';
