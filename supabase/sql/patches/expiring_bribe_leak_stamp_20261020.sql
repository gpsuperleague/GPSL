-- =============================================================================
-- Expiring bribe: 20% leak → public "Leaked bids" stamp only (no rumour / amounts)
-- Envelope still holder-only. Safe re-run.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Bribe: 20% leak, no transfer-rumour story (amounts stay private to holder)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.expiring_bribe_reveal_contract_offers(p_player_id text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_club text;
  v_pid text := btrim(p_player_id);
  v_holder text;
  v_phase text := public.gpsl_expiring_market_phase(now());
  v_season text;
  v_leaked boolean := false;
  v_offers jsonb := '[]'::jsonb;
  v_player_name text;
  v_inv_id bigint;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  IF v_phase <> 'playoff' THEN
    RAISE EXCEPTION 'Agent bribes are only available in the Playoff month';
  END IF;

  v_club := public.my_club_shortname();
  IF v_club IS NULL OR btrim(v_club) = '' THEN
    RAISE EXCEPTION 'No club linked to this account';
  END IF;

  SELECT
    public.player_contracted_club_key(p."Contracted_Team"),
    p."Name"
  INTO v_holder, v_player_name
  FROM public."Players" p
  WHERE p."Konami_ID"::text = v_pid;

  IF v_holder IS NULL OR upper(btrim(v_holder)) <> upper(btrim(v_club)) THEN
    RAISE EXCEPTION 'Only the holding club can bribe the agent for this player';
  END IF;

  v_season := coalesce(public.current_gpsl_season_label(), 'unknown');

  IF EXISTS (
    SELECT 1
    FROM public.contract_expiry_offer_bribes b
    WHERE b.player_id = v_pid
      AND b.owner_id = v_uid
      AND b.season_label = v_season
  ) THEN
    SELECT coalesce(
      jsonb_agg(
        jsonb_build_object(
          'club_short_name', b.bidder_club_short_name,
          'wage_offer', b.wage_offer
        )
        ORDER BY b.wage_offer DESC, b.bidder_club_short_name
      ),
      '[]'::jsonb
    )
    INTO v_offers
    FROM public.contract_expiry_wage_bids b
    WHERE b.player_id = v_pid
      AND b.season_label = v_season;

    RETURN jsonb_build_object(
      'ok', true,
      'already_bribed', true,
      'leaked', EXISTS (
        SELECT 1
        FROM public.contract_expiry_offer_bribes b
        WHERE b.player_id = v_pid
          AND b.owner_id = v_uid
          AND b.season_label = v_season
          AND b.leaked = true
      ),
      'cost', 0,
      'used_envelope', false,
      'offers', v_offers
    );
  END IF;

  SELECT i.id INTO v_inv_id
  FROM public.club_prize_inventory i
  WHERE upper(btrim(i.club_short_name)) = upper(btrim(v_club))
    AND i.prize_type = 'agent_bribe'
    AND i.status = 'available'
  ORDER BY i.id
  LIMIT 1
  FOR UPDATE;

  IF v_inv_id IS NULL THEN
    RAISE EXCEPTION
      'Buy a Brown envelope from the Owners Shop Side door aisle first (₿50,000)';
  END IF;

  UPDATE public.club_prize_inventory
  SET status = 'consumed',
      consumed_at = now(),
      metadata = coalesce(metadata, '{}'::jsonb) || jsonb_build_object(
        'consumed_for', 'expiring_bribe',
        'player_id', v_pid
      )
  WHERE id = v_inv_id;

  v_leaked := (random() < 0.20);

  INSERT INTO public.contract_expiry_offer_bribes (
    player_id, owner_id, season_label, leaked
  )
  VALUES (v_pid, v_uid, v_season, v_leaked);

  SELECT coalesce(
    jsonb_agg(
      jsonb_build_object(
        'club_short_name', b.bidder_club_short_name,
        'wage_offer', b.wage_offer
      )
      ORDER BY b.wage_offer DESC, b.bidder_club_short_name
    ),
    '[]'::jsonb
  )
  INTO v_offers
  FROM public.contract_expiry_wage_bids b
  WHERE b.player_id = v_pid
    AND b.season_label = v_season;

  RETURN jsonb_build_object(
    'ok', true,
    'already_bribed', false,
    'leaked', v_leaked,
    'cost', 0,
    'used_envelope', true,
    'inventory_id', v_inv_id,
    'offers', v_offers,
    'player_name', v_player_name
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.expiring_bribe_reveal_contract_offers(text) TO authenticated;

-- ---------------------------------------------------------------------------
-- Market list: expose bribe_leaked to everyone (stamp only — no amounts)
-- ---------------------------------------------------------------------------
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
  v_phase text := public.gpsl_expiring_market_phase(now());
  v_interested jsonb;
  v_bribed boolean;
  v_bribe_leaked boolean;
  v_revealed jsonb;
  v_bidding_open boolean;
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

    -- Interested clubs (names only) — holding club only
    v_interested := '[]'::jsonb;
    IF v_viewer IS NOT NULL
       AND v_holder IS NOT NULL
       AND upper(btrim(v_viewer)) = upper(btrim(v_holder)) THEN
      SELECT coalesce(
        jsonb_agg(
          jsonb_build_object('club_short_name', b.bidder_club_short_name)
          ORDER BY b.bidder_club_short_name
        ),
        '[]'::jsonb
      )
      INTO v_interested
      FROM public.contract_expiry_wage_bids b
      WHERE b.player_id = v_row.player_id
        AND b.season_label = v_season;
    END IF;

    -- Public leak stamp (no amounts). Amounts only if this viewer bribed.
    v_bribe_leaked := EXISTS (
      SELECT 1
      FROM public.contract_expiry_offer_bribes br
      WHERE br.player_id = v_row.player_id
        AND br.season_label = v_season
        AND br.leaked = true
    );

    v_bribed := false;
    v_revealed := NULL;
    IF v_viewer IS NOT NULL
       AND v_holder IS NOT NULL
       AND upper(btrim(v_viewer)) = upper(btrim(v_holder))
       AND auth.uid() IS NOT NULL THEN
      SELECT EXISTS (
        SELECT 1
        FROM public.contract_expiry_offer_bribes br
        WHERE br.player_id = v_row.player_id
          AND br.owner_id = auth.uid()
          AND br.season_label = v_season
      ) INTO v_bribed;

      IF v_bribed THEN
        SELECT coalesce(
          jsonb_agg(
            jsonb_build_object(
              'club_short_name', b.bidder_club_short_name,
              'wage_offer', b.wage_offer
            )
            ORDER BY b.wage_offer DESC
          ),
          '[]'::jsonb
        )
        INTO v_revealed
        FROM public.contract_expiry_wage_bids b
        WHERE b.player_id = v_row.player_id
          AND b.season_label = v_season;
      END IF;
    END IF;

    BEGIN
      v_bidding_open := public.player_expiry_bidding_open(v_row.player_id);
    EXCEPTION
      WHEN OTHERS THEN
        v_bidding_open := false;
    END;

    IF v_phase = 'transfer' THEN
      v_bidding_open := false;
    ELSIF v_phase = 'playoff' THEN
      v_bidding_open := (
        v_viewer IS NOT NULL
        AND v_holder IS NOT NULL
        AND upper(btrim(v_viewer)) = upper(btrim(v_holder))
      );
    ELSIF v_phase = 'other' THEN
      v_bidding_open := false;
    END IF;

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
          'season_label', v_season,
          'bidding_open', v_bidding_open,
          'market_phase', v_phase,
          'interested_clubs', v_interested,
          'bribe_used', v_bribed,
          'bribe_leaked', v_bribe_leaked,
          'revealed_offers', v_revealed,
          'contract_end_window', (
            SELECT coalesce(px.contract_end_window, 'summer')
            FROM public."Players" px
            WHERE px."Konami_ID"::text = v_row.player_id
          )
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
