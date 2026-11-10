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
  v_ask numeric;
  v_value numeric;
  v_price text;
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

  SELECT p."Name", l.player_id::text
  INTO v_player_name, v_player_id
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
    l.reserve_price,
    l.market_value
  INTO v_seller, v_ask, v_value
  FROM public."Player_Transfer_Listings" l
  LEFT JOIN public."Clubs" c
    ON c."ShortName" = upper(btrim(l.seller_club_id::text))
  WHERE l.id = p_listing_id;

  v_price := CASE
    WHEN coalesce(v_ask, 0) = coalesce(v_value, 0) THEN
      '₿' || to_char(coalesce(v_ask, 0), 'FM999,999,999,990')
    ELSE
      '₿' || to_char(coalesce(v_ask, 0), 'FM999,999,999,990') || ' asking'
  END;

  RETURN jsonb_build_object(
    'content', v_line,
    'card_id', v_player_id,
    'card_layout', 'mini',
    'badge_club', v_club,
    'embed', jsonb_build_object(
      'author', jsonb_build_object(
        'name', coalesce(v_owner, 'Interest shown')
      ),
      'title', 'INTEREST · ' || v_player_name,
      'url', 'https://gpsuperleague.github.io/GPSL/all_listings.html?listing=' || p_listing_id,
      'description', v_club_name || ' have shown interest.',
      'color', 3066993,
      'fields', jsonb_build_array(
        jsonb_build_object('name', 'Shown by', 'value', v_club_name, 'inline', true),
        jsonb_build_object('name', 'Owner', 'value', coalesce(v_owner, '—'), 'inline', true),
        jsonb_build_object('name', 'Selling club', 'value', coalesce(v_seller, '—'), 'inline', true),
        jsonb_build_object('name', 'Asking', 'value', v_price, 'inline', true)
      ),
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
