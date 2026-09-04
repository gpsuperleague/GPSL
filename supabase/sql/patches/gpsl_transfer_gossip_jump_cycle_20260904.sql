-- =============================================================================
-- Discord gossip jumps ticker + resets 30-minute news cycle
--
-- On ingest of valid Discord transfer gossip:
--   - Rumour lives 30 minutes (not UK day-end)
--   - Active idle fillers are cleared so gossip can take a slot
--   - Ticker cycle clock resets (deal rotation starts a fresh 30-min window)
--
-- Feed order: Discord gossip first → notable day deals (rotated) → idle fillers
-- Safe re-run.
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.gpsl_transfer_ticker_cycle (
  id int PRIMARY KEY DEFAULT 1 CHECK (id = 1),
  cycle_started_at timestamptz NOT NULL DEFAULT now(),
  reset_reason text,
  updated_at timestamptz NOT NULL DEFAULT now()
);

INSERT INTO public.gpsl_transfer_ticker_cycle (id, cycle_started_at, reset_reason)
VALUES (1, now(), 'init')
ON CONFLICT (id) DO NOTHING;

ALTER TABLE public.gpsl_transfer_ticker_cycle ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS gpsl_transfer_ticker_cycle_admin
  ON public.gpsl_transfer_ticker_cycle;
CREATE POLICY gpsl_transfer_ticker_cycle_admin
  ON public.gpsl_transfer_ticker_cycle
  FOR ALL TO authenticated
  USING (public.is_gpsl_admin())
  WITH CHECK (public.is_gpsl_admin());

GRANT SELECT ON public.gpsl_transfer_ticker_cycle TO authenticated;
GRANT ALL ON public.gpsl_transfer_ticker_cycle TO service_role;

CREATE OR REPLACE FUNCTION public.gpsl_transfer_ticker_reset_cycle(
  p_reason text DEFAULT 'manual'
)
RETURNS timestamptz
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_at timestamptz := now();
BEGIN
  INSERT INTO public.gpsl_transfer_ticker_cycle (id, cycle_started_at, reset_reason, updated_at)
  VALUES (1, v_at, nullif(btrim(coalesce(p_reason, '')), ''), v_at)
  ON CONFLICT (id) DO UPDATE
  SET cycle_started_at = excluded.cycle_started_at,
      reset_reason = excluded.reset_reason,
      updated_at = excluded.updated_at;

  RETURN v_at;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.gpsl_transfer_ticker_reset_cycle(text)
  TO service_role, authenticated;

-- Shorten any still-active day-long Discord rumours to one fresh 30-min window
UPDATE public.gpsl_transfer_rumours
SET expires_at = now() + interval '30 minutes'
WHERE source = 'discord'
  AND expires_at > now()
  AND expires_at > now() + interval '30 minutes';

CREATE OR REPLACE FUNCTION public.gpsl_transfer_gossip_ingest_post(
  p_discord_message_id text,
  p_discord_user_id text,
  p_content text,
  p_posted_at timestamptz DEFAULT now()
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_msg text := nullif(btrim(coalesce(p_discord_message_id, '')), '');
  v_raw text := btrim(coalesce(p_content, ''));
  v_club_text text;
  v_player_text text;
  v_m text[];
  v_club jsonb;
  v_player jsonb;
  v_season_id bigint;
  v_headline text;
  v_id bigint;
  v_month text;
  v_angle text;
  v_at timestamptz := coalesce(p_posted_at, now());
  v_expires timestamptz := v_at + interval '30 minutes';
BEGIN
  IF coalesce(auth.role(), '') <> 'service_role' AND NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Not allowed';
  END IF;

  IF v_msg IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'status', 'ignored', 'reason', 'Missing message id');
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.gpsl_transfer_rumours r WHERE r.discord_message_id = v_msg
  ) THEN
    RETURN jsonb_build_object('ok', true, 'status', 'duplicate', 'reason', 'Already ingested');
  END IF;

  v_raw := regexp_replace(v_raw, E'[\\u2013\\u2014\\u2212]', '-', 'g');
  v_raw := regexp_replace(v_raw, E'[\\u200B-\\u200D\\uFEFF]', '', 'g');
  v_raw := split_part(v_raw, E'\n', 1);
  v_raw := regexp_replace(v_raw, '<@!?[0-9]+>', '', 'g');
  v_raw := regexp_replace(v_raw, '<@&[0-9]+>', '', 'g');
  v_raw := regexp_replace(v_raw, '@[A-Za-z0-9_./-]+', '', 'g');
  v_raw := regexp_replace(v_raw, '\s+', ' ', 'g');
  v_raw := btrim(v_raw);

  v_m := regexp_match(v_raw, '^(.+?)\s+is\s+interested\s+in\s+(.+)$', 'i');
  IF v_m IS NOT NULL THEN
    v_angle := 'player_to_club';
    v_player_text := btrim(v_m[1]);
    v_club_text := btrim(v_m[2]);
  ELSE
    v_m := regexp_match(v_raw, '^(.+?)\s+are\s+interested\s+in\s+(.+)$', 'i');
    IF v_m IS NULL THEN
      RETURN jsonb_build_object(
        'ok', false,
        'status', 'ignored',
        'reason', 'Bad format — use: Club are interested in Player  OR  Player is interested in Club'
      );
    END IF;
    v_angle := 'club_to_player';
    v_club_text := btrim(v_m[1]);
    v_player_text := btrim(v_m[2]);
  END IF;

  v_club := public.gpsl_rumour_resolve_club(v_club_text);
  IF v_club IS NULL THEN
    RETURN jsonb_build_object(
      'ok', false,
      'status', 'ignored',
      'reason', format('Unknown club "%s"', v_club_text)
    );
  END IF;

  v_player := public.gpsl_rumour_resolve_player(v_player_text);
  IF v_player IS NULL THEN
    RETURN jsonb_build_object(
      'ok', false,
      'status', 'ignored',
      'reason', format('Unknown or ambiguous player "%s"', v_player_text)
    );
  END IF;

  SELECT id INTO v_season_id
  FROM public.competition_seasons
  WHERE is_current = true
  ORDER BY id DESC
  LIMIT 1;

  IF v_season_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'status', 'ignored', 'reason', 'No current season');
  END IF;

  BEGIN
    v_month := lower(coalesce(
      public.competition_active_gpsl_month(v_season_id, v_at),
      ''
    ));
  EXCEPTION WHEN OTHERS THEN
    v_month := '';
  END;

  IF v_month IS NULL OR v_month = '' OR v_month NOT IN ('june', 'july', 'august', 'january') THEN
    RETURN jsonb_build_object(
      'ok', false,
      'status', 'ignored',
      'reason', 'Outside transfer news window (Jun/Jul/Aug/Jan)'
    );
  END IF;

  IF v_angle = 'player_to_club' THEN
    v_headline := public.gpsl_rumour_discord_headline_player(
      v_club ->> 'club_name',
      v_player ->> 'player_name'
    );
  ELSE
    v_headline := public.gpsl_rumour_discord_headline(
      v_club ->> 'club_name',
      v_player ->> 'player_name'
    );
  END IF;

  -- Clear idle fillers so gossip can jump into ticker slots immediately
  UPDATE public.gpsl_transfer_rumours r
  SET expires_at = least(r.expires_at, now())
  WHERE r.season_id = v_season_id
    AND r.source = 'idle'
    AND r.expires_at > now();

  -- Fresh 30-minute ticker cycle (deal rotation + news window)
  PERFORM public.gpsl_transfer_ticker_reset_cycle('discord_gossip');

  INSERT INTO public.gpsl_transfer_rumours (
    season_id, source, kind, angle, club_short_name, club_name,
    player_id, player_name, headline,
    discord_message_id, discord_user_id, expires_at
  )
  VALUES (
    v_season_id, 'discord', 'rumour', v_angle,
    v_club ->> 'short_name', v_club ->> 'club_name',
    v_player ->> 'player_id', v_player ->> 'player_name',
    v_headline,
    v_msg, nullif(btrim(coalesce(p_discord_user_id, '')), ''),
    v_expires
  )
  RETURNING id INTO v_id;

  RETURN jsonb_build_object(
    'ok', true,
    'status', 'rumour',
    'angle', v_angle,
    'rumour_id', v_id,
    'headline', v_headline,
    'club', v_club ->> 'short_name',
    'player', v_player ->> 'player_name',
    'expires_at', v_expires,
    'cycle_reset', true
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.gpsl_transfer_gossip_ingest_post(text, text, text, timestamptz)
  TO service_role, authenticated;

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
  v_count int := 0;
  v_force text := lower(nullif(btrim(coalesce(p_force_month, '')), ''));
  v_window_months text[] := ARRAY['june', 'july', 'august', 'january'];
  v_rumour record;
  v_pool_ids bigint[] := ARRAY[]::bigint[];
  v_pool_n int := 0;
  v_deal_slots int := 3;
  v_show int;
  v_offset int := 0;
  v_i int;
  v_pick_id bigint;
  v_has_filter boolean :=
    to_regprocedure('public.gpsl_discord_feed_transfer_passes_news_filter(text)') IS NOT NULL;
  v_discord_n int := 0;
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

  -- If the cycle window has fully elapsed with no gossip reset, roll a new one
  IF v_cycle_start <= now() - interval '30 minutes' THEN
    -- Keep advancing in 30-min steps from the last reset (stable rotation)
    v_cycle_mins := greatest(
      0,
      floor(extract(epoch FROM (now() - v_cycle_start)) / 60.0)::int
    );
  ELSE
    v_cycle_mins := greatest(
      0,
      floor(extract(epoch FROM (now() - v_cycle_start)) / 60.0)::int
    );
  END IF;

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

  -- 2) Notable UK-day deals in the current 30-min cycle rotation
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
  v_deal_slots := least(3, 5 - v_count);
  v_show := least(v_deal_slots, v_pool_n);
  IF v_pool_n > 0 AND v_show > 0 THEN
    v_offset := (v_cycle_mins / 30) % v_pool_n;
  END IF;

  FOR v_i IN 0..(v_show - 1) LOOP
    EXIT WHEN v_count >= 5;
    v_pick_id := v_pool_ids[1 + ((v_offset + v_i) % v_pool_n)];

    SELECT
      h.id, h.player_id, h.seller_club_id, h.buyer_club_id, h.fee,
      h.transfer_time, h.listing_id, h.foreign_buyer_name, h.transfer_sale_note
    INTO v_row
    FROM public."Transfer_History" h
    WHERE h.id = v_pick_id;

    IF NOT FOUND THEN
      CONTINUE;
    END IF;

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
  'Transfer ticker: Discord gossip first (30m), then UK-day notable deals on a resettable 30m cycle, then idle.';

GRANT EXECUTE ON FUNCTION public.gpsl_transfer_news_feed(text) TO authenticated;

NOTIFY pgrst, 'reload schema';
