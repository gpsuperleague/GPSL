-- =============================================================================
-- Deals digest lookback for admin "Publish now"
--
-- Why Publish did nothing: first install marked ALL Transfer_History as digested
-- so cron wouldn't dump history. Until a new deal lands, tick finds 0 rows.
--
-- Fix: admin publish reopens the last 48h of deals, then digests them.
-- Nightly cron still uses lookback 0 (new deals only).
--
-- Run after discord_deals_digest_and_news_filter_20260904.sql
-- Safe re-run.
-- =============================================================================

DROP FUNCTION IF EXISTS public.admin_discord_deals_digest_now(int);
DROP FUNCTION IF EXISTS public.admin_discord_deals_digest_now(int, int);
DROP FUNCTION IF EXISTS public.gpsl_discord_deals_digest_tick(int);
DROP FUNCTION IF EXISTS public.gpsl_discord_deals_digest_tick(int, int);

CREATE OR REPLACE FUNCTION public.gpsl_discord_deals_digest_tick(
  p_max_posts int DEFAULT 5,
  p_lookback_hours int DEFAULT 0
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_max int := greatest(1, least(coalesce(p_max_posts, 5), 10));
  v_lookback int := greatest(0, least(coalesce(p_lookback_hours, 0), 168));
  v_day text := to_char((now() AT TIME ZONE 'Europe/London')::date, 'YYYY-MM-DD');
  v_day_label text := to_char((now() AT TIME ZONE 'Europe/London')::date, 'Dy DD Mon YYYY');
  v_row record;
  v_chunk_ids bigint[] := ARRAY[]::bigint[];
  v_marked_ids bigint[] := ARRAY[]::bigint[];
  v_name text;
  v_seller text;
  v_buyer text;
  v_fee text;
  v_method text;
  v_listing_type text;
  v_line text;
  v_chunk text := '';
  v_chunk_n int := 0;
  v_posted int := 0;
  v_qid bigint;
  v_part int := 0;
  v_dedupe text;
  v_do_flush boolean;
  v_reopened int := 0;
  v_stamp text := floor(extract(epoch from now()))::bigint::text;
BEGIN
  -- Admin lookback: reopen recent deals so Publish now has content
  IF v_lookback > 0 THEN
    UPDATE public."Transfer_History" h
    SET discord_deals_digested_at = NULL
    WHERE h.discord_deals_digested_at IS NOT NULL
      AND h.transfer_time >= now() - (v_lookback || ' hours')::interval
      AND lower(coalesce(btrim(h.transfer_sale_note), ''))
            IS DISTINCT FROM 'voluntary_contract_release';
    GET DIAGNOSTICS v_reopened = ROW_COUNT;
  END IF;

  FOR v_row IN
    SELECT
      h.id,
      h.player_id,
      h.seller_club_id,
      h.buyer_club_id,
      h.foreign_buyer_name,
      h.fee,
      h.listing_id,
      h.transfer_sale_note,
      h.transfer_time
    FROM public."Transfer_History" h
    WHERE h.discord_deals_digested_at IS NULL
      AND lower(coalesce(btrim(h.transfer_sale_note), ''))
            IS DISTINCT FROM 'voluntary_contract_release'
    ORDER BY h.transfer_time NULLS LAST, h.id
    LIMIT 200
  LOOP
    SELECT coalesce(nullif(btrim(p."Name"), ''), 'Player ' || v_row.player_id::text)
    INTO v_name
    FROM public."Players" p
    WHERE p."Konami_ID"::text = v_row.player_id::text
    LIMIT 1;

    IF v_name IS NULL OR btrim(v_name) = '' THEN
      v_name := 'Player ' || coalesce(v_row.player_id::text, '?');
    END IF;

    BEGIN
      v_seller := public.gpsl_discord_feed_club_name(v_row.seller_club_id);
    EXCEPTION WHEN OTHERS THEN
      v_seller := coalesce(nullif(btrim(v_row.seller_club_id), ''), '—');
    END;

    BEGIN
      IF v_row.buyer_club_id = 'FOREIGN' THEN
        v_buyer := coalesce(nullif(btrim(v_row.foreign_buyer_name), ''), 'Foreign club');
      ELSE
        v_buyer := public.gpsl_discord_feed_club_name(v_row.buyer_club_id);
      END IF;
    EXCEPTION WHEN OTHERS THEN
      v_buyer := coalesce(nullif(btrim(v_row.buyer_club_id), ''), '—');
    END;

    BEGIN
      v_fee := public.transfer_format_money(coalesce(v_row.fee, 0));
    EXCEPTION WHEN OTHERS THEN
      v_fee := coalesce(v_row.fee, 0)::text;
    END;

    v_listing_type := NULL;
    IF v_row.listing_id IS NOT NULL THEN
      SELECT l.listing_type INTO v_listing_type
      FROM public."Player_Transfer_Listings" l
      WHERE l.id = v_row.listing_id;
    END IF;

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
        WHEN lower(coalesce(v_listing_type, '')) = 'draft' THEN 'Draft'
        WHEN lower(coalesce(v_listing_type, '')) = 'direct' THEN 'Direct offer'
        WHEN v_row.listing_id IS NOT NULL THEN 'Transfer list'
        ELSE 'Transfer'
      END;
    END;

    v_line := format(
      '• **%s** — %s → %s · %s · _%s_',
      v_name,
      v_seller,
      v_buyer,
      v_fee,
      v_method
    );

    v_do_flush := (length(v_chunk) + length(v_line) + 1 > 3500 AND v_chunk <> '');
    IF v_do_flush THEN
      v_part := v_part + 1;
      v_dedupe := format(
        'deals_digest:%s:part:%s%s',
        v_day,
        v_part,
        CASE WHEN v_lookback > 0 THEN ':lb' || v_lookback::text || ':' || v_stamp ELSE '' END
      );
      v_qid := public.gpsl_discord_feed_enqueue_deals(
        'deals_digest',
        CASE
          WHEN v_part = 1 THEN format('🧾 COMPLETED DEALS — %s', v_day_label)
          ELSE format('🧾 COMPLETED DEALS — %s (%s)', v_day_label, v_part)
        END,
        v_chunk,
        42641,
        v_dedupe,
        jsonb_build_object(
          'digest', true,
          'day', v_day,
          'part', v_part,
          'deal_count', v_chunk_n,
          'lookback_hours', v_lookback
        )
      );
      IF v_qid IS NOT NULL THEN
        v_posted := v_posted + 1;
        v_marked_ids := v_marked_ids || v_chunk_ids;
      END IF;
      v_chunk := '';
      v_chunk_n := 0;
      v_chunk_ids := ARRAY[]::bigint[];
      IF v_posted >= v_max THEN
        EXIT;
      END IF;
    END IF;

    IF v_chunk = '' THEN
      v_chunk := v_line;
    ELSE
      v_chunk := v_chunk || E'\n' || v_line;
    END IF;
    v_chunk_n := v_chunk_n + 1;
    v_chunk_ids := array_append(v_chunk_ids, v_row.id);
  END LOOP;

  IF v_chunk <> '' AND v_posted < v_max THEN
    v_part := v_part + 1;
    v_dedupe := format(
      'deals_digest:%s:part:%s%s',
      v_day,
      v_part,
      CASE WHEN v_lookback > 0 THEN ':lb' || v_lookback::text || ':' || v_stamp ELSE '' END
    );
    v_qid := public.gpsl_discord_feed_enqueue_deals(
      'deals_digest',
      CASE
        WHEN v_part = 1 THEN format('🧾 COMPLETED DEALS — %s', v_day_label)
        ELSE format('🧾 COMPLETED DEALS — %s (%s)', v_day_label, v_part)
      END,
      v_chunk,
      42641,
      v_dedupe,
      jsonb_build_object(
        'digest', true,
        'day', v_day,
        'part', v_part,
        'deal_count', v_chunk_n,
        'lookback_hours', v_lookback
      )
    );
    IF v_qid IS NOT NULL THEN
      v_posted := v_posted + 1;
      v_marked_ids := v_marked_ids || v_chunk_ids;
    END IF;
  END IF;

  IF coalesce(array_length(v_marked_ids, 1), 0) > 0 THEN
    UPDATE public."Transfer_History" h
    SET discord_deals_digested_at = now()
    WHERE h.id = ANY (v_marked_ids)
      AND h.discord_deals_digested_at IS NULL;
  END IF;

  BEGIN
    PERFORM public.gpsl_discord_feed_request_flush();
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;

  RETURN jsonb_build_object(
    'ok', true,
    'posts_queued', v_posted,
    'deals_marked', coalesce(array_length(v_marked_ids, 1), 0),
    'reopened', v_reopened,
    'lookback_hours', v_lookback,
    'day', v_day
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_discord_deals_digest_now(
  p_max_posts int DEFAULT 5,
  p_lookback_hours int DEFAULT 48
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF NOT public.is_gpsl_admin()
     AND current_user NOT IN ('postgres', 'supabase_admin', 'service_role') THEN
    RAISE EXCEPTION 'Admin only';
  END IF;
  -- Manual publish: last 48h by default (so the button works after install)
  RETURN public.gpsl_discord_deals_digest_tick(
    p_max_posts,
    coalesce(p_lookback_hours, 48)
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.gpsl_discord_deals_digest_tick(int, int)
  TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.admin_discord_deals_digest_now(int, int)
  TO authenticated, service_role;

DO $cron$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    BEGIN
      PERFORM cron.unschedule('gpsl-discord-deals-digest');
    EXCEPTION WHEN OTHERS THEN
      NULL;
    END;
    PERFORM cron.schedule(
      'gpsl-discord-deals-digest',
      '0 21 * * *',
      $$SELECT public.gpsl_discord_deals_digest_tick(5, 0);$$
    );
  END IF;
EXCEPTION WHEN OTHERS THEN
  RAISE NOTICE 'pg_cron deals digest schedule skipped: %', SQLERRM;
END;
$cron$;

NOTIFY pgrst, 'reload schema';
