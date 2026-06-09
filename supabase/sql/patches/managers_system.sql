-- =============================================================================
-- GPSL — Manager system (MGDB, contracts, transfer market, targets, draft)
-- Apply in Supabase SQL Editor after managers_seed_data.sql.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Catalog
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public."Managers" (
  id bigserial PRIMARY KEY,
  slug text NOT NULL UNIQUE,
  name text NOT NULL,
  nation text,
  possession smallint NOT NULL DEFAULT 0 CHECK (possession >= 0 AND possession <= 99),
  quick_counter smallint NOT NULL DEFAULT 0 CHECK (quick_counter >= 0 AND quick_counter <= 99),
  long_ball_counter smallint NOT NULL DEFAULT 0 CHECK (long_ball_counter >= 0 AND long_ball_counter <= 99),
  out_wide smallint NOT NULL DEFAULT 0 CHECK (out_wide >= 0 AND out_wide <= 99),
  long_ball smallint NOT NULL DEFAULT 0 CHECK (long_ball >= 0 AND long_ball <= 99),
  age smallint CHECK (age IS NULL OR (age >= 16 AND age <= 99)),
  rating smallint NOT NULL CHECK (rating >= 1 AND rating <= 99),
  market_value bigint NOT NULL DEFAULT 0 CHECK (market_value >= 0),
  contracted_club text REFERENCES public."Clubs" ("ShortName") ON DELETE SET NULL,
  contract_seasons_remaining smallint NOT NULL DEFAULT 0 CHECK (contract_seasons_remaining >= 0),
  weekly_wage bigint NOT NULL DEFAULT 0 CHECK (weekly_wage >= 0),
  signed_season_id bigint REFERENCES public.competition_seasons (id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS managers_contracted_club_idx ON public."Managers" (contracted_club);
CREATE INDEX IF NOT EXISTS managers_rating_idx ON public."Managers" (rating DESC);
CREATE INDEX IF NOT EXISTS managers_market_value_idx ON public."Managers" (market_value DESC);

COMMENT ON TABLE public."Managers" IS
  'GPSL manager catalog (MGDB). Rating = max playstyle; MV = sum of per-playstyle tier values.';

-- ---------------------------------------------------------------------------
-- Clubs linkage + sack quota
-- ---------------------------------------------------------------------------

ALTER TABLE public."Clubs"
  ADD COLUMN IF NOT EXISTS manager_id bigint REFERENCES public."Managers" (id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS manager_sacks_remaining smallint NOT NULL DEFAULT 1
    CHECK (manager_sacks_remaining >= 0 AND manager_sacks_remaining <= 1);

COMMENT ON COLUMN public."Clubs".manager_id IS 'Signed manager (Managers.id). Syncs manager_rating for attendance v2.';
COMMENT ON COLUMN public."Clubs".manager_sacks_remaining IS '1 per season — sack manager for half MV. Reset on season activate.';

-- ---------------------------------------------------------------------------
-- Rating → contract target rules (admin)
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.manager_rating_targets (
  id serial PRIMARY KEY,
  min_rating smallint NOT NULL CHECK (min_rating >= 1 AND min_rating <= 99),
  max_rating smallint NOT NULL CHECK (max_rating >= min_rating AND max_rating <= 99),
  division text NOT NULL CHECK (
    division IN ('superleague', 'championship_a', 'championship_b')
  ),
  target_kind text NOT NULL CHECK (
    target_kind IN ('max_position', 'promotion', 'avoid_relegation')
  ),
  target_value smallint,
  label text,
  sort_order smallint NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT manager_rating_targets_value_chk CHECK (
    (target_kind = 'max_position' AND target_value IS NOT NULL AND target_value >= 1)
    OR (target_kind IN ('promotion', 'avoid_relegation') AND target_value IS NULL)
  )
);

CREATE INDEX IF NOT EXISTS manager_rating_targets_lookup_idx
  ON public.manager_rating_targets (division, min_rating, max_rating);

COMMENT ON TABLE public.manager_rating_targets IS
  'Admin: expected finish by manager rating + division (e.g. 87 SL → top 2).';

-- Sensible defaults (admin can edit) — only when table is empty
DO $manager_targets_seed$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.manager_rating_targets) THEN
    INSERT INTO public.manager_rating_targets
      (min_rating, max_rating, division, target_kind, target_value, label, sort_order)
    VALUES
      (85, 87, 'superleague', 'max_position', 2, 'Top 2 in Super League', 10),
      (85, 87, 'championship_a', 'promotion', NULL, 'Win promotion (Championship)', 20),
      (85, 87, 'championship_b', 'promotion', NULL, 'Win promotion (Championship)', 21),
      (80, 84, 'superleague', 'max_position', 6, 'Top 6 in Super League', 30),
      (80, 84, 'championship_a', 'max_position', 2, 'Top 2 / promotion push', 40),
      (80, 84, 'championship_b', 'max_position', 2, 'Top 2 / promotion push', 41),
      (75, 79, 'superleague', 'max_position', 10, 'Top 10 in Super League', 50),
      (75, 79, 'championship_a', 'max_position', 6, 'Top 6 in Championship', 60),
      (75, 79, 'championship_b', 'max_position', 6, 'Top 6 in Championship', 61),
      (70, 74, 'superleague', 'max_position', 14, 'Mid-table Super League', 70),
      (70, 74, 'championship_a', 'max_position', 10, 'Upper-mid Championship', 80),
      (70, 74, 'championship_b', 'max_position', 10, 'Upper-mid Championship', 81),
      (60, 69, 'superleague', 'avoid_relegation', NULL, 'Avoid relegation (SL)', 90),
      (60, 69, 'championship_a', 'max_position', 14, 'Mid-table Championship', 100),
      (60, 69, 'championship_b', 'max_position', 14, 'Mid-table Championship', 101);
  END IF;
END;
$manager_targets_seed$;

-- ---------------------------------------------------------------------------
-- Transfer market + draft listings
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public."Manager_Transfer_Listings" (
  id bigserial PRIMARY KEY,
  manager_id bigint NOT NULL REFERENCES public."Managers" (id) ON DELETE CASCADE,
  seller_club_id text REFERENCES public."Clubs" ("ShortName") ON DELETE SET NULL,
  listing_type text NOT NULL DEFAULT 'standard'
    CHECK (listing_type IN ('standard', 'direct', 'draft')),
  status text NOT NULL DEFAULT 'Active'
    CHECK (status IN ('Active', 'Review', 'Seller Review', 'Closed', 'Cancelled')),
  end_time timestamptz,
  market_value bigint NOT NULL DEFAULT 0,
  current_highest_bid numeric(14, 2),
  current_highest_bidder text REFERENCES public."Clubs" ("ShortName") ON DELETE SET NULL,
  transfer_completed boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS manager_listings_active_idx
  ON public."Manager_Transfer_Listings" (status, end_time)
  WHERE status = 'Active';

CREATE TABLE IF NOT EXISTS public."Manager_Transfer_Bids" (
  id bigserial PRIMARY KEY,
  listing_id bigint NOT NULL REFERENCES public."Manager_Transfer_Listings" (id) ON DELETE CASCADE,
  manager_id bigint NOT NULL REFERENCES public."Managers" (id) ON DELETE CASCADE,
  bidder_club_id text NOT NULL REFERENCES public."Clubs" ("ShortName") ON DELETE CASCADE,
  bid_amount numeric(14, 2) NOT NULL CHECK (bid_amount > 0),
  bid_time timestamptz NOT NULL DEFAULT now(),
  is_direct boolean NOT NULL DEFAULT false
);

CREATE INDEX IF NOT EXISTS manager_bids_listing_idx ON public."Manager_Transfer_Bids" (listing_id, bid_amount DESC);

-- ---------------------------------------------------------------------------
-- Global settings — manager draft toggle + wage %
-- ---------------------------------------------------------------------------

ALTER TABLE public.global_settings
  ADD COLUMN IF NOT EXISTS manager_draft_auction_enabled boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS manager_wage_pct numeric(6, 3) NOT NULL DEFAULT 50.000;

-- ---------------------------------------------------------------------------
-- Helpers — MV = sum of playstyle tier values (see managers_playstyle_mv.sql)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.manager_playstyle_tier_value(p_rating smallint)
RETURNS bigint
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE
    WHEN coalesce(p_rating, 0) <= 60 THEN 0::bigint
    WHEN p_rating <= 65 THEN 1000000::bigint
    WHEN p_rating <= 70 THEN 2000000::bigint
    WHEN p_rating <= 73 THEN 5000000::bigint
    WHEN p_rating <= 76 THEN 8000000::bigint
    WHEN p_rating <= 79 THEN 16000000::bigint
    WHEN p_rating <= 83 THEN 25000000::bigint
    WHEN p_rating <= 85 THEN 40000000::bigint
    WHEN p_rating <= 90 THEN 60000000::bigint
    ELSE 60000000::bigint
  END;
$$;

CREATE OR REPLACE FUNCTION public.manager_market_value_from_playstyles(
  p_possession smallint,
  p_quick_counter smallint,
  p_long_ball_counter smallint,
  p_out_wide smallint,
  p_long_ball smallint
)
RETURNS bigint
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT
    public.manager_playstyle_tier_value(p_possession)
    + public.manager_playstyle_tier_value(p_quick_counter)
    + public.manager_playstyle_tier_value(p_long_ball_counter)
    + public.manager_playstyle_tier_value(p_out_wide)
    + public.manager_playstyle_tier_value(p_long_ball);
$$;

CREATE OR REPLACE FUNCTION public.manager_weekly_wage_for(p_market_value bigint)
RETURNS bigint
LANGUAGE sql
STABLE
AS $$
  SELECT greatest(
    0,
    round(
      coalesce(p_market_value, 0)::numeric
      * coalesce(
          (SELECT manager_wage_pct FROM public.global_settings WHERE id = 1 LIMIT 1),
          50.0
        )
      / 100.0
      / 52.0
    )::bigint
  );
$$;

CREATE OR REPLACE FUNCTION public.manager_sync_club_rating(p_club_short text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_rating smallint;
  v_manager_id bigint;
BEGIN
  SELECT m.id, m.rating
  INTO v_manager_id, v_rating
  FROM public."Managers" m
  WHERE m.contracted_club = p_club_short
  LIMIT 1;

  UPDATE public."Clubs" c
  SET manager_id = v_manager_id,
      manager_rating = v_rating
  WHERE c."ShortName" = p_club_short;
END;
$function$;

CREATE OR REPLACE FUNCTION public.manager_target_for(
  p_rating smallint,
  p_division text
)
RETURNS public.manager_rating_targets
LANGUAGE sql
STABLE
AS $$
  SELECT t.*
  FROM public.manager_rating_targets t
  WHERE t.division = p_division
    AND p_rating BETWEEN t.min_rating AND t.max_rating
  ORDER BY t.sort_order, t.id
  LIMIT 1;
$$;

CREATE OR REPLACE FUNCTION public.manager_target_met(
  p_target public.manager_rating_targets,
  p_actual_position smallint,
  p_division text
)
RETURNS boolean
LANGUAGE plpgsql
IMMUTABLE
AS $function$
BEGIN
  IF p_target IS NULL OR p_actual_position IS NULL THEN
    RETURN NULL;
  END IF;

  IF p_target.target_kind = 'max_position' THEN
    RETURN p_actual_position <= p_target.target_value;
  END IF;

  IF p_target.target_kind = 'promotion' THEN
    RETURN p_actual_position <= 2;
  END IF;

  IF p_target.target_kind = 'avoid_relegation' THEN
    IF p_division = 'superleague' THEN
      RETURN p_actual_position <= 18;
    END IF;
    RETURN p_actual_position <= 18;
  END IF;

  RETURN NULL;
END;
$function$;

-- Live table position (standings) or archived final position for a season
CREATE OR REPLACE FUNCTION public.manager_club_season_position(
  p_season_id bigint,
  p_club_short_name text
)
RETURNS TABLE (
  division text,
  season_position smallint
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF p_season_id IS NULL OR p_club_short_name IS NULL OR btrim(p_club_short_name) = '' THEN
    RETURN;
  END IF;

  RETURN QUERY
  SELECT a.division, a.final_position
  FROM public.competition_club_season_archive a
  WHERE a.season_id = p_season_id
    AND a.club_short_name = p_club_short_name;

  IF FOUND THEN
    RETURN;
  END IF;

  RETURN QUERY
  SELECT s.division, s.table_position::smallint
  FROM public.competition_standings_public s
  WHERE s.season_id = p_season_id
    AND s.club_short_name = p_club_short_name;
END;
$function$;

-- ---------------------------------------------------------------------------
-- Assign / release
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.manager_assign_to_club(
  p_manager_id bigint,
  p_club_short text,
  p_seasons smallint DEFAULT 2,
  p_fee numeric DEFAULT NULL,
  p_buyer_pays boolean DEFAULT true
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_mgr public."Managers"%rowtype;
  v_existing bigint;
  v_balance numeric;
  v_fee numeric;
  v_season_id bigint;
  v_wage bigint;
BEGIN
  SELECT * INTO v_mgr FROM public."Managers" WHERE id = p_manager_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Manager not found';
  END IF;

  IF v_mgr.contracted_club IS NOT NULL AND btrim(v_mgr.contracted_club) <> '' THEN
    RAISE EXCEPTION 'Manager already contracted to %', v_mgr.contracted_club;
  END IF;

  SELECT m.id INTO v_existing
  FROM public."Managers" m
  WHERE m.contracted_club = p_club_short
  LIMIT 1;

  IF v_existing IS NOT NULL THEN
    RAISE EXCEPTION 'Club already has a manager signed';
  END IF;

  v_fee := coalesce(p_fee, v_mgr.market_value::numeric);

  IF p_buyer_pays AND v_fee > 0 THEN
    SELECT balance INTO v_balance
    FROM public."Club_Finances"
    WHERE club_name = p_club_short
    FOR UPDATE;

    IF v_balance IS NULL THEN
      RAISE EXCEPTION 'Club finances not found for %', p_club_short;
    END IF;
    IF v_balance < v_fee THEN
      RAISE EXCEPTION 'Insufficient balance (need %, have %)', v_fee, v_balance;
    END IF;

    PERFORM public.post_club_ledger(
      p_club_short,
      'transfer_purchase',
      -abs(v_fee),
      format('Manager signing — %s', v_mgr.name),
      jsonb_build_object('manager_id', p_manager_id, 'kind', 'manager')
    );
  END IF;

  SELECT id INTO v_season_id
  FROM public.competition_seasons
  WHERE is_current = true
  LIMIT 1;

  v_wage := public.manager_weekly_wage_for(v_mgr.market_value);

  UPDATE public."Managers"
  SET contracted_club = p_club_short,
      contract_seasons_remaining = greatest(coalesce(p_seasons, 2), 1),
      weekly_wage = v_wage,
      signed_season_id = v_season_id,
      updated_at = now()
  WHERE id = p_manager_id;

  PERFORM public.manager_sync_club_rating(p_club_short);

  RETURN jsonb_build_object(
    'ok', true,
    'manager_id', p_manager_id,
    'club', p_club_short,
    'fee', v_fee,
    'seasons', p_seasons,
    'weekly_wage', v_wage
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.manager_release_from_club(
  p_manager_id bigint,
  p_payout_club text DEFAULT NULL,
  p_payout_amount numeric DEFAULT NULL,
  p_ledger_type text DEFAULT 'transfer_sale'
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_mgr public."Managers"%rowtype;
  v_club text;
  v_payout numeric;
BEGIN
  SELECT * INTO v_mgr FROM public."Managers" WHERE id = p_manager_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Manager not found';
  END IF;

  v_club := v_mgr.contracted_club;
  IF v_club IS NULL OR btrim(v_club) = '' THEN
    RAISE EXCEPTION 'Manager is a free agent';
  END IF;

  v_payout := coalesce(p_payout_amount, v_mgr.market_value::numeric);

  IF p_payout_club IS NOT NULL AND v_payout > 0 THEN
    PERFORM public.post_club_ledger(
      p_payout_club,
      p_ledger_type,
      abs(v_payout),
      format('Manager release — %s', v_mgr.name),
      jsonb_build_object('manager_id', p_manager_id, 'kind', 'manager')
    );
  END IF;

  UPDATE public."Managers"
  SET contracted_club = NULL,
      contract_seasons_remaining = 0,
      weekly_wage = 0,
      signed_season_id = NULL,
      updated_at = now()
  WHERE id = p_manager_id;

  UPDATE public."Clubs"
  SET manager_id = NULL,
      manager_rating = NULL
  WHERE "ShortName" = v_club;

  UPDATE public."Manager_Transfer_Listings"
  SET status = 'Cancelled', updated_at = now()
  WHERE manager_id = p_manager_id AND status = 'Active';

  RETURN jsonb_build_object(
    'ok', true,
    'manager_id', p_manager_id,
    'former_club', v_club,
    'payout', v_payout
  );
END;
$function$;

-- Owner: sack manager (half MV, once per season)
CREATE OR REPLACE FUNCTION public.manager_sack()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text;
  v_mgr public."Managers"%rowtype;
  v_payout numeric;
  v_sacks smallint;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  v_club := public.my_club_shortname();
  IF v_club IS NULL THEN
    RAISE EXCEPTION 'No club linked to your account';
  END IF;

  SELECT manager_sacks_remaining INTO v_sacks
  FROM public."Clubs"
  WHERE "ShortName" = v_club
  FOR UPDATE;

  IF coalesce(v_sacks, 0) < 1 THEN
    RAISE EXCEPTION 'Manager sack already used this season';
  END IF;

  SELECT * INTO v_mgr
  FROM public."Managers"
  WHERE contracted_club = v_club
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'No manager signed at your club';
  END IF;

  v_payout := round(greatest(v_mgr.market_value, 0)::numeric / 2.0, 0);

  UPDATE public."Clubs"
  SET manager_sacks_remaining = 0
  WHERE "ShortName" = v_club;

  RETURN public.manager_release_from_club(
    v_mgr.id,
    v_club,
    v_payout,
    'contract_release_comp'
  );
END;
$function$;

-- List manager on transfer market (owner)
CREATE OR REPLACE FUNCTION public.manager_list_for_transfer(p_manager_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text;
  v_mgr public."Managers"%rowtype;
  v_end timestamptz;
  v_listing_id bigint;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  v_club := public.my_club_shortname();
  IF v_club IS NULL THEN
    RAISE EXCEPTION 'No club linked to your account';
  END IF;

  SELECT * INTO v_mgr FROM public."Managers" WHERE id = p_manager_id FOR UPDATE;
  IF NOT FOUND OR v_mgr.contracted_club IS DISTINCT FROM v_club THEN
    RAISE EXCEPTION 'Manager not at your club';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public."Manager_Transfer_Listings"
    WHERE manager_id = p_manager_id AND status = 'Active'
  ) THEN
    RAISE EXCEPTION 'Manager already listed';
  END IF;

  v_end := now() + interval '24 hours';

  INSERT INTO public."Manager_Transfer_Listings" (
    manager_id, seller_club_id, listing_type, status, end_time, market_value
  )
  VALUES (
    p_manager_id, v_club, 'standard', 'Active', v_end, v_mgr.market_value
  )
  RETURNING id INTO v_listing_id;

  RETURN jsonb_build_object('ok', true, 'listing_id', v_listing_id, 'end_time', v_end);
END;
$function$;

CREATE OR REPLACE FUNCTION public.manager_place_bid(
  p_listing_id bigint,
  p_amount numeric
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text;
  v_listing public."Manager_Transfer_Listings"%rowtype;
  v_mgr public."Managers"%rowtype;
  v_balance numeric;
  v_min numeric;
  v_high numeric;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  v_club := public.my_club_shortname();
  IF v_club IS NULL THEN
    RAISE EXCEPTION 'No club linked to your account';
  END IF;

  SELECT * INTO v_listing
  FROM public."Manager_Transfer_Listings"
  WHERE id = p_listing_id
  FOR UPDATE;

  IF NOT FOUND OR v_listing.status <> 'Active' THEN
    RAISE EXCEPTION 'Listing not open';
  END IF;

  IF v_listing.end_time IS NOT NULL AND v_listing.end_time < now() THEN
    RAISE EXCEPTION 'Listing has expired';
  END IF;

  IF v_listing.seller_club_id IS NOT DISTINCT FROM v_club THEN
    RAISE EXCEPTION 'Cannot bid on your own listing';
  END IF;

  SELECT * INTO v_mgr FROM public."Managers" WHERE id = v_listing.manager_id;

  IF EXISTS (
    SELECT 1 FROM public."Managers" m WHERE m.contracted_club = v_club
  ) THEN
    RAISE EXCEPTION 'Your club already has a manager';
  END IF;

  v_high := coalesce(v_listing.current_highest_bid, 0);
  v_min := greatest(v_listing.market_value::numeric, v_high + 500000);

  IF p_amount < v_min THEN
    RAISE EXCEPTION 'Bid must be at least %', v_min;
  END IF;

  SELECT balance INTO v_balance
  FROM public."Club_Finances"
  WHERE club_name = v_club;

  IF coalesce(v_balance, 0) < p_amount THEN
    RAISE EXCEPTION 'Insufficient balance';
  END IF;

  INSERT INTO public."Manager_Transfer_Bids" (
    listing_id, manager_id, bidder_club_id, bid_amount, is_direct
  )
  VALUES (p_listing_id, v_listing.manager_id, v_club, p_amount, true);

  UPDATE public."Manager_Transfer_Listings"
  SET current_highest_bid = p_amount,
      current_highest_bidder = v_club,
      updated_at = now()
  WHERE id = p_listing_id;

  RETURN jsonb_build_object('ok', true, 'bid', p_amount, 'listing_id', p_listing_id);
END;
$function$;

CREATE OR REPLACE FUNCTION public.manager_settle_listing(p_listing_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_listing public."Manager_Transfer_Listings"%rowtype;
  v_seller text;
  v_buyer text;
  v_fee numeric;
  v_mgr_id bigint;
BEGIN
  SELECT * INTO v_listing
  FROM public."Manager_Transfer_Listings"
  WHERE id = p_listing_id
  FOR UPDATE;

  IF NOT FOUND OR v_listing.status <> 'Active' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_active');
  END IF;

  v_buyer := v_listing.current_highest_bidder;
  v_fee := v_listing.current_highest_bid;
  v_seller := v_listing.seller_club_id;
  v_mgr_id := v_listing.manager_id;

  IF v_buyer IS NULL OR v_fee IS NULL THEN
    UPDATE public."Manager_Transfer_Listings"
    SET status = 'Closed', transfer_completed = false, updated_at = now()
    WHERE id = p_listing_id;
    RETURN jsonb_build_object('ok', true, 'sold', false);
  END IF;

  PERFORM public.manager_release_from_club(v_mgr_id, NULL, NULL, 'transfer_sale');

  IF v_fee > 0 THEN
    PERFORM public.post_club_ledger(
      v_buyer,
      'transfer_purchase',
      -abs(v_fee),
      format('Manager purchase — listing %s', p_listing_id),
      jsonb_build_object('manager_id', v_mgr_id, 'seller', v_seller)
    );

    IF v_seller IS NOT NULL THEN
      PERFORM public.post_club_ledger(
        v_seller,
        'transfer_sale',
        abs(v_fee),
        format('Manager sale — listing %s', p_listing_id),
        jsonb_build_object('manager_id', v_mgr_id, 'buyer', v_buyer)
      );
    END IF;
  END IF;

  PERFORM public.manager_assign_to_club(v_mgr_id, v_buyer, 2, 0, false);

  UPDATE public."Manager_Transfer_Listings"
  SET status = 'Closed', transfer_completed = true, updated_at = now()
  WHERE id = p_listing_id;

  RETURN jsonb_build_object('ok', true, 'sold', true, 'buyer', v_buyer, 'fee', v_fee);
END;
$function$;

-- Season end: evaluate targets, renew or release; tick contracts
CREATE OR REPLACE FUNCTION public.manager_process_season_end()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season public.competition_seasons;
  v_mgr public."Managers"%rowtype;
  v_division text;
  v_pos smallint;
  v_target public.manager_rating_targets;
  v_met boolean;
  v_results jsonb := '[]'::jsonb;
  v_row jsonb;
BEGIN
  SELECT * INTO v_season
  FROM public.competition_seasons
  WHERE is_current = true
  ORDER BY id DESC
  LIMIT 1;

  FOR v_mgr IN
    SELECT * FROM public."Managers"
    WHERE contracted_club IS NOT NULL
      AND contract_seasons_remaining > 0
  LOOP
    SELECT cs.division, cs.season_position
    INTO v_division, v_pos
    FROM public.manager_club_season_position(v_season.id, v_mgr.contracted_club) cs;

    v_target := public.manager_target_for(v_mgr.rating, coalesce(v_division, 'championship_a'));
    v_met := public.manager_target_met(v_target, v_pos, v_division);

    IF v_met IS TRUE THEN
      -- Renew at market value (new 2-year deal, no cash movement)
      UPDATE public."Managers"
      SET contract_seasons_remaining = 2,
          weekly_wage = public.manager_weekly_wage_for(market_value),
          updated_at = now()
      WHERE id = v_mgr.id;

      v_row := jsonb_build_object(
        'manager_id', v_mgr.id,
        'club', v_mgr.contracted_club,
        'action', 'renewed',
        'position', v_pos
      );
    ELSIF v_met IS FALSE THEN
      -- Failed target — released; club receives MV
      PERFORM public.manager_release_from_club(
        v_mgr.id,
        v_mgr.contracted_club,
        v_mgr.market_value::numeric,
        'transfer_sale'
      );

      v_row := jsonb_build_object(
        'manager_id', v_mgr.id,
        'club', v_mgr.contracted_club,
        'action', 'released',
        'position', v_pos,
        'payout', v_mgr.market_value
      );
    ELSE
      -- Contract tick-down when no evaluation possible
      UPDATE public."Managers"
      SET contract_seasons_remaining = greatest(contract_seasons_remaining - 1, 0),
          updated_at = now()
      WHERE id = v_mgr.id;

      IF (SELECT contract_seasons_remaining FROM public."Managers" WHERE id = v_mgr.id) = 0 THEN
        PERFORM public.manager_release_from_club(v_mgr.id, NULL, NULL, 'transfer_sale');
        v_row := jsonb_build_object('manager_id', v_mgr.id, 'club', v_mgr.contracted_club, 'action', 'contract_expired');
      ELSE
        v_row := jsonb_build_object('manager_id', v_mgr.id, 'club', v_mgr.contracted_club, 'action', 'season_tick');
      END IF;
    END IF;

    v_results := v_results || jsonb_build_array(v_row);
  END LOOP;

  RETURN jsonb_build_object('season_id', v_season.id, 'results', v_results);
END;
$function$;

-- Reset sack quota on season activate (wrap existing if present)
CREATE OR REPLACE FUNCTION public.manager_reset_season_quotas()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  UPDATE public."Clubs"
  SET manager_sacks_remaining = 1
  WHERE manager_sacks_remaining IS DISTINCT FROM 1;
END;
$function$;

-- Admin CRUD for targets
CREATE OR REPLACE FUNCTION public.admin_upsert_manager_rating_target(p_payload jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_id int;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  v_id := nullif(p_payload ->> 'id', '')::int;

  IF v_id IS NOT NULL THEN
    UPDATE public.manager_rating_targets
    SET min_rating = (p_payload ->> 'min_rating')::smallint,
        max_rating = (p_payload ->> 'max_rating')::smallint,
        division = p_payload ->> 'division',
        target_kind = p_payload ->> 'target_kind',
        target_value = nullif(p_payload ->> 'target_value', '')::smallint,
        label = p_payload ->> 'label',
        sort_order = coalesce((p_payload ->> 'sort_order')::smallint, 0),
        updated_at = now()
    WHERE id = v_id;
  ELSE
    INSERT INTO public.manager_rating_targets (
      min_rating, max_rating, division, target_kind, target_value, label, sort_order
    )
    VALUES (
      (p_payload ->> 'min_rating')::smallint,
      (p_payload ->> 'max_rating')::smallint,
      p_payload ->> 'division',
      p_payload ->> 'target_kind',
      nullif(p_payload ->> 'target_value', '')::smallint,
      p_payload ->> 'label',
      coalesce((p_payload ->> 'sort_order')::smallint, 0)
    )
    RETURNING id INTO v_id;
  END IF;

  RETURN jsonb_build_object('ok', true, 'id', v_id);
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_delete_manager_rating_target(p_id int)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;
  DELETE FROM public.manager_rating_targets WHERE id = p_id;
END;
$function$;

-- ---------------------------------------------------------------------------
-- Public views
-- ---------------------------------------------------------------------------

CREATE OR REPLACE VIEW public.managers_gpdb_public
WITH (security_invoker = true)
AS
SELECT
  m.id,
  m.slug,
  m.name,
  m.nation,
  m.possession,
  m.quick_counter,
  m.long_ball_counter,
  m.out_wide,
  m.long_ball,
  m.age,
  m.rating,
  m.market_value,
  m.contracted_club,
  m.contract_seasons_remaining,
  m.weekly_wage,
  CASE
    WHEN m.contracted_club IS NULL OR btrim(m.contracted_club) = '' THEN 'FREE AGENT'
    ELSE m.contracted_club
  END AS contracted_display
FROM public."Managers" m;

GRANT SELECT ON public.managers_gpdb_public TO authenticated;
GRANT SELECT ON public.managers_gpdb_public TO anon;

CREATE OR REPLACE VIEW public.manager_club_status_public
WITH (security_invoker = true)
AS
SELECT
  c."ShortName" AS club_short_name,
  m.id AS manager_id,
  m.name AS manager_name,
  m.rating AS manager_rating,
  m.market_value,
  m.contract_seasons_remaining,
  m.weekly_wage,
  c.manager_sacks_remaining,
  coalesce(pos.division, ccs.division) AS division,
  pos.season_position,
  t.target_kind,
  t.target_value,
  t.label AS target_label,
  public.manager_target_met(
    t,
    pos.season_position,
    coalesce(pos.division, ccs.division)
  ) AS target_met
FROM public."Clubs" c
LEFT JOIN public."Managers" m ON m.id = c.manager_id
LEFT JOIN public.competition_seasons s ON s.is_current = true
LEFT JOIN public.competition_club_seasons ccs
  ON ccs.club_short_name = c."ShortName" AND ccs.season_id = s.id
LEFT JOIN LATERAL public.manager_club_season_position(s.id, c."ShortName") pos ON s.id IS NOT NULL
LEFT JOIN public.manager_rating_targets t
  ON m.id IS NOT NULL
  AND coalesce(pos.division, ccs.division) IS NOT NULL
  AND m.rating BETWEEN t.min_rating AND t.max_rating
  AND t.division = coalesce(pos.division, ccs.division)
  AND t.id = (
    SELECT t2.id
    FROM public.manager_rating_targets t2
    WHERE t2.division = coalesce(pos.division, ccs.division)
      AND m.rating BETWEEN t2.min_rating AND t2.max_rating
    ORDER BY t2.sort_order, t2.id
    LIMIT 1
  );

GRANT SELECT ON public.manager_club_status_public TO authenticated;

-- Extend global_settings_public (minimal draft columns only).
-- After this patch, run repair_global_settings_public.sql for the full view
-- (wages/TV/subsidies + manager_draft_bidding_open) so player draft + admin pages work.
DROP VIEW IF EXISTS public.global_settings_public;

CREATE VIEW public.global_settings_public
WITH (security_invoker = false)
AS
SELECT
  gs.id,
  gs.transfer_window_open,
  gs.draft_auction_enabled,
  gs.manager_draft_auction_enabled,
  gs.draft_auction_start_time,
  gs.updated_at,
  gs.league_phase,
  (
    COALESCE(gs.draft_auction_enabled, false)
    AND gs.draft_auction_start_time IS NOT NULL
    AND now() >= gs.draft_auction_start_time
    AND (
      gs.draft_random_finish_time IS NULL
      OR now() < gs.draft_random_finish_time
    )
  ) AS draft_bidding_open,
  (
    COALESCE(gs.manager_draft_auction_enabled, false)
    AND gs.draft_auction_start_time IS NOT NULL
    AND now() >= gs.draft_auction_start_time
    AND (
      gs.draft_random_finish_time IS NULL
      OR now() < gs.draft_random_finish_time
    )
  ) AS manager_draft_bidding_open
FROM public.global_settings gs;

GRANT SELECT ON public.global_settings_public TO authenticated;
GRANT SELECT ON public.global_settings_public TO anon;

-- RLS
ALTER TABLE public."Managers" ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.manager_rating_targets ENABLE ROW LEVEL SECURITY;
ALTER TABLE public."Manager_Transfer_Listings" ENABLE ROW LEVEL SECURITY;
ALTER TABLE public."Manager_Transfer_Bids" ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS managers_select ON public."Managers";
CREATE POLICY managers_select ON public."Managers" FOR SELECT TO authenticated USING (true);

DROP POLICY IF EXISTS manager_targets_select ON public.manager_rating_targets;
CREATE POLICY manager_targets_select ON public.manager_rating_targets FOR SELECT TO authenticated USING (true);

DROP POLICY IF EXISTS manager_targets_admin ON public.manager_rating_targets;
CREATE POLICY manager_targets_admin ON public.manager_rating_targets FOR ALL TO authenticated
  USING (public.is_gpsl_admin()) WITH CHECK (public.is_gpsl_admin());

DROP POLICY IF EXISTS manager_listings_select ON public."Manager_Transfer_Listings";
CREATE POLICY manager_listings_select ON public."Manager_Transfer_Listings" FOR SELECT TO authenticated USING (true);

DROP POLICY IF EXISTS manager_bids_select ON public."Manager_Transfer_Bids";
CREATE POLICY manager_bids_select ON public."Manager_Transfer_Bids" FOR SELECT TO authenticated USING (true);

GRANT EXECUTE ON FUNCTION public.manager_sack() TO authenticated;
GRANT EXECUTE ON FUNCTION public.manager_list_for_transfer(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.manager_place_bid(bigint, numeric) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_upsert_manager_rating_target(jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_delete_manager_rating_target(int) TO authenticated;

CREATE OR REPLACE FUNCTION public.admin_set_manager_draft_enabled(p_enabled boolean)
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
  SET manager_draft_auction_enabled = coalesce(p_enabled, false),
      updated_at = now()
  WHERE id = 1;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.admin_set_manager_draft_enabled(boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.manager_process_season_end() TO authenticated;
GRANT EXECUTE ON FUNCTION public.manager_settle_listing(bigint) TO authenticated;
