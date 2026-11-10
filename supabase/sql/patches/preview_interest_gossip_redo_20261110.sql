-- =============================================================================
-- Retrospective transfer gossip, in order
--
-- 1. Every current listing (preview and live), orange, headed LISTED
-- 2. Then every Show interest still on a preview listing, blue, headed INTEREST
--
-- A listing keeps the card, season detail, and a transfer-market link.
-- Interest is only who showed it, the selling club, and the asking price.
-- The interest line stays "Club are interested in Player" so the ticker can read it.
-- Run once. A second run posts them all again.
-- Needs the listing gossip functions (listing_gossip_card_20261110.sql).
-- =============================================================================

CREATE OR REPLACE FUNCTION public.gpsl_gossip_style_listing(p_item jsonb)
RETURNS jsonb
LANGUAGE sql
IMMUTABLE
AS $function$
  SELECT CASE
    WHEN p_item IS NULL THEN NULL
    ELSE p_item || jsonb_build_object(
      'content', regexp_replace(
        coalesce(p_item ->> 'content', ''),
        '^(Preview|For sale|Listed)',
        'Listed'
      ),
      'embed', coalesce(p_item -> 'embed', '{}'::jsonb) || jsonb_build_object(
        'author', jsonb_build_object('name', 'Player listed'),
        'title', 'LISTED · ' || regexp_replace(
          coalesce(p_item #>> '{embed,title}', ''),
          '^(LISTED|INTEREST) · ',
          ''
        ),
        'color', 15105570,
        'url', 'https://gpsuperleague.github.io/GPSL/all_listings.html?listing='
          || coalesce(p_item ->> 'listing_id', ''),
        'fields', (
          SELECT coalesce(jsonb_agg(t.elem ORDER BY t.ord), '[]'::jsonb)
          FROM jsonb_array_elements(coalesce(p_item #> '{embed,fields}', '[]'::jsonb))
            WITH ORDINALITY AS t(elem, ord)
          WHERE t.elem ->> 'name' IS DISTINCT FROM 'Market'
        ) || jsonb_build_array(jsonb_build_object(
          'name', 'Market',
          'value', '[Open this listing](https://gpsuperleague.github.io/GPSL/all_listings.html?listing='
            || coalesce(p_item ->> 'listing_id', '') || ')',
          'inline', false
        )),
        'footer', jsonb_build_object('text', 'On the market · GPSL')
      )
    )
  END;
$function$;

CREATE OR REPLACE FUNCTION public.gpsl_preview_interest_gossip_item(
  p_listing_id bigint,
  p_club text
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := upper(btrim(coalesce(p_club, '')));
  v_club_name text;
  v_player_name text;
  v_player_id text;
  v_owner text;
  v_line text;
  v_seller text;
  v_seller_short text;
  v_ask numeric;
  v_value numeric;
  v_price text;
  v_rem int;
  v_season bigint;
  v_apps int := 0;
  v_goals int := 0;
  v_assists int := 0;
  v_avg numeric;
  v_mp int;
  v_inj int := 0;
  v_pct int;
  v_player_quote text;
  v_mgr_quote text;
  v_desc text;
BEGIN
  SELECT
    coalesce(nullif(btrim(c."Club"), ''), c."ShortName"),
    CASE
      WHEN c.owner_id IS NULL THEN 'Vacant'
      WHEN nullif(btrim(c.owner), '') IS NULL THEN 'Owned'
      ELSE '@' || regexp_replace(btrim(c.owner), '^@+', '')
    END
  INTO v_club_name, v_owner
  FROM public."Clubs" c
  WHERE c."ShortName" = v_club;

  SELECT p."Name", l.player_id::text, p.contract_seasons_remaining
  INTO v_player_name, v_player_id, v_rem
  FROM public."Player_Transfer_Listings" l
  JOIN public."Players" p ON p."Konami_ID"::text = l.player_id::text
  WHERE l.id = p_listing_id;

  v_club_name := btrim(regexp_replace(coalesce(v_club_name, v_club), '[\r\n]+', ' ', 'g'));
  v_player_name := btrim(regexp_replace(coalesce(v_player_name, ''), '[\r\n]+', ' ', 'g'));
  IF v_club_name = '' OR v_player_name = '' THEN
    RETURN NULL;
  END IF;

  v_line := v_club_name || ' are interested in ' || v_player_name;

  SELECT
    coalesce(nullif(btrim(c."Club"), ''), l.seller_club_id),
    upper(btrim(l.seller_club_id::text)),
    l.reserve_price,
    l.market_value
  INTO v_seller, v_seller_short, v_ask, v_value
  FROM public."Player_Transfer_Listings" l
  LEFT JOIN public."Clubs" c
    ON c."ShortName" = upper(btrim(l.seller_club_id::text))
  WHERE l.id = p_listing_id;

  v_price := '₿' || to_char(coalesce(v_ask, 0), 'FM999,999,999,990');

  SELECT id INTO v_season
  FROM public.competition_seasons
  WHERE is_current = true
  ORDER BY id DESC
  LIMIT 1;

  IF v_season IS NOT NULL THEN
    BEGIN
      SELECT
        count(*) FILTER (WHERE coalesce(m.appeared, false))::int,
        coalesce(sum(m.goals), 0)::int,
        coalesce(sum(m.assists), 0)::int,
        round(avg(m.rating) FILTER (
          WHERE coalesce(m.appeared, false) AND m.rating IS NOT NULL
        ), 2)
      INTO v_apps, v_goals, v_assists, v_avg
      FROM public.competition_match_player_stats m
      JOIN public.competition_fixtures f ON f.id = m.fixture_id
      WHERE m.player_id::text = v_player_id
        AND f.season_id = v_season
        AND f.status = 'played'
        AND coalesce(f.is_void, false) = false;
    EXCEPTION WHEN OTHERS THEN
      v_apps := 0;
    END;

    BEGIN
      SELECT count(*) FILTER (WHERE i.status = 'active')::int
      INTO v_inj
      FROM public.competition_player_injuries i
      WHERE i.player_id::text = v_player_id
        AND i.season_id = v_season;
    EXCEPTION WHEN OTHERS THEN
      v_inj := 0;
    END;

    BEGIN
      SELECT s.mp
      INTO v_mp
      FROM public.competition_standings_public s
      WHERE s.club_short_name = v_seller_short
      LIMIT 1;
    EXCEPTION WHEN OTHERS THEN
      v_mp := NULL;
    END;
  END IF;

  v_pct := CASE
    WHEN coalesce(v_mp, 0) > 0 THEN
      least(100, round(100.0 * coalesce(v_apps, 0) / v_mp))::int
    ELSE NULL
  END;

  v_player_quote := CASE
    WHEN coalesce(v_inj, 0) > 0 THEN
      'Let me get fit. Then I''ll know if I want to go.'
    WHEN v_rem IS NOT NULL AND v_rem <= 1 THEN
      'The deal is nearly done. I''m open to what comes next.'
    WHEN v_pct IS NOT NULL AND v_pct < 40 AND coalesce(v_mp, 0) >= 4 THEN
      'I need more minutes. A move would give me that.'
    WHEN v_avg IS NOT NULL AND v_avg >= 7.2 AND coalesce(v_apps, 0) >= 3 THEN
      'I''m enjoying it here. It would take a serious offer.'
    WHEN v_avg IS NOT NULL AND v_avg < 6.3 AND coalesce(v_apps, 0) >= 4 THEN
      'It hasn''t clicked. A new start might suit me.'
    WHEN coalesce(v_goals, 0) >= 5 THEN
      'I know the goals matter. I''m not forcing a move.'
    ELSE
      'I''ll listen. I''m not pushing for the door.'
  END;

  v_mgr_quote := CASE
    WHEN v_pct IS NOT NULL AND v_pct >= 70
         AND v_avg IS NOT NULL AND v_avg >= 7 THEN
      'He has been in the side and he has delivered. We do not need to sell.'
    WHEN v_pct IS NOT NULL AND v_pct >= 70
         AND v_avg IS NOT NULL AND v_avg < 6.5 THEN
      'He has played a lot, and it has not been his season. We would talk.'
    WHEN v_pct IS NOT NULL AND v_pct < 40 AND coalesce(v_mp, 0) >= 4 THEN
      'He has not had the run of games. A change could suit everyone.'
    WHEN coalesce(v_goals, 0) + coalesce(v_assists, 0) >= 6 THEN
      'The numbers are real. Any conversation starts with the fee.'
    WHEN coalesce(v_apps, 0) = 0 THEN
      'It is early for him here. We are still seeing what he can do.'
    ELSE
      'We know there is interest. Nothing is agreed.'
  END;

  v_desc :=
    '**' || v_club_name || '** interested in **' || v_player_name
    || '** of **' || coalesce(v_seller, '—') || '**'
    || E'\n\n**Asking fee:** ' || v_price
    || E'\n\n*Player:* "' || v_player_quote || '"'
    || E'\n*Manager, to journalists:* "' || v_mgr_quote || '"'
    || E'\n\n[Transfer market](https://gpsuperleague.github.io/GPSL/all_listings.html?listing='
    || p_listing_id || ')';

  RETURN jsonb_build_object(
    'content', v_line,
    'card_id', v_player_id,
    'card_layout', 'mini',
    'badge_club', v_club,
    'embed', jsonb_build_object(
      'author', jsonb_build_object(
        'name', coalesce(v_owner, 'Interest shown')
      ),
      'description', v_desc,
      'color', 3066993,
      'footer', jsonb_build_object('text', 'Interest shown · GPSL')
    )
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.gpsl_preview_interest_gossip_item(bigint, text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.gpsl_preview_interest_gossip_item(bigint, text)
  TO postgres, service_role;

CREATE OR REPLACE FUNCTION public.gpsl_preview_interest_post_gossip(
  p_listing_id bigint,
  p_club text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions, net
AS $function$
DECLARE
  v_item jsonb;
  v_url text;
  v_key text;
BEGIN
  IF EXISTS (
    SELECT 1
    FROM public.listing_preview_interest i
    WHERE i.listing_id = p_listing_id
      AND i.club_short_name = upper(btrim(coalesce(p_club, '')))
      AND i.gossip_posted_at IS NOT NULL
  ) THEN
    RETURN;
  END IF;

  v_item := public.gpsl_preview_interest_gossip_item(p_listing_id, p_club);
  IF v_item IS NULL THEN
    RETURN;
  END IF;

  SELECT s.edge_function_url, nullif(btrim(s.invoke_key), '')
  INTO v_url, v_key
  FROM public.gpsl_discord_transfer_gossip_settings s
  WHERE s.id = 1;

  IF v_url IS NULL OR btrim(v_url) = '' OR v_key IS NULL THEN
    RAISE WARNING 'preview interest gossip: gossip settings have no url or key';
    RETURN;
  END IF;

  PERFORM net.http_post(
    url := v_url,
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || v_key
    ),
    body := jsonb_build_object(
      'action', 'post_cards',
      'items', jsonb_build_array(v_item)
    ),
    timeout_milliseconds := 20000
  );

  UPDATE public.listing_preview_interest i
  SET gossip_posted_at = clock_timestamp()
  WHERE i.listing_id = p_listing_id
    AND i.club_short_name = upper(btrim(coalesce(p_club, '')))
    AND i.gossip_posted_at IS NULL;
EXCEPTION
  WHEN undefined_table THEN
    RAISE WARNING 'preview interest gossip: settings table missing';
  WHEN undefined_function THEN
    RAISE WARNING 'preview interest gossip: pg_net missing';
  WHEN OTHERS THEN
    RAISE WARNING 'preview interest gossip failed: %', SQLERRM;
END;
$function$;

REVOKE ALL ON FUNCTION public.gpsl_preview_interest_post_gossip(bigint, text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.gpsl_preview_interest_post_gossip(bigint, text)
  TO postgres, service_role;

CREATE OR REPLACE FUNCTION public.gpsl_listing_gossip_send(p_ids bigint[])
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions, net
AS $function$
DECLARE
  v_url text;
  v_key text;
  v_ids bigint[];
  v_items jsonb := '[]'::jsonb;
  r record;
  v_payload jsonb;
BEGIN
  IF p_ids IS NULL OR cardinality(p_ids) = 0 THEN
    RETURN 0;
  END IF;

  SELECT s.edge_function_url, nullif(btrim(s.invoke_key), '')
  INTO v_url, v_key
  FROM public.gpsl_discord_transfer_gossip_settings s
  WHERE s.id = 1;

  IF v_url IS NULL OR btrim(v_url) = '' OR v_key IS NULL THEN
    RAISE WARNING 'listing gossip: gossip settings have no url or key';
    RETURN 0;
  END IF;

  WITH claim AS (
    UPDATE public."Player_Transfer_Listings" l
    SET gossip_listed_at = clock_timestamp()
    WHERE l.id = ANY (p_ids)
      AND l.gossip_listed_at IS NULL
    RETURNING l.id
  )
  SELECT coalesce(array_agg(id), ARRAY[]::bigint[])
  INTO v_ids
  FROM claim;

  IF cardinality(v_ids) = 0 THEN
    RETURN 0;
  END IF;

  FOR r IN
    SELECT u.id
    FROM unnest(v_ids) AS u(id)
  LOOP
    v_payload := public.gpsl_gossip_style_listing(public.gpsl_listing_gossip_payload(r.id));
    IF v_payload IS NOT NULL THEN
      v_items := v_items || v_payload;
    END IF;
  END LOOP;

  IF jsonb_array_length(v_items) = 0 THEN
    RETURN 0;
  END IF;

  PERFORM net.http_post(
    url := v_url,
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || v_key
    ),
    body := jsonb_build_object(
      'action', 'post_cards',
      'items', v_items
    ),
    timeout_milliseconds := 180000
  );

  RETURN jsonb_array_length(v_items);
EXCEPTION
  WHEN undefined_table THEN
    RAISE WARNING 'listing gossip: settings table missing';
    RETURN 0;
  WHEN undefined_function THEN
    RAISE WARNING 'listing gossip: pg_net missing';
    RETURN 0;
  WHEN OTHERS THEN
    UPDATE public."Player_Transfer_Listings" l
    SET gossip_listed_at = NULL
    WHERE l.id = ANY (coalesce(v_ids, ARRAY[]::bigint[]));
    RAISE WARNING 'listing gossip failed: %', SQLERRM;
    RETURN 0;
END;
$function$;

DO $retro$
DECLARE
  r record;
  v_url text;
  v_key text;
  v_item jsonb;
  v_listings jsonb := '[]'::jsonb;
  v_interest jsonb := '[]'::jsonb;
  v_listed_ids bigint[] := ARRAY[]::bigint[];
  v_n_listed int := 0;
  v_n_interest int := 0;
BEGIN
  PERFORM set_config('search_path', 'public, extensions, net', true);

  IF to_regprocedure('public.gpsl_listing_gossip_payload(bigint)') IS NULL THEN
    RAISE EXCEPTION 'listing gossip is not installed. Run listing_gossip_card_20261110.sql first';
  END IF;

  SELECT s.edge_function_url, nullif(btrim(s.invoke_key), '')
  INTO v_url, v_key
  FROM public.gpsl_discord_transfer_gossip_settings s
  WHERE s.id = 1;

  IF v_url IS NULL OR btrim(v_url) = '' OR v_key IS NULL THEN
    RAISE EXCEPTION 'transfer gossip settings have no url or key';
  END IF;

  FOR r IN
    SELECT l.id
    FROM public."Player_Transfer_Listings" l
    WHERE l.status IN ('Pending Window', 'Active')
      AND lower(coalesce(l.listing_type::text, '')) IS DISTINCT FROM 'draft'
      AND nullif(btrim(coalesce(l.seller_club_id::text, '')), '') IS NOT NULL
    ORDER BY l.created_at, l.id
  LOOP
    v_item := public.gpsl_gossip_style_listing(public.gpsl_listing_gossip_payload(r.id));
    IF v_item IS NULL THEN
      CONTINUE;
    END IF;
    v_listings := v_listings || v_item;
    v_listed_ids := v_listed_ids || r.id;
    v_n_listed := v_n_listed + 1;
  END LOOP;

  FOR r IN
    SELECT i.listing_id, i.club_short_name
    FROM public.listing_preview_interest i
    JOIN public."Player_Transfer_Listings" l ON l.id = i.listing_id
    WHERE l.status = 'Pending Window'
      AND lower(coalesce(l.listing_type::text, '')) IS DISTINCT FROM 'draft'
    ORDER BY i.created_at, i.listing_id, i.club_short_name
  LOOP
    v_item := public.gpsl_preview_interest_gossip_item(r.listing_id, r.club_short_name);
    IF v_item IS NULL THEN
      CONTINUE;
    END IF;
    v_interest := v_interest || v_item;
    UPDATE public.listing_preview_interest
    SET gossip_posted_at = NULL
    WHERE listing_id = r.listing_id
      AND club_short_name = r.club_short_name;
    v_n_interest := v_n_interest + 1;
  END LOOP;

  IF v_n_listed = 0 AND v_n_interest = 0 THEN
    RAISE NOTICE 'nothing on the market to post';
    RETURN;
  END IF;

  PERFORM net.http_post(
    url := v_url,
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || v_key
    ),
    body := jsonb_build_object(
      'action', 'post_cards',
      'items', v_listings || v_interest
    ),
    timeout_milliseconds := 180000
  );

  UPDATE public."Player_Transfer_Listings" l
  SET gossip_listed_at = clock_timestamp()
  WHERE l.id = ANY (v_listed_ids);

  UPDATE public.listing_preview_interest i
  SET gossip_posted_at = clock_timestamp()
  FROM public."Player_Transfer_Listings" l
  WHERE l.id = i.listing_id
    AND l.status = 'Pending Window'
    AND lower(coalesce(l.listing_type::text, '')) IS DISTINCT FROM 'draft'
    AND i.gossip_posted_at IS NULL;

  RAISE NOTICE 'gossip queued % listings, then % interest', v_n_listed, v_n_interest;
END;
$retro$;

SELECT kind, club, player, sent_at
FROM (
  SELECT
    'listed'::text AS kind,
    coalesce(nullif(btrim(c."Club"), ''), l.seller_club_id) AS club,
    p."Name" AS player,
    l.gossip_listed_at AS sent_at
  FROM public."Player_Transfer_Listings" l
  LEFT JOIN public."Players" p ON p."Konami_ID"::text = l.player_id::text
  LEFT JOIN public."Clubs" c ON c."ShortName" = upper(btrim(l.seller_club_id::text))
  WHERE l.status IN ('Pending Window', 'Active')
    AND lower(coalesce(l.listing_type::text, '')) IS DISTINCT FROM 'draft'
    AND l.gossip_listed_at IS NOT NULL
  UNION ALL
  SELECT
    'interest'::text,
    coalesce(nullif(btrim(c."Club"), ''), i.club_short_name),
    p."Name",
    i.gossip_posted_at
  FROM public.listing_preview_interest i
  JOIN public."Player_Transfer_Listings" l ON l.id = i.listing_id
  JOIN public."Players" p ON p."Konami_ID"::text = l.player_id::text
  LEFT JOIN public."Clubs" c ON c."ShortName" = i.club_short_name
  WHERE l.status = 'Pending Window'
) q
ORDER BY sent_at, kind DESC, club, player;
