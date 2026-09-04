-- =============================================================================
-- Discord routing updates (2026-09-04)
--
-- 1) Contract releases + out-of-contract → #gpsl-contracts (batched ~21:00 UTC)
--    (no longer live on #gpsl-news / notifications)
-- 2) Listings / transfer requests on News → same rating filter as done deals
--    (age≤21 @68+ / age≥22 @76+; draft still excluded)
-- 3) Vacant league clubs → #gpsl-job-center (league clubs only, not spare)
-- 4) Nation pick turns → #gpsl-nation-pick
-- 5) #gpsl-notifications remains the calendar feed (name mismatch only)
--
-- Secrets (Edge Functions):
--   DISCORD_CONTRACTS_WEBHOOK_URL
--   DISCORD_JOB_CENTER_WEBHOOK_URL
--   DISCORD_NATION_PICK_WEBHOOK_URL
-- Redeploy discord-sky-feed after secrets.
-- Safe re-run.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Channel enqueue helpers
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.gpsl_discord_feed_enqueue_contracts(
  p_event_type text,
  p_headline text,
  p_body text DEFAULT NULL,
  p_color integer DEFAULT 12370112,
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
    coalesce(nullif(btrim(p_event_type), ''), 'contracts'),
    p_headline,
    p_body,
    p_color,
    p_dedupe_key,
    coalesce(p_metadata, '{}'::jsonb) || jsonb_build_object('channel', 'contracts')
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.gpsl_discord_feed_enqueue_job_center(
  p_event_type text,
  p_headline text,
  p_body text DEFAULT NULL,
  p_color integer DEFAULT 10038562,
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
    coalesce(nullif(btrim(p_event_type), ''), 'job_center'),
    p_headline,
    p_body,
    p_color,
    p_dedupe_key,
    coalesce(p_metadata, '{}'::jsonb) || jsonb_build_object('channel', 'job_center')
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.gpsl_discord_feed_enqueue_nation_pick(
  p_event_type text,
  p_headline text,
  p_body text DEFAULT NULL,
  p_color integer DEFAULT 5793266,
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
    coalesce(nullif(btrim(p_event_type), ''), 'nation_pick'),
    p_headline,
    p_body,
    p_color,
    p_dedupe_key,
    coalesce(p_metadata, '{}'::jsonb) || jsonb_build_object('channel', 'nation_pick')
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.gpsl_discord_feed_enqueue_contracts(text, text, text, integer, text, jsonb)
  TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.gpsl_discord_feed_enqueue_job_center(text, text, text, integer, text, jsonb)
  TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.gpsl_discord_feed_enqueue_nation_pick(text, text, text, integer, text, jsonb)
  TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Transfer trigger: no live contract-release → news; deals filter unchanged
-- ---------------------------------------------------------------------------

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

  -- Contract releases → #gpsl-contracts daily digest (not live news)
  IF v_note = 'voluntary_contract_release' THEN
    RETURN NEW;
  END IF;

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
-- Listings / transfer requests → news only if rating filter passes
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.gpsl_discord_feed_on_listing()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_name text;
  v_club text;
  v_club_full text;
  v_price text;
  v_headline text;
  v_body text;
  v_ask numeric;
  v_source text;
  v_tier text;
  v_age text;
  v_rating text;
  v_was_pending boolean := false;
BEGIN
  IF TG_OP = 'UPDATE' THEN
    v_was_pending := (
      lower(coalesce(OLD.status::text, '')) = 'pending window'
      AND lower(coalesce(NEW.status::text, '')) = 'active'
    );
    IF NOT v_was_pending THEN
      RETURN NEW;
    END IF;
  ELSIF TG_OP = 'INSERT' THEN
    IF lower(coalesce(NEW.status::text, '')) IS DISTINCT FROM 'active' THEN
      RETURN NEW;
    END IF;
  ELSE
    RETURN NEW;
  END IF;

  IF lower(coalesce(NEW.listing_type::text, '')) = 'draft' THEN
    RETURN NEW;
  END IF;

  -- Same News filter as completed market transfers
  IF NOT public.gpsl_discord_feed_transfer_passes_news_filter(NEW.player_id::text) THEN
    RETURN NEW;
  END IF;

  SELECT
    p."Name",
    nullif(btrim(p."Age"::text), ''),
    nullif(btrim(p."Rating"::text), '')
  INTO v_name, v_age, v_rating
  FROM public."Players" p
  WHERE p."Konami_ID"::text = NEW.player_id::text
  LIMIT 1;

  v_name := coalesce(nullif(btrim(v_name), ''), 'Player ' || NEW.player_id::text);
  v_club := coalesce(nullif(btrim(NEW.seller_club_id), ''), 'Unknown');

  BEGIN
    v_club_full := public.gpsl_discord_feed_club_name(v_club);
  EXCEPTION WHEN OTHERS THEN
    v_club_full := v_club;
  END;

  v_ask := coalesce(NEW.reserve_price, NEW.market_value, 0);

  BEGIN
    v_price := public.transfer_format_money(v_ask);
  EXCEPTION WHEN OTHERS THEN
    v_price := v_ask::text;
  END;

  v_source := lower(coalesce(NEW.special_rules ->> 'source', ''));
  v_tier := lower(coalesce(NEW.special_rules ->> 'tier', ''));

  IF v_source = 'underperformance' THEN
    v_headline := format('🚪 TRANSFER REQUEST — %s', v_name);
    v_body := format(
      E'%s has handed in a transfer request at %s.\nListed at market value: %s\n%s · Age %s · Rating %s\nPerpetual listing until sold.',
      v_name,
      v_club_full,
      v_price,
      CASE v_tier
        WHEN 'big' THEN 'Big club underperformance'
        WHEN 'medium' THEN 'Medium club underperformance'
        ELSE 'Club underperformance'
      END,
      coalesce(v_age, '?'),
      coalesce(v_rating, '?')
    );

    PERFORM public.gpsl_discord_feed_enqueue(
      'transfer_request',
      v_headline,
      v_body,
      15105570,
      'transfer_request:' || NEW.id::text,
      jsonb_build_object(
        'listing_id', NEW.id,
        'player_id', NEW.player_id,
        'club', v_club,
        'source', 'underperformance',
        'tier', v_tier,
        'channel', 'news'
      )
    );

    RETURN NEW;
  END IF;

  v_headline := format('📋 LISTED — %s', v_name);
  v_body := format(
    E'Club: %s\nAsking: %s\nAge %s · Rating %s',
    v_club_full,
    v_price,
    coalesce(v_age, '?'),
    coalesce(v_rating, '?')
  );

  PERFORM public.gpsl_discord_feed_enqueue(
    'listing',
    v_headline,
    v_body,
    16763904,
    'listing:' || NEW.id::text,
    jsonb_build_object(
      'listing_id', NEW.id,
      'player_id', NEW.player_id,
      'channel', 'news'
    )
  );

  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_gpsl_discord_feed_listing ON public."Player_Transfer_Listings";
DROP TRIGGER IF EXISTS trg_gpsl_discord_feed_listing_activate ON public."Player_Transfer_Listings";

CREATE TRIGGER trg_gpsl_discord_feed_listing
  AFTER INSERT ON public."Player_Transfer_Listings"
  FOR EACH ROW
  EXECUTE FUNCTION public.gpsl_discord_feed_on_listing();

CREATE TRIGGER trg_gpsl_discord_feed_listing_activate
  AFTER UPDATE OF status ON public."Player_Transfer_Listings"
  FOR EACH ROW
  EXECUTE FUNCTION public.gpsl_discord_feed_on_listing();

-- ---------------------------------------------------------------------------
-- Contracts digest (releases + OOC note can also enqueue here)
-- ---------------------------------------------------------------------------

ALTER TABLE public."Transfer_History"
  ADD COLUMN IF NOT EXISTS discord_contracts_digested_at timestamptz;

COMMENT ON COLUMN public."Transfer_History".discord_contracts_digested_at IS
  'When this voluntary contract release was included in #gpsl-contracts digest.';

UPDATE public."Transfer_History"
SET discord_contracts_digested_at = coalesce(discord_contracts_digested_at, now())
WHERE discord_contracts_digested_at IS NULL
  AND lower(coalesce(btrim(transfer_sale_note), '')) = 'voluntary_contract_release';

CREATE OR REPLACE FUNCTION public.gpsl_discord_contracts_digest_tick(
  p_max_posts int DEFAULT 3,
  p_lookback_hours int DEFAULT 0
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_max int := greatest(1, least(coalesce(p_max_posts, 3), 8));
  v_lookback int := greatest(0, least(coalesce(p_lookback_hours, 0), 168));
  v_day text := to_char((now() AT TIME ZONE 'Europe/London')::date, 'YYYY-MM-DD');
  v_day_label text := to_char((now() AT TIME ZONE 'Europe/London')::date, 'Dy DD Mon YYYY');
  v_row record;
  v_chunk text := '';
  v_chunk_n int := 0;
  v_chunk_ids bigint[] := ARRAY[]::bigint[];
  v_marked_ids bigint[] := ARRAY[]::bigint[];
  v_name text;
  v_seller text;
  v_line text;
  v_posted int := 0;
  v_qid bigint;
  v_part int := 0;
  v_dedupe text;
  v_reopened int := 0;
  v_stamp text := floor(extract(epoch from now()))::bigint::text;
BEGIN
  IF v_lookback > 0 THEN
    UPDATE public."Transfer_History" h
    SET discord_contracts_digested_at = NULL
    WHERE h.discord_contracts_digested_at IS NOT NULL
      AND lower(coalesce(btrim(h.transfer_sale_note), '')) = 'voluntary_contract_release'
      AND h.transfer_time >= now() - (v_lookback || ' hours')::interval;
    GET DIAGNOSTICS v_reopened = ROW_COUNT;
  END IF;

  FOR v_row IN
    SELECT h.id, h.player_id, h.seller_club_id, h.transfer_time
    FROM public."Transfer_History" h
    WHERE h.discord_contracts_digested_at IS NULL
      AND lower(coalesce(btrim(h.transfer_sale_note), '')) = 'voluntary_contract_release'
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
      v_seller := coalesce(v_row.seller_club_id, '—');
    END;

    v_line := format('• **%s** left **%s** (contract release)', v_name, v_seller);

    IF length(v_chunk) + length(v_line) + 1 > 3500 AND v_chunk <> '' THEN
      v_part := v_part + 1;
      v_dedupe := format(
        'contracts_digest:%s:part:%s%s',
        v_day, v_part,
        CASE WHEN v_lookback > 0 THEN ':lb' || v_lookback || ':' || v_stamp ELSE '' END
      );
      v_qid := public.gpsl_discord_feed_enqueue_contracts(
        'contracts_digest',
        CASE WHEN v_part = 1 THEN format('📋 CONTRACT RELEASES — %s', v_day_label)
             ELSE format('📋 CONTRACT RELEASES — %s (%s)', v_day_label, v_part) END,
        v_chunk,
        12370112,
        v_dedupe,
        jsonb_build_object('digest', true, 'kind', 'contract_releases', 'deal_count', v_chunk_n)
      );
      IF v_qid IS NOT NULL THEN
        v_posted := v_posted + 1;
        v_marked_ids := v_marked_ids || v_chunk_ids;
      END IF;
      v_chunk := '';
      v_chunk_n := 0;
      v_chunk_ids := ARRAY[]::bigint[];
      IF v_posted >= v_max THEN EXIT; END IF;
    END IF;

    IF v_chunk = '' THEN v_chunk := v_line; ELSE v_chunk := v_chunk || E'\n' || v_line; END IF;
    v_chunk_n := v_chunk_n + 1;
    v_chunk_ids := array_append(v_chunk_ids, v_row.id);
  END LOOP;

  IF v_chunk <> '' AND v_posted < v_max THEN
    v_part := v_part + 1;
    v_dedupe := format(
      'contracts_digest:%s:part:%s%s',
      v_day, v_part,
      CASE WHEN v_lookback > 0 THEN ':lb' || v_lookback || ':' || v_stamp ELSE '' END
    );
    v_qid := public.gpsl_discord_feed_enqueue_contracts(
      'contracts_digest',
      CASE WHEN v_part = 1 THEN format('📋 CONTRACT RELEASES — %s', v_day_label)
           ELSE format('📋 CONTRACT RELEASES — %s (%s)', v_day_label, v_part) END,
      v_chunk,
      12370112,
      v_dedupe,
      jsonb_build_object('digest', true, 'kind', 'contract_releases', 'deal_count', v_chunk_n)
    );
    IF v_qid IS NOT NULL THEN
      v_posted := v_posted + 1;
      v_marked_ids := v_marked_ids || v_chunk_ids;
    END IF;
  END IF;

  IF coalesce(array_length(v_marked_ids, 1), 0) > 0 THEN
    UPDATE public."Transfer_History" h
    SET discord_contracts_digested_at = now()
    WHERE h.id = ANY (v_marked_ids)
      AND h.discord_contracts_digested_at IS NULL;
  END IF;

  BEGIN
    PERFORM public.gpsl_discord_feed_request_flush();
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;

  RETURN jsonb_build_object(
    'ok', true,
    'posts_queued', v_posted,
    'releases_marked', coalesce(array_length(v_marked_ids, 1), 0),
    'reopened', v_reopened,
    'lookback_hours', v_lookback
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_discord_contracts_digest_now(
  p_max_posts int DEFAULT 3,
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
  RETURN public.gpsl_discord_contracts_digest_tick(p_max_posts, coalesce(p_lookback_hours, 48));
END;
$function$;

GRANT EXECUTE ON FUNCTION public.gpsl_discord_contracts_digest_tick(int, int)
  TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.admin_discord_contracts_digest_now(int, int)
  TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Nation pick → own channel
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.owner_inbox_notify_nation_pick_turn(p_pick_rank smallint)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club record;
  v_tag text;
  v_mention text;
  v_club_name text;
  v_total int;
BEGIN
  SELECT count(*)::int INTO v_total
  FROM public.international_owner_draft_order();

  FOR v_club IN
    SELECT d.club_short_name, d.pick_order
    FROM public.international_owner_draft_order() d
    WHERE d.pick_order = p_pick_rank
  LOOP
    PERFORM public.owner_inbox_send(
      'nation_pick_turn',
      'Your turn — pick a nation',
      format(
        E'Nation selection: you are pick #%s of %s.\nChoose your national team on the Nation selection page.',
        p_pick_rank,
        v_total
      ),
      v_club.club_short_name,
      NULL,
      NULL, NULL, NULL, NULL,
      'nation_select.html',
      'nation_pick:' || p_pick_rank::text || ':' || v_club.club_short_name,
      NULL, NULL
    );

    BEGIN
      v_tag := public.gpsl_discord_notifications_owner_tag(v_club.club_short_name);
    EXCEPTION WHEN OTHERS THEN
      v_tag := NULL;
    END;
    v_mention := CASE WHEN v_tag IS NOT NULL THEN '@' || ltrim(v_tag, '@') ELSE NULL END;
    SELECT coalesce(c."Club", v_club.club_short_name) INTO v_club_name
    FROM public."Clubs" c
    WHERE c."ShortName" = v_club.club_short_name;

    PERFORM public.gpsl_discord_feed_enqueue_nation_pick(
      'nation_pick',
      format('🌍 NATION SELECTION — pick #%s', p_pick_rank),
      concat_ws(
        E'\n',
        format('%s is on the clock.', coalesce(v_club_name, v_club.club_short_name)),
        CASE WHEN v_mention IS NOT NULL THEN format('Your turn %s — choose a nation.', v_mention) END,
        format('Pick %s of %s.', p_pick_rank, coalesce(v_total, 0))
      ),
      5793266,
      'nation_pick_turn:' || p_pick_rank::text || ':' || v_club.club_short_name,
      jsonb_build_object(
        'kind', 'nation_pick_turn',
        'club_short_name', v_club.club_short_name,
        'pick_rank', p_pick_rank,
        'owner_tag', v_tag,
        'mention', v_mention,
        'ping', true
      )
    );
  END LOOP;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.owner_inbox_notify_nation_pick_turn(smallint)
  TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Notifications tick: vacant → job center (league only); OOC → contracts
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.gpsl_discord_notifications_tick()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_state public.gpsl_discord_notifications_state%rowtype;
  v_month text;
  v_prev_month text;
  v_month_label text;
  v_season_id bigint;
  v_key text;
  v_count int;
  v_cup int;
  v_intl int;
  v_names text;
  v_lines text;
  v_done text[] := ARRAY[]::text[];
  v_gs public.global_settings%rowtype;
  r record;
BEGIN
  SELECT * INTO v_state FROM public.gpsl_discord_notifications_state WHERE id = 1;
  IF NOT FOUND THEN
    INSERT INTO public.gpsl_discord_notifications_state (id) VALUES (1);
    SELECT * INTO v_state FROM public.gpsl_discord_notifications_state WHERE id = 1;
  END IF;

  v_prev_month := v_state.last_gpsl_month;

  SELECT id INTO v_season_id
  FROM public.competition_seasons
  WHERE is_current = true
  ORDER BY id DESC
  LIMIT 1;

  BEGIN
    IF to_regprocedure('public.competition_active_gpsl_month()') IS NOT NULL THEN
      v_month := public.competition_active_gpsl_month();
    END IF;
  EXCEPTION WHEN OTHERS THEN
    v_month := NULL;
  END;

  IF v_season_id IS NOT NULL
     AND v_month IS NOT NULL
     AND v_prev_month IS NOT NULL
     AND lower(v_month) IS DISTINCT FROM lower(v_prev_month)
     AND to_regclass('public.competition_challenge_config') IS NOT NULL THEN
    FOR r IN
      SELECT c.id, c.title, c.window_phase, c.gpsl_month_to
      FROM public.competition_challenge_config c
      WHERE c.season_id = v_season_id
        AND lower(c.gpsl_month_to) = lower(v_prev_month)
    LOOP
      PERFORM public.gpsl_discord_feed_enqueue_notification(
        'notification',
        format('🎯 CHALLENGES CLOSING — %s', initcap(coalesce(r.window_phase, 'window'))),
        format('%s has closed with the end of %s.', coalesce(r.title, 'Season challenges'), initcap(r.gpsl_month_to)),
        10038562,
        'chal_close:' || r.id::text || ':' || r.gpsl_month_to,
        jsonb_build_object('kind', 'challenge_close', 'challenge_id', r.id)
      );
      v_done := v_done || ARRAY['challenge_close'];
    END LOOP;
  END IF;

  IF v_month IS NOT NULL AND v_month IS DISTINCT FROM v_prev_month THEN
    BEGIN
      v_month_label := public.competition_gpsl_month_label(v_month);
    EXCEPTION WHEN OTHERS THEN
      v_month_label := initcap(v_month);
    END;

    PERFORM public.gpsl_discord_feed_enqueue_notification(
      'notification',
      format('📅 GPSL MONTH — %s', v_month_label),
      format('We are now in %s. Fixtures, challenges, and calendars have moved on.', v_month_label),
      5793266,
      'gpsl_month:' || coalesce(v_season_id::text, 'x') || ':' || v_month,
      jsonb_build_object('kind', 'gpsl_month', 'gpsl_month', v_month)
    );
    UPDATE public.gpsl_discord_notifications_state
    SET last_gpsl_month = v_month, updated_at = now()
    WHERE id = 1;
    v_done := v_done || ARRAY['gpsl_month'];
  END IF;

  SELECT * INTO v_gs FROM public.global_settings LIMIT 1;
  IF FOUND
     AND v_gs.draft_auction_start_time IS NOT NULL
     AND now() >= v_gs.draft_auction_start_time
     AND (
       coalesce(v_gs.draft_auction_enabled, false)
       OR coalesce(v_gs.manager_draft_auction_enabled, false)
     ) THEN
    v_key := 'draft_open:' || to_char(v_gs.draft_auction_start_time AT TIME ZONE 'UTC', 'YYYYMMDDHH24MI');
    IF v_state.last_draft_open_key IS DISTINCT FROM v_key THEN
      PERFORM public.gpsl_discord_feed_enqueue_notification(
        'draft',
        '🧾 DRAFT AUCTION LIVE',
        concat_ws(
          E'\n',
          CASE WHEN coalesce(v_gs.draft_auction_enabled, false) THEN 'Player draft bidding is open.' END,
          CASE WHEN coalesce(v_gs.manager_draft_auction_enabled, false) THEN 'Manager draft bidding is open.' END
        ),
        8070335,
        v_key,
        jsonb_build_object('kind', 'draft_open')
      );
      UPDATE public.gpsl_discord_notifications_state
      SET last_draft_open_key = v_key, updated_at = now()
      WHERE id = 1;
      v_done := v_done || ARRAY['draft_open'];
    END IF;
  END IF;

  IF v_season_id IS NOT NULL AND v_month IS NOT NULL
     AND to_regclass('public.competition_challenge_config') IS NOT NULL THEN
    FOR r IN
      SELECT c.id, c.title, c.window_phase, c.gpsl_month_from
      FROM public.competition_challenge_config c
      WHERE c.season_id = v_season_id
        AND lower(c.gpsl_month_from) = lower(v_month)
    LOOP
      PERFORM public.gpsl_discord_feed_enqueue_notification(
        'notification',
        format('🎯 CHALLENGES STARTING — %s', initcap(coalesce(r.window_phase, 'window'))),
        format('%s is now open for %s.', coalesce(r.title, 'Season challenges'), initcap(v_month)),
        15844367,
        'chal_start:' || r.id::text || ':' || v_month,
        jsonb_build_object('kind', 'challenge_start', 'challenge_id', r.id)
      );
      v_done := v_done || ARRAY['challenge_start'];
    END LOOP;
  END IF;

  IF v_season_id IS NOT NULL AND v_month IS NOT NULL
     AND to_regclass('public.international_fixtures') IS NOT NULL THEN
    BEGIN
      SELECT count(*)::int INTO v_count
      FROM public.international_fixtures f
      WHERE lower(f.gpsl_month) = lower(v_month)
        AND coalesce(f.played, false) = false
        AND coalesce(f.status, '') IS DISTINCT FROM 'played';
    EXCEPTION WHEN OTHERS THEN
      v_count := 0;
    END;

    IF coalesce(v_count, 0) > 0 THEN
      v_key := 'intl:' || v_season_id::text || ':' || v_month;
      IF v_state.last_intl_week_key IS DISTINCT FROM v_key THEN
        PERFORM public.gpsl_discord_feed_enqueue_notification(
          'notification',
          format('🌐 INTERNATIONAL / WORLD CUP — %s', initcap(v_month)),
          format(
            E'%s international fixture(s) this GPSL month (qualifiers / finals).\nArrange kick-offs and submit results on International Matchday.',
            v_count
          ),
          5793266,
          v_key,
          jsonb_build_object('kind', 'international_week', 'count', v_count)
        );
        UPDATE public.gpsl_discord_notifications_state
        SET last_intl_week_key = v_key, updated_at = now()
        WHERE id = 1;
        v_done := v_done || ARRAY['international_week'];
      END IF;
    END IF;
  END IF;

  IF v_season_id IS NOT NULL AND v_month IS NOT NULL THEN
    v_key := 'matches:' || v_season_id::text || ':' || v_month || ':' ||
             to_char(now() AT TIME ZONE 'Europe/London', 'IYYY-IW');

    IF v_state.last_match_reminder_key IS DISTINCT FROM v_key THEN
      SELECT count(*)::int INTO v_count
      FROM public.competition_fixtures f
      WHERE f.season_id = v_season_id
        AND lower(f.gpsl_month) = lower(v_month)
        AND f.status = 'scheduled'
        AND f.competition_type = 'league';

      SELECT count(*)::int INTO v_cup
      FROM public.competition_fixtures f
      WHERE f.season_id = v_season_id
        AND lower(f.gpsl_month) = lower(v_month)
        AND f.status = 'scheduled'
        AND f.competition_type = 'cup';

      v_intl := 0;
      IF to_regclass('public.international_fixtures') IS NOT NULL THEN
        BEGIN
          SELECT count(*)::int INTO v_intl
          FROM public.international_fixtures f
          WHERE lower(f.gpsl_month) = lower(v_month)
            AND coalesce(f.played, false) = false
            AND coalesce(f.status, '') IS DISTINCT FROM 'played';
        EXCEPTION WHEN OTHERS THEN
          v_intl := 0;
        END;
      END IF;

      IF coalesce(v_count, 0) > 0 OR coalesce(v_cup, 0) > 0 OR coalesce(v_intl, 0) > 0 THEN
        PERFORM public.gpsl_discord_feed_enqueue_notification(
          'notification',
          format('⚽ MATCHES DUE — %s', initcap(v_month)),
          format(
            E'Weekly reminder for outstanding fixtures this GPSL month:\nLeague: %s scheduled\nCup: %s scheduled\nWorld Cup / international: %s outstanding\nPlease arrange kick-offs and submit results.',
            coalesce(v_count, 0),
            coalesce(v_cup, 0),
            coalesce(v_intl, 0)
          ),
          15158332,
          v_key,
          jsonb_build_object(
            'kind', 'match_reminder',
            'league_scheduled', coalesce(v_count, 0),
            'cup_scheduled', coalesce(v_cup, 0),
            'intl_outstanding', coalesce(v_intl, 0)
          )
        );
        UPDATE public.gpsl_discord_notifications_state
        SET last_match_reminder_key = v_key, updated_at = now()
        WHERE id = 1;
        v_done := v_done || ARRAY['match_reminder'];
      END IF;
    END IF;
  END IF;

  -- Job center: vacant LEAGUE clubs only (in competition_club_seasons)
  v_key := 'job_center:' || to_char(now() AT TIME ZONE 'Europe/London', 'YYYY-MM-DD');
  IF v_state.last_vacant_key IS DISTINCT FROM v_key THEN
    v_count := 0;
    v_lines := '';
    IF v_season_id IS NOT NULL AND to_regclass('public.competition_club_seasons') IS NOT NULL THEN
      SELECT count(*)::int,
             string_agg(
               format(
                 '• %s (%s)',
                 coalesce(nullif(btrim(c."Club"), ''), c."ShortName"),
                 CASE lower(ccs.division)
                   WHEN 'superleague' THEN 'Super League'
                   WHEN 'championship_a' THEN 'Championship A'
                   WHEN 'championship_b' THEN 'Championship B'
                   ELSE coalesce(ccs.division, 'League')
                 END
               ),
               E'\n'
               ORDER BY
                 CASE lower(ccs.division)
                   WHEN 'superleague' THEN 1
                   WHEN 'championship_a' THEN 2
                   WHEN 'championship_b' THEN 3
                   ELSE 9
                 END,
                 c."Club"
             )
      INTO v_count, v_lines
      FROM public.competition_club_seasons ccs
      JOIN public."Clubs" c ON c."ShortName" = ccs.club_short_name
      WHERE ccs.season_id = v_season_id
        AND c.owner_id IS NULL
        AND c."ShortName" IS DISTINCT FROM 'FOREIGN';
    END IF;

    IF coalesce(v_count, 0) > 0 THEN
      PERFORM public.gpsl_discord_feed_enqueue_job_center(
        'job_center',
        format('🏚️ JOB CENTER — %s vacant league club(s)', v_count),
        left(coalesce(v_lines, 'Vacant league clubs.'), 3800),
        10038562,
        v_key,
        jsonb_build_object('kind', 'job_center', 'count', v_count, 'season_id', v_season_id)
      );
      UPDATE public.gpsl_discord_notifications_state
      SET last_vacant_key = v_key, updated_at = now()
      WHERE id = 1;
      v_done := v_done || ARRAY['job_center'];
    ELSE
      -- Still advance key so we don't re-check constantly when none vacant
      UPDATE public.gpsl_discord_notifications_state
      SET last_vacant_key = v_key, updated_at = now()
      WHERE id = 1;
    END IF;
  END IF;

  -- Out of contract → #gpsl-contracts
  v_key := 'ooc:' || coalesce(v_season_id::text, 'x') || ':' || coalesce(v_month, 'x');
  IF v_state.last_ooc_key IS DISTINCT FROM v_key THEN
    v_count := NULL;
    BEGIN
      SELECT count(*)::int INTO v_count
      FROM public."Players" p
      WHERE p.contract_seasons_remaining = 0
        AND nullif(btrim(p."Club"::text), '') IS NOT NULL
        AND p."Club"::text IS DISTINCT FROM 'FOREIGN';
    EXCEPTION WHEN undefined_column THEN
      BEGIN
        SELECT count(*)::int INTO v_count
        FROM public."Players" p
        WHERE nullif(btrim(p."Contract"::text), '') IN ('0', '0.0')
          AND nullif(btrim(p."Club"::text), '') IS NOT NULL;
      EXCEPTION WHEN OTHERS THEN
        v_count := NULL;
      END;
    WHEN OTHERS THEN
      v_count := NULL;
    END;

    IF coalesce(v_count, 0) > 0 THEN
      PERFORM public.gpsl_discord_feed_enqueue_contracts(
        'contracts',
        format('📋 OUT OF CONTRACT — %s players', v_count),
        format(
          '%s player(s) are out of contract (batch notice). Check contracts / free agents — not listed individually here.',
          v_count
        ),
        12370112,
        v_key,
        jsonb_build_object('kind', 'out_of_contract_batch', 'count', v_count)
      );
      UPDATE public.gpsl_discord_notifications_state
      SET last_ooc_key = v_key, updated_at = now()
      WHERE id = 1;
      v_done := v_done || ARRAY['out_of_contract'];
    END IF;
  END IF;

  -- Also run contracts release digest (same evening window if cron co-fires)
  BEGIN
    PERFORM public.gpsl_discord_contracts_digest_tick(3, 0);
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;

  BEGIN
    PERFORM public.gpsl_discord_feed_request_flush();
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;

  RETURN jsonb_build_object(
    'ok', true,
    'announced', to_jsonb(v_done),
    'gpsl_month', v_month,
    'season_id', v_season_id
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.gpsl_discord_notifications_tick()
  TO authenticated, service_role;

-- Cron for contracts digest at 21:00 UTC (with deals)
DO $cron$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    BEGIN
      PERFORM cron.unschedule('gpsl-discord-contracts-digest');
    EXCEPTION WHEN OTHERS THEN
      NULL;
    END;
    PERFORM cron.schedule(
      'gpsl-discord-contracts-digest',
      '0 21 * * *',
      $$SELECT public.gpsl_discord_contracts_digest_tick(3, 0);$$
    );
  END IF;
EXCEPTION WHEN OTHERS THEN
  RAISE NOTICE 'pg_cron contracts digest schedule skipped: %', SQLERRM;
END;
$cron$;

NOTIFY pgrst, 'reload schema';
