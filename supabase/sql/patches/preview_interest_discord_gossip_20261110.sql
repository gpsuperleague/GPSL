-- =============================================================================
-- Preview interest → #gpsl-transfer-gossip
--
-- Show interest on a Pending Window listing posts one line:
--   Club are interested in Player
-- The gossip reader already turns that sentence into the transfer ticker.
-- A repeat click does not post again. Taking interest off does not delete it.
--
-- Deploy discord-transfer-gossip-ingest first (it posts the line, and it now
-- reads a GPSL bot line in that sentence). Then run this in the SQL editor.
-- Needs listing_preview_interest (listing_preview_interest_20261109.sql).
-- Safe re-run. A second run does not post a line that was already sent.
-- The last block also sends every Show interest already on a preview listing.
-- =============================================================================

ALTER TABLE public.listing_preview_interest
  ADD COLUMN IF NOT EXISTS gossip_posted_at timestamptz;

COMMENT ON COLUMN public.listing_preview_interest.gossip_posted_at IS
  'When this Show interest was queued to #gpsl-transfer-gossip.';

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

CREATE OR REPLACE FUNCTION public.listing_preview_interest_set(
  p_listing_id bigint,
  p_interested boolean
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := upper(nullif(btrim(coalesce(public.my_club_shortname(), '')), ''));
  v_seller text;
  v_status text;
  v_type text;
  v_new int := 0;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;
  IF v_club IS NULL THEN
    RAISE EXCEPTION 'No club';
  END IF;
  IF p_listing_id IS NULL THEN
    RAISE EXCEPTION 'Listing required';
  END IF;

  SELECT
    upper(btrim(l.seller_club_id)),
    l.status,
    lower(coalesce(l.listing_type::text, ''))
  INTO v_seller, v_status, v_type
  FROM public."Player_Transfer_Listings" l
  WHERE l.id = p_listing_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Listing not found';
  END IF;
  IF v_type = 'draft' OR v_status IS DISTINCT FROM 'Pending Window' THEN
    RAISE EXCEPTION 'Interest is only for a preview listing';
  END IF;
  IF v_seller = v_club THEN
    RAISE EXCEPTION 'You cannot declare interest in your own player';
  END IF;

  IF coalesce(p_interested, false) THEN
    INSERT INTO public.listing_preview_interest (listing_id, club_short_name)
    VALUES (p_listing_id, v_club)
    ON CONFLICT (listing_id, club_short_name) DO NOTHING;
    GET DIAGNOSTICS v_new = ROW_COUNT;
    IF v_new = 1 THEN
      BEGIN
        PERFORM public.gpsl_preview_interest_post_gossip(p_listing_id, v_club);
      EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'preview interest gossip: %', SQLERRM;
      END;
    END IF;
  ELSE
    DELETE FROM public.listing_preview_interest
    WHERE listing_id = p_listing_id
      AND club_short_name = v_club;
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'listing_id', p_listing_id,
    'club', v_club,
    'interested', coalesce(p_interested, false)
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.listing_preview_interest_set(bigint, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.listing_preview_interest_set(bigint, boolean)
  TO authenticated;

DO $retro$
DECLARE
  r record;
  v_before int := 0;
  v_after int := 0;
BEGIN
  SELECT count(*)::int
  INTO v_before
  FROM public.listing_preview_interest i
  JOIN public."Player_Transfer_Listings" l ON l.id = i.listing_id
  WHERE i.gossip_posted_at IS NULL
    AND l.status = 'Pending Window'
    AND lower(coalesce(l.listing_type::text, '')) IS DISTINCT FROM 'draft';

  FOR r IN
    SELECT i.listing_id, i.club_short_name
    FROM public.listing_preview_interest i
    JOIN public."Player_Transfer_Listings" l ON l.id = i.listing_id
    WHERE i.gossip_posted_at IS NULL
      AND l.status = 'Pending Window'
      AND lower(coalesce(l.listing_type::text, '')) IS DISTINCT FROM 'draft'
    ORDER BY i.created_at, i.listing_id, i.club_short_name
  LOOP
    PERFORM public.gpsl_preview_interest_post_gossip(r.listing_id, r.club_short_name);
  END LOOP;

  SELECT count(*)::int
  INTO v_after
  FROM public.listing_preview_interest i
  JOIN public."Player_Transfer_Listings" l ON l.id = i.listing_id
  WHERE i.gossip_posted_at IS NULL
    AND l.status = 'Pending Window'
    AND lower(coalesce(l.listing_type::text, '')) IS DISTINCT FROM 'draft';

  RAISE NOTICE 'preview interest gossip queued %; still waiting %',
    v_before - v_after, v_after;
END;
$retro$;

SELECT
  coalesce(nullif(btrim(c."Club"), ''), i.club_short_name) AS club,
  p."Name" AS player,
  i.gossip_posted_at
FROM public.listing_preview_interest i
JOIN public."Player_Transfer_Listings" l ON l.id = i.listing_id
JOIN public."Players" p ON p."Konami_ID"::text = l.player_id::text
LEFT JOIN public."Clubs" c ON c."ShortName" = i.club_short_name
WHERE l.status = 'Pending Window'
  AND i.gossip_posted_at IS NOT NULL
ORDER BY i.gossip_posted_at, club, player;
