-- =============================================================================
-- Club commercial: main sponsor deal rebalance (2026-10-08)
-- =============================================================================
-- Value = the club's sponsor value for the season (band by tier, last season's
-- results).
--
--   Long-term     75% of value a season for 2 seasons, guaranteed (150% total).
--   One-season    50% up front. At Close Finances another 50% if the club was
--                 on target, missed slightly, or reached a club cup target
--                 (100% total); a bad / abysmal miss pays nothing more (50%).
--   Performance   10% up front. At Close Finances another 190% if the club
--                 finished ABOVE its expected league position (200% total);
--                 otherwise nothing more (10%).
--
-- Settings: long_deal_pct 0.75, short_upfront_pct 0.50, perf_deal_base_pct
-- 0.10, perf_success_pct 2.00 (club_commercial_settings).
--
-- Pitchside boards: slot 1 is always the house board "GPSL on Ko-fi" (paid
-- like any other slot); slots 2–5 are random brands. The house brand is
-- inactive so it is never offered as a main sponsor.
-- Must run before offers are made (GPSL June). Safe to re-run.
-- =============================================================================

INSERT INTO public.commercial_brands (name, sector, tagline, tier_pref, active)
VALUES ('GPSL on Ko-fi', 'Supporters', 'Keep GPSL running — ko-fi.com/gpsluk', 'premium', false)
ON CONFLICT (name) DO UPDATE
SET sector = excluded.sector, tagline = excluded.tagline, active = false;

-- Boards already sold this season: slot 1 becomes the Ko-fi board (amount unchanged)
UPDATE public.club_commercial_boards bd
SET brand_id = (SELECT id FROM public.commercial_brands WHERE name = 'GPSL on Ko-fi')
WHERE bd.slot = 1
  AND bd.season_id = public.club_commercial_current_season();

ALTER TABLE public.club_commercial_settings
  ADD COLUMN IF NOT EXISTS short_upfront_pct numeric NOT NULL DEFAULT 0.50;
ALTER TABLE public.club_commercial_settings
  ADD COLUMN IF NOT EXISTS perf_success_pct numeric NOT NULL DEFAULT 2.00;

UPDATE public.club_commercial_settings
SET long_deal_pct = 0.75,
    perf_deal_base_pct = 0.10,
    short_upfront_pct = 0.50,
    perf_success_pct = 2.00,
    updated_at = now()
WHERE id = 1;

-- ---------------------------------------------------------------------------
-- Season payment: one-season and performance deals pay their up-front part
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.club_commercial_pay_sponsor_season(
  p_sponsorship_id bigint,
  p_season_id bigint
)
RETURNS numeric
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  c public.club_commercial_sponsorships;
  v_brand text;
  v_amount numeric;
  v_pay_id bigint;
  v_ledger bigint;
  v_n int;
BEGIN
  SELECT * INTO c FROM public.club_commercial_sponsorships WHERE id = p_sponsorship_id;
  IF NOT FOUND THEN
    RETURN 0;
  END IF;

  SELECT name INTO v_brand FROM public.commercial_brands WHERE id = c.brand_id;
  v_amount := CASE
    WHEN c.deal_kind IN ('performance', 'short') THEN coalesce(c.base_amount, c.amount_per_season)
    ELSE c.amount_per_season
  END;
  v_n := public.club_commercial_season_offset(c.start_season_id, p_season_id) + 1;

  INSERT INTO public.club_commercial_sponsorship_payments (sponsorship_id, season_id, kind, amount)
  VALUES (c.id, p_season_id, 'season', v_amount)
  ON CONFLICT (sponsorship_id, season_id, kind) DO NOTHING
  RETURNING id INTO v_pay_id;

  IF v_pay_id IS NULL THEN
    RETURN 0;
  END IF;

  v_ledger := public.club_commercial_post(
    c.club_short_name,
    'commercial_sponsorship',
    v_amount,
    CASE
      WHEN c.deal_kind = 'long' THEN format('Main sponsor: %s (season %s of %s)', v_brand, v_n, c.seasons_total)
      ELSE format('Main sponsor: %s (up-front payment)', v_brand)
    END,
    jsonb_build_object('sponsorship_id', c.id, 'brand', v_brand, 'deal_kind', c.deal_kind, 'kind', 'season'),
    p_season_id
  );

  UPDATE public.club_commercial_sponsorship_payments SET ledger_id = v_ledger WHERE id = v_pay_id;
  RETURN v_amount;
END;
$function$;

-- ---------------------------------------------------------------------------
-- Season start for one club: boards, sponsor payment or offers (new terms)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.club_commercial_ensure_season(p_club text, p_season bigint)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  s public.club_commercial_settings;
  v_tier text;
  v_band numeric[];
  v_pref text;
  v_prev bigint;
  v_score numeric;
  v_value numeric;
  v_total numeric;
  v_weights numeric[] := ARRAY[0.30, 0.24, 0.19, 0.15, 0.12];
  v_slot int := 0;
  v_amt numeric;
  v_left numeric;
  v_ledger bigint;
  v_brand record;
  v_contract bigint;
  v_owner uuid;
  v_expired_long bigint;
  v_offers_made boolean := false;
  v_names text[];
  v_long numeric;
  v_short numeric;
  v_short_up numeric;
  v_perf_up numeric;
  v_perf_max numeric;
BEGIN
  SELECT * INTO s FROM public.club_commercial_settings WHERE id = 1;
  IF NOT coalesce(s.enabled, false) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'disabled');
  END IF;
  IF NOT public.club_commercial_season_open(p_season) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'season_closed');
  END IF;
  IF NOT public.club_commercial_in_season(p_club, p_season) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_in_season');
  END IF;

  PERFORM pg_advisory_xact_lock(hashtext('club_commercial:' || p_club || ':' || p_season));

  v_tier := public.club_commercial_tier(p_club);
  v_band := public.club_commercial_band(v_tier);
  v_pref := CASE v_tier WHEN 'big' THEN 'premium' WHEN 'medium' THEN 'standard' ELSE 'local' END;
  v_prev := public.club_commercial_prev_season(p_season);
  v_score := public.club_commercial_perf_score(p_club, v_prev);
  v_value := public.club_commercial_value(v_tier, v_score);

  SELECT owner_id INTO v_owner FROM public."Clubs" WHERE "ShortName" = p_club;

  -- Pitchside boards (once per season)
  IF NOT EXISTS (
    SELECT 1 FROM public.club_commercial_boards
    WHERE season_id = p_season AND club_short_name = p_club
  ) THEN
    v_total := v_value;
    v_left := v_total;
    FOR v_brand IN
      SELECT x.id, x.name
      FROM (
        SELECT h.id, h.name, 0 AS grp, 0::float8 AS k
        FROM public.commercial_brands h
        WHERE h.name = 'GPSL on Ko-fi'
        UNION ALL
        (
          SELECT b.id, b.name, 1, (CASE WHEN b.tier_pref = v_pref THEN 0 ELSE 0.7 END) + random()
          FROM public.commercial_brands b
          WHERE b.active
          ORDER BY 4
          LIMIT 5
        )
      ) x
      ORDER BY x.grp, x.k
      LIMIT 5
    LOOP
      v_slot := v_slot + 1;
      v_amt := CASE WHEN v_slot = 5 THEN v_left
                    ELSE public.club_commercial_round(v_total * v_weights[v_slot]) END;
      v_amt := greatest(0, least(v_amt, v_left));
      v_left := v_left - v_amt;

      v_ledger := public.club_commercial_post(
        p_club, 'commercial_advertising', v_amt,
        format('Pitchside advertising: %s', v_brand.name),
        jsonb_build_object('brand', v_brand.name, 'slot', v_slot),
        p_season
      );

      INSERT INTO public.club_commercial_boards (season_id, club_short_name, slot, brand_id, amount, ledger_id)
      VALUES (p_season, p_club, v_slot, v_brand.id, v_amt, v_ledger);
    END LOOP;
  END IF;

  -- Main sponsor
  v_contract := public.club_commercial_active_sponsorship(p_club, p_season);

  IF v_contract IS NOT NULL THEN
    PERFORM public.club_commercial_pay_sponsor_season(v_contract, p_season);
  ELSIF v_owner IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.club_commercial_sponsor_offers
    WHERE season_id = p_season AND club_short_name = p_club
  ) THEN
    -- Vacant clubs get no offers; the first owner to take the club (June onwards) does.
    v_long := public.club_commercial_round(v_value * coalesce(s.long_deal_pct, 0.75));
    v_short := v_value;
    v_short_up := public.club_commercial_round(v_value * coalesce(s.short_upfront_pct, 0.50));
    v_perf_up := public.club_commercial_round(v_value * coalesce(s.perf_deal_base_pct, 0.10));
    v_perf_max := public.club_commercial_round(v_value * coalesce(s.perf_success_pct, 2.00));

    v_slot := 0;
    v_names := ARRAY[]::text[];
    FOR v_brand IN
      SELECT b.id, b.name
      FROM public.commercial_brands b
      WHERE b.active
        AND NOT EXISTS (
          SELECT 1 FROM public.club_commercial_sponsorships cs
          WHERE cs.brand_id = b.id
            AND cs.club_short_name <> p_club
            AND cs.start_season_id <= p_season
            AND public.club_commercial_season_offset(cs.start_season_id, p_season) < cs.seasons_total
        )
        AND NOT EXISTS (
          SELECT 1 FROM public.club_commercial_sponsor_offers so
          WHERE so.brand_id = b.id
            AND so.season_id = p_season
            AND so.status = 'offered'
        )
      ORDER BY (CASE WHEN b.tier_pref = v_pref THEN 0 ELSE 0.7 END) + random()
      LIMIT 3
    LOOP
      v_slot := v_slot + 1;
      v_names := v_names || v_brand.name;
      INSERT INTO public.club_commercial_sponsor_offers (
        season_id, club_short_name, brand_id, deal_kind, seasons,
        amount_per_season, base_amount, max_amount, band_min, band_max, expires_at
      ) VALUES (
        p_season, p_club, v_brand.id,
        (ARRAY['long', 'short', 'performance'])[v_slot],
        CASE WHEN v_slot = 1 THEN 2 ELSE 1 END,
        CASE v_slot WHEN 1 THEN v_long WHEN 2 THEN v_short ELSE v_perf_up END,
        CASE v_slot WHEN 1 THEN NULL WHEN 2 THEN v_short_up ELSE v_perf_up END,
        CASE v_slot WHEN 1 THEN NULL WHEN 2 THEN v_short ELSE v_perf_max END,
        v_band[1], v_band[2],
        now() + make_interval(days => greatest(1, s.offer_days))
      );
    END LOOP;
    v_offers_made := v_slot > 0;

    IF v_offers_made THEN
      DECLARE
        v_title text := '🤝 Sponsorship offers are in';
        v_body text := format(
          'Three companies want to be your main sponsor this season: %s. '
          'Guaranteed money for two seasons, a one-season deal that depends on avoiding a big miss, '
          'or a big-bonus performance gamble on beating your expected league position? '
          'Choose on the Stadium page within %s days — otherwise the long-term deal is signed for you.',
          array_to_string(v_names, ', '), greatest(1, s.offer_days)
        );
        v_dedupe text := format('commercial_offer:%s:%s', p_season, p_club);
      BEGIN
        BEGIN
          PERFORM public.owner_inbox_send(
            'commercial_offer'::text, v_title, v_body, p_club, v_owner,
            NULL::bigint, NULL::bigint, NULL::bigint, NULL::bigint,
            'stadium.html#commercialPanel'::text, v_dedupe, NULL::text, p_season, NULL::bigint
          );
        EXCEPTION WHEN undefined_function THEN
          PERFORM public.owner_inbox_send(
            'commercial_offer'::text, v_title, v_body, p_club, v_owner,
            NULL::bigint, NULL::bigint, NULL::bigint, NULL::bigint,
            'stadium.html#commercialPanel'::text, v_dedupe, NULL::text, p_season
          );
        END;
      EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'commercial offer inbox skipped for %: %', p_club, SQLERRM;
      END;
    END IF;
  ELSE
    -- Deadline passed with no choice → sign the safest (long) offer.
    SELECT id INTO v_expired_long
    FROM public.club_commercial_sponsor_offers
    WHERE season_id = p_season AND club_short_name = p_club
      AND status = 'offered' AND expires_at < now()
    ORDER BY CASE deal_kind WHEN 'long' THEN 0 WHEN 'short' THEN 1 ELSE 2 END
    LIMIT 1;
    IF v_expired_long IS NOT NULL THEN
      PERFORM public.club_commercial_accept_internal(v_expired_long, true);
    END IF;
  END IF;

  RETURN jsonb_build_object('ok', true, 'club', p_club, 'tier', v_tier, 'score', v_score, 'offers_made', v_offers_made);
END;
$function$;

-- ---------------------------------------------------------------------------
-- End of season: merchandising + one-season / performance top-ups
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.competition_post_commercial_eos(p_season_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  s public.club_commercial_settings;
  r record;
  c record;
  v_tier text;
  v_perf numeric;
  v_fill numeric;
  v_total numeric;
  v_shop numeric;
  v_global numeric;
  v_shop_id bigint;
  v_global_id bigint;
  v_bonus numeric;
  v_pay_id bigint;
  v_ledger bigint;
  v_merch_n int := 0;
  v_bonus_n int := 0;
  v_metrics jsonb;
  v_band text;
  v_cup_met boolean;
  v_exp int;
  v_act int;
  v_pass boolean;
  v_desc text;
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  SELECT * INTO s FROM public.club_commercial_settings WHERE id = 1;
  IF NOT coalesce(s.enabled, false) OR p_season_id IS NULL THEN
    RETURN jsonb_build_object('ok', true, 'skipped', true);
  END IF;

  FOR r IN
    SELECT DISTINCT ccs.club_short_name AS club
    FROM public.competition_club_seasons ccs
    WHERE ccs.season_id = p_season_id
      AND ccs.division IN ('superleague', 'championship_a', 'championship_b')
      AND ccs.club_short_name <> 'FOREIGN'
  LOOP
    v_tier := public.club_commercial_tier(r.club);
    v_perf := public.club_commercial_perf_score(r.club, p_season_id);

    -- Merchandising
    IF NOT EXISTS (
      SELECT 1 FROM public.club_commercial_merch
      WHERE season_id = p_season_id AND club_short_name = r.club
    ) THEN
      v_fill := public.club_commercial_fill_score(r.club, p_season_id);
      v_total := public.club_commercial_value(
        v_tier, (1 - s.merch_fill_weight) * v_perf + s.merch_fill_weight * v_fill
      );
      v_shop := public.club_commercial_round(v_total * s.shop_share);
      v_global := greatest(0, v_total - v_shop);

      v_shop_id := public.club_commercial_post(
        r.club, 'commercial_merchandise', v_shop,
        'Merchandising: club shop (kits & novelties)',
        jsonb_build_object('stream', 'shop', 'perf_score', v_perf, 'fill_score', v_fill),
        p_season_id
      );
      v_global_id := public.club_commercial_post(
        r.club, 'commercial_merchandise', v_global,
        'Merchandising: global kit sales',
        jsonb_build_object('stream', 'global', 'perf_score', v_perf, 'fill_score', v_fill),
        p_season_id
      );

      INSERT INTO public.club_commercial_merch (
        season_id, club_short_name, perf_score, fill_score,
        shop_amount, global_amount, shop_ledger_id, global_ledger_id
      ) VALUES (
        p_season_id, r.club, v_perf, v_fill, v_shop, v_global, v_shop_id, v_global_id
      );
      v_merch_n := v_merch_n + 1;
    END IF;

    -- Season result vs expectation
    v_metrics := NULL;
    BEGIN
      v_metrics := public.competition_stadium_season_metrics(r.club, p_season_id, NULL);
    EXCEPTION WHEN OTHERS THEN
      v_metrics := NULL;
    END;
    v_exp := CASE WHEN (v_metrics->>'expected_position') ~ '^\d+$' THEN (v_metrics->>'expected_position')::int END;
    v_act := CASE WHEN (v_metrics->>'actual_position') ~ '^\d+$' THEN (v_metrics->>'actual_position')::int END;
    IF v_act IS NULL THEN
      SELECT st.table_position INTO v_act
      FROM public.competition_standings_public st
      WHERE st.club_short_name = r.club;
    END IF;
    v_band := public.club_expectation_band_for_season(r.club, p_season_id);
    v_cup_met := false;
    BEGIN
      v_cup_met := coalesce((public.club_cup_target_status(r.club, p_season_id)->>'met')::boolean, false);
    EXCEPTION WHEN OTHERS THEN
      v_cup_met := false;
    END;

    -- One-season / performance top-ups (deals with an up-front part)
    FOR c IN
      SELECT sp.*, b.name AS brand_name
      FROM public.club_commercial_sponsorships sp
      JOIN public.commercial_brands b ON b.id = sp.brand_id
      WHERE sp.club_short_name = r.club
        AND sp.deal_kind IN ('performance', 'short')
        AND sp.base_amount IS NOT NULL
        AND sp.max_amount IS NOT NULL
        AND sp.start_season_id <= p_season_id
        AND public.club_commercial_season_offset(sp.start_season_id, p_season_id) < sp.seasons_total
    LOOP
      IF c.deal_kind = 'short' THEN
        v_pass := v_band IN ('on_target', 'slight') OR v_cup_met;
        v_desc := CASE WHEN v_pass
          THEN format('Main sponsor end-of-season payment: %s (target met)', c.brand_name)
          ELSE format('Main sponsor: %s — no end-of-season payment (missed expectation)', c.brand_name) END;
      ELSE
        v_pass := v_exp IS NOT NULL AND v_act IS NOT NULL AND v_act < v_exp;
        v_desc := CASE WHEN v_pass
          THEN format('Main sponsor performance bonus: %s (finished above expected position)', c.brand_name)
          ELSE format('Main sponsor: %s — no performance bonus (did not beat expected position)', c.brand_name) END;
      END IF;

      v_bonus := CASE WHEN v_pass THEN greatest(0, c.max_amount - c.base_amount) ELSE 0 END;

      v_pay_id := NULL;
      INSERT INTO public.club_commercial_sponsorship_payments (sponsorship_id, season_id, kind, amount)
      VALUES (c.id, p_season_id, 'performance_bonus', v_bonus)
      ON CONFLICT (sponsorship_id, season_id, kind) DO NOTHING
      RETURNING id INTO v_pay_id;

      IF v_pay_id IS NOT NULL THEN
        v_ledger := public.club_commercial_post(
          r.club, 'commercial_sponsorship', v_bonus, v_desc,
          jsonb_build_object(
            'sponsorship_id', c.id, 'brand', c.brand_name, 'kind', 'performance_bonus',
            'deal_kind', c.deal_kind, 'passed', v_pass, 'band', v_band, 'cup_met', v_cup_met,
            'expected_position', v_exp, 'actual_position', v_act
          ),
          p_season_id
        );
        UPDATE public.club_commercial_sponsorship_payments SET ledger_id = v_ledger WHERE id = v_pay_id;
        v_bonus_n := v_bonus_n + 1;
      END IF;
    END LOOP;
  END LOOP;

  RETURN jsonb_build_object('ok', true, 'merch_clubs', v_merch_n, 'performance_bonuses', v_bonus_n);
END;
$function$;

NOTIFY pgrst, 'reload schema';

-- Check: new terms, and no offers made yet under the old ones
SELECT long_deal_pct, short_upfront_pct, perf_deal_base_pct, perf_success_pct,
  (SELECT count(*) FROM public.club_commercial_sponsor_offers) AS offers_existing,
  (SELECT count(*) FROM public.commercial_brands WHERE name = 'GPSL on Ko-fi' AND NOT active) AS kofi_house_brand,
  position('GPSL on Ko-fi' IN pg_get_functiondef('public.club_commercial_ensure_season(text, bigint)'::regprocedure)) > 0
    AS kofi_board_slot1
FROM public.club_commercial_settings WHERE id = 1;
