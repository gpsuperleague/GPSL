-- Allow gpsl_transfer_news_feed('may'|'june'|'july') from SQL Editor
-- (auth.uid() is null there). Browser still requires is_gpsl_admin().

CREATE OR REPLACE FUNCTION public.gpsl_transfer_news_feed(
  p_force_month text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season_id bigint;
  v_month text;
  v_month_label text;
  v_uk_today date;
  v_win_start timestamptz;
  v_win_end timestamptz;
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
  v_need int := 5;
  v_count int := 0;
  v_ids bigint[] := ARRAY[]::bigint[];
  v_force text := lower(nullif(btrim(coalesce(p_force_month, '')), ''));
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
    IF auth.uid() IS NOT NULL AND NOT public.is_gpsl_admin() THEN
      RAISE EXCEPTION 'Admin only — force month is for testing';
    END IF;
    IF v_force NOT IN ('may', 'june', 'july') THEN
      RAISE EXCEPTION 'force month must be may, june, or july';
    END IF;
    v_month := v_force;
  END IF;

  IF v_month NOT IN ('may', 'june', 'july') THEN
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

  SELECT m.unlock_at, m.lock_at
  INTO v_win_start, v_win_end
  FROM public.competition_season_calendar m
  WHERE m.season_id = v_season_id
    AND lower(m.gpsl_month) = v_month
  LIMIT 1;

  IF v_month = 'may' THEN
    v_stories := v_stories || jsonb_build_array(
      jsonb_build_object(
        'id', 'teaser-june-window',
        'kind', 'window',
        'kicker', 'TRANSFER NEWS',
        'headline', 'Transfer window opens in June',
        'body', 'The GPSL free-market window unlocks next month — clubs can move early via drafts while May fixtures finish.',
        'href', 'transfer_center.html',
        'fee', null,
        'transfer_time', null
      )
    );
    v_count := 1;
    v_need := 4;
  END IF;

  FOR v_row IN
    SELECT
      h.id,
      h.player_id,
      h.seller_club_id,
      h.buyer_club_id,
      h.fee,
      h.agent_fee,
      h.transfer_time,
      h.listing_id,
      h.foreign_buyer_name,
      h.transfer_sale_note,
      l.listing_type
    FROM public."Transfer_History" h
    LEFT JOIN public."Player_Transfer_Listings" l ON l.id = h.listing_id
    WHERE coalesce(h.transfer_sale_note, '') NOT IN (
      'voluntary_contract_release',
      'squad_overflow',
      'new_owner_release'
    )
      AND (
        CASE
          WHEN v_month IN ('june', 'july') THEN
            (h.transfer_time AT TIME ZONE 'Europe/London')::date = v_uk_today
          ELSE
            (
              (v_win_start IS NOT NULL AND h.transfer_time >= v_win_start AND h.transfer_time < coalesce(v_win_end, now() + interval '1 day'))
              OR (v_win_start IS NULL AND h.transfer_time >= (now() - interval '14 days'))
            )
        END
      )
    ORDER BY
      CASE WHEN v_month IN ('june', 'july') THEN coalesce(h.fee, 0) ELSE 0 END DESC,
      h.transfer_time DESC,
      h.id DESC
    LIMIT v_need
  LOOP
    v_ids := array_append(v_ids, v_row.id);
    v_listing_type := lower(coalesce(v_row.listing_type, ''));

    SELECT p."Name" INTO v_name
    FROM public."Players" p
    WHERE p."Konami_ID"::text = v_row.player_id::text
    LIMIT 1;
    v_name := coalesce(nullif(btrim(v_name), ''), 'Player');

    SELECT coalesce(c."Club", v_row.seller_club_id) INTO v_seller
    FROM public."Clubs" c
    WHERE c."ShortName" = v_row.seller_club_id
    LIMIT 1;
    v_seller := coalesce(v_seller, nullif(btrim(v_row.seller_club_id), ''), 'Free agent');

    IF v_row.buyer_club_id = 'FOREIGN' THEN
      v_buyer := coalesce(nullif(btrim(v_row.foreign_buyer_name), ''), 'Foreign club');
    ELSE
      SELECT coalesce(c."Club", v_row.buyer_club_id) INTO v_buyer
      FROM public."Clubs" c
      WHERE c."ShortName" = v_row.buyer_club_id
      LIMIT 1;
      v_buyer := coalesce(v_buyer, v_row.buyer_club_id, 'Unknown');
    END IF;

    BEGIN
      v_fee_label := public.transfer_format_money(coalesce(v_row.fee, 0));
    EXCEPTION WHEN OTHERS THEN
      v_fee_label := coalesce(v_row.fee, 0)::text;
    END;

    BEGIN
      v_method := public.transfer_classify_method(
        v_row.seller_club_id,
        v_row.buyer_club_id,
        v_row.listing_id,
        v_row.transfer_sale_note,
        v_row.foreign_buyer_name,
        NULL
      );
    EXCEPTION WHEN OTHERS THEN
      v_method := CASE
        WHEN v_listing_type = 'draft' THEN 'Draft auction'
        WHEN v_listing_type = 'direct' THEN 'Transfer market'
        ELSE 'Transfer'
      END;
    END;

    IF v_listing_type = 'draft' OR v_method ILIKE 'Draft%' THEN
      v_kind := 'draft';
      v_headline := format('DRAFT DEAL — %s joins %s', v_name, v_buyer);
      v_body := coalesce(v_method, 'Draft auction');
    ELSE
      v_kind := 'transfer';
      v_headline := format('DONE DEAL — %s', v_name);
      v_body := format('%s → %s · %s', v_seller, v_buyer, v_fee_label);
      IF v_method IS NOT NULL THEN
        v_body := v_body || ' · ' || v_method;
      END IF;
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
        'transfer_time', v_row.transfer_time,
        'player_name', v_name,
        'method', v_method
      )
    );
    v_count := v_count + 1;
  END LOOP;

  IF v_month IN ('june', 'july') AND v_count < 5 THEN
    v_need := 5 - v_count;
    FOR v_row IN
      SELECT
        h.id,
        h.player_id,
        h.seller_club_id,
        h.buyer_club_id,
        h.fee,
        h.transfer_time,
        h.listing_id,
        h.foreign_buyer_name,
        h.transfer_sale_note,
        l.listing_type
      FROM public."Transfer_History" h
      LEFT JOIN public."Player_Transfer_Listings" l ON l.id = h.listing_id
      WHERE coalesce(h.transfer_sale_note, '') NOT IN (
        'voluntary_contract_release',
        'squad_overflow',
        'new_owner_release'
      )
        AND NOT (h.id = ANY (v_ids))
        AND (
          (v_win_start IS NOT NULL AND h.transfer_time >= v_win_start AND h.transfer_time < coalesce(v_win_end, now() + interval '1 day'))
          OR (v_win_start IS NULL AND (h.transfer_time AT TIME ZONE 'Europe/London')::date >= date_trunc('month', v_uk_today)::date)
        )
      ORDER BY coalesce(h.fee, 0) DESC, h.transfer_time DESC, h.id DESC
      LIMIT v_need
    LOOP
      SELECT p."Name" INTO v_name
      FROM public."Players" p
      WHERE p."Konami_ID"::text = v_row.player_id::text
      LIMIT 1;
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

      v_listing_type := lower(coalesce(v_row.listing_type, ''));
      IF v_listing_type = 'draft' THEN
        v_kind := 'draft';
        v_headline := format('DRAFT DEAL — %s joins %s', v_name, v_buyer);
        v_body := 'Draft auction';
      ELSE
        v_kind := 'transfer';
        v_headline := format('DONE DEAL — %s', v_name);
        v_body := format('%s → %s · %s', v_seller, v_buyer, v_fee_label);
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
  END IF;

  RETURN jsonb_build_object(
    'visible', jsonb_array_length(v_stories) > 0,
    'gpsl_month', v_month,
    'gpsl_month_label', v_month_label,
    'uk_date', v_uk_today,
    'forced', v_force IS NOT NULL,
    'story_count', jsonb_array_length(v_stories),
    'stories', v_stories
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.gpsl_transfer_news_feed(text) TO authenticated;

NOTIFY pgrst, 'reload schema';
