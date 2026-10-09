-- =============================================================================
-- Main sponsor choice: open for the whole of GPSL June (2026-10-09)
-- =============================================================================
-- Before: owners had offer_days (7) to choose, then the long deal was signed
-- for them. Now the three offers stay open until GPSL June locks. Clubs that
-- take over after June still get offer_days.
--
--   1) club_commercial_offer_deadline(season): June lock_at, or now() +
--      offer_days if June has already locked / has no calendar row.
--   2) Trigger: every new offer gets at least that deadline.
--   3) club_commercial_ensure_season: inbox text shows the real deadline.
--   4) Current season, June not yet locked:
--        • offers still open → deadline moved to June lock
--        • long deal auto-signed (owner never chose) → reversed: up-front
--          payment taken back (Central Bank refunded), contract removed,
--          all three offers reopened, owner told by inbox
-- Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.club_commercial_offer_deadline(p_season bigint)
RETURNS timestamptz
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_june_lock timestamptz;
  v_days int;
BEGIN
  SELECT m.lock_at INTO v_june_lock
  FROM public.competition_season_calendar m
  WHERE m.season_id = p_season AND m.gpsl_month = 'june';

  IF v_june_lock IS NOT NULL AND v_june_lock > now() THEN
    RETURN v_june_lock;
  END IF;

  SELECT greatest(1, coalesce(s.offer_days, 7)) INTO v_days
  FROM public.club_commercial_settings s WHERE s.id = 1;
  RETURN now() + make_interval(days => coalesce(v_days, 7));
END;
$function$;

CREATE OR REPLACE FUNCTION public.trg_club_commercial_offer_deadline()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  NEW.expires_at := greatest(
    coalesce(NEW.expires_at, now()),
    public.club_commercial_offer_deadline(NEW.season_id)
  );
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS club_commercial_offer_deadline ON public.club_commercial_sponsor_offers;
CREATE TRIGGER club_commercial_offer_deadline
  BEFORE INSERT ON public.club_commercial_sponsor_offers
  FOR EACH ROW EXECUTE FUNCTION public.trg_club_commercial_offer_deadline();

-- ---------------------------------------------------------------------------
-- Same as club_commercial_deal_rebalance_20261008.sql; only the offer inbox
-- text changes (real deadline instead of "within N days").
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
    v_long := public.club_commercial_round(v_value * coalesce(s.long_deal_pct, 0.75));
    v_short := v_value;
    v_short_up := public.club_commercial_round(v_value * coalesce(s.short_upfront_pct, 0.50));
    v_perf_up := public.club_commercial_round(v_value * coalesce(s.perf_deal_base_pct, 0.10));
    v_perf_max := public.club_commercial_round(v_value * coalesce(s.perf_success_pct, 2.00));
    v_deadline := public.club_commercial_offer_deadline(p_season);

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
        v_deadline
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
    END IF;
  END IF;

  RETURN jsonb_build_object('ok', true, 'club', p_club, 'tier', v_tier, 'score', v_score, 'offers_made', v_offers_made);
END;
$function$;

-- ---------------------------------------------------------------------------
-- 4. Apply to the current season
-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS _sponsor_reopen;
CREATE TEMP TABLE _sponsor_reopen (club text, action text, detail text);

DO $$
DECLARE
  v_season bigint := public.club_commercial_current_season();
  v_june_lock timestamptz;
  v_deadline timestamptz;
  r record;
  p record;
  v_id bigint;
  v_owner uuid;
BEGIN
  SELECT m.lock_at INTO v_june_lock
  FROM public.competition_season_calendar m
  WHERE m.season_id = v_season AND m.gpsl_month = 'june';

  IF v_june_lock IS NULL OR v_june_lock <= now() THEN
    INSERT INTO _sponsor_reopen VALUES (NULL, 'skipped',
      format('GPSL June lock is %s — nothing reopened', coalesce(v_june_lock::text, 'not on the calendar')));
    RETURN;
  END IF;
  v_deadline := v_june_lock;

  -- Still choosing: extend
  WITH upd AS (
    UPDATE public.club_commercial_sponsor_offers o
    SET expires_at = v_deadline
    WHERE o.season_id = v_season AND o.status = 'offered' AND o.expires_at < v_deadline
    RETURNING o.club_short_name
  )
  INSERT INTO _sponsor_reopen
  SELECT DISTINCT club_short_name, 'extended', 'offers open until June locks' FROM upd;

  -- Auto-signed: reverse and reopen
  FOR r IN
    SELECT cs.*
    FROM public.club_commercial_sponsorships cs
    WHERE cs.start_season_id = v_season
      AND cs.auto_selected = true
  LOOP
    FOR p IN
      SELECT sp.* FROM public.club_commercial_sponsorship_payments sp
      WHERE sp.sponsorship_id = r.id
    LOOP
      IF coalesce(p.amount, 0) > 0 THEN
        v_id := public.post_club_ledger(
          r.club_short_name, 'commercial_sponsorship', -p.amount,
          'Main sponsor auto-signing reversed — choose your sponsor on the Stadium page',
          jsonb_build_object('sponsorship_id', r.id, 'reverses_payment_id', p.id, 'kind', 'reopen'),
          v_season, NULL, true, true
        );
        IF v_id IS NOT NULL
           AND NOT EXISTS (SELECT 1 FROM public.bank_ledger b WHERE b.club_ledger_id = v_id) THEN
          UPDATE public.gpsl_bank_account SET reserves = reserves + p.amount, updated_at = now() WHERE id = 1;
          INSERT INTO public.bank_ledger (entry_type, amount, description, club_short_name, club_ledger_id, metadata)
          VALUES ('commercial_sponsorship', p.amount,
                  'Main sponsor auto-signing reversed', r.club_short_name, v_id,
                  jsonb_build_object('sponsorship_id', r.id, 'kind', 'reopen'));
        END IF;
      END IF;
    END LOOP;

    DELETE FROM public.club_commercial_sponsorship_payments WHERE sponsorship_id = r.id;
    DELETE FROM public.club_commercial_sponsorships WHERE id = r.id;

    UPDATE public.club_commercial_sponsor_offers
    SET status = 'offered', decided_at = NULL, decided_by = NULL,
        auto_selected = false, expires_at = v_deadline
    WHERE season_id = v_season AND club_short_name = r.club_short_name;

    INSERT INTO _sponsor_reopen VALUES (r.club_short_name, 'reopened',
      format('auto-signed %s deal reversed', r.deal_kind));

    SELECT owner_id INTO v_owner FROM public."Clubs" WHERE "ShortName" = r.club_short_name;
    IF v_owner IS NOT NULL THEN
      BEGIN
        PERFORM public.owner_inbox_send(
          p_message_type => 'commercial_offer',
          p_title => '🤝 Your sponsor choice is open again',
          p_body => format(
            'Your long-term sponsor was signed automatically because no choice was made in time. '
            'Owners now have the whole of GPSL June to decide, so that signing has been undone and your '
            'three offers are open again. Choose on the Stadium page by %s (UK) — otherwise the '
            'long-term deal is signed for you.',
            to_char(v_deadline AT TIME ZONE 'Europe/London', 'FMDay DD Mon, HH24:MI')),
          p_recipient_club => r.club_short_name,
          p_owner_id => v_owner,
          p_action_href => 'stadium.html#commercialPanel',
          p_dedupe_key => format('commercial_reopen:%s:%s', v_season, r.club_short_name)
        );
      EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'reopen inbox skipped for %: %', r.club_short_name, SQLERRM;
      END;
    END IF;
  END LOOP;
END $$;

NOTIFY pgrst, 'reload schema';

SELECT
  coalesce(x.club, '—') AS club,
  coalesce(x.action, 'nothing to change') AS action,
  coalesce(x.detail, '') AS detail,
  (SELECT m.lock_at AT TIME ZONE 'Europe/London' FROM public.competition_season_calendar m
   WHERE m.season_id = public.club_commercial_current_season() AND m.gpsl_month = 'june') AS june_locks_uk
FROM (SELECT 1) one
LEFT JOIN _sponsor_reopen x ON true
ORDER BY x.action, x.club;
