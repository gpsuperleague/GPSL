-- Transfer gossip cards for two moments that were silent:
--   a listed player taken off the market ("no longer for sale")
--   a completed sale ("done deal"), with the fee, wage, and both clubs
-- Same channel and player-card post as a new listing.
-- Past sales are stamped and left alone.
-- Ivan Provedel (listing 3314) was taken off after his listed card and is posted once.

ALTER TABLE public."Player_Transfer_Listings"
  ADD COLUMN IF NOT EXISTS gossip_withdrawn_at timestamptz;

COMMENT ON COLUMN public."Player_Transfer_Listings".gossip_withdrawn_at IS
  'When a "no longer for sale" card was queued to #gpsl-transfer-gossip.';

ALTER TABLE public."Transfer_History"
  ADD COLUMN IF NOT EXISTS discord_gossip_sold_at timestamptz;

COMMENT ON COLUMN public."Transfer_History".discord_gossip_sold_at IS
  'When a done-deal card was queued to #gpsl-transfer-gossip.';

UPDATE public."Player_Transfer_Listings"
SET gossip_withdrawn_at = clock_timestamp()
WHERE gossip_withdrawn_at IS NULL
  AND status IS DISTINCT FROM 'Pending Window'
  AND status IS DISTINCT FROM 'Active'
  AND status IS DISTINCT FROM 'Review'
  AND status IS DISTINCT FROM 'Seller Review'
  AND id <> 3314;

UPDATE public."Transfer_History"
SET discord_gossip_sold_at = clock_timestamp()
WHERE discord_gossip_sold_at IS NULL;

CREATE OR REPLACE FUNCTION public.gpsl_gossip_money(p_amount numeric)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $function$
  SELECT '₿' || to_char(round(coalesce(p_amount, 0), 0), 'FM999,999,999,990');
$function$;

CREATE OR REPLACE FUNCTION public.gpsl_gossip_post_cards(p_items jsonb)
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions, net
AS $function$
DECLARE
  v_url text;
  v_key text;
BEGIN
  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
    RETURN 0;
  END IF;

  SELECT s.edge_function_url, nullif(btrim(s.invoke_key), '')
  INTO v_url, v_key
  FROM public.gpsl_discord_transfer_gossip_settings s
  WHERE s.id = 1;

  IF v_url IS NULL OR btrim(v_url) = '' OR v_key IS NULL THEN
    RAISE WARNING 'transfer gossip: settings have no url or key';
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
      'items', p_items
    ),
    timeout_milliseconds := 60000
  );

  RETURN jsonb_array_length(p_items);
EXCEPTION
  WHEN OTHERS THEN
    RAISE WARNING 'transfer gossip post failed: %', SQLERRM;
    RETURN 0;
END;
$function$;

REVOKE ALL ON FUNCTION public.gpsl_gossip_post_cards(jsonb)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.gpsl_gossip_post_cards(jsonb)
  TO postgres, service_role;

CREATE OR REPLACE FUNCTION public.gpsl_listing_gossip_withdraw(p_listing_id bigint)
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_player_id text;
  v_seller text;
  v_type text;
  v_ask numeric;
  v_name text;
  v_position text;
  v_playstyle text;
  v_club text;
  v_owner text;
  v_still boolean;
  v_item jsonb;
  v_n int;
BEGIN
  SELECT
    l.player_id::text,
    upper(nullif(btrim(l.seller_club_id::text), '')),
    lower(coalesce(l.listing_type::text, '')),
    l.reserve_price
  INTO v_player_id, v_seller, v_type, v_ask
  FROM public."Player_Transfer_Listings" l
  WHERE l.id = p_listing_id
    AND l.status = 'Closed'
    AND coalesce(l.transfer_completed, false) = false
    AND l.gossip_listed_at IS NOT NULL
    AND l.gossip_withdrawn_at IS NULL;

  IF NOT FOUND OR v_seller IS NULL OR v_type = 'draft' THEN
    RETURN 0;
  END IF;

  SELECT
    nullif(btrim(p."Name"), ''),
    nullif(btrim(p."Position"), ''),
    nullif(btrim(p."Playstyle"), '')
  INTO v_name, v_position, v_playstyle
  FROM public."Players" p
  WHERE p."Konami_ID"::text = v_player_id;

  IF v_name IS NULL THEN
    RETURN 0;
  END IF;

  SELECT
    coalesce(nullif(btrim(c."Club"), ''), c."ShortName"),
    CASE
      WHEN c.owner_id IS NULL THEN 'Vacant'
      WHEN nullif(btrim(c.owner), '') IS NULL THEN 'Owned'
      ELSE '@' || regexp_replace(btrim(c.owner), '^@+', '')
    END,
    EXISTS (
      SELECT 1
      FROM public."Players" p
      WHERE p."Konami_ID"::text = v_player_id
        AND (
          upper(btrim(p."Contracted_Team")) = c."ShortName"
          OR upper(btrim(p."Contracted_Team")) = upper(btrim(c."Club"))
        )
    )
  INTO v_club, v_owner, v_still
  FROM public."Clubs" c
  WHERE c."ShortName" = v_seller;

  IF NOT coalesce(v_still, false) THEN
    RETURN 0;
  END IF;

  v_club := coalesce(v_club, v_seller);

  UPDATE public."Player_Transfer_Listings"
  SET gossip_withdrawn_at = clock_timestamp()
  WHERE id = p_listing_id
    AND gossip_withdrawn_at IS NULL;

  IF NOT FOUND THEN
    RETURN 0;
  END IF;

  v_item := jsonb_build_object(
    'card_id', v_player_id,
    'badge_club', v_seller,
    'content', v_name || ' is no longer for sale.',
    'embed', jsonb_build_object(
      'author', jsonb_build_object('name', 'No longer for sale'),
      'title', 'OFF THE LIST · ' || v_name || CASE
        WHEN v_position IS NULL THEN ''
        ELSE ' · ' || v_position
      END,
      'description', 'Taken off the transfer list.',
      'color', 9807270,
      'fields', jsonb_build_array(
        jsonb_build_object('name', 'Club', 'value', v_club, 'inline', true),
        jsonb_build_object(
          'name', 'Playstyle',
          'value', coalesce(v_playstyle, '—'),
          'inline', true
        ),
        jsonb_build_object('name', 'Owner', 'value', coalesce(v_owner, 'Owned'), 'inline', true),
        jsonb_build_object(
          'name', 'Was listed at',
          'value', public.gpsl_gossip_money(v_ask),
          'inline', true
        )
      ),
      'footer', jsonb_build_object('text', 'Taken off the list · GPSL')
    )
  );

  v_n := public.gpsl_gossip_post_cards(jsonb_build_array(v_item));
  IF v_n = 0 THEN
    UPDATE public."Player_Transfer_Listings"
    SET gossip_withdrawn_at = NULL
    WHERE id = p_listing_id;
  END IF;
  RETURN v_n;
EXCEPTION
  WHEN OTHERS THEN
    UPDATE public."Player_Transfer_Listings"
    SET gossip_withdrawn_at = NULL
    WHERE id = p_listing_id
      AND gossip_withdrawn_at IS NOT NULL;
    RAISE WARNING 'listing withdraw gossip: %', SQLERRM;
    RETURN 0;
END;
$function$;

REVOKE ALL ON FUNCTION public.gpsl_listing_gossip_withdraw(bigint)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.gpsl_listing_gossip_withdraw(bigint)
  TO postgres, service_role;

CREATE OR REPLACE FUNCTION public.trg_listing_gossip_withdraw()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF NEW.status IS DISTINCT FROM 'Closed' THEN
    RETURN NEW;
  END IF;
  IF OLD.status IS NOT DISTINCT FROM 'Closed' THEN
    RETURN NEW;
  END IF;
  IF coalesce(NEW.transfer_completed, false) THEN
    RETURN NEW;
  END IF;
  IF lower(coalesce(NEW.listing_type::text, '')) = 'draft' THEN
    RETURN NEW;
  END IF;
  IF NEW.gossip_listed_at IS NULL THEN
    RETURN NEW;
  END IF;
  PERFORM public.gpsl_listing_gossip_withdraw(NEW.id);
  RETURN NEW;
EXCEPTION
  WHEN OTHERS THEN
    RAISE WARNING 'listing withdraw gossip: %', SQLERRM;
    RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_listing_gossip_withdraw
  ON public."Player_Transfer_Listings";
CREATE TRIGGER trg_listing_gossip_withdraw
  AFTER UPDATE OF status, transfer_completed
  ON public."Player_Transfer_Listings"
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_listing_gossip_withdraw();

CREATE OR REPLACE FUNCTION public.gpsl_transfer_gossip_sold(p_history_id bigint)
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_player_id text;
  v_seller text;
  v_buyer text;
  v_fee numeric;
  v_agent numeric;
  v_note text;
  v_foreign text;
  v_listing bigint;
  v_type text;
  v_name text;
  v_position text;
  v_playstyle text;
  v_wage numeric;
  v_rem int;
  v_seller_name text;
  v_buyer_name text;
  v_buyer_owner text;
  v_apps int := 0;
  v_goals int := 0;
  v_assists int := 0;
  v_avg numeric;
  v_season bigint;
  v_fields jsonb := '[]'::jsonb;
  v_item jsonb;
  v_n int;
BEGIN
  SELECT
    h.player_id::text,
    upper(nullif(btrim(h.seller_club_id::text), '')),
    upper(nullif(btrim(h.buyer_club_id::text), '')),
    h.fee,
    h.agent_fee,
    lower(coalesce(btrim(h.transfer_sale_note), '')),
    nullif(btrim(h.foreign_buyer_name), ''),
    h.listing_id
  INTO v_player_id, v_seller, v_buyer, v_fee, v_agent, v_note, v_foreign, v_listing
  FROM public."Transfer_History" h
  WHERE h.id = p_history_id
    AND h.discord_gossip_sold_at IS NULL;

  IF NOT FOUND OR v_player_id IS NULL OR v_buyer IS NULL THEN
    RETURN 0;
  END IF;

  IF v_note <> '' AND v_note NOT IN ('special_auction', 'special_auction_star_swap') THEN
    UPDATE public."Transfer_History"
    SET discord_gossip_sold_at = clock_timestamp()
    WHERE id = p_history_id;
    RETURN 0;
  END IF;

  IF v_listing IS NOT NULL THEN
    SELECT lower(coalesce(l.listing_type::text, ''))
    INTO v_type
    FROM public."Player_Transfer_Listings" l
    WHERE l.id = v_listing;
    IF v_type = 'draft' THEN
      UPDATE public."Transfer_History"
      SET discord_gossip_sold_at = clock_timestamp()
      WHERE id = p_history_id;
      RETURN 0;
    END IF;
  END IF;

  SELECT
    nullif(btrim(p."Name"), ''),
    nullif(btrim(p."Position"), ''),
    nullif(btrim(p."Playstyle"), ''),
    p.contract_wage,
    p.contract_seasons_remaining
  INTO v_name, v_position, v_playstyle, v_wage, v_rem
  FROM public."Players" p
  WHERE p."Konami_ID"::text = v_player_id;

  IF v_name IS NULL THEN
    RETURN 0;
  END IF;

  SELECT coalesce(nullif(btrim(c."Club"), ''), c."ShortName")
  INTO v_seller_name
  FROM public."Clubs" c
  WHERE c."ShortName" = v_seller;
  v_seller_name := coalesce(v_seller_name, v_seller, 'Free agent');

  IF v_buyer = 'FOREIGN' THEN
    v_buyer_name := coalesce(v_foreign, 'Foreign club');
    v_buyer_owner := NULL;
  ELSE
    SELECT
      coalesce(nullif(btrim(c."Club"), ''), c."ShortName"),
      CASE
        WHEN c.owner_id IS NULL THEN 'Vacant'
        WHEN nullif(btrim(c.owner), '') IS NULL THEN 'Owned'
        ELSE '@' || regexp_replace(btrim(c.owner), '^@+', '')
      END
    INTO v_buyer_name, v_buyer_owner
    FROM public."Clubs" c
    WHERE c."ShortName" = v_buyer;
    v_buyer_name := coalesce(v_buyer_name, v_buyer);
  END IF;

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
    EXCEPTION
      WHEN OTHERS THEN
        v_apps := 0;
    END;
  END IF;

  v_fields := jsonb_build_array(
    jsonb_build_object('name', 'From', 'value', v_seller_name, 'inline', true),
    jsonb_build_object('name', 'Buying club', 'value', v_buyer_name, 'inline', true),
    jsonb_build_object('name', 'Fee', 'value', public.gpsl_gossip_money(v_fee), 'inline', true)
  );

  IF coalesce(v_agent, 0) > 0 THEN
    v_fields := v_fields || jsonb_build_object(
      'name', 'Agent fee',
      'value', public.gpsl_gossip_money(v_agent),
      'inline', true
    );
  END IF;

  IF coalesce(v_wage, 0) > 0 THEN
    v_fields := v_fields || jsonb_build_object(
      'name', 'Wage',
      'value', public.gpsl_gossip_money(v_wage),
      'inline', true
    );
  END IF;

  v_fields := v_fields || jsonb_build_object(
    'name', 'Playstyle',
    'value', coalesce(v_playstyle, '—'),
    'inline', true
  );

  IF v_buyer_owner IS NOT NULL THEN
    v_fields := v_fields || jsonb_build_object(
      'name', 'Buying owner',
      'value', v_buyer_owner,
      'inline', true
    );
  END IF;

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

  v_fields := v_fields || jsonb_build_object(
    'name', 'This season',
    'value', CASE
      WHEN coalesce(v_apps, 0) = 0 THEN 'No appearances yet'
      ELSE format(
        '%s apps · %s goals · %s assists%s',
        v_apps,
        v_goals,
        v_assists,
        CASE
          WHEN v_avg IS NULL THEN ''
          ELSE ' · avg ' || to_char(v_avg, 'FM990.00')
        END
      )
    END,
    'inline', false
  );

  UPDATE public."Transfer_History"
  SET discord_gossip_sold_at = clock_timestamp()
  WHERE id = p_history_id
    AND discord_gossip_sold_at IS NULL;

  IF NOT FOUND THEN
    RETURN 0;
  END IF;

  v_item := jsonb_build_object(
    'card_id', v_player_id,
    'badge_club', CASE WHEN v_buyer = 'FOREIGN' THEN v_seller ELSE v_buyer END,
    'content', 'Done deal: ' || v_name || ' joins ' || v_buyer_name || '.',
    'embed', jsonb_build_object(
      'author', jsonb_build_object('name', 'Done deal'),
      'title', 'SIGNED · ' || v_name || CASE
        WHEN v_position IS NULL THEN ''
        ELSE ' · ' || v_position
      END,
      'url', 'https://gpsuperleague.github.io/GPSL/season_transfers.html',
      'description', v_buyer_name || ' have signed ' || v_name || ' from ' || v_seller_name || '.',
      'color', 3066993,
      'fields', v_fields,
      'footer', jsonb_build_object('text', 'Signed · GPSL')
    )
  );

  v_n := public.gpsl_gossip_post_cards(jsonb_build_array(v_item));
  IF v_n = 0 THEN
    UPDATE public."Transfer_History"
    SET discord_gossip_sold_at = NULL
    WHERE id = p_history_id;
  END IF;
  RETURN v_n;
EXCEPTION
  WHEN OTHERS THEN
    UPDATE public."Transfer_History"
    SET discord_gossip_sold_at = NULL
    WHERE id = p_history_id;
    RAISE WARNING 'sold gossip: %', SQLERRM;
    RETURN 0;
END;
$function$;

REVOKE ALL ON FUNCTION public.gpsl_transfer_gossip_sold(bigint)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.gpsl_transfer_gossip_sold(bigint)
  TO postgres, service_role;

CREATE OR REPLACE FUNCTION public.trg_transfer_gossip_sold()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  PERFORM public.gpsl_transfer_gossip_sold(NEW.id);
  RETURN NEW;
EXCEPTION
  WHEN OTHERS THEN
    RAISE WARNING 'sold gossip: %', SQLERRM;
    RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_transfer_gossip_sold
  ON public."Transfer_History";
CREATE TRIGGER trg_transfer_gossip_sold
  AFTER INSERT ON public."Transfer_History"
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_transfer_gossip_sold();

SELECT public.gpsl_listing_gossip_withdraw(3314) AS provedel_card;
