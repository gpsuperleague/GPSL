-- =============================================================================
-- GPSL — Government subsidies (HG / Youth / Built not bought)
-- Run once after squad_composition_rules.sql and competition_league_prizes.sql
-- (or any file that extended competition_finance_ledger entry types).
-- =============================================================================
-- HG (layered bands): Quota 1–5 @ rate1, Flying the Flag 6–8 @ rate2, National Pride 9+ @ rate3
-- Youth (banded): Grassroots ≤3, Youth Dev 4–5, Academy 6–7, Centre 8+
-- Weak squad bonus (BnB): 14+ contracted players with Rating ≤72 → flat ₿10M at EOS
-- EOS payout when all 3 league divisions complete (38/38), idempotent per club/type
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Admin settings on global_settings
-- ---------------------------------------------------------------------------

ALTER TABLE public.global_settings
  ADD COLUMN IF NOT EXISTS hg_sub_band1_max smallint NOT NULL DEFAULT 5,
  ADD COLUMN IF NOT EXISTS hg_sub_band1_per_player numeric(14, 2) NOT NULL DEFAULT 500000,
  ADD COLUMN IF NOT EXISTS hg_sub_band2_max smallint NOT NULL DEFAULT 8,
  ADD COLUMN IF NOT EXISTS hg_sub_band2_per_player numeric(14, 2) NOT NULL DEFAULT 1500000,
  ADD COLUMN IF NOT EXISTS hg_sub_band3_per_player numeric(14, 2) NOT NULL DEFAULT 2000000,
  ADD COLUMN IF NOT EXISTS youth_sub_band1_max smallint NOT NULL DEFAULT 3,
  ADD COLUMN IF NOT EXISTS youth_sub_band1_per_player numeric(14, 2) NOT NULL DEFAULT 500000,
  ADD COLUMN IF NOT EXISTS youth_sub_band2_max smallint NOT NULL DEFAULT 5,
  ADD COLUMN IF NOT EXISTS youth_sub_band2_per_player numeric(14, 2) NOT NULL DEFAULT 1000000,
  ADD COLUMN IF NOT EXISTS youth_sub_band3_max smallint NOT NULL DEFAULT 7,
  ADD COLUMN IF NOT EXISTS youth_sub_band3_per_player numeric(14, 2) NOT NULL DEFAULT 1250000,
  ADD COLUMN IF NOT EXISTS youth_sub_band4_per_player numeric(14, 2) NOT NULL DEFAULT 1500000,
  ADD COLUMN IF NOT EXISTS bnb_max_rating smallint NOT NULL DEFAULT 72,
  ADD COLUMN IF NOT EXISTS bnb_min_players smallint NOT NULL DEFAULT 14,
  ADD COLUMN IF NOT EXISTS bnb_per_player numeric(14, 2) NOT NULL DEFAULT 10000000;

-- Recreate global_settings_public with FULL column set (see repair_global_settings_public.sql).
-- Do not trim this view — finance/draft patches rely on computed draft_* columns.
DROP VIEW IF EXISTS public.global_settings_public;

CREATE VIEW public.global_settings_public
WITH (security_invoker = false)
AS
SELECT
  id,
  transfer_window_open,
  draft_auction_enabled,
  manager_draft_auction_enabled,
  club_auction_enabled,
  draft_auction_start_time,
  updated_at,
  league_phase,
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
  emergency_tac_threshold,
  (
    COALESCE(draft_auction_enabled, false)
    AND draft_auction_start_time IS NOT NULL
    AND draft_random_finish_time IS NOT NULL
    AND now() >= draft_auction_start_time
    AND now() < draft_random_finish_time
  ) AS draft_bidding_open,
  (
    COALESCE(manager_draft_auction_enabled, false)
    AND draft_auction_start_time IS NOT NULL
    AND draft_random_finish_time IS NOT NULL
    AND now() >= draft_auction_start_time
    AND now() < draft_random_finish_time
  ) AS manager_draft_bidding_open,
  (
    COALESCE(club_auction_enabled, false)
    AND draft_auction_start_time IS NOT NULL
    AND draft_random_finish_time IS NOT NULL
    AND now() >= draft_auction_start_time
    AND now() < draft_random_finish_time
  ) AS club_auction_bidding_open,
  CASE
    WHEN draft_random_finish_time IS NOT NULL
     AND now() >= draft_random_finish_time
    THEN draft_random_finish_time
    ELSE NULL
  END AS draft_random_finish_revealed
FROM public.global_settings;

GRANT SELECT ON public.global_settings_public TO authenticated;
GRANT SELECT ON public.global_settings_public TO anon;

-- ---------------------------------------------------------------------------
-- Ledger types (keep in sync with patches/competition_finance_ledger_entry_types_repair.sql)
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

CREATE TABLE IF NOT EXISTS public.competition_gov_subsidy_paid (
  season_id bigint NOT NULL REFERENCES public.competition_seasons (id) ON DELETE CASCADE,
  club_short_name text NOT NULL REFERENCES public."Clubs" ("ShortName"),
  subsidy_type text NOT NULL CHECK (
    subsidy_type IN ('gov_hg_subsidy', 'gov_youth_subsidy', 'gov_bnb_subsidy')
  ),
  amount numeric(14, 2) NOT NULL CHECK (amount > 0),
  status_label text,
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  paid_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (season_id, club_short_name, subsidy_type)
);

ALTER TABLE public.competition_gov_subsidy_paid ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS competition_gov_subsidy_paid_select ON public.competition_gov_subsidy_paid;
CREATE POLICY competition_gov_subsidy_paid_select ON public.competition_gov_subsidy_paid
  FOR SELECT TO authenticated USING (true);

-- ---------------------------------------------------------------------------
-- Load settings row
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.gov_subsidy_settings()
RETURNS public.global_settings
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT * FROM public.global_settings WHERE id = 1;
$$;

-- ---------------------------------------------------------------------------
-- Squad counts for subsidies
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.gov_subsidy_squad_counts(p_club_short_name text)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club_nation text;
  v_hg int;
  v_u21 int;
  v_bnb int;
BEGIN
  SELECT c."Nation" INTO v_club_nation
  FROM public."Clubs" c
  WHERE c."ShortName" = p_club_short_name;

  SELECT
    count(*) FILTER (
      WHERE public.normalize_nation_key(p."Nation") = public.normalize_nation_key(v_club_nation)
        AND public.normalize_nation_key(p."Nation") <> ''
    )::int,
    count(*) FILTER (
      WHERE p."Age" IS NOT NULL
        AND btrim(p."Age"::text) <> ''
        AND btrim(p."Age"::text)::numeric <= 21
    )::int,
    count(*) FILTER (
      WHERE p."Rating" IS NOT NULL
        AND btrim(p."Rating"::text) <> ''
        AND btrim(p."Rating"::text)::numeric <= (
          SELECT bnb_max_rating FROM public.global_settings WHERE id = 1
        )
    )::int
  INTO v_hg, v_u21, v_bnb
  FROM public."Players" p
  WHERE p."Contracted_Team" = p_club_short_name;

  RETURN jsonb_build_object(
    'home_grown', coalesce(v_hg, 0),
    'under_21', coalesce(v_u21, 0),
    'bnb_qualifying', coalesce(v_bnb, 0)
  );
END;
$function$;

-- Band payout: first band1_max at rate1, next (band2_max - band1_max) at rate2, rest at rate3
CREATE OR REPLACE FUNCTION public.gov_subsidy_banded_amount(
  p_count int,
  p_band1_max int,
  p_band1_rate numeric,
  p_band2_max int,
  p_band2_rate numeric,
  p_band3_rate numeric
)
RETURNS numeric
LANGUAGE plpgsql
IMMUTABLE
AS $function$
DECLARE
  v_n int := greatest(coalesce(p_count, 0), 0);
  v_b1 int;
  v_b2 int;
  v_b3 int;
BEGIN
  IF v_n = 0 THEN
    RETURN 0;
  END IF;

  v_b1 := least(v_n, greatest(p_band1_max, 0));
  v_b2 := greatest(least(v_n, greatest(p_band2_max, 0)) - greatest(p_band1_max, 0), 0);
  v_b3 := greatest(v_n - greatest(p_band2_max, 0), 0);

  RETURN round(
    v_b1 * coalesce(p_band1_rate, 0)
    + v_b2 * coalesce(p_band2_rate, 0)
    + v_b3 * coalesce(p_band3_rate, 0),
    0
  );
END;
$function$;

-- ---------------------------------------------------------------------------
-- Compute HG / Youth / BnB (preview + payout)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.gov_compute_hg_subsidy(p_club_short_name text)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_s public.global_settings;
  v_hg int;
  v_amount numeric;
  v_status text;
  v_band1 int;
  v_band2 int;
  v_band3 int;
BEGIN
  v_s := public.gov_subsidy_settings();
  v_hg := (public.gov_subsidy_squad_counts(p_club_short_name)->>'home_grown')::int;

  v_band1 := least(v_hg, v_s.hg_sub_band1_max);
  v_band2 := greatest(least(v_hg, v_s.hg_sub_band2_max) - v_s.hg_sub_band1_max, 0);
  v_band3 := greatest(v_hg - v_s.hg_sub_band2_max, 0);

  v_amount := public.gov_subsidy_banded_amount(
    v_hg,
    v_s.hg_sub_band1_max,
    v_s.hg_sub_band1_per_player,
    v_s.hg_sub_band2_max,
    v_s.hg_sub_band2_per_player,
    v_s.hg_sub_band3_per_player
  );

  v_status := CASE
    WHEN v_hg >= v_s.hg_sub_band2_max + 1 THEN 'National pride'
    WHEN v_hg >= v_s.hg_sub_band1_max + 1 THEN 'Flying the flag'
    WHEN v_hg >= 1 THEN 'Quota'
    ELSE '—'
  END;

  RETURN jsonb_build_object(
    'count', v_hg,
    'status', v_status,
    'amount', v_amount,
    'bands', jsonb_build_object(
      'quota_players', v_band1,
      'flying_players', v_band2,
      'pride_players', v_band3
    )
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.gov_compute_youth_subsidy(p_club_short_name text)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_s public.global_settings;
  v_u21 int;
  v_amount numeric;
  v_status text;
  v_b1 int;
  v_b2 int;
  v_b3 int;
  v_b4 int;
BEGIN
  v_s := public.gov_subsidy_settings();
  v_u21 := (public.gov_subsidy_squad_counts(p_club_short_name)->>'under_21')::int;

  v_b1 := least(v_u21, v_s.youth_sub_band1_max);
  v_b2 := greatest(least(v_u21, v_s.youth_sub_band2_max) - v_s.youth_sub_band1_max, 0);
  v_b3 := greatest(least(v_u21, v_s.youth_sub_band3_max) - v_s.youth_sub_band2_max, 0);
  v_b4 := greatest(v_u21 - v_s.youth_sub_band3_max, 0);

  v_amount := round(
    v_b1 * v_s.youth_sub_band1_per_player
    + v_b2 * v_s.youth_sub_band2_per_player
    + v_b3 * v_s.youth_sub_band3_per_player
    + v_b4 * v_s.youth_sub_band4_per_player,
    0
  );

  v_status := CASE
    WHEN v_u21 > v_s.youth_sub_band3_max THEN 'Centre of excellence'
    WHEN v_u21 > v_s.youth_sub_band2_max THEN 'Academy'
    WHEN v_u21 > v_s.youth_sub_band1_max THEN 'Youth Development'
    WHEN v_u21 >= 1 THEN 'Grassroots'
    ELSE '—'
  END;

  RETURN jsonb_build_object(
    'count', v_u21,
    'status', v_status,
    'amount', v_amount,
    'bands', jsonb_build_object(
      'grassroots', v_b1,
      'youth_development', v_b2,
      'academy', v_b3,
      'centre', v_b4
    )
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.gov_compute_bnb_subsidy(p_club_short_name text)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_s public.global_settings;
  v_count int;
  v_amount numeric;
  v_status text;
BEGIN
  v_s := public.gov_subsidy_settings();
  v_count := (public.gov_subsidy_squad_counts(p_club_short_name)->>'bnb_qualifying')::int;

  IF v_count >= v_s.bnb_min_players THEN
    v_amount := round(coalesce(v_s.bnb_per_player, 0), 0);
    v_status := 'Weak squad bonus';
  ELSE
    v_amount := 0;
    v_status := '—';
  END IF;

  RETURN jsonb_build_object(
    'count', v_count,
    'min_required', v_s.bnb_min_players,
    'max_rating', v_s.bnb_max_rating,
    'flat_bonus', v_s.bnb_per_player,
    'status', v_status,
    'amount', v_amount
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.gov_subsidy_club_preview(p_club_short_name text)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := btrim(p_club_short_name);
  v_me text := public.my_club_shortname();
BEGIN
  IF v_club IS NULL OR v_club = '' THEN
    RAISE EXCEPTION 'Club required';
  END IF;

  IF NOT public.is_gpsl_admin() AND (v_me IS NULL OR v_me <> v_club) THEN
    RAISE EXCEPTION 'Not allowed to preview subsidies for this club';
  END IF;

  RETURN jsonb_build_object(
    'homegrown', public.gov_compute_hg_subsidy(v_club),
    'youth', public.gov_compute_youth_subsidy(v_club),
    'bnb', public.gov_compute_bnb_subsidy(v_club)
  );
END;
$function$;

-- ---------------------------------------------------------------------------
-- Season league complete (all 3 divisions)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.competition_season_league_complete(p_season_id bigint)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_div text;
BEGIN
  IF p_season_id IS NULL THEN
    RETURN false;
  END IF;

  FOREACH v_div IN ARRAY ARRAY['superleague', 'championship_a', 'championship_b']
  LOOP
    IF NOT public.competition_division_league_complete(p_season_id, v_div) THEN
      RETURN false;
    END IF;
  END LOOP;

  RETURN true;
END;
$function$;

-- ---------------------------------------------------------------------------
-- Pay one subsidy type for a club
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.gov_pay_club_subsidy(
  p_season_id bigint,
  p_club_short_name text,
  p_subsidy_type text,
  p_amount numeric,
  p_status_label text,
  p_metadata jsonb DEFAULT '{}'::jsonb
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_desc text;
BEGIN
  IF p_amount IS NULL OR p_amount <= 0 THEN
    RETURN false;
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.competition_gov_subsidy_paid
    WHERE season_id = p_season_id
      AND club_short_name = p_club_short_name
      AND subsidy_type = p_subsidy_type
  ) THEN
    RETURN false;
  END IF;

  PERFORM public.competition_credit_club_balance(p_club_short_name, p_amount);

  v_desc := CASE p_subsidy_type
    WHEN 'gov_hg_subsidy' THEN format('HG subsidy — %s', coalesce(p_status_label, 'Homegrown'))
    WHEN 'gov_youth_subsidy' THEN format('Youth subsidy — %s', coalesce(p_status_label, 'Youth'))
    WHEN 'gov_bnb_subsidy' THEN format('Weak squad bonus — %s', coalesce(p_status_label, 'BnB'))
    ELSE 'Government subsidy'
  END;

  INSERT INTO public.competition_finance_ledger (
    season_id, fixture_id, club_short_name, entry_type, amount, description, metadata
  )
  VALUES (
    p_season_id,
    NULL,
    p_club_short_name,
    p_subsidy_type,
    p_amount,
    v_desc,
    p_metadata
  );

  INSERT INTO public.competition_gov_subsidy_paid (
    season_id, club_short_name, subsidy_type, amount, status_label, metadata
  )
  VALUES (
    p_season_id, p_club_short_name, p_subsidy_type, p_amount, p_status_label, p_metadata
  );

  RETURN true;
END;
$function$;

CREATE OR REPLACE FUNCTION public.gov_pay_club_all_subsidies(
  p_season_id bigint,
  p_club_short_name text
)
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_hg jsonb;
  v_youth jsonb;
  v_bnb jsonb;
  v_paid int := 0;
BEGIN
  v_hg := public.gov_compute_hg_subsidy(p_club_short_name);
  v_youth := public.gov_compute_youth_subsidy(p_club_short_name);
  v_bnb := public.gov_compute_bnb_subsidy(p_club_short_name);

  IF public.gov_pay_club_subsidy(
    p_season_id, p_club_short_name, 'gov_hg_subsidy',
    (v_hg->>'amount')::numeric, v_hg->>'status', v_hg
  ) THEN
    v_paid := v_paid + 1;
  END IF;

  IF public.gov_pay_club_subsidy(
    p_season_id, p_club_short_name, 'gov_youth_subsidy',
    (v_youth->>'amount')::numeric, v_youth->>'status', v_youth
  ) THEN
    v_paid := v_paid + 1;
  END IF;

  IF public.gov_pay_club_subsidy(
    p_season_id, p_club_short_name, 'gov_bnb_subsidy',
    (v_bnb->>'amount')::numeric, v_bnb->>'status', v_bnb
  ) THEN
    v_paid := v_paid + 1;
  END IF;

  RETURN v_paid;
END;
$function$;

CREATE OR REPLACE FUNCTION public.competition_try_pay_government_subsidies(p_season_id bigint)
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text;
  v_total int := 0;
  v_n int;
BEGIN
  IF p_season_id IS NULL THEN
    RETURN 0;
  END IF;

  IF NOT public.competition_season_league_complete(p_season_id) THEN
    RETURN 0;
  END IF;

  FOR v_club IN
    SELECT ccs.club_short_name
    FROM public.competition_club_seasons ccs
    WHERE ccs.season_id = p_season_id
      AND ccs.division IN ('superleague', 'championship_a', 'championship_b')
  LOOP
    v_n := public.gov_pay_club_all_subsidies(p_season_id, v_club);
    v_total := v_total + v_n;
  END LOOP;

  RETURN v_total;
END;
$function$;

-- ---------------------------------------------------------------------------
-- Admin RPCs
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.admin_update_gov_subsidy_settings(p_settings jsonb)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF p_settings IS NULL OR jsonb_typeof(p_settings) <> 'object' THEN
    RAISE EXCEPTION 'settings must be a JSON object';
  END IF;

  UPDATE public.global_settings
  SET
    hg_sub_band1_max = coalesce((p_settings->>'hg_sub_band1_max')::smallint, hg_sub_band1_max),
    hg_sub_band1_per_player = coalesce((p_settings->>'hg_sub_band1_per_player')::numeric, hg_sub_band1_per_player),
    hg_sub_band2_max = coalesce((p_settings->>'hg_sub_band2_max')::smallint, hg_sub_band2_max),
    hg_sub_band2_per_player = coalesce((p_settings->>'hg_sub_band2_per_player')::numeric, hg_sub_band2_per_player),
    hg_sub_band3_per_player = coalesce((p_settings->>'hg_sub_band3_per_player')::numeric, hg_sub_band3_per_player),
    youth_sub_band1_max = coalesce((p_settings->>'youth_sub_band1_max')::smallint, youth_sub_band1_max),
    youth_sub_band1_per_player = coalesce((p_settings->>'youth_sub_band1_per_player')::numeric, youth_sub_band1_per_player),
    youth_sub_band2_max = coalesce((p_settings->>'youth_sub_band2_max')::smallint, youth_sub_band2_max),
    youth_sub_band2_per_player = coalesce((p_settings->>'youth_sub_band2_per_player')::numeric, youth_sub_band2_per_player),
    youth_sub_band3_max = coalesce((p_settings->>'youth_sub_band3_max')::smallint, youth_sub_band3_max),
    youth_sub_band3_per_player = coalesce((p_settings->>'youth_sub_band3_per_player')::numeric, youth_sub_band3_per_player),
    youth_sub_band4_per_player = coalesce((p_settings->>'youth_sub_band4_per_player')::numeric, youth_sub_band4_per_player),
    bnb_max_rating = coalesce((p_settings->>'bnb_max_rating')::smallint, bnb_max_rating),
    bnb_min_players = coalesce((p_settings->>'bnb_min_players')::smallint, bnb_min_players),
    bnb_per_player = coalesce((p_settings->>'bnb_per_player')::numeric, bnb_per_player),
    updated_at = now()
  WHERE id = 1;
END;
$function$;

CREATE OR REPLACE FUNCTION public.competition_admin_pay_government_subsidies(
  p_season_id bigint DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season_id bigint;
  v_paid int;
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

  IF v_season_id IS NULL THEN
    RAISE EXCEPTION 'No season';
  END IF;

  v_paid := public.competition_try_pay_government_subsidies(v_season_id);

  RETURN jsonb_build_object(
    'season_id', v_season_id,
    'subsidy_lines_paid', v_paid,
    'season_league_complete', public.competition_season_league_complete(v_season_id)
  );
END;
$function$;

-- Hook EOS: after league division prizes, try government subsidies
CREATE OR REPLACE FUNCTION public.competition_try_pay_league_division_prizes(
  p_season_id bigint,
  p_division text
)
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_paid int;
BEGIN
  v_paid := public.competition_pay_league_division_prizes(p_season_id, p_division);
  PERFORM public.competition_try_pay_government_subsidies(p_season_id);
  RETURN v_paid;
END;
$function$;

-- Manual league prize pay should also attempt government subsidies
CREATE OR REPLACE FUNCTION public.competition_admin_pay_league_prizes(
  p_season_id bigint DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season_id bigint;
  v_div text;
  v_paid int;
  v_total int := 0;
  v_result jsonb := '{}'::jsonb;
  v_gov int;
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

  IF v_season_id IS NULL THEN
    RAISE EXCEPTION 'No season';
  END IF;

  FOREACH v_div IN ARRAY ARRAY['superleague', 'championship_a', 'championship_b']
  LOOP
    v_paid := public.competition_pay_league_division_prizes(v_season_id, v_div);
    v_result := v_result || jsonb_build_object(v_div, v_paid);
    v_total := v_total + v_paid;
  END LOOP;

  v_gov := public.competition_try_pay_government_subsidies(v_season_id);

  RETURN jsonb_build_object(
    'season_id', v_season_id,
    'clubs_paid', v_total,
    'by_division', v_result,
    'gov_subsidy_lines_paid', v_gov
  );
END;
$function$;

-- Weak squad bonus defaults (safe to re-run)
ALTER TABLE public.global_settings
  ALTER COLUMN bnb_max_rating SET DEFAULT 72,
  ALTER COLUMN bnb_min_players SET DEFAULT 14,
  ALTER COLUMN bnb_per_player SET DEFAULT 10000000;

UPDATE public.global_settings
SET
  bnb_max_rating = 72,
  bnb_min_players = 14,
  bnb_per_player = 10000000,
  updated_at = now()
WHERE id = 1;

GRANT EXECUTE ON FUNCTION public.gov_subsidy_club_preview(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.competition_admin_pay_government_subsidies(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_update_gov_subsidy_settings(jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.competition_season_league_complete(bigint) TO authenticated;

NOTIFY pgrst, 'reload schema';
