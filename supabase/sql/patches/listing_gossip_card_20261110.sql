-- =============================================================================
-- Listing → #gpsl-transfer-gossip
--
-- A standard listing, including a preview (Pending Window), posts once:
--   the player card, selling club, asking price, owner, and a short note
--   drawn from this season's rating, goals, assists, injuries, contract,
--   league place, form, and the manager's rating.
-- Draft listings are skipped. Taking a listing down does not delete the post.
-- A second run does not post a line that was already sent.
-- The last block also sends listings already on the market.
--
-- Deploy discord-transfer-gossip-ingest first, then run this.
-- Safe re-run.
-- =============================================================================

ALTER TABLE public."Player_Transfer_Listings"
  ADD COLUMN IF NOT EXISTS gossip_listed_at timestamptz;

COMMENT ON COLUMN public."Player_Transfer_Listings".gossip_listed_at IS
  'When this listing was queued to #gpsl-transfer-gossip.';

CREATE OR REPLACE FUNCTION public.gpsl_listing_gossip_unmark(p_ids bigint[])
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF coalesce(auth.role(), '') <> 'service_role' AND NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Not allowed';
  END IF;
  UPDATE public."Player_Transfer_Listings" l
  SET gossip_listed_at = NULL
  WHERE l.id = ANY (coalesce(p_ids, ARRAY[]::bigint[]));
END;
$function$;

REVOKE ALL ON FUNCTION public.gpsl_listing_gossip_unmark(bigint[])
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.gpsl_listing_gossip_unmark(bigint[])
  TO service_role;

CREATE OR REPLACE FUNCTION public.gpsl_listing_gossip_payload(p_listing_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_player_id text;
  v_seller text;
  v_status text;
  v_type text;
  v_ask numeric;
  v_value numeric;
  v_name text;
  v_position text;
  v_overall numeric;
  v_rem int;
  v_club text;
  v_owner text;
  v_mgr_name text;
  v_mgr_rating numeric;
  v_season bigint;
  v_apps int := 0;
  v_goals int := 0;
  v_assists int := 0;
  v_avg numeric;
  v_inj_active int := 0;
  v_inj_season int := 0;
  v_pos int;
  v_pts int;
  v_mp int;
  v_places int;
  v_division text;
  v_form text;
  v_form5 text;
  v_lines text[] := ARRAY[]::text[];
  v_blurb text;
  v_fields jsonb := '[]'::jsonb;
  v_preview boolean;
  v_money text;
BEGIN
  SELECT
    l.player_id::text,
    upper(nullif(btrim(l.seller_club_id::text), '')),
    l.status,
    lower(coalesce(l.listing_type::text, '')),
    l.reserve_price,
    l.market_value
  INTO v_player_id, v_seller, v_status, v_type, v_ask, v_value
  FROM public."Player_Transfer_Listings" l
  WHERE l.id = p_listing_id;

  IF NOT FOUND OR v_seller IS NULL OR v_type = 'draft' THEN
    RETURN NULL;
  END IF;
  IF v_status NOT IN ('Pending Window', 'Active') THEN
    RETURN NULL;
  END IF;

  v_preview := v_status = 'Pending Window';

  SELECT
    nullif(btrim(p."Name"), ''),
    nullif(btrim(p."Position"), ''),
    CASE
      WHEN p."Rating"::text ~ '^[0-9]+(\.[0-9]+)?$' THEN p."Rating"::numeric
      ELSE NULL
    END,
    p.contract_seasons_remaining
  INTO v_name, v_position, v_overall, v_rem
  FROM public."Players" p
  WHERE p."Konami_ID"::text = v_player_id;

  IF v_name IS NULL THEN
    RETURN NULL;
  END IF;

  SELECT
    coalesce(nullif(btrim(c."Club"), ''), c."ShortName"),
    CASE
      WHEN c.owner_id IS NULL THEN 'Vacant'
      WHEN nullif(btrim(c.owner), '') IS NULL THEN 'Owned'
      ELSE '@' || regexp_replace(btrim(c.owner), '^@+', '')
    END
  INTO v_club, v_owner
  FROM public."Clubs" c
  WHERE c."ShortName" = v_seller;

  v_club := coalesce(v_club, v_seller);
  v_owner := coalesce(v_owner, 'Owned');

  SELECT m.name, m.rating
  INTO v_mgr_name, v_mgr_rating
  FROM public."Clubs" c
  JOIN public."Managers" m ON m.id = c.manager_id
  WHERE c."ShortName" = v_seller;

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
      SELECT
        count(*) FILTER (WHERE i.status = 'active')::int,
        count(*) FILTER (WHERE i.status IS DISTINCT FROM 'cancelled')::int
      INTO v_inj_active, v_inj_season
      FROM public.competition_player_injuries i
      WHERE i.player_id::text = v_player_id
        AND i.season_id = v_season;
    EXCEPTION WHEN OTHERS THEN
      v_inj_active := 0;
      v_inj_season := 0;
    END;

    BEGIN
      SELECT
        s.table_position, s.pts, s.mp, s.division, s.form_last10,
        (
          SELECT count(*)::int
          FROM public.competition_standings_public s2
          WHERE s2.division = s.division
        )
      INTO v_pos, v_pts, v_mp, v_division, v_form, v_places
      FROM public.competition_standings_public s
      WHERE s.club_short_name = v_seller
      LIMIT 1;
    EXCEPTION WHEN OTHERS THEN
      v_pos := NULL;
    END;
  END IF;

  v_form5 := right(coalesce(v_form, ''), 5);
  v_division := CASE v_division
    WHEN 'superleague' THEN 'Super League'
    WHEN 'championship_a' THEN 'Championship A'
    WHEN 'championship_b' THEN 'Championship B'
    ELSE v_division
  END;

  IF coalesce(v_inj_active, 0) > 0 THEN
    v_lines := array_append(v_lines, CASE
      WHEN coalesce(v_inj_season, 0) > 1 THEN
        format('Currently injured — spell %s this season.', v_inj_season)
      ELSE 'Currently injured.'
    END);
  ELSIF coalesce(v_inj_season, 0) >= 2 THEN
    v_lines := array_append(v_lines, format(
      'The treatment room has seen him %s times this season.', v_inj_season
    ));
  END IF;

  IF coalesce(v_apps, 0) >= 3 AND v_avg IS NOT NULL AND v_avg < 6
     AND v_overall IS NOT NULL AND v_overall >= 78 THEN
    v_lines := array_append(v_lines, format(
      'An %s-rated card averaging %s from %s games.',
      to_char(v_overall, 'FM999'), to_char(v_avg, 'FM990.00'), v_apps
    ));
  ELSIF coalesce(v_apps, 0) >= 3 AND v_avg IS NOT NULL AND v_avg >= 7.5 THEN
    v_lines := array_append(v_lines, format(
      '%s from %s games. An odd time to cash in.',
      to_char(v_avg, 'FM990.00'), v_apps
    ));
  ELSIF coalesce(v_apps, 0) >= 4 AND v_avg IS NOT NULL AND v_avg < 6 THEN
    v_lines := array_append(v_lines, format(
      '%s from %s games. The ratings have gone quiet.',
      to_char(v_avg, 'FM990.00'), v_apps
    ));
  END IF;

  IF coalesce(v_goals, 0) >= 5 THEN
    v_lines := array_append(v_lines, format('%s goals already this season.', v_goals));
  ELSIF coalesce(v_assists, 0) >= 5 THEN
    v_lines := array_append(v_lines, format('%s assists already this season.', v_assists));
  END IF;

  IF v_rem IS NOT NULL AND v_rem <= 1 THEN
    v_lines := array_append(v_lines, CASE
      WHEN v_rem <= 0 THEN 'The contract is at its end.'
      ELSE 'Only one season left on the contract.'
    END);
  END IF;

  IF v_pos = 1 AND coalesce(v_mp, 0) >= 4 AND v_division IS NOT NULL THEN
    v_lines := array_append(v_lines, format('%s are top of the %s.', v_club, v_division));
  ELSIF v_places IS NOT NULL AND v_places >= 6 AND v_pos IS NOT NULL
        AND v_pos >= v_places - 2 AND coalesce(v_mp, 0) >= 4
        AND v_division IS NOT NULL THEN
    v_lines := array_append(v_lines, format(
      '%s are %s in the %s.',
      v_club,
      CASE
        WHEN v_pos % 100 IN (11, 12, 13) THEN v_pos::text || 'th'
        WHEN v_pos % 10 = 1 THEN v_pos::text || 'st'
        WHEN v_pos % 10 = 2 THEN v_pos::text || 'nd'
        WHEN v_pos % 10 = 3 THEN v_pos::text || 'rd'
        ELSE v_pos::text || 'th'
      END,
      v_division
    ));
  END IF;

  IF v_form5 = 'LLLLL' THEN
    v_lines := array_append(v_lines, 'Five league defeats in a row.');
  ELSIF v_form5 = 'WWWWW' THEN
    v_lines := array_append(v_lines, 'Five league wins in a row, and still open to a sale.');
  END IF;

  IF coalesce(v_value, 0) > 0 AND coalesce(v_ask, 0) >= v_value * 1.25 THEN
    v_lines := array_append(v_lines, 'The asking price sits well above the market value.');
  ELSIF coalesce(v_value, 0) > 0 AND coalesce(v_ask, 0) > 0
        AND v_ask <= v_value * 0.75 THEN
    v_lines := array_append(v_lines, 'The asking price is a friendly one.');
  END IF;

  IF v_mgr_name IS NOT NULL AND v_mgr_rating IS NOT NULL
     AND v_mgr_rating BETWEEN 60 AND 99 AND v_mgr_rating <= 75 THEN
    v_lines := array_append(v_lines, format(
      '%s is rated %s in the dugout.',
      btrim(v_mgr_name), to_char(v_mgr_rating, 'FM999')
    ));
  ELSIF v_mgr_name IS NOT NULL AND v_mgr_rating IS NOT NULL
        AND v_mgr_rating >= 84 THEN
    v_lines := array_append(v_lines, format(
      'Hard to pin this on %s — rated %s.',
      btrim(v_mgr_name), to_char(v_mgr_rating, 'FM999')
    ));
  END IF;

  IF coalesce(array_length(v_lines, 1), 0) = 0 THEN
    v_lines := ARRAY[CASE
      WHEN v_preview THEN 'Listed early, before the window opens.'
      ELSE 'On the market.'
    END];
  END IF;

  v_blurb := array_to_string(v_lines[1:2], ' ');

  v_money := CASE
    WHEN coalesce(v_ask, 0) = coalesce(v_value, 0) THEN
      '₿' || to_char(coalesce(v_ask, 0), 'FM999,999,999,990')
    ELSE
      '₿' || to_char(coalesce(v_ask, 0), 'FM999,999,999,990')
      || ' asking · ₿' || to_char(coalesce(v_value, 0), 'FM999,999,999,990') || ' value'
  END;

  v_fields := v_fields || jsonb_build_array(
    jsonb_build_object('name', 'Selling club', 'value', v_club, 'inline', true),
    jsonb_build_object('name', 'Owner', 'value', v_owner, 'inline', true),
    jsonb_build_object('name', 'Price', 'value', v_money, 'inline', true)
  );

  v_fields := v_fields || jsonb_build_object(
    'name', 'Manager',
    'value', CASE
      WHEN v_mgr_name IS NULL THEN 'No manager'
      WHEN v_mgr_rating IS NULL THEN btrim(v_mgr_name)
      ELSE btrim(v_mgr_name) || ' · ' || to_char(v_mgr_rating, 'FM999')
    END,
    'inline', true
  );

  v_fields := v_fields || jsonb_build_object(
    'name', 'This season',
    'value', CASE
      WHEN coalesce(v_apps, 0) = 0 THEN 'No appearances yet'
      ELSE format(
        '%s apps · %s goals · %s assists%s',
        v_apps, v_goals, v_assists,
        CASE
          WHEN v_avg IS NULL THEN ''
          ELSE ' · avg ' || to_char(v_avg, 'FM990.00')
        END
      )
    END,
    'inline', true
  );

  IF v_rem IS NOT NULL THEN
    v_fields := v_fields || jsonb_build_object(
      'name', 'Contract',
      'value', CASE
        WHEN v_rem <= 0 THEN 'At its end'
        WHEN v_rem = 1 THEN '1 season left'
        ELSE v_rem::text || ' seasons left'
      END,
      'inline', true
    );
  END IF;

  IF v_pos IS NOT NULL AND v_division IS NOT NULL THEN
    v_fields := v_fields || jsonb_build_object(
      'name', 'Club',
      'value', format(
        '%s in the %s · %s pts%s',
        CASE
          WHEN v_pos % 100 IN (11, 12, 13) THEN v_pos::text || 'th'
          WHEN v_pos % 10 = 1 THEN v_pos::text || 'st'
          WHEN v_pos % 10 = 2 THEN v_pos::text || 'nd'
          WHEN v_pos % 10 = 3 THEN v_pos::text || 'rd'
          ELSE v_pos::text || 'th'
        END,
        v_division,
        coalesce(v_pts, 0),
        CASE
          WHEN length(v_form5) >= 3 THEN ' · form ' || v_form5
          ELSE ''
        END
      ),
      'inline', false
    );
  END IF;

  RETURN jsonb_build_object(
    'listing_id', p_listing_id,
    'card_id', v_player_id,
    'content', 'Listed: ' || v_name || ' — ' || v_club,
    'embed', jsonb_build_object(
      'author', jsonb_build_object('name', 'Player listed'),
      'title', 'LISTED · ' || v_name || CASE
        WHEN v_position IS NULL THEN ''
        ELSE ' · ' || v_position
      END,
      'url', 'https://gpsuperleague.github.io/GPSL/player_career.html?id=' || v_player_id,
      'description', v_blurb,
      'color', 15105570,
      'fields', v_fields,
      'footer', jsonb_build_object(
        'text', CASE
          WHEN v_preview THEN 'Preview listing · GPSL'
          ELSE 'On the market · GPSL'
        END
      )
    )
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.gpsl_listing_gossip_payload(bigint)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.gpsl_listing_gossip_payload(bigint)
  TO postgres, service_role;

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
        'footer', jsonb_build_object('text', 'On the market · GPSL')
      )
    )
  END;
$function$;

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

REVOKE ALL ON FUNCTION public.gpsl_listing_gossip_send(bigint[])
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.gpsl_listing_gossip_send(bigint[])
  TO postgres, service_role;

CREATE OR REPLACE FUNCTION public.trg_listing_gossip_card()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF lower(coalesce(NEW.listing_type::text, '')) = 'draft' THEN
    RETURN NEW;
  END IF;
  IF NEW.status NOT IN ('Pending Window', 'Active') THEN
    RETURN NEW;
  END IF;
  IF nullif(btrim(coalesce(NEW.seller_club_id::text, '')), '') IS NULL THEN
    RETURN NEW;
  END IF;
  PERFORM public.gpsl_listing_gossip_send(ARRAY[NEW.id]);
  RETURN NEW;
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING 'listing gossip: %', SQLERRM;
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_listing_gossip_card
  ON public."Player_Transfer_Listings";
CREATE TRIGGER trg_listing_gossip_card
  AFTER INSERT ON public."Player_Transfer_Listings"
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_listing_gossip_card();

-- Backfill is preview_interest_gossip_redo_20261110.sql (listings, then interest).

SELECT
  coalesce(nullif(btrim(c."Club"), ''), l.seller_club_id) AS club,
  p."Name" AS player,
  l.status,
  l.gossip_listed_at
FROM public."Player_Transfer_Listings" l
LEFT JOIN public."Players" p ON p."Konami_ID"::text = l.player_id::text
LEFT JOIN public."Clubs" c ON c."ShortName" = upper(btrim(l.seller_club_id::text))
WHERE l.status IN ('Pending Window', 'Active')
  AND lower(coalesce(l.listing_type::text, '')) IS DISTINCT FROM 'draft'
  AND l.gossip_listed_at IS NOT NULL
ORDER BY l.gossip_listed_at, club, player;
