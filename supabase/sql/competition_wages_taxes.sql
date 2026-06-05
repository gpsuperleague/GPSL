-- =============================================================================
-- GPSL — Season wage bill + upkeep taxes (34+ / star) + emergency TAC
-- Run once after competition_challenges.sql
-- =============================================================================

ALTER TABLE public.global_settings
  ADD COLUMN IF NOT EXISTS wage_34plus_min_rating smallint NOT NULL DEFAULT 34,
  ADD COLUMN IF NOT EXISTS wage_34plus_per_player numeric(14, 2) NOT NULL DEFAULT 500000,
  ADD COLUMN IF NOT EXISTS star_tax_min_rating smallint NOT NULL DEFAULT 70,
  ADD COLUMN IF NOT EXISTS star_tax_per_player numeric(14, 2) NOT NULL DEFAULT 1000000,
  ADD COLUMN IF NOT EXISTS emergency_tac_pct numeric(6, 3) NOT NULL DEFAULT 10.000,
  ADD COLUMN IF NOT EXISTS emergency_tac_threshold numeric(14, 2) NOT NULL DEFAULT 100000000;

-- ---------------------------------------------------------------------------
-- Ledger types
-- ---------------------------------------------------------------------------

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
      'infra_expansion_penalty'
    )
  );

DROP VIEW IF EXISTS public.global_settings_public;

CREATE VIEW public.global_settings_public
WITH (security_invoker = false)
AS
SELECT
  id,
  transfer_window_open,
  draft_auction_enabled,
  draft_auction_start_time,
  updated_at,
  wage_pct_superleague,
  wage_pct_championship,
  stadium_cost_tier1,
  stadium_cost_tier2,
  stadium_cost_tier3,
  stadium_capacity_tier_mid,
  stadium_capacity_tier_high,
  stadium_expansion_cancel_penalty,
  hg_sub_band1_max,
  hg_sub_band1_per_player,
  hg_sub_band2_max,
  hg_sub_band2_per_player,
  hg_sub_band3_per_player,
  youth_sub_band1_max,
  youth_sub_band1_per_player,
  youth_sub_band2_max,
  youth_sub_band2_per_player,
  youth_sub_band3_max,
  youth_sub_band3_per_player,
  youth_sub_band4_per_player,
  bnb_max_rating,
  bnb_min_players,
  bnb_per_player,
  tv_per_match_amount,
  tv_matches_per_month,
  tv_club_min_season,
  tv_club_max_season,
  tv_weight_top8_clash,
  tv_weight_title_race,
  tv_weight_promotion,
  tv_weight_relegation,
  tv_weight_super8,
  tv_weight_playoff,
  tv_weight_dry_spell,
  tv_weight_below_min,
  challenge_default_prize,
  challenge_period_bonus,
  wage_34plus_min_rating,
  wage_34plus_per_player,
  star_tax_min_rating,
  star_tax_per_player,
  emergency_tac_pct,
  emergency_tac_threshold
FROM public.global_settings;

GRANT SELECT ON public.global_settings_public TO authenticated;
GRANT SELECT ON public.global_settings_public TO anon;

-- ---------------------------------------------------------------------------
-- Idempotent season charge tracking
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.competition_season_charge_paid (
  season_id bigint NOT NULL REFERENCES public.competition_seasons (id) ON DELETE CASCADE,
  club_short_name text NOT NULL REFERENCES public."Clubs" ("ShortName"),
  charge_type text NOT NULL CHECK (
    charge_type IN ('wage_squad', 'wage_renewal_34plus', 'wage_star_tax', 'gov_emergency_tax')
  ),
  amount numeric(14, 2) NOT NULL CHECK (amount > 0),
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  paid_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (season_id, club_short_name, charge_type)
);

ALTER TABLE public.competition_season_charge_paid ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS competition_season_charge_paid_select ON public.competition_season_charge_paid;
CREATE POLICY competition_season_charge_paid_select ON public.competition_season_charge_paid
  FOR SELECT TO authenticated USING (true);

-- ---------------------------------------------------------------------------
-- Compute amounts
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.competition_player_base_rating(p_player_id text)
RETURNS int
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT CASE
    WHEN p."Rating" IS NULL OR btrim(p."Rating"::text) = '' THEN NULL
    ELSE btrim(p."Rating"::text)::int
  END
  FROM public."Players" p
  WHERE p."Konami_ID"::text = p_player_id;
$$;

CREATE OR REPLACE FUNCTION public.competition_club_wage_bill_total(
  p_club_short_name text,
  p_season_id bigint DEFAULT NULL
)
RETURNS numeric
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_total numeric := 0;
  v_row record;
  v_wage numeric;
BEGIN
  FOR v_row IN
    SELECT p."Konami_ID"::text AS player_id, p.contract_wage
    FROM public."Players" p
    WHERE p."Contracted_Team" = p_club_short_name
  LOOP
    v_wage := coalesce(
      v_row.contract_wage,
      public.calculate_player_wage_for_club(v_row.player_id, p_club_short_name)
    );
    v_total := v_total + coalesce(v_wage, 0);
  END LOOP;

  RETURN round(v_total, 0);
END;
$function$;

CREATE OR REPLACE FUNCTION public.competition_club_34plus_count(p_club_short_name text)
RETURNS int
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_min int;
BEGIN
  v_min := (SELECT wage_34plus_min_rating FROM public.global_settings WHERE id = 1);

  RETURN (
    SELECT count(*)::int
    FROM public."Players" p
    WHERE p."Contracted_Team" = p_club_short_name
      AND p."Rating" IS NOT NULL
      AND btrim(p."Rating"::text) <> ''
      AND btrim(p."Rating"::text)::int >= coalesce(v_min, 34)
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.competition_club_star_tax_count(p_club_short_name text)
RETURNS int
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_min int;
BEGIN
  v_min := (SELECT star_tax_min_rating FROM public.global_settings WHERE id = 1);

  RETURN (
    SELECT count(*)::int
    FROM public."Players" p
    WHERE p."Contracted_Team" = p_club_short_name
      AND p."Rating" IS NOT NULL
      AND btrim(p."Rating"::text) <> ''
      AND btrim(p."Rating"::text)::int >= coalesce(v_min, 70)
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.competition_club_emergency_tac_amount(p_club_short_name text)
RETURNS numeric
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_balance numeric;
  v_pct numeric;
  v_threshold numeric;
  v_excess numeric;
BEGIN
  SELECT balance INTO v_balance
  FROM public."Club_Finances"
  WHERE club_name = p_club_short_name;

  SELECT emergency_tac_pct, emergency_tac_threshold
  INTO v_pct, v_threshold
  FROM public.global_settings
  WHERE id = 1;

  IF v_balance IS NULL OR v_balance <= coalesce(v_threshold, 0) THEN
    RETURN 0;
  END IF;

  v_excess := v_balance - v_threshold;
  RETURN round(v_excess * coalesce(v_pct, 0) / 100.0, 0);
END;
$function$;

CREATE OR REPLACE FUNCTION public.competition_club_upkeep_preview(p_club_short_name text)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := btrim(p_club_short_name);
  v_me text := public.my_club_shortname();
  v_season_id bigint;
  v_s public.global_settings;
  v_wage numeric;
  v_34 int;
  v_star int;
  v_34_amt numeric;
  v_star_amt numeric;
  v_tac numeric;
BEGIN
  IF v_club IS NULL OR v_club = '' THEN
    RAISE EXCEPTION 'Club required';
  END IF;

  IF NOT public.is_gpsl_admin() AND (v_me IS NULL OR v_me <> v_club) THEN
    RAISE EXCEPTION 'Not allowed';
  END IF;

  SELECT id INTO v_season_id
  FROM public.competition_seasons
  WHERE is_current = true
  ORDER BY id DESC
  LIMIT 1;

  v_s := (SELECT g FROM public.global_settings g WHERE g.id = 1);
  v_wage := public.competition_club_wage_bill_total(v_club, v_season_id);
  v_34 := public.competition_club_34plus_count(v_club);
  v_star := public.competition_club_star_tax_count(v_club);
  v_34_amt := round(v_34 * coalesce(v_s.wage_34plus_per_player, 0), 0);
  v_star_amt := round(v_star * coalesce(v_s.star_tax_per_player, 0), 0);
  v_tac := public.competition_club_emergency_tac_amount(v_club);

  RETURN jsonb_build_object(
    'season_id', v_season_id,
    'club_short_name', v_club,
    'wage_bill', v_wage,
    'players_34plus', v_34,
    'amount_34plus', v_34_amt,
    'players_star_tax', v_star,
    'amount_star_tax', v_star_amt,
    'emergency_tac_amount', v_tac,
    'settings', jsonb_build_object(
      'wage_34plus_min_rating', v_s.wage_34plus_min_rating,
      'wage_34plus_per_player', v_s.wage_34plus_per_player,
      'star_tax_min_rating', v_s.star_tax_min_rating,
      'star_tax_per_player', v_s.star_tax_per_player,
      'emergency_tac_pct', v_s.emergency_tac_pct,
      'emergency_tac_threshold', v_s.emergency_tac_threshold
    )
  );
END;
$function$;

-- ---------------------------------------------------------------------------
-- Post charges (debit club)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.competition_post_club_charge(
  p_season_id bigint,
  p_club_short_name text,
  p_charge_type text,
  p_amount numeric,
  p_description text,
  p_metadata jsonb DEFAULT '{}'::jsonb
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF p_amount IS NULL OR p_amount <= 0 THEN
    RETURN false;
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.competition_season_charge_paid
    WHERE season_id = p_season_id
      AND club_short_name = p_club_short_name
      AND charge_type = p_charge_type
  ) THEN
    RETURN false;
  END IF;

  PERFORM public.competition_credit_club_balance(p_club_short_name, -p_amount);

  INSERT INTO public.competition_finance_ledger (
    season_id, fixture_id, club_short_name, entry_type, amount, description, metadata
  )
  VALUES (
    p_season_id,
    NULL,
    p_club_short_name,
    p_charge_type,
    -p_amount,
    p_description,
    p_metadata
  );

  INSERT INTO public.competition_season_charge_paid (
    season_id, club_short_name, charge_type, amount, metadata
  )
  VALUES (
    p_season_id, p_club_short_name, p_charge_type, p_amount, p_metadata
  );

  RETURN true;
END;
$function$;

CREATE OR REPLACE FUNCTION public.competition_post_club_wage_bill(
  p_season_id bigint,
  p_club_short_name text
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_amount numeric;
BEGIN
  v_amount := public.competition_club_wage_bill_total(p_club_short_name, p_season_id);

  RETURN public.competition_post_club_charge(
    p_season_id,
    p_club_short_name,
    'wage_squad',
    v_amount,
    format('Season squad wages — %s players', (
      SELECT count(*)::int FROM public."Players" WHERE "Contracted_Team" = p_club_short_name
    )),
    jsonb_build_object('wage_bill', v_amount)
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.competition_post_club_34plus_tax(
  p_season_id bigint,
  p_club_short_name text
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_count int;
  v_rate numeric;
  v_min int;
  v_amount numeric;
BEGIN
  v_count := public.competition_club_34plus_count(p_club_short_name);
  IF v_count = 0 THEN
    RETURN false;
  END IF;

  SELECT wage_34plus_per_player, wage_34plus_min_rating
  INTO v_rate, v_min
  FROM public.global_settings WHERE id = 1;

  v_amount := round(v_count * coalesce(v_rate, 0), 0);

  RETURN public.competition_post_club_charge(
    p_season_id,
    p_club_short_name,
    'wage_renewal_34plus',
    v_amount,
    format('%s+ rating fee — %s player(s)', coalesce(v_min, 34), v_count),
    jsonb_build_object('player_count', v_count, 'min_rating', v_min)
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.competition_post_club_star_tax(
  p_season_id bigint,
  p_club_short_name text
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_count int;
  v_rate numeric;
  v_min int;
  v_amount numeric;
BEGIN
  v_count := public.competition_club_star_tax_count(p_club_short_name);
  IF v_count = 0 THEN
    RETURN false;
  END IF;

  SELECT star_tax_per_player, star_tax_min_rating
  INTO v_rate, v_min
  FROM public.global_settings WHERE id = 1;

  v_amount := round(v_count * coalesce(v_rate, 0), 0);

  RETURN public.competition_post_club_charge(
    p_season_id,
    p_club_short_name,
    'wage_star_tax',
    v_amount,
    format('Star tax — %s player(s) rated %s+', v_count, coalesce(v_min, 70)),
    jsonb_build_object('player_count', v_count, 'min_rating', v_min)
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.competition_post_club_emergency_tac(
  p_season_id bigint,
  p_club_short_name text
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_amount numeric;
  v_pct numeric;
  v_threshold numeric;
  v_balance numeric;
BEGIN
  v_amount := public.competition_club_emergency_tac_amount(p_club_short_name);
  IF v_amount <= 0 THEN
    RETURN false;
  END IF;

  SELECT emergency_tac_pct, emergency_tac_threshold
  INTO v_pct, v_threshold
  FROM public.global_settings WHERE id = 1;

  SELECT balance INTO v_balance
  FROM public."Club_Finances"
  WHERE club_name = p_club_short_name;

  RETURN public.competition_post_club_charge(
    p_season_id,
    p_club_short_name,
    'gov_emergency_tax',
    v_amount,
    format('Emergency TAC — %s%% on balance above %s', v_pct, v_threshold),
    jsonb_build_object(
      'balance', v_balance,
      'threshold', v_threshold,
      'pct', v_pct
    )
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.competition_post_club_season_upkeep(
  p_season_id bigint,
  p_club_short_name text
)
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_n int := 0;
BEGIN
  IF public.competition_post_club_wage_bill(p_season_id, p_club_short_name) THEN
    v_n := v_n + 1;
  END IF;
  IF public.competition_post_club_34plus_tax(p_season_id, p_club_short_name) THEN
    v_n := v_n + 1;
  END IF;
  IF public.competition_post_club_star_tax(p_season_id, p_club_short_name) THEN
    v_n := v_n + 1;
  END IF;
  RETURN v_n;
END;
$function$;

-- ---------------------------------------------------------------------------
-- Admin RPCs
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.admin_update_upkeep_tax_settings(p_settings jsonb)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  UPDATE public.global_settings
  SET
    wage_34plus_min_rating = coalesce((p_settings->>'wage_34plus_min_rating')::smallint, wage_34plus_min_rating),
    wage_34plus_per_player = coalesce((p_settings->>'wage_34plus_per_player')::numeric, wage_34plus_per_player),
    star_tax_min_rating = coalesce((p_settings->>'star_tax_min_rating')::smallint, star_tax_min_rating),
    star_tax_per_player = coalesce((p_settings->>'star_tax_per_player')::numeric, star_tax_per_player),
    emergency_tac_pct = coalesce((p_settings->>'emergency_tac_pct')::numeric, emergency_tac_pct),
    emergency_tac_threshold = coalesce((p_settings->>'emergency_tac_threshold')::numeric, emergency_tac_threshold),
    updated_at = now()
  WHERE id = 1;
END;
$function$;

CREATE OR REPLACE FUNCTION public.competition_admin_post_season_wage_bills(
  p_season_id bigint DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season_id bigint;
  v_club text;
  v_lines int := 0;
  v_clubs int := 0;
  v_n int;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF p_season_id IS NULL THEN
    SELECT id INTO v_season_id
    FROM public.competition_seasons
    WHERE is_current = true
    ORDER BY id DESC
    LIMIT 1;
  ELSE
    v_season_id := p_season_id;
  END IF;

  FOR v_club IN
    SELECT ccs.club_short_name
    FROM public.competition_club_seasons ccs
    WHERE ccs.season_id = v_season_id
      AND ccs.division IN ('superleague', 'championship_a', 'championship_b')
  LOOP
    v_n := public.competition_post_club_season_upkeep(v_season_id, v_club);
    IF v_n > 0 THEN
      v_clubs := v_clubs + 1;
      v_lines := v_lines + v_n;
    END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'season_id', v_season_id,
    'clubs_charged', v_clubs,
    'charge_lines', v_lines
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.competition_admin_apply_emergency_tac(
  p_season_id bigint DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season_id bigint;
  v_club text;
  v_paid int := 0;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF p_season_id IS NULL THEN
    SELECT id INTO v_season_id
    FROM public.competition_seasons
    WHERE is_current = true
    ORDER BY id DESC
    LIMIT 1;
  ELSE
    v_season_id := p_season_id;
  END IF;

  FOR v_club IN
    SELECT ccs.club_short_name
    FROM public.competition_club_seasons ccs
    WHERE ccs.season_id = v_season_id
      AND ccs.division IN ('superleague', 'championship_a', 'championship_b')
  LOOP
    IF public.competition_post_club_emergency_tac(v_season_id, v_club) THEN
      v_paid := v_paid + 1;
    END IF;
  END LOOP;

  RETURN jsonb_build_object('season_id', v_season_id, 'clubs_taxed', v_paid);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.admin_update_upkeep_tax_settings(jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.competition_admin_post_season_wage_bills(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.competition_admin_apply_emergency_tac(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.competition_club_upkeep_preview(text) TO authenticated;
