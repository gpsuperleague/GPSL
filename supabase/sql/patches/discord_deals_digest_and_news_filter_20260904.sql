-- =============================================================================
-- Discord transfers:
--   1) #gpsl-news filter refresh
--        Age ≤21 → rating ≥68
--        Age ≥22 → rating ≥76
--        Market only: listing must exist and listing_type ≠ draft
--        (direct offers + transfer-list auctions yes; draft no)
--   2) #gpsl-deals — daily batched digest of ALL completed deals
--        (draft, market, direct, foreign, etc. — not contract releases)
--        Cron 21:00 UTC (≈9pm UK winter / 10pm BST)
--
-- Setup:
--   1) Discord → create #gpsl-deals → Webhooks → copy URL
--   2) Supabase → Edge Functions → Secrets:
--        DISCORD_DEALS_WEBHOOK_URL = #gpsl-deals
--   3) Run this SQL
--   4) Redeploy: supabase functions deploy discord-sky-feed
--
-- Safe re-run.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- News filter thresholds
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.gpsl_discord_feed_transfer_passes_news_filter(
  p_player_id text
)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_age int;
  v_rating numeric;
BEGIN
  SELECT
    CASE
      WHEN nullif(btrim(p."Age"::text), '') ~ '^[0-9]+$'
      THEN nullif(btrim(p."Age"::text), '')::int
      ELSE NULL
    END,
    CASE
      WHEN to_regprocedure('public.player_rating_as_numeric(text)') IS NOT NULL
      THEN public.player_rating_as_numeric(p."Rating"::text)
      WHEN nullif(btrim(p."Rating"::text), '') ~ '^[0-9]+(\.[0-9]+)?$'
      THEN nullif(btrim(p."Rating"::text), '')::numeric
      ELSE 0
    END
  INTO v_age, v_rating
  FROM public."Players" p
  WHERE p."Konami_ID"::text = btrim(coalesce(p_player_id, ''))
  LIMIT 1;

  IF v_age IS NULL OR v_rating IS NULL THEN
    RETURN false;
  END IF;

  -- Age 21 or younger → 68+
  IF v_age <= 21 THEN
    RETURN v_rating >= 68;
  END IF;

  -- Age 22+ → 76+
  RETURN v_rating >= 76;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.gpsl_discord_feed_transfer_passes_news_filter(text)
  TO authenticated, service_role;

COMMENT ON FUNCTION public.gpsl_discord_feed_transfer_passes_news_filter(text) IS
  'Discord #gpsl-news transfer filter: age≤21 rating≥68; age≥22 rating≥76.';

-- Live #gpsl-news posts for notable market deals (not draft)
CREATE OR REPLACE FUNCTION public.gpsl_discord_feed_on_transfer()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_name text;
  v_seller text;
  v_buyer text;
  v_fee text;
  v_listing_type text;
  v_method text;
  v_note text := lower(coalesce(btrim(NEW.transfer_sale_note), ''));
  v_age int;
  v_rating numeric;
BEGIN
  SELECT
    p."Name",
    CASE
      WHEN nullif(btrim(p."Age"::text), '') ~ '^[0-9]+$'
      THEN nullif(btrim(p."Age"::text), '')::int
      ELSE NULL
    END,
    CASE
      WHEN to_regprocedure('public.player_rating_as_numeric(text)') IS NOT NULL
      THEN public.player_rating_as_numeric(p."Rating"::text)
      WHEN nullif(btrim(p."Rating"::text), '') ~ '^[0-9]+(\.[0-9]+)?$'
      THEN nullif(btrim(p."Rating"::text), '')::numeric
      ELSE 0
    END
  INTO v_name, v_age, v_rating
  FROM public."Players" p
  WHERE p."Konami_ID"::text = NEW.player_id::text
  LIMIT 1;

  v_name := coalesce(nullif(btrim(v_name), ''), 'Player ' || NEW.player_id::text);
  v_seller := public.gpsl_discord_feed_club_name(NEW.seller_club_id);

  -- Voluntary contract release (no listing) — keep on news channel
  IF v_note = 'voluntary_contract_release' THEN
    PERFORM public.gpsl_discord_feed_enqueue(
      'release',
      format('📋 CONTRACT RELEASE — %s', v_name),
      format('%s left %s.', v_name, v_seller),
      12370112, -- 0xbcbc80
      'transfer:' || NEW.id::text,
      jsonb_build_object(
        'transfer_history_id', NEW.id,
        'transfer_sale_note', NEW.transfer_sale_note,
        'channel', 'news'
      )
    );
    RETURN NEW;
  END IF;

  -- Notable live news: market system only (listing required, not draft)
  IF NEW.listing_id IS NULL THEN
    RETURN NEW;
  END IF;

  SELECT l.listing_type INTO v_listing_type
  FROM public."Player_Transfer_Listings" l
  WHERE l.id = NEW.listing_id;

  IF lower(coalesce(v_listing_type, '')) = 'draft' THEN
    RETURN NEW;
  END IF;

  IF NOT public.gpsl_discord_feed_transfer_passes_news_filter(NEW.player_id::text) THEN
    RETURN NEW;
  END IF;

  v_buyer := CASE
    WHEN NEW.buyer_club_id = 'FOREIGN' THEN coalesce(nullif(btrim(NEW.foreign_buyer_name), ''), 'Foreign club')
    ELSE public.gpsl_discord_feed_club_name(NEW.buyer_club_id)
  END;

  BEGIN
    v_fee := public.transfer_format_money(coalesce(NEW.fee, 0));
  EXCEPTION WHEN OTHERS THEN
    v_fee := coalesce(NEW.fee, 0)::text;
  END;

  BEGIN
    v_method := public.transfer_classify_method(
      NEW.seller_club_id, NEW.buyer_club_id, NEW.listing_id,
      NEW.transfer_sale_note, NEW.foreign_buyer_name, NULL
    );
  EXCEPTION WHEN OTHERS THEN
    v_method := CASE
      WHEN lower(coalesce(v_listing_type, '')) = 'direct' THEN 'Direct offer (transfer market)'
      ELSE 'Transfer list (auction)'
    END;
  END;

  PERFORM public.gpsl_discord_feed_enqueue(
    'transfer',
    format('🔨 DONE DEAL — %s', v_name),
    format(
      E'%s → %s\nFee: %s\n%s\nAge %s · Rating %s',
      v_seller,
      v_buyer,
      v_fee,
      v_method,
      coalesce(v_age::text, '?'),
      coalesce(trim(to_char(v_rating, 'FM999')), '?')
    ),
    42641,
    'transfer:' || NEW.id::text,
    jsonb_build_object(
      'transfer_history_id', NEW.id,
      'listing_type', v_listing_type,
      'player_age', v_age,
      'player_rating', v_rating,
      'channel', 'news'
    )
  );

  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_gpsl_discord_feed_transfer ON public."Transfer_History";
CREATE TRIGGER trg_gpsl_discord_feed_transfer
  AFTER INSERT ON public."Transfer_History"
  FOR EACH ROW
  EXECUTE FUNCTION public.gpsl_discord_feed_on_transfer();

-- ---------------------------------------------------------------------------
-- #gpsl-deals daily digest (all completed deals, batched)
-- ---------------------------------------------------------------------------

ALTER TABLE public."Transfer_History"
  ADD COLUMN IF NOT EXISTS discord_deals_digested_at timestamptz;

COMMENT ON COLUMN public."Transfer_History".discord_deals_digested_at IS
  'When this transfer was included in a Discord #gpsl-deals daily digest.';

-- Do not re-post the whole history on first digest run
UPDATE public."Transfer_History"
SET discord_deals_digested_at = coalesce(discord_deals_digested_at, now())
WHERE discord_deals_digested_at IS NULL;

CREATE OR REPLACE FUNCTION public.gpsl_discord_feed_enqueue_deals(
  p_event_type text,
  p_headline text,
  p_body text DEFAULT NULL,
  p_color integer DEFAULT 42641, -- green
  p_dedupe_key text DEFAULT NULL,
  p_metadata jsonb DEFAULT '{}'::jsonb
)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  RETURN public.gpsl_discord_feed_enqueue(
    coalesce(nullif(btrim(p_event_type), ''), 'deals_digest'),
    p_headline,
    p_body,
    p_color,
    p_dedupe_key,
    coalesce(p_metadata, '{}'::jsonb) || jsonb_build_object('channel', 'deals')
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.gpsl_discord_feed_enqueue_deals(text, text, text, integer, text, jsonb)
  TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.gpsl_discord_deals_digest_tick(
  p_max_posts int DEFAULT 5
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_max int := greatest(1, least(coalesce(p_max_posts, 5), 10));
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
BEGIN
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
      v_dedupe := format('deals_digest:%s:part:%s', v_day, v_part);
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
          'deal_count', v_chunk_n
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
    v_dedupe := format('deals_digest:%s:part:%s', v_day, v_part);
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
        'deal_count', v_chunk_n
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
    'day', v_day
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_discord_deals_digest_now(
  p_max_posts int DEFAULT 5
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
  RETURN public.gpsl_discord_deals_digest_tick(p_max_posts);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.gpsl_discord_deals_digest_tick(int)
  TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.admin_discord_deals_digest_now(int)
  TO authenticated, service_role;

-- Daily cron 21:00 UTC (~9pm UK winter / 10pm BST)
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
      $$SELECT public.gpsl_discord_deals_digest_tick(5);$$
    );
  END IF;
EXCEPTION WHEN OTHERS THEN
  RAISE NOTICE 'pg_cron deals digest schedule skipped: %', SQLERRM;
END;
$cron$;

NOTIFY pgrst, 'reload schema';

-- =============================================================================
-- Manual now:
--   SELECT public.admin_discord_deals_digest_now();
-- Then Push queue / wait for auto-flush.
-- =============================================================================
