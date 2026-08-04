-- Expiry wage-auction exemption brackets (safe re-run):
--   1) Home-grown AND age ≤ 23
--   2) Not home-grown AND age ≤ 21
-- Everyone else in final year → contested expiring-contract market.
-- Run in Supabase SQL Editor.

CREATE OR REPLACE FUNCTION public.is_player_expiry_auction_exempt(
  p_player_id text,
  p_club_short_name text
)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_pid   text := btrim(p_player_id);
  v_club  text := btrim(p_club_short_name);
  v_age   numeric;
  v_hg    boolean;
BEGIN
  IF v_pid IS NULL OR v_pid = '' OR v_club IS NULL OR v_club = '' THEN
    RETURN false;
  END IF;

  SELECT
    CASE
      WHEN p."Age" IS NULL OR btrim(p."Age"::text) = '' THEN NULL
      ELSE btrim(p."Age"::text)::numeric
    END
  INTO v_age
  FROM public."Players" p
  WHERE p."Konami_ID"::text = v_pid;

  IF NOT FOUND OR v_age IS NULL THEN
    RETURN false;
  END IF;

  v_hg := public.is_player_homegrown(v_pid, v_club);

  -- HG ≤23
  IF v_hg AND v_age <= 23 THEN
    RETURN true;
  END IF;

  -- Non-HG ≤21
  IF (NOT v_hg) AND v_age <= 21 THEN
    RETURN true;
  END IF;

  RETURN false;
END;
$function$;

COMMENT ON FUNCTION public.is_player_expiry_auction_exempt(text, text) IS
  'Uncontested renew/release only: (HG and age≤23) OR (not HG and age≤21).';

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

  IF coalesce(v_player.pesdb_unavailable, false) THEN
    RETURN false;
  END IF;

  v_club := public.player_contracted_club_key(v_player."Contracted_Team");
  IF v_club IS NULL THEN
    RETURN false;
  END IF;

  IF coalesce(v_player.contract_seasons_remaining, 0) <> 1 THEN
    RETURN false;
  END IF;

  IF public.is_player_expiry_auction_exempt(btrim(p_player_id), v_club) THEN
    RETURN false;
  END IF;

  RETURN true;
END;
$function$;

-- Same-wage renew for either uncontested bracket
CREATE OR REPLACE FUNCTION public.player_contract_renew(
  p_player_id text,
  p_wage numeric DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club     text;
  v_player   public."Players"%rowtype;
  v_pid      text := btrim(p_player_id);
  v_wage     numeric;
  v_exempt   boolean;
  v_season   text;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  v_club := public.my_club_shortname();
  IF v_club IS NULL OR btrim(v_club) = '' THEN
    RAISE EXCEPTION 'No club linked to this account';
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

  IF coalesce(v_player.contract_seasons_remaining, 0) <> 1 THEN
    RAISE EXCEPTION 'Renewal is only available in the final contract year (1 season remaining)';
  END IF;

  v_exempt := public.is_player_expiry_auction_exempt(v_pid, v_club);
  v_wage := coalesce(p_wage, v_player.contract_wage);

  IF v_exempt THEN
    v_wage := coalesce(v_player.contract_wage, v_wage);
  ELSE
    IF v_wage IS NULL OR v_wage < coalesce(v_player.contract_wage, 0) THEN
      RAISE EXCEPTION
        'Renewal wage must be at least the current contract wage (₿ %)',
        coalesce(v_player.contract_wage, 0);
    END IF;
  END IF;

  v_season := public.current_gpsl_season_label();

  UPDATE public."Players"
  SET
    contract_seasons_remaining = 3,
    contract_wage = round(v_wage, 0),
    "Season_Signed" = v_season
  WHERE "Konami_ID"::text = v_pid;

  RETURN jsonb_build_object(
    'ok', true,
    'player_id', v_pid,
    'contract_seasons_remaining', 3,
    'contract_wage', round(v_wage, 0),
    'expiry_auction_exempt', v_exempt,
    'homegrown_u23', public.is_player_homegrown_u23(v_pid, v_club)
  );
END;
$function$;

-- Market list: contested final-year only
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
  v_step   numeric := public.contract_expiry_wage_bid_step();
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
      p."Nation" AS nation,
      p."Playstyle" AS playstyle,
      p."Rating" AS rating,
      p."Age" AS age,
      p.market_value,
      p."Contracted_Team" AS holding_club,
      p.contract_wage AS current_wage
    FROM public."Players" p
    WHERE public.player_expiry_auction_applies(p."Konami_ID"::text)
    ORDER BY p."Name"
  LOOP
    v_my_bid := NULL;
    IF v_viewer IS NOT NULL THEN
      SELECT b.wage_offer
      INTO v_my_bid
      FROM public.contract_expiry_wage_bids b
      WHERE b.player_id = v_row.player_id
        AND b.season_label = v_season
        AND b.bidder_club_short_name = v_viewer;
    END IF;

    v_out := v_out || jsonb_build_array(
      jsonb_build_object(
        'player_id', v_row.player_id,
        'player_name', v_row.player_name,
        'position', v_row.position,
        'nation', v_row.nation,
        'playstyle', v_row.playstyle,
        'rating', v_row.rating,
        'age', v_row.age,
        'market_value', v_row.market_value,
        'holding_club', v_row.holding_club,
        'current_wage', v_row.current_wage,
        'min_wage_offer', public.contract_expiry_min_wage_offer(v_row.current_wage),
        'wage_step', v_step,
        'my_wage_bid', v_my_bid,
        'season_label', v_season
      )
    );
  END LOOP;

  RETURN coalesce(v_out, '[]'::jsonb);
END;
$function$;

-- Note: re-run season_contract_tick_catchup.sql afterwards so admin market counts
-- use player_expiry_auction_applies (already updated in repo).

GRANT EXECUTE ON FUNCTION public.is_player_expiry_auction_exempt(text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.player_expiry_auction_applies(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.player_contract_renew(text, numeric) TO authenticated;
GRANT EXECUTE ON FUNCTION public.list_expiring_contract_market() TO authenticated;
