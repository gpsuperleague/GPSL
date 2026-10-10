-- =============================================================================
-- Main sponsor: every club gets all three offers (2026-10-10)
-- =============================================================================
-- Before: a brand already offered to (or signed by) another club could not be
-- offered again. 57 brands × 3 offers each ran out after ~19 clubs, so later
-- clubs got one or two offers (often just the long-term deal) or none.
--
-- Now:
--   1) club_commercial_add_missing_offers(club, season, deadline): adds any of
--      long / short / performance the club is missing. Brands free elsewhere
--      are preferred, but a brand can be offered to several clubs at once.
--   2) club_commercial_ensure_season uses it for new offers, and tops up a
--      club that is still choosing but has fewer than three offers.
--   3) Current season: every owned club still choosing (no main sponsor) is
--      topped up to three offers now, same deadline as its existing offers,
--      and told by inbox.
-- Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.club_commercial_add_missing_offers(
  p_club text,
  p_season bigint,
  p_deadline timestamptz DEFAULT NULL
)
RETURNS text[]
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  s public.club_commercial_settings;
  v_tier text;
  v_band numeric[];
  v_pref text;
  v_score numeric;
  v_value numeric;
  v_long numeric;
  v_short numeric;
  v_short_up numeric;
  v_perf_up numeric;
  v_perf_max numeric;
  v_deadline timestamptz;
  v_kind text;
  v_brand record;
  v_names text[] := ARRAY[]::text[];
BEGIN
  SELECT * INTO s FROM public.club_commercial_settings WHERE id = 1;

  v_tier := public.club_commercial_tier(p_club);
  v_band := public.club_commercial_band(v_tier);
  v_pref := CASE v_tier WHEN 'big' THEN 'premium' WHEN 'medium' THEN 'standard' ELSE 'local' END;
  v_score := public.club_commercial_perf_score(p_club, public.club_commercial_prev_season(p_season));
  v_value := public.club_commercial_value(v_tier, v_score);

  v_long := public.club_commercial_round(v_value * coalesce(s.long_deal_pct, 0.75));
  v_short := v_value;
  v_short_up := public.club_commercial_round(v_value * coalesce(s.short_upfront_pct, 0.50));
  v_perf_up := public.club_commercial_round(v_value * coalesce(s.perf_deal_base_pct, 0.10));
  v_perf_max := public.club_commercial_round(v_value * coalesce(s.perf_success_pct, 2.00));
  v_deadline := coalesce(p_deadline, public.club_commercial_offer_deadline(p_season));

  FOREACH v_kind IN ARRAY ARRAY['long', 'short', 'performance'] LOOP
    CONTINUE WHEN EXISTS (
      SELECT 1 FROM public.club_commercial_sponsor_offers o
      WHERE o.season_id = p_season AND o.club_short_name = p_club AND o.deal_kind = v_kind
    );

    SELECT b.id, b.name INTO v_brand
    FROM public.commercial_brands b
    WHERE b.active
      AND NOT EXISTS (
        SELECT 1 FROM public.club_commercial_sponsor_offers mine
        WHERE mine.season_id = p_season AND mine.club_short_name = p_club AND mine.brand_id = b.id
      )
    ORDER BY
      (CASE WHEN EXISTS (
         SELECT 1 FROM public.club_commercial_sponsorships cs
         WHERE cs.brand_id = b.id
           AND cs.club_short_name <> p_club
           AND cs.start_season_id <= p_season
           AND public.club_commercial_season_offset(cs.start_season_id, p_season) < cs.seasons_total
       ) THEN 4 ELSE 0 END)
      + (CASE WHEN EXISTS (
         SELECT 1 FROM public.club_commercial_sponsor_offers so
         WHERE so.brand_id = b.id AND so.season_id = p_season
           AND so.status = 'offered' AND so.club_short_name <> p_club
       ) THEN 2 ELSE 0 END)
      + (CASE WHEN b.tier_pref = v_pref THEN 0 ELSE 0.7 END)
      + random()
    LIMIT 1;

    EXIT WHEN v_brand.id IS NULL;

    INSERT INTO public.club_commercial_sponsor_offers (
      season_id, club_short_name, brand_id, deal_kind, seasons,
      amount_per_season, base_amount, max_amount, band_min, band_max, expires_at
    ) VALUES (
      p_season, p_club, v_brand.id, v_kind,
      CASE WHEN v_kind = 'long' THEN 2 ELSE 1 END,
      CASE v_kind WHEN 'long' THEN v_long WHEN 'short' THEN v_short ELSE v_perf_up END,
      CASE v_kind WHEN 'long' THEN NULL WHEN 'short' THEN v_short_up ELSE v_perf_up END,
      CASE v_kind WHEN 'long' THEN NULL WHEN 'short' THEN v_short ELSE v_perf_max END,
      v_band[1], v_band[2],
      v_deadline
    )
    ON CONFLICT (season_id, club_short_name, deal_kind) DO NOTHING;

    IF FOUND THEN
      v_names := v_names || v_brand.name;
    END IF;
  END LOOP;

  RETURN v_names;
END;
$function$;

REVOKE EXECUTE ON FUNCTION public.club_commercial_add_missing_offers(text, bigint, timestamptz)
  FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Same as club_commercial_offers_until_june_lock_20261009.sql except the
-- offer step (club_commercial_add_missing_offers) and the top-up.
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
  v_deadline timestamptz;
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
    v_deadline := public.club_commercial_offer_deadline(p_season);
    v_names := public.club_commercial_add_missing_offers(p_club, p_season, v_deadline);
    v_offers_made := coalesce(array_length(v_names, 1), 0) > 0;

    IF v_offers_made THEN
      DECLARE
        v_title text := '🤝 Sponsorship offers are in';
        v_body text := format(
          'Three companies want to be your main sponsor this season: %s. '
          'Guaranteed money for two seasons, a one-season deal that depends on avoiding a big miss, '
          'or a big-bonus performance gamble on beating your expected league position? '
          'Choose on the Stadium page by %s (UK) — otherwise the long-term deal is signed for you.',
          array_to_string(v_names, ', '),
          to_char(v_deadline AT TIME ZONE 'Europe/London', 'FMDay DD Mon, HH24:MI')
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
    ELSIF v_owner IS NOT NULL THEN
      -- Still choosing but short of offers (brand pool ran out) → fill the gaps.
      SELECT max(o.expires_at) INTO v_deadline
      FROM public.club_commercial_sponsor_offers o
      WHERE o.season_id = p_season AND o.club_short_name = p_club
        AND o.status = 'offered' AND o.expires_at >= now();
      IF v_deadline IS NOT NULL AND (
        SELECT count(*) FROM public.club_commercial_sponsor_offers o
        WHERE o.season_id = p_season AND o.club_short_name = p_club
      ) < 3 THEN
        PERFORM public.club_commercial_add_missing_offers(p_club, p_season, v_deadline);
      END IF;
    END IF;
  END IF;

  RETURN jsonb_build_object('ok', true, 'club', p_club, 'tier', v_tier, 'score', v_score, 'offers_made', v_offers_made);
END;
$function$;

REVOKE EXECUTE ON FUNCTION public.club_commercial_ensure_season(text, bigint) FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Apply to the current season: top up every owned club still choosing
-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS _sponsor_topup;
CREATE TEMP TABLE _sponsor_topup (club text, offers_before int, added text, deadline_uk timestamp);

DO $$
DECLARE
  v_season bigint := public.club_commercial_current_season();
  r record;
  v_deadline timestamptz;
  v_names text[];
BEGIN
  IF v_season IS NULL OR NOT public.club_commercial_season_open(v_season) THEN
    INSERT INTO _sponsor_topup VALUES (NULL, NULL, 'skipped — no open commercial season', NULL);
    RETURN;
  END IF;

  FOR r IN
    SELECT c."ShortName" AS club, c.owner_id,
      (SELECT count(*) FROM public.club_commercial_sponsor_offers o
       WHERE o.season_id = v_season AND o.club_short_name = c."ShortName")::int AS n_offers,
      (SELECT max(o.expires_at) FROM public.club_commercial_sponsor_offers o
       WHERE o.season_id = v_season AND o.club_short_name = c."ShortName"
         AND o.status = 'offered') AS open_until
    FROM public."Clubs" c
    WHERE c.owner_id IS NOT NULL
      AND public.club_commercial_in_season(c."ShortName", v_season)
      AND public.club_commercial_active_sponsorship(c."ShortName", v_season) IS NULL
  LOOP
    CONTINUE WHEN r.n_offers >= 3;
    -- Clubs with no offers at all are handled by ensure_season on next page load / tick.
    CONTINUE WHEN r.n_offers = 0;
    CONTINUE WHEN r.open_until IS NULL OR r.open_until < now();

    PERFORM pg_advisory_xact_lock(hashtext('club_commercial:' || r.club || ':' || v_season));
    v_deadline := greatest(r.open_until, public.club_commercial_offer_deadline(v_season));

    UPDATE public.club_commercial_sponsor_offers
    SET expires_at = v_deadline
    WHERE season_id = v_season AND club_short_name = r.club AND status = 'offered'
      AND expires_at < v_deadline;

    v_names := public.club_commercial_add_missing_offers(r.club, v_season, v_deadline);

    INSERT INTO _sponsor_topup VALUES (
      r.club, r.n_offers,
      coalesce(nullif(array_to_string(v_names, ', '), ''), 'nothing added'),
      v_deadline AT TIME ZONE 'Europe/London'
    );

    IF coalesce(array_length(v_names, 1), 0) > 0 THEN
      BEGIN
        PERFORM public.owner_inbox_send(
          p_message_type => 'commercial_offer',
          p_title => '🤝 More sponsorship offers',
          p_body => format(
            'You were short of sponsor offers — that''s now fixed. New offers from: %s. '
            'You now have a long-term, one-season and performance deal to choose from. '
            'Choose on the Stadium page by %s (UK) — otherwise the long-term deal is signed for you.',
            array_to_string(v_names, ', '),
            to_char(v_deadline AT TIME ZONE 'Europe/London', 'FMDay DD Mon, HH24:MI')),
          p_recipient_club => r.club,
          p_owner_id => r.owner_id,
          p_action_href => 'stadium.html#commercialPanel',
          p_dedupe_key => format('commercial_topup:%s:%s', v_season, r.club)
        );
      EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'top-up inbox skipped for %: %', r.club, SQLERRM;
      END;
    END IF;
  END LOOP;
END $$;

NOTIFY pgrst, 'reload schema';

SELECT
  coalesce(x.club, '—') AS club,
  x.offers_before,
  coalesce(x.added, 'no club was short of offers') AS added,
  x.deadline_uk
FROM (SELECT 1) one
LEFT JOIN _sponsor_topup x ON true
ORDER BY x.club;
