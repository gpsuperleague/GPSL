-- =============================================================================
-- Player contracts — phase 3 (C4–C5): expiring-contract wage bids + resolution
-- Run AFTER player_contracts_phase2.sql
-- =============================================================================

-- player_assign_to_club (3-season sign + squad overflow) lives in squad_overflow_enforcement.sql

-- Standard players in final year (not home-grown ≤23) → contested expiry market
CREATE OR REPLACE FUNCTION public.player_expiry_auction_applies(p_player_id text)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_player public."Players"%rowtype;
  v_club text;
BEGIN
  SELECT * INTO v_player
  FROM public."Players" p
  WHERE p."Konami_ID"::text = btrim(p_player_id);

  IF NOT FOUND THEN
    RETURN false;
  END IF;

  v_club := public.player_contracted_club_key(v_player."Contracted_Team");
  IF v_club IS NULL THEN
    RETURN false;
  END IF;

  IF coalesce(v_player.contract_seasons_remaining, 0) <> 1 THEN
    RETURN false;
  END IF;

  IF public.is_player_homegrown_u23(btrim(p_player_id), v_club) THEN
    RETURN false;
  END IF;

  RETURN true;
END;
$function$;

-- ---------------------------------------------------------------------------
-- Hidden wage bids (one per club per player per season label)
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.contract_expiry_wage_bids (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  player_id text NOT NULL,
  bidder_club_short_name text NOT NULL,
  wage_offer numeric NOT NULL CHECK (wage_offer > 0),
  season_label text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT contract_expiry_wage_bids_unique
    UNIQUE (player_id, bidder_club_short_name, season_label)
);

CREATE INDEX IF NOT EXISTS contract_expiry_wage_bids_player_idx
  ON public.contract_expiry_wage_bids (player_id, season_label);

ALTER TABLE public.contract_expiry_wage_bids ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS contract_expiry_bids_no_direct ON public.contract_expiry_wage_bids;
CREATE POLICY contract_expiry_bids_no_direct ON public.contract_expiry_wage_bids
  FOR ALL
  TO authenticated
  USING (false)
  WITH CHECK (false);

-- Submit / update hidden wage bid (own club only via RPC)
CREATE OR REPLACE FUNCTION public.contract_submit_expiry_wage_bid(
  p_player_id text,
  p_wage_offer numeric
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club   text;
  v_pid    text := btrim(p_player_id);
  v_wage   numeric;
  v_season text;
  v_holder text;
  v_min    numeric;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  v_club := public.my_club_shortname();
  IF v_club IS NULL OR btrim(v_club) = '' THEN
    RAISE EXCEPTION 'No club linked to this account';
  END IF;

  IF NOT public.player_expiry_auction_applies(v_pid) THEN
    RAISE EXCEPTION
      'This player is not on the expiring-contract market (final year, standard player only)';
  END IF;

  v_wage := round(coalesce(p_wage_offer, 0), 0);
  IF v_wage <= 0 THEN
    RAISE EXCEPTION 'Wage bid must be greater than zero';
  END IF;

  SELECT public.player_contracted_club_key(p."Contracted_Team")
  INTO v_holder
  FROM public."Players" p
  WHERE p."Konami_ID"::text = v_pid;

  SELECT p.contract_wage INTO v_min
  FROM public."Players" p
  WHERE p."Konami_ID"::text = v_pid;

  IF v_club = v_holder AND v_wage < coalesce(v_min, 0) THEN
    RAISE EXCEPTION
      'Your club holds this player — bid must be at least current contract wage (₿ %)',
      coalesce(v_min, 0);
  END IF;

  v_season := coalesce(public.current_gpsl_season_label(), 'unknown');

  INSERT INTO public.contract_expiry_wage_bids (
    player_id,
    bidder_club_short_name,
    wage_offer,
    season_label,
    updated_at
  )
  VALUES (v_pid, v_club, v_wage, v_season, now())
  ON CONFLICT ON CONSTRAINT contract_expiry_wage_bids_unique
  DO UPDATE SET
    wage_offer = EXCLUDED.wage_offer,
    updated_at = now();

  RETURN jsonb_build_object(
    'ok', true,
    'player_id', v_pid,
    'bidder_club_short_name', v_club,
    'wage_offer', v_wage,
    'season_label', v_season
  );
END;
$function$;

-- Market list: player info + caller's own bid only (amounts hidden)
CREATE OR REPLACE FUNCTION public.list_expiring_contract_market()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_viewer text;
  v_season text;
  v_out    jsonb := '[]'::jsonb;
  v_row    record;
  v_my_bid numeric;
BEGIN
  v_season := coalesce(public.current_gpsl_season_label(), 'unknown');

  BEGIN
    v_viewer := public.my_club_shortname();
  EXCEPTION
    WHEN OTHERS THEN
      v_viewer := NULL;
  END;

  FOR v_row IN
    SELECT
      p."Konami_ID"::text AS player_id,
      p."Name" AS player_name,
      p."Position" AS position,
      p."Rating" AS rating,
      p."Age" AS age,
      p.market_value,
      p."Contracted_Team" AS holding_club,
      p.contract_wage AS current_wage
    FROM public."Players" p
    WHERE public.player_contracted_club_key(p."Contracted_Team") IS NOT NULL
      AND coalesce(p.contract_seasons_remaining, 0) = 1
      AND NOT public.is_player_homegrown_u23(
        p."Konami_ID"::text,
        public.player_contracted_club_key(p."Contracted_Team")
      )
    ORDER BY p."Name"
  LOOP
    v_my_bid := NULL;
    IF v_viewer IS NOT NULL THEN
      SELECT b.wage_offer
      INTO v_my_bid
      FROM public.contract_expiry_wage_bids b
      WHERE b.player_id = v_row.player_id
        AND b.bidder_club_short_name = v_viewer
        AND b.season_label = v_season;
    END IF;

    v_out := v_out || jsonb_build_array(
      jsonb_build_object(
        'player_id', v_row.player_id,
        'player_name', v_row.player_name,
        'position', v_row.position,
        'rating', v_row.rating,
        'age', v_row.age,
        'market_value', v_row.market_value,
        'holding_club', v_row.holding_club,
        'current_wage', v_row.current_wage,
        'my_wage_bid', v_my_bid,
        'season_label', v_season
      )
    );
  END LOOP;

  RETURN coalesce(v_out, '[]'::jsonb);
END;
$function$;

-- Resolve all expiry bids for current season label (admin rollover only — not before)
CREATE OR REPLACE FUNCTION public.contract_resolve_all_expiry_bids()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season    text;
  v_player    record;
  v_bid       record;
  v_resolved  int := 0;
  v_holder    text;
BEGIN
  v_season := coalesce(public.current_gpsl_season_label(), 'unknown');

  FOR v_player IN
    SELECT p."Konami_ID"::text AS player_id
    FROM public."Players" p
    WHERE public.player_expiry_auction_applies(p."Konami_ID"::text)
  LOOP
    SELECT public.player_contracted_club_key(p."Contracted_Team")
    INTO v_holder
    FROM public."Players" p
    WHERE p."Konami_ID"::text = v_player.player_id
    FOR UPDATE;

    IF v_holder IS NULL THEN
      DELETE FROM public.contract_expiry_wage_bids b
      WHERE b.player_id = v_player.player_id
        AND b.season_label = v_season;
      CONTINUE;
    END IF;

    SELECT b.bidder_club_short_name, b.wage_offer
    INTO v_bid
    FROM public.contract_expiry_wage_bids b
    WHERE b.player_id = v_player.player_id
      AND b.season_label = v_season
    ORDER BY
      b.wage_offer DESC,
      CASE WHEN b.bidder_club_short_name = v_holder THEN 0 ELSE 1 END,
      b.created_at ASC
    LIMIT 1;

    IF NOT FOUND THEN
      CONTINUE;
    END IF;

    PERFORM public.player_assign_to_club(
      v_player.player_id,
      v_bid.bidder_club_short_name,
      v_bid.wage_offer
    );

    DELETE FROM public.contract_expiry_wage_bids b
    WHERE b.player_id = v_player.player_id
      AND b.season_label = v_season;

    v_resolved := v_resolved + 1;
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true,
    'season_label', v_season,
    'players_resolved', v_resolved
  );
END;
$function$;

-- Natural contract end: 0 seasons left → release + MV to holding club
CREATE OR REPLACE FUNCTION public.contract_release_zero_year_players()
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_player public."Players"%rowtype;
  v_club   text;
  v_fee    numeric;
  v_bal    numeric;
  v_count  int := 0;
BEGIN
  FOR v_player IN
    SELECT *
    FROM public."Players" p
    WHERE public.player_contracted_club_key(p."Contracted_Team") IS NOT NULL
      AND p.contract_seasons_remaining IS NOT NULL
      AND p.contract_seasons_remaining <= 0
    FOR UPDATE
  LOOP
    v_club := public.player_contracted_club_key(v_player."Contracted_Team");
    v_fee := greatest(coalesce(v_player.market_value::numeric, 0), 0);

    SELECT balance INTO v_bal
    FROM public."Club_Finances"
    WHERE club_name = v_club
    FOR UPDATE;

    IF v_bal IS NOT NULL THEN
      UPDATE public."Club_Finances"
      SET balance = v_bal + v_fee
      WHERE club_name = v_club;
    END IF;

    PERFORM public.player_release_from_club(v_player."Konami_ID"::text);

    INSERT INTO public."Transfer_History" (
      player_id,
      seller_club_id,
      buyer_club_id,
      fee,
      agent_fee,
      transfer_time,
      listing_id
    )
    VALUES (
      v_player."Konami_ID",
      v_club,
      NULL,
      v_fee,
      0,
      now(),
      NULL
    );

    v_count := v_count + 1;
  END LOOP;

  RETURN v_count;
END;
$function$;

-- Rollover tick: tick multi-year deals → resolve final-year bids → end unclaimed contracts
-- Order matters: expiry winners get a fresh 3-season deal and must NOT be decremented same tick.
CREATE OR REPLACE FUNCTION public.contract_tick_season_rollover()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_resolve jsonb;
  v_updated int;
  v_ended   int;
  v_final   int;
  v_released int;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  -- 3→2, 2→1 (not final-year players — they stay at 1 until bid resolution below)
  UPDATE public."Players" p
  SET contract_seasons_remaining = contract_seasons_remaining - 1
  WHERE public.player_contracted_club_key(p."Contracted_Team") IS NOT NULL
    AND p.contract_seasons_remaining IS NOT NULL
    AND p.contract_seasons_remaining >= 2;

  GET DIAGNOSTICS v_updated = ROW_COUNT;

  -- Final year (1 left): highest hidden wage bid wins → new 3-season contract at bid wage.
  -- Player stayed at holding club all season; move/renew only applies now (admin rollover).
  v_resolve := public.contract_resolve_all_expiry_bids();

  -- Standard final-year players with no winning bid → contract ended (0) → release + MV
  UPDATE public."Players" p
  SET contract_seasons_remaining = 0
  WHERE public.player_contracted_club_key(p."Contracted_Team") IS NOT NULL
    AND p.contract_seasons_remaining = 1
    AND public.player_expiry_auction_applies(p."Konami_ID"::text);

  GET DIAGNOSTICS v_ended = ROW_COUNT;

  v_released := public.contract_release_zero_year_players();

  SELECT count(*)::int
  INTO v_final
  FROM public."Players" p
  WHERE public.player_contracted_club_key(p."Contracted_Team") IS NOT NULL
    AND p.contract_seasons_remaining = 1;

  RETURN jsonb_build_object(
    'ok', true,
    'expiry_resolved', v_resolve,
    'players_decremented', v_updated,
    'players_contract_ended_no_bid', v_ended,
    'players_released_zero_years', v_released,
    'players_final_year', v_final
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.player_expiry_auction_applies(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.contract_submit_expiry_wage_bid(text, numeric) TO authenticated;
GRANT EXECUTE ON FUNCTION public.list_expiring_contract_market() TO authenticated;
GRANT EXECUTE ON FUNCTION public.contract_resolve_all_expiry_bids() TO authenticated;
GRANT EXECUTE ON FUNCTION public.contract_release_zero_year_players() TO authenticated;
