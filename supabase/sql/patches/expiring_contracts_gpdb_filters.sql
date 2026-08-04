-- Expand expiring-contract market rows for GPDB-style filters (nation, playstyle).
-- Safe re-run.

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

GRANT EXECUTE ON FUNCTION public.list_expiring_contract_market() TO authenticated;

NOTIFY pgrst, 'reload schema';
