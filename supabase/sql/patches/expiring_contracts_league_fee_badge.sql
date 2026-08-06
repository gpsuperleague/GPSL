-- =============================================================================
-- Expiring Contracts market: holding league + Champ→SL fee flag for viewer
--
-- Adds to list_expiring_contract_market():
--   holding_division, holding_league, holding_tier
--   viewer_tier, champ_sl_fee_applies, champ_sl_fee_pct, champ_sl_fee_estimate
--
-- Run in Supabase SQL Editor. Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.list_expiring_contract_market()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_viewer text;
  v_viewer_tier text := NULL;
  v_season text;
  v_out    jsonb := '[]'::jsonb;
  v_row    record;
  v_my_bid numeric;
  v_step   numeric := 1;
  v_min    numeric;
  v_applies boolean;
  v_holder text;
  v_div text;
  v_league text;
  v_tier text;
  v_fee_pct numeric := 15;
  v_fee_applies boolean;
  v_fee_est numeric;
  v_viewer_div text;
BEGIN
  BEGIN
    v_season := coalesce(public.current_gpsl_season_label(), 'unknown');
  EXCEPTION
    WHEN OTHERS THEN
      v_season := 'unknown';
  END;

  BEGIN
    v_step := public.contract_expiry_wage_bid_step();
  EXCEPTION
    WHEN OTHERS THEN
      v_step := 1;
  END;

  BEGIN
    v_fee_pct := public.contract_expiry_champ_sl_signing_fee_pct();
  EXCEPTION
    WHEN OTHERS THEN
      v_fee_pct := 15;
  END;

  BEGIN
    v_viewer := public.my_club_shortname();
  EXCEPTION
    WHEN OTHERS THEN
      v_viewer := NULL;
  END;

  IF v_viewer IS NOT NULL THEN
    BEGIN
      v_viewer_tier := public.competition_club_division_tier(v_viewer);
    EXCEPTION
      WHEN OTHERS THEN
        v_viewer_tier := NULL;
    END;

    -- Prefer explicit division from club seasons (works in summer break too)
    BEGIN
      SELECT ccs.division INTO v_viewer_div
      FROM public.competition_club_seasons ccs
      JOIN public.competition_seasons s ON s.id = ccs.season_id
      WHERE ccs.club_short_name = v_viewer
        AND ccs.division IN ('superleague', 'championship_a', 'championship_b')
      ORDER BY
        CASE WHEN s.is_current THEN 0 ELSE 1 END,
        CASE s.status WHEN 'active' THEN 0 WHEN 'preseason' THEN 1 ELSE 2 END,
        s.id DESC
      LIMIT 1;
      IF v_viewer_div = 'superleague' THEN
        v_viewer_tier := 'superleague';
      ELSIF v_viewer_div IS NOT NULL THEN
        v_viewer_tier := 'championship';
      END IF;
    EXCEPTION
      WHEN OTHERS THEN
        NULL;
    END;
  END IF;

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
      p."Contracted_Team" AS holding_club_raw,
      p.contract_wage AS current_wage
    FROM public."Players" p
    WHERE coalesce(p.contract_seasons_remaining, 0) = 1
      AND nullif(btrim(coalesce(p."Contracted_Team", '')), '') IS NOT NULL
    ORDER BY p."Name"
  LOOP
    BEGIN
      v_applies := public.player_expiry_auction_applies(v_row.player_id);
    EXCEPTION
      WHEN OTHERS THEN
        v_applies := false;
    END;
    IF NOT coalesce(v_applies, false) THEN
      CONTINUE;
    END IF;

    BEGIN
      v_holder := public.player_contracted_club_key(v_row.holding_club_raw);
    EXCEPTION
      WHEN OTHERS THEN
        v_holder := nullif(btrim(coalesce(v_row.holding_club_raw, '')), '');
    END;

    v_div := NULL;
    v_league := NULL;
    v_tier := NULL;

    IF v_holder IS NOT NULL THEN
      SELECT ccs.division
      INTO v_div
      FROM public.competition_club_seasons ccs
      JOIN public.competition_seasons s ON s.id = ccs.season_id
      WHERE ccs.club_short_name = v_holder
        AND ccs.division IN ('superleague', 'championship_a', 'championship_b')
      ORDER BY
        CASE WHEN s.is_current THEN 0 ELSE 1 END,
        CASE s.status
          WHEN 'active' THEN 0
          WHEN 'preseason' THEN 1
          WHEN 'summer_break' THEN 2
          ELSE 3
        END,
        s.id DESC
      LIMIT 1;

      v_league := CASE v_div
        WHEN 'superleague' THEN 'Super League'
        WHEN 'championship_a' THEN 'Championship A'
        WHEN 'championship_b' THEN 'Championship B'
        ELSE NULL
      END;

      BEGIN
        v_tier := public.competition_club_division_tier(v_holder);
      EXCEPTION
        WHEN OTHERS THEN
          v_tier := CASE
            WHEN v_div = 'superleague' THEN 'superleague'
            WHEN v_div IS NOT NULL THEN 'championship'
            ELSE NULL
          END;
      END;
    END IF;

    v_fee_applies :=
      coalesce(v_viewer_tier, '') = 'championship'
      AND coalesce(v_tier, '') = 'superleague';

    v_fee_est := NULL;
    IF v_fee_applies THEN
      v_fee_est := round(greatest(coalesce(v_row.market_value::numeric, 0), 0) * v_fee_pct / 100.0);
    END IF;

    v_my_bid := NULL;
    IF v_viewer IS NOT NULL THEN
      BEGIN
        SELECT b.wage_offer
        INTO v_my_bid
        FROM public.contract_expiry_wage_bids b
        WHERE b.player_id = v_row.player_id
          AND b.season_label = v_season
          AND b.bidder_club_short_name = v_viewer;
      EXCEPTION
        WHEN OTHERS THEN
          v_my_bid := NULL;
      END;
    END IF;

    BEGIN
      v_min := public.contract_expiry_min_wage_offer(v_row.current_wage);
    EXCEPTION
      WHEN OTHERS THEN
        v_min := greatest(coalesce(v_row.current_wage, 0) + 1, 10000);
    END;

    BEGIN
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
          'holding_club', coalesce(v_holder, v_row.holding_club_raw),
          'holding_division', v_div,
          'holding_league', v_league,
          'holding_tier', v_tier,
          'viewer_tier', v_viewer_tier,
          'champ_sl_fee_applies', v_fee_applies,
          'champ_sl_fee_pct', v_fee_pct,
          'champ_sl_fee_estimate', v_fee_est,
          'current_wage', v_row.current_wage,
          'min_wage_offer', v_min,
          'wage_step', v_step,
          'my_wage_bid', v_my_bid,
          'season_label', v_season
        )
      );
    EXCEPTION
      WHEN OTHERS THEN
        NULL;
    END;
  END LOOP;

  RETURN coalesce(v_out, '[]'::jsonb);
EXCEPTION
  WHEN OTHERS THEN
    RETURN '[]'::jsonb;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.list_expiring_contract_market() TO authenticated;

NOTIFY pgrst, 'reload schema';
