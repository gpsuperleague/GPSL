-- =============================================================================
-- Transfer news ticker: "top deals" from the last 48 hours (market + draft)
--
-- Deal pool = signings by GPSL clubs in the last 48h (draft auction included;
-- releases, foreign sales and special-auction keep-prep excluded), drawn from:
--   • TOP SIGNING  — 5 highest rated
--   • BIG MONEY    — 5 most expensive
--   • WONDERKID    — 5 highest rated under 22
--   • OVERPAID?    — 5 biggest % paid above market value
-- A deal appears once (first list it makes, ranks interleaved across lists).
--
-- Ticker: Discord gossip first, then up to 4 deal slots rotating every 15 min
-- (a fresh set of 4 each step), then idle fillers. Max 5 stories.
--
-- Replaces gpsl_transfer_gossip_jump_cycle_20260904 feed. Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.gpsl_transfer_news_feed(
  p_force_month text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season_id bigint;
  v_month text;
  v_month_label text;
  v_uk_today date;
  v_cycle_start timestamptz;
  v_cycle_mins int;
  v_stories jsonb := '[]'::jsonb;
  v_row record;
  v_name text;
  v_seller text;
  v_buyer text;
  v_fee_label text;
  v_method text;
  v_headline text;
  v_body text;
  v_kind text;
  v_cat text;
  v_count int := 0;
  v_force text := lower(nullif(btrim(coalesce(p_force_month, '')), ''));
  v_window_months text[] := ARRAY['june', 'july', 'august', 'january'];
  v_rumour record;
  v_pool_ids bigint[] := ARRAY[]::bigint[];
  v_pool_cats text[] := ARRAY[]::text[];
  v_pool_n int := 0;
  v_deal_slots int := 4;
  v_rotate_mins int := 15;
  v_show int;
  v_offset int := 0;
  v_i int;
  v_idx int;
  v_discord_n int := 0;
  v_pct numeric;
BEGIN
  SELECT id INTO v_season_id
  FROM public.competition_seasons
  WHERE is_current = true
  ORDER BY id DESC
  LIMIT 1;

  IF v_season_id IS NULL THEN
    RETURN jsonb_build_object('visible', false, 'reason', 'no_season', 'stories', '[]'::jsonb);
  END IF;

  BEGIN
    v_month := lower(coalesce(public.competition_active_gpsl_month(v_season_id, now()), ''));
  EXCEPTION WHEN OTHERS THEN
    v_month := '';
  END;

  IF v_force IS NOT NULL THEN
    IF NOT (v_force = ANY (v_window_months)) THEN
      RAISE EXCEPTION 'force month must be june, july, august, or january';
    END IF;
    v_month := v_force;
  END IF;

  IF NOT (v_month = ANY (v_window_months)) THEN
    RETURN jsonb_build_object(
      'visible', false,
      'reason', 'outside_transfer_news_months',
      'gpsl_month', nullif(v_month, ''),
      'stories', '[]'::jsonb
    );
  END IF;

  BEGIN
    v_month_label := public.competition_gpsl_month_label(v_month);
  EXCEPTION WHEN OTHERS THEN
    v_month_label := initcap(v_month);
  END;

  v_uk_today := (now() AT TIME ZONE 'Europe/London')::date;

  SELECT c.cycle_started_at INTO v_cycle_start
  FROM public.gpsl_transfer_ticker_cycle c
  WHERE c.id = 1;

  IF v_cycle_start IS NULL THEN
    v_cycle_start := public.gpsl_transfer_ticker_reset_cycle('feed_init');
  END IF;

  v_cycle_mins := greatest(0, floor(extract(epoch FROM (now() - v_cycle_start)) / 60.0)::int);

  -- 1) Discord gossip first (jumps the ticker)
  FOR v_rumour IN
    SELECT r.id, r.kind, r.headline, r.created_at, r.source
    FROM public.gpsl_transfer_rumours r
    WHERE r.season_id = v_season_id
      AND r.source = 'discord'
      AND r.expires_at > now()
    ORDER BY r.created_at DESC
    LIMIT 5
  LOOP
    EXIT WHEN v_count >= 5;
    v_stories := v_stories || jsonb_build_array(
      jsonb_build_object(
        'id', 'rumour:' || v_rumour.id::text,
        'kind', 'rumour',
        'kicker', 'TRANSFER RUMOUR',
        'headline', v_rumour.headline,
        'body', '',
        'href', 'transfer_center.html',
        'created_at', v_rumour.created_at
      )
    );
    v_count := v_count + 1;
    v_discord_n := v_discord_n + 1;
  END LOOP;

  -- 2) Top deals of the last 48 hours
  WITH deals AS (
    SELECT
      h.id,
      coalesce(h.fee, 0)::numeric AS fee,
      h.transfer_time,
      CASE WHEN btrim(coalesce(p."Rating"::text, '')) ~ '^[0-9]+(\.[0-9]+)?$'
           THEN btrim(p."Rating"::text)::numeric ELSE 0 END AS rating,
      CASE WHEN btrim(coalesce(p."Age"::text, '')) ~ '^[0-9]+$'
           THEN btrim(p."Age"::text)::int ELSE NULL END AS age,
      coalesce(
        nullif(CASE WHEN btrim(coalesce(l.market_value::text, '')) ~ '^[0-9]+(\.[0-9]+)?$'
                    THEN btrim(l.market_value::text)::numeric END, 0),
        CASE WHEN btrim(coalesce(p.market_value::text, '')) ~ '^[0-9]+(\.[0-9]+)?$'
             THEN btrim(p.market_value::text)::numeric END
      ) AS worth
    FROM public."Transfer_History" h
    LEFT JOIN public."Player_Transfer_Listings" l ON l.id = h.listing_id
    LEFT JOIN public."Players" p ON p."Konami_ID"::text = h.player_id::text
    WHERE h.transfer_time >= now() - interval '48 hours'
      AND coalesce(h.transfer_sale_note, '') NOT IN (
        'voluntary_contract_release', 'squad_overflow', 'new_owner_release',
        'special_auction_keep_prep'
      )
      AND nullif(btrim(coalesce(h.buyer_club_id, '')), '') IS NOT NULL
      AND h.buyer_club_id <> 'FOREIGN'
  ),
  ranked AS (
    SELECT id, 'top_rated'::text AS cat, 1 AS c,
           row_number() OVER (ORDER BY rating DESC, fee DESC, id DESC) AS r
    FROM deals
    UNION ALL
    SELECT id, 'big_money', 2,
           row_number() OVER (ORDER BY fee DESC, rating DESC, id DESC)
    FROM deals WHERE fee > 0
    UNION ALL
    SELECT id, 'wonderkid', 3,
           row_number() OVER (ORDER BY rating DESC, fee DESC, id DESC)
    FROM deals WHERE age IS NOT NULL AND age < 22
    UNION ALL
    SELECT id, 'overpaid', 4,
           row_number() OVER (ORDER BY fee / worth DESC, fee DESC, id DESC)
    FROM deals WHERE fee > 0 AND worth > 0 AND fee > worth
  ),
  firsts AS (
    SELECT DISTINCT ON (id) id, cat, c, r
    FROM ranked
    WHERE r <= 5
    ORDER BY id, r, c
  )
  SELECT coalesce(array_agg(id ORDER BY r, c), ARRAY[]::bigint[]),
         coalesce(array_agg(cat ORDER BY r, c), ARRAY[]::text[])
  INTO v_pool_ids, v_pool_cats
  FROM firsts;

  v_pool_n := coalesce(array_length(v_pool_ids, 1), 0);
  v_show := least(v_deal_slots, 5 - v_count, v_pool_n);
  IF v_pool_n > 0 AND v_show > 0 THEN
    v_offset := ((v_cycle_mins / v_rotate_mins) * v_show) % v_pool_n;
  END IF;

  FOR v_i IN 0..(v_show - 1) LOOP
    EXIT WHEN v_count >= 5;
    v_idx := 1 + ((v_offset + v_i) % v_pool_n);
    v_cat := v_pool_cats[v_idx];

    SELECT
      h.id, h.player_id, h.seller_club_id, h.buyer_club_id, h.fee,
      h.transfer_time, h.listing_id, h.foreign_buyer_name, h.transfer_sale_note,
      lower(coalesce(l.listing_type, '')) AS listing_type,
      p."Name" AS player_name,
      p."Rating"::text AS rating,
      p."Age"::text AS age,
      coalesce(
        nullif(CASE WHEN btrim(coalesce(l.market_value::text, '')) ~ '^[0-9]+(\.[0-9]+)?$'
                    THEN btrim(l.market_value::text)::numeric END, 0),
        CASE WHEN btrim(coalesce(p.market_value::text, '')) ~ '^[0-9]+(\.[0-9]+)?$'
             THEN btrim(p.market_value::text)::numeric END
      ) AS worth
    INTO v_row
    FROM public."Transfer_History" h
    LEFT JOIN public."Player_Transfer_Listings" l ON l.id = h.listing_id
    LEFT JOIN public."Players" p ON p."Konami_ID"::text = h.player_id::text
    WHERE h.id = v_pool_ids[v_idx];

    IF NOT FOUND THEN
      CONTINUE;
    END IF;

    v_name := coalesce(nullif(btrim(v_row.player_name), ''), 'Player');

    IF v_row.listing_type = 'draft' THEN
      v_seller := 'Draft auction';
    ELSE
      SELECT coalesce(c."Club", v_row.seller_club_id) INTO v_seller
      FROM public."Clubs" c WHERE c."ShortName" = v_row.seller_club_id LIMIT 1;
      v_seller := coalesce(v_seller, nullif(btrim(v_row.seller_club_id), ''), 'Free agent');
    END IF;

    SELECT coalesce(c."Club", v_row.buyer_club_id) INTO v_buyer
    FROM public."Clubs" c WHERE c."ShortName" = v_row.buyer_club_id LIMIT 1;
    v_buyer := coalesce(v_buyer, v_row.buyer_club_id, 'Unknown');

    BEGIN
      v_fee_label := public.transfer_format_money(coalesce(v_row.fee, 0));
    EXCEPTION WHEN OTHERS THEN
      v_fee_label := coalesce(v_row.fee, 0)::text;
    END;

    v_method := NULL;
    IF v_row.listing_type <> 'draft' THEN
      BEGIN
        v_method := public.transfer_classify_method(
          v_row.seller_club_id, v_row.buyer_club_id, v_row.listing_id,
          v_row.transfer_sale_note, v_row.foreign_buyer_name, NULL
        );
      EXCEPTION WHEN OTHERS THEN
        v_method := NULL;
      END;
    END IF;

    v_headline := CASE v_cat
      WHEN 'top_rated' THEN format('TOP SIGNING — %s (%s)', v_name, coalesce(nullif(btrim(v_row.rating), ''), '?'))
      WHEN 'big_money' THEN format('BIG MONEY — %s', v_name)
      WHEN 'wonderkid' THEN format('WONDERKID — %s (%s, age %s)', v_name,
                                   coalesce(nullif(btrim(v_row.rating), ''), '?'),
                                   coalesce(nullif(btrim(v_row.age), ''), '?'))
      WHEN 'overpaid' THEN format('OVERPAID? — %s', v_name)
      ELSE format('DONE DEAL — %s', v_name)
    END;

    v_body := format('%s → %s · %s', v_seller, v_buyer, v_fee_label);
    IF v_cat = 'overpaid' AND coalesce(v_row.worth, 0) > 0 THEN
      v_pct := round((v_row.fee / v_row.worth - 1) * 100);
      v_body := v_body || format(' · %s%% over market value', v_pct);
    END IF;
    IF v_method IS NOT NULL AND v_method NOT ILIKE 'Foreign sale%' THEN
      v_body := v_body || ' · ' || v_method;
    END IF;

    v_kind := CASE WHEN v_row.listing_type = 'draft' THEN 'draft' ELSE 'transfer' END;

    v_stories := v_stories || jsonb_build_array(
      jsonb_build_object(
        'id', 'transfer:' || v_row.id::text,
        'kind', v_kind,
        'category', v_cat,
        'kicker', 'TRANSFER NEWS',
        'headline', v_headline,
        'body', v_body,
        'href', 'transfer_center.html',
        'fee', coalesce(v_row.fee, 0),
        'transfer_time', v_row.transfer_time
      )
    );
    v_count := v_count + 1;
  END LOOP;

  -- 3) Idle fun fillers for leftover slots
  IF v_count < 5 THEN
    IF v_count < 2 THEN
      PERFORM public.gpsl_rumour_ensure_idle(v_season_id, 3);
    ELSIF v_count < 4 THEN
      PERFORM public.gpsl_rumour_ensure_idle(v_season_id, 2);
    ELSE
      PERFORM public.gpsl_rumour_ensure_idle(v_season_id, 1);
    END IF;

    FOR v_rumour IN
      SELECT r.id, r.kind, r.headline, r.created_at, r.source
      FROM public.gpsl_transfer_rumours r
      WHERE r.season_id = v_season_id
        AND r.source = 'idle'
        AND r.expires_at > now()
      ORDER BY r.created_at DESC
      LIMIT (5 - v_count)
    LOOP
      v_stories := v_stories || jsonb_build_array(
        jsonb_build_object(
          'id', 'rumour:' || v_rumour.id::text,
          'kind', 'idle',
          'kicker', 'TRANSFER RUMOUR',
          'headline', v_rumour.headline,
          'body', '',
          'href', 'transfer_center.html',
          'created_at', v_rumour.created_at
        )
      );
      v_count := v_count + 1;
    END LOOP;
  END IF;

  RETURN jsonb_build_object(
    'visible', jsonb_array_length(v_stories) > 0,
    'gpsl_month', v_month,
    'gpsl_month_label', v_month_label,
    'uk_date', v_uk_today,
    'forced', v_force IS NOT NULL,
    'story_count', jsonb_array_length(v_stories),
    'deal_pool_count', v_pool_n,
    'deal_rotate_offset', v_offset,
    'deal_slots_shown', v_show,
    'discord_shown', v_discord_n,
    'cycle_started_at', v_cycle_start,
    'cycle_mins', v_cycle_mins,
    'stories', v_stories
  );
END;
$function$;

COMMENT ON FUNCTION public.gpsl_transfer_news_feed(text) IS
  'Transfer ticker: Discord gossip first, then top deals of last 48h (top rated / big money / wonderkid U22 / overpaid %, market + draft) — 4 slots rotating every 15m, then idle.';

GRANT EXECUTE ON FUNCTION public.gpsl_transfer_news_feed(text) TO authenticated;

NOTIFY pgrst, 'reload schema';

-- Report: what the ticker would show right now (reason shown if outside window months)
SELECT f->>'visible' AS visible,
       f->>'reason' AS reason,
       f->>'gpsl_month' AS gpsl_month,
       f->>'deal_pool_count' AS deal_pool_48h,
       s->>'headline' AS headline,
       s->>'body' AS body
FROM (SELECT public.gpsl_transfer_news_feed() AS f) x
LEFT JOIN LATERAL jsonb_array_elements(coalesce(x.f->'stories', '[]'::jsonb)) s ON true;
