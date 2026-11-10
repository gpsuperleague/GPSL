-- =============================================================================
-- Repost Show interest that is still on a preview listing.
--
-- Clears the sent mark, then queues one gossip line per current interest:
--   Club are interested in Player
-- Run once. Running it again posts the same lines again.
-- =============================================================================

DO $redo$
DECLARE
  r record;
  v_url text;
  v_key text;
  v_line text;
  v_items jsonb := '[]'::jsonb;
  v_n int := 0;
BEGIN
  PERFORM set_config('search_path', 'public, extensions, net', true);

  SELECT s.edge_function_url, nullif(btrim(s.invoke_key), '')
  INTO v_url, v_key
  FROM public.gpsl_discord_transfer_gossip_settings s
  WHERE s.id = 1;

  IF v_url IS NULL OR btrim(v_url) = '' OR v_key IS NULL THEN
    RAISE EXCEPTION 'preview interest gossip: gossip settings have no url or key';
  END IF;

  FOR r IN
    SELECT
      i.listing_id,
      i.club_short_name,
      coalesce(nullif(btrim(c."Club"), ''), i.club_short_name) AS club_name,
      p."Name" AS player_name
    FROM public.listing_preview_interest i
    JOIN public."Player_Transfer_Listings" l ON l.id = i.listing_id
    JOIN public."Players" p ON p."Konami_ID"::text = l.player_id::text
    LEFT JOIN public."Clubs" c ON c."ShortName" = i.club_short_name
    WHERE l.status = 'Pending Window'
      AND lower(coalesce(l.listing_type::text, '')) IS DISTINCT FROM 'draft'
    ORDER BY i.created_at, i.listing_id, i.club_short_name
  LOOP
    v_line := btrim(regexp_replace(coalesce(r.club_name, ''), '[\r\n]+', ' ', 'g'))
      || ' are interested in '
      || btrim(regexp_replace(coalesce(r.player_name, ''), '[\r\n]+', ' ', 'g'));
    IF btrim(coalesce(r.player_name, '')) = '' OR btrim(coalesce(r.club_name, '')) = '' THEN
      CONTINUE;
    END IF;

    UPDATE public.listing_preview_interest
    SET gossip_posted_at = NULL
    WHERE listing_id = r.listing_id
      AND club_short_name = r.club_short_name;

    v_items := v_items || jsonb_build_object('content', v_line);
    v_n := v_n + 1;
  END LOOP;

  IF v_n = 0 THEN
    RAISE NOTICE 'no preview interest currently shown';
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
      'items', v_items
    ),
    timeout_milliseconds := 180000
  );

  UPDATE public.listing_preview_interest i
  SET gossip_posted_at = clock_timestamp()
  FROM public."Player_Transfer_Listings" l
  WHERE l.id = i.listing_id
    AND l.status = 'Pending Window'
    AND lower(coalesce(l.listing_type::text, '')) IS DISTINCT FROM 'draft'
    AND i.gossip_posted_at IS NULL;

  RAISE NOTICE 'preview interest gossip reposted %', v_n;
END;
$redo$;

SELECT
  coalesce(nullif(btrim(c."Club"), ''), i.club_short_name) AS club,
  p."Name" AS player,
  i.gossip_posted_at
FROM public.listing_preview_interest i
JOIN public."Player_Transfer_Listings" l ON l.id = i.listing_id
JOIN public."Players" p ON p."Konami_ID"::text = l.player_id::text
LEFT JOIN public."Clubs" c ON c."ShortName" = i.club_short_name
WHERE l.status = 'Pending Window'
ORDER BY club, player;
