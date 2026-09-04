-- =============================================================================
-- Transfer news ticker: notable deals only, UK-day cyclic rotation
--
-- Matches Discord #gpsl-news quality bar:
--   age ≤21 → rating ≥68 ; age ≥22 → rating ≥76
--   market / direct only (no draft)
--
-- Deals:
--   - Only transfers completed on the current UK calendar day
--   - Up to 3 deal slots at a time, rotating through that day's pool every 30 min
--   - Next UK day = fresh pool (no month-window padding)
--
-- Remaining ticker slots: Discord gossip, then idle fillers.
--
-- Requires: gpsl_discord_feed_transfer_passes_news_filter (deals news filter patch)
-- Safe re-run.
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
  v_uk_mins int;
  v_stories jsonb := '[]'::jsonb;
  v_row record;
  v_name text;
  v_seller text;
  v_buyer text;
  v_fee_label text;
  v_method text;
  v_listing_type text;
  v_headline text;
  v_body text;
  v_kind text;
  v_count int := 0;
  v_force text := lower(nullif(btrim(coalesce(p_force_month, '')), ''));
  v_window_months text[] := ARRAY['june', 'july', 'august', 'january'];
  v_rumour record;
  v_pool_ids bigint[] := ARRAY[]::bigint[];
  v_pool_n int := 0;
  v_deal_slots int := 3; -- leave room for gossip / fillers
  v_show int;
  v_offset int := 0;
  v_i int;
  v_pick_id bigint;
  v_has_filter boolean :=
    to_regprocedure('public.gpsl_discord_feed_transfer_passes_news_filter(text)') IS NOT NULL;
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
  v_uk_mins := (
    extract(hour FROM (now() AT TIME ZONE 'Europe/London'))::int * 60
    + extract(minute FROM (now() AT TIME ZONE 'Europe/London'))::int
  );

  -- Today's notable market deals (Discord news bar). Stable order for rotation.
  SELECT coalesce(array_agg(x.id ORDER BY x.fee DESC, x.transfer_time DESC, x.id DESC), ARRAY[]::bigint[])
  INTO v_pool_ids
  FROM (
    SELECT
      h.id,
      coalesce(h.fee, 0) AS fee,
      h.transfer_time
    FROM public."Transfer_History" h
    INNER JOIN public."Player_Transfer_Listings" l ON l.id = h.listing_id
    WHERE coalesce(h.transfer_sale_note, '') NOT IN (
      'voluntary_contract_release', 'squad_overflow', 'new_owner_release'
    )
      AND (h.transfer_time AT TIME ZONE 'Europe/London')::date = v_uk_today
      AND lower(coalesce(l.listing_type, '')) <> 'draft'
      AND (
        NOT v_has_filter
        OR public.gpsl_discord_feed_transfer_passes_news_filter(h.player_id::text)
      )
  ) x;

  v_pool_n := coalesce(array_length(v_pool_ids, 1), 0);
  v_show := least(v_deal_slots, v_pool_n);
  IF v_pool_n > 0 THEN
    -- Advance every 30 UK minutes; wraps so the whole day pool cycles.
    v_offset := (v_uk_mins / 30) % v_pool_n;
  END IF;

  FOR v_i IN 0..(v_show - 1) LOOP
    v_pick_id := v_pool_ids[1 + ((v_offset + v_i) % v_pool_n)];

    SELECT
      h.id, h.player_id, h.seller_club_id, h.buyer_club_id, h.fee,
      h.transfer_time, h.listing_id, h.foreign_buyer_name, h.transfer_sale_note,
      l.listing_type
    INTO v_row
    FROM public."Transfer_History" h
    LEFT JOIN public."Player_Transfer_Listings" l ON l.id = h.listing_id
    WHERE h.id = v_pick_id;

    IF NOT FOUND THEN
      CONTINUE;
    END IF;

    v_listing_type := lower(coalesce(v_row.listing_type, ''));

    SELECT p."Name" INTO v_name FROM public."Players" p
    WHERE p."Konami_ID"::text = v_row.player_id::text LIMIT 1;
    v_name := coalesce(nullif(btrim(v_name), ''), 'Player');

    SELECT coalesce(c."Club", v_row.seller_club_id) INTO v_seller
    FROM public."Clubs" c WHERE c."ShortName" = v_row.seller_club_id LIMIT 1;
    v_seller := coalesce(v_seller, nullif(btrim(v_row.seller_club_id), ''), 'Free agent');

    IF v_row.buyer_club_id = 'FOREIGN' THEN
      v_buyer := coalesce(nullif(btrim(v_row.foreign_buyer_name), ''), 'Foreign club');
    ELSE
      SELECT coalesce(c."Club", v_row.buyer_club_id) INTO v_buyer
      FROM public."Clubs" c WHERE c."ShortName" = v_row.buyer_club_id LIMIT 1;
      v_buyer := coalesce(v_buyer, v_row.buyer_club_id, 'Unknown');
    END IF;

    BEGIN
      v_fee_label := public.transfer_format_money(coalesce(v_row.fee, 0));
    EXCEPTION WHEN OTHERS THEN
      v_fee_label := coalesce(v_row.fee, 0)::text;
    END;

    BEGIN
      v_method := public.transfer_classify_method(
        v_row.seller_club_id, v_row.buyer_club_id, v_row.listing_id,
        v_row.transfer_sale_note, v_row.foreign_buyer_name, NULL
      );
    EXCEPTION WHEN OTHERS THEN
      v_method := 'Transfer';
    END;

    v_kind := 'transfer';
    v_headline := format('DONE DEAL — %s', v_name);
    v_body := format('%s → %s · %s', v_seller, v_buyer, v_fee_label);
    IF v_method IS NOT NULL
       AND coalesce(v_row.buyer_club_id, '') <> 'FOREIGN'
       AND v_method NOT ILIKE 'Foreign sale%' THEN
      v_body := v_body || ' · ' || v_method;
    END IF;

    v_stories := v_stories || jsonb_build_array(
      jsonb_build_object(
        'id', 'transfer:' || v_row.id::text,
        'kind', v_kind,
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

  -- Discord rumours + idle fillers for remaining slots
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
        AND r.expires_at > now()
      ORDER BY
        CASE WHEN r.source = 'discord' THEN 0 ELSE 1 END,
        r.created_at DESC
      LIMIT (5 - v_count)
    LOOP
      v_stories := v_stories || jsonb_build_array(
        jsonb_build_object(
          'id', 'rumour:' || v_rumour.id::text,
          'kind', CASE WHEN v_rumour.kind = 'idle' THEN 'idle' ELSE 'rumour' END,
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
    'stories', v_stories
  );
END;
$function$;

COMMENT ON FUNCTION public.gpsl_transfer_news_feed(text) IS
  'Transfer ticker: UK-day notable market deals (Discord rating bar) in 30-min rotation, then gossip/idle. Max 5.';

GRANT EXECUTE ON FUNCTION public.gpsl_transfer_news_feed(text) TO authenticated;

NOTIFY pgrst, 'reload schema';
