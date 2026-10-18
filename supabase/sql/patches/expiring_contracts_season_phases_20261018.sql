-- =============================================================================
-- Expiring contracts: Aug–Dec transfer / Jan–May wage / Playoff owner-only + bribe
--
-- • market_phase: transfer | wage | playoff | other
-- • Wage bids: Jan–May for all; Playoff = holding club only; Aug–Dec blocked
-- • Holding club sees interested_clubs (names) when wage bids exist
-- • Playoff bribe: ₿50,000 owner wealth reveals wage offers; 5% leak story
--
-- Safe re-run. Apply in Supabase after merge.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Bribe ledger
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.contract_expiry_offer_bribes (
  id bigserial PRIMARY KEY,
  player_id text NOT NULL,
  owner_id uuid NOT NULL REFERENCES auth.users (id),
  season_label text NOT NULL,
  leaked boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (player_id, owner_id, season_label)
);

CREATE INDEX IF NOT EXISTS contract_expiry_offer_bribes_player_idx
  ON public.contract_expiry_offer_bribes (player_id, season_label);

ALTER TABLE public.contract_expiry_offer_bribes ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS contract_expiry_offer_bribes_select_self ON public.contract_expiry_offer_bribes;
CREATE POLICY contract_expiry_offer_bribes_select_self
  ON public.contract_expiry_offer_bribes
  FOR SELECT TO authenticated
  USING (owner_id = auth.uid() OR public.is_gpsl_admin());

GRANT SELECT ON public.contract_expiry_offer_bribes TO authenticated;

-- ---------------------------------------------------------------------------
-- Active GPSL month → market phase
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.gpsl_expiring_market_phase(p_at timestamptz DEFAULT now())
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season_id bigint;
  v_month text;
BEGIN
  SELECT id INTO v_season_id
  FROM public.competition_seasons
  WHERE is_current = true
  ORDER BY id DESC
  LIMIT 1;

  IF v_season_id IS NULL THEN
    RETURN 'other';
  END IF;

  BEGIN
    v_month := lower(coalesce(public.competition_active_gpsl_month(v_season_id, p_at), ''));
  EXCEPTION
    WHEN OTHERS THEN
      v_month := '';
  END;

  IF v_month IN ('august', 'september', 'october', 'november', 'december') THEN
    RETURN 'transfer';
  END IF;
  IF v_month IN ('january', 'february', 'march', 'april', 'may') THEN
    RETURN 'wage';
  END IF;
  IF v_month IN ('playoffs', 'playoff') THEN
    RETURN 'playoff';
  END IF;
  RETURN 'other';
END;
$function$;

GRANT EXECUTE ON FUNCTION public.gpsl_expiring_market_phase(timestamptz) TO authenticated;

-- ---------------------------------------------------------------------------
-- Wage bid submit: phase + playoff owner-only
-- ---------------------------------------------------------------------------
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
  v_club      text;
  v_pid       text := btrim(p_player_id);
  v_wage      numeric;
  v_season    text;
  v_holder    text;
  v_current   numeric;
  v_min_offer numeric;
  v_pct       numeric := public.contract_expiry_min_wage_uplift_pct();
  v_existing  numeric;
  v_phase     text := public.gpsl_expiring_market_phase(now());
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  v_club := public.my_club_shortname();
  IF v_club IS NULL OR btrim(v_club) = '' THEN
    RAISE EXCEPTION 'No club linked to this account';
  END IF;

  IF NOT public.player_expiry_auction_applies(v_pid) THEN
    RAISE EXCEPTION 'This player is not on the expiring-contract market';
  END IF;

  IF v_phase = 'transfer' THEN
    RAISE EXCEPTION 'Wage contract offers open from GPSL January. Use Make transfer offer until then.';
  END IF;

  IF v_phase = 'other' THEN
    RAISE EXCEPTION 'Contract wage offers are not open in this GPSL month';
  END IF;

  SELECT public.player_contracted_club_key(p."Contracted_Team"),
         p.contract_wage
  INTO v_holder, v_current
  FROM public."Players" p
  WHERE p."Konami_ID"::text = v_pid;

  IF v_phase = 'playoff' THEN
    IF v_holder IS NULL OR upper(btrim(v_holder)) <> upper(btrim(v_club)) THEN
      RAISE EXCEPTION 'In Playoffs only the holding club can make a contract offer';
    END IF;
  ELSIF NOT public.player_expiry_bidding_open(v_pid) THEN
    RAISE EXCEPTION 'Wage bids are not open yet for this player';
  END IF;

  v_wage := round(coalesce(p_wage_offer, 0), 0);
  IF v_wage <= 0 THEN
    RAISE EXCEPTION 'Wage bid must be greater than zero';
  END IF;

  v_min_offer := public.contract_expiry_min_wage_offer(v_current);

  IF v_wage < v_min_offer THEN
    RAISE EXCEPTION
      'Wage offer must be at least ₿% (% %% above current wage ₿%)',
      to_char(v_min_offer, 'FM999,999,999'),
      to_char(v_pct, 'FM999'),
      to_char(coalesce(v_current, 0), 'FM999,999,999');
  END IF;

  v_season := coalesce(public.current_gpsl_season_label(), 'unknown');

  SELECT b.wage_offer
  INTO v_existing
  FROM public.contract_expiry_wage_bids b
  WHERE b.player_id = v_pid
    AND b.bidder_club_short_name = v_club
    AND b.season_label = v_season;

  IF FOUND THEN
    RAISE EXCEPTION
      'Your wage bid is locked in at ₿% and cannot be changed',
      to_char(v_existing, 'FM999,999,999');
  END IF;

  INSERT INTO public.contract_expiry_wage_bids (
    player_id,
    bidder_club_short_name,
    wage_offer,
    season_label,
    updated_at
  )
  VALUES (v_pid, v_club, v_wage, v_season, now());

  RETURN jsonb_build_object(
    'ok', true,
    'player_id', v_pid,
    'bidder_club_short_name', v_club,
    'wage_offer', v_wage,
    'min_wage_offer', v_min_offer,
    'min_uplift_pct', v_pct,
    'wage_step', 1,
    'season_label', v_season,
    'locked', true,
    'market_phase', v_phase
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.contract_submit_expiry_wage_bid(text, numeric) TO authenticated;

-- ---------------------------------------------------------------------------
-- Bribe: reveal offers in Playoff (₿50k owner wealth, 5% leak)
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
  v_season_id bigint;
  v_bal numeric;
  v_cost numeric := 50000;
  v_leaked boolean := false;
  v_offers jsonb := '[]'::jsonb;
  v_player_name text;
  v_club_name text;
  v_headline text;
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
    -- Already paid — return offers again
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
      'leaked', false,
      'cost', 0,
      'offers', v_offers
    );
  END IF;

  PERFORM public.owner_wallet_ensure(v_uid);
  SELECT balance INTO v_bal FROM public.owner_wallets WHERE owner_id = v_uid;
  IF coalesce(v_bal, 0) < v_cost THEN
    RAISE EXCEPTION 'Need ₿% owner wealth to bribe the agent (you have ₿%)',
      to_char(v_cost, 'FM999,999,999'),
      to_char(coalesce(v_bal, 0), 'FM999,999,999');
  END IF;

  PERFORM public._post_owner_ledger_internal(
    v_uid,
    'agent_bribe',
    -v_cost,
    'Bribed agent to reveal contract offers (' || coalesce(v_player_name, v_pid) || ')',
    jsonb_build_object('player_id', v_pid, 'club', v_club),
    NULL,
    true
  );

  v_leaked := (random() < 0.05);

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

  IF v_leaked THEN
    SELECT id INTO v_season_id
    FROM public.competition_seasons
    WHERE is_current = true
    ORDER BY id DESC
    LIMIT 1;

    BEGIN
      v_club_name := public.club_display_name(v_club);
    EXCEPTION
      WHEN OTHERS THEN
        v_club_name := v_club;
    END;

    v_headline :=
      'LEAK: '
      || coalesce(v_club_name, v_club)
      || ' bribed an agent for contract intel on '
      || coalesce(v_player_name, 'a player');

    IF v_season_id IS NOT NULL THEN
      INSERT INTO public.gpsl_transfer_rumours (
        season_id, source, kind, club_short_name, club_name,
        player_id, player_name, headline, expires_at
      )
      VALUES (
        v_season_id, 'idle', 'rumour', v_club, v_club_name,
        v_pid, v_player_name, v_headline,
        now() + interval '48 hours'
      );
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'already_bribed', false,
    'leaked', v_leaked,
    'cost', v_cost,
    'offers', v_offers,
    'headline', CASE WHEN v_leaked THEN v_headline ELSE NULL END
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.expiring_bribe_reveal_contract_offers(text) TO authenticated;

-- ---------------------------------------------------------------------------
-- Market list: phase + interested clubs + bribe status
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

    -- Interested clubs (names only) when viewer is holder or has bribed
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

    v_bribed := false;
    v_revealed := NULL;
    IF v_viewer IS NOT NULL AND auth.uid() IS NOT NULL THEN
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

    -- Phase overrides for UI
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
