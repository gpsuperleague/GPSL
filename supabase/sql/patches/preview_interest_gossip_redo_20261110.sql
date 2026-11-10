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

CREATE OR REPLACE FUNCTION public.gpsl_interest_journalist_lines(
  p_seed text,
  p_pos int,
  p_places int,
  p_mp int,
  p_apps int,
  p_starts int,
  p_goals int,
  p_assists int,
  p_avg numeric,
  p_overall numeric,
  p_rem int,
  p_inj_active int,
  p_inj_season int,
  p_relegated boolean,
  p_trophy boolean,
  p_app_pct int,
  p_start_pct int,
  p_ask numeric,
  p_value numeric
)
RETURNS TABLE (player_line text, manager_line text)
LANGUAGE plpgsql
IMMUTABLE
AS $function$
DECLARE
  v_reason text;
  v_n int;
  v_p text[];
  v_m text[];
BEGIN
  v_reason := CASE
    WHEN coalesce(p_inj_active, 0) > 0 THEN 'hurt_now'
    WHEN coalesce(p_inj_season, 0) >= 2 THEN 'hurt_often'
    WHEN coalesce(p_relegated, false) THEN 'relegated'
    WHEN p_places IS NOT NULL AND p_places >= 8 AND p_pos IS NOT NULL
         AND p_pos >= p_places - 2 AND coalesce(p_mp, 0) >= 4 THEN 'relegation_fight'
    WHEN coalesce(p_trophy, false) THEN 'trophy'
    WHEN p_pos IS NOT NULL AND p_pos <= 2 AND coalesce(p_mp, 0) >= 4
         AND (coalesce(p_avg, 0) >= 6.8 OR coalesce(p_overall, 0) >= 80) THEN 'title_push'
    WHEN coalesce(p_overall, 0) >= 84
         OR (coalesce(p_avg, 0) >= 7.6 AND coalesce(p_apps, 0) >= 4) THEN 'top_player'
    WHEN p_rem IS NOT NULL AND p_rem <= 1 THEN 'contract_end'
    WHEN p_start_pct IS NOT NULL AND p_start_pct >= 65 AND coalesce(p_mp, 0) >= 4
         AND p_avg IS NOT NULL AND p_avg < 6.4 AND coalesce(p_apps, 0) >= 4 THEN 'starter_poor'
    WHEN p_app_pct IS NOT NULL AND p_app_pct < 30 AND coalesce(p_mp, 0) >= 5 THEN 'barely_played'
    WHEN p_app_pct IS NOT NULL AND p_start_pct IS NOT NULL
         AND p_app_pct >= 40 AND p_start_pct < 40 AND coalesce(p_mp, 0) >= 4 THEN 'not_starting'
    WHEN p_start_pct IS NOT NULL AND p_start_pct >= 65 AND coalesce(p_mp, 0) >= 4
         AND p_avg IS NOT NULL AND p_avg >= 7 THEN 'starter_good'
    WHEN coalesce(p_goals, 0) + coalesce(p_assists, 0) >= 5 THEN 'contributor'
    WHEN coalesce(p_value, 0) > 0 AND coalesce(p_ask, 0) >= p_value * 1.3 THEN 'price_high'
    WHEN coalesce(p_value, 0) > 0 AND coalesce(p_ask, 0) > 0
         AND p_ask <= p_value * 0.75 THEN 'price_low'
    WHEN p_rem IS NOT NULL AND p_rem >= 4 THEN 'long_contract'
    ELSE 'default'
  END;

  v_n := 1 + mod(abs(hashtext(coalesce(p_seed, '') || ':' || v_reason)), 3);

  v_p := CASE v_reason
    WHEN 'hurt_now' THEN ARRAY[
      'The treatment room has me. A move is not the conversation today.',
      'I want to be fit before I talk about my future.',
      'Journalists can wait. I am trying to get back on the pitch.']
    WHEN 'hurt_often' THEN ARRAY[
      'The body has taken a beating this season. A change of load might help.',
      'I have been in and out of the treatment room. I need a clear run.',
      'Injuries have written my season. I am open to a fresh start.']
    WHEN 'relegated' THEN ARRAY[
      'Last season ended the wrong way. I want the level I know.',
      'Dropping down hurt. I am ready for a club with a higher aim.',
      'I did not come here to settle for last year''s result.']
    WHEN 'relegation_fight' THEN ARRAY[
      'The table is ugly. I want a club that is going up, not down.',
      'Fighting at the bottom takes it out of you. I would listen.',
      'I will keep playing, but I do not want another year in this scrap.']
    WHEN 'trophy' THEN ARRAY[
      'We have already won something. I would like to win more here.',
      'A trophy changes how a move feels. I am settled.',
      'I came for nights like that final. Leaving now would be strange.']
    WHEN 'title_push' THEN ARRAY[
      'We are in a title fight. It would take a lot to make me leave.',
      'I want the medal. Walking out of this race is not the plan.',
      'The league is there to be won. I am happy where I am.']
    WHEN 'top_player' THEN ARRAY[
      'I know the level I am at. The next club has to match it.',
      'I am playing like a player people pay for. I can wait.',
      'Big offers get a hearing. Small ones do not.']
    WHEN 'contract_end' THEN ARRAY[
      'The contract is running out. Of course I will hear what is out there.',
      'I want clarity. A new club now is better than a free later.',
      'My deal is nearly done. This is the window to decide.']
    WHEN 'starter_poor' THEN ARRAY[
      'I am playing every week, and it is not good enough. A new start might help.',
      'The shirt is mine and the form is not. I have to be honest.',
      'Regular football with these numbers is hard to enjoy.']
    WHEN 'barely_played' THEN ARRAY[
      'I have barely played. I need a club that will use me.',
      'Watching is not why I signed. I am available.',
      'Give me games and I will stay. Without them, I will look.']
    WHEN 'not_starting' THEN ARRAY[
      'I am in the squad and not in the team. I want to start.',
      'Coming off the bench every week is not enough.',
      'I need a manager who picks me. That might be somewhere else.']
    WHEN 'starter_good' THEN ARRAY[
      'I start every week and I am playing well. Why would I rush?',
      'The manager trusts me. That is worth more than a rumour.',
      'Form like this, in the team, I am in no hurry.']
    WHEN 'contributor' THEN ARRAY[
      'The goals and assists are there. I can wait for a step up.',
      'I am contributing. A move has to be upwards, not sideways.',
      'Numbers like mine get you linked. I am calm about it.']
    WHEN 'price_high' THEN ARRAY[
      'The fee is the club''s, not mine. I just want to play.',
      'I have seen the number. They are not desperate to lose me.',
      'A price like that means I stay unless someone is serious.']
    WHEN 'price_low' THEN ARRAY[
      'The fee looks friendly. Someone could get a deal done.',
      'I can see the club is open to it. So am I, for the right place.',
      'A price like that means they will talk. I will too.']
    WHEN 'long_contract' THEN ARRAY[
      'I have years left here. I did not ask to be listed.',
      'The contract is long. If I go, it is because the club wants the fee.',
      'I am under contract. Any move is their choice, not a demand from me.']
    ELSE ARRAY[
      'I will speak to the club and to anyone serious. Nothing is decided.',
      'Rumours are part of the job. I am focused on the next match.',
      'I have seen the link. We will see if it becomes anything.']
  END;

  v_m := CASE v_reason
    WHEN 'hurt_now' THEN ARRAY[
      'He is injured. Any talk waits until he is training.',
      'We are thinking about his recovery, not a transfer.',
      'There is interest, and there is an injury. Recovery comes first.']
    WHEN 'hurt_often' THEN ARRAY[
      'He has missed too much. We would listen if the fee is right.',
      'The injuries have been the story. A move is not off the table.',
      'We rate him, but he has not been able to stay fit.']
    WHEN 'relegated' THEN ARRAY[
      'He has ambitions above this division. We understand the interest.',
      'After relegation, some players want the next step. We would talk.',
      'He handled the drop. If a bigger club comes, we will see the number.']
    WHEN 'relegation_fight' THEN ARRAY[
      'The league position is the problem. Offers will be heard.',
      'Selling in a scrap is a hard call. We will still look at a bid.',
      'Survival comes first. A fee that helps the club would be discussed.']
    WHEN 'trophy' THEN ARRAY[
      'He has a medal this season. We do not need to cash in.',
      'Winners attract bids. That does not mean we accept them.',
      'The trophy was the point. Selling him next is not the plan.']
    WHEN 'title_push' THEN ARRAY[
      'He is in a side chasing the title. We are not a selling club this month.',
      'Interest is flattering. The league table is the priority.',
      'You do not break up a title push unless the fee is absurd.']
    WHEN 'top_player' THEN ARRAY[
      'He is one of the best here. The fee has to say so.',
      'Top players get linked. Our valuation is firm.',
      'Meet the number and we talk. We will not give him away.']
    WHEN 'contract_end' THEN ARRAY[
      'His contract is short. We would rather sell than lose him for nothing.',
      'A year left changes the conversation. Sensible bids will be heard.',
      'We know the contract. That is why the name is out there.']
    WHEN 'starter_poor' THEN ARRAY[
      'He starts, and the form has dropped. We would consider a bid.',
      'He has had the shirt. The performances have not repaid it.',
      'He has had the chances. The level has not been there.']
    WHEN 'barely_played' THEN ARRAY[
      'He has not had the games. A move is fair to discuss.',
      'The pathway here is blocked. We will not stand in the way of a fair fee.',
      'He is frustrated, and the team sheet shows why. Offers are welcome.']
    WHEN 'not_starting' THEN ARRAY[
      'He wants to start. We cannot promise that here.',
      'He is a useful squad man. A club that would start him may suit him.',
      'Bench minutes are not what he wants. We would listen.']
    WHEN 'starter_good' THEN ARRAY[
      'He is a regular and he is playing well. The price is high for a reason.',
      'You do not sell your best starter unless you are bowled over.',
      'Interest is noted. He is central to how we play.']
    WHEN 'contributor' THEN ARRAY[
      'He is on the scoresheet. That sets the fee.',
      'Players who create attract noise. We are relaxed.',
      'If the bid respects what he gives us, we will pick up the phone.']
    WHEN 'price_high' THEN ARRAY[
      'The asking fee is deliberate. Tyre-kickers can stay away.',
      'We set it high because we do not have to sell.',
      'Meet the valuation or keep the rumour. Those are the options.']
    WHEN 'price_low' THEN ARRAY[
      'The fee is realistic. We are open to doing business.',
      'We priced him to draw interest, and it has.',
      'A sensible bid gets a sensible answer.']
    WHEN 'long_contract' THEN ARRAY[
      'He is tied down. Listing him is about the offer, not unrest.',
      'A long contract means we set the price. We are comfortable either way.',
      'Nobody is forcing him out. We are testing the market.']
    ELSE ARRAY[
      'There is interest. That is all it is until a bid arrives.',
      'We listed him. We will judge each call on its merits.',
      'Journalists can write. The decision will be the club''s.']
  END;

  player_line := v_p[v_n];
  manager_line := v_m[v_n];
  RETURN NEXT;
END;
$function$;

REVOKE ALL ON FUNCTION public.gpsl_interest_journalist_lines(
  text, int, int, int, int, int, int, int, numeric, numeric, int, int, int,
  boolean, boolean, int, int, numeric, numeric
) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.gpsl_interest_journalist_lines(
  text, int, int, int, int, int, int, int, numeric, numeric, int, int, int,
  boolean, boolean, int, int, numeric, numeric
) TO postgres, service_role;

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
  v_starts int := 0;
  v_goals int := 0;
  v_assists int := 0;
  v_avg numeric;
  v_overall numeric;
  v_mp int;
  v_pos int;
  v_places int;
  v_inj int := 0;
  v_inj_season int := 0;
  v_pct int;
  v_start_pct int;
  v_prev_div text;
  v_cur_div text;
  v_relegated boolean := false;
  v_trophy boolean := false;
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

  SELECT
    p."Name",
    l.player_id::text,
    p.contract_seasons_remaining,
    CASE
      WHEN p."Rating"::text ~ '^[0-9]+(\.[0-9]+)?$' THEN p."Rating"::numeric
      ELSE NULL
    END
  INTO v_player_name, v_player_id, v_rem, v_overall
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
        count(*) FILTER (WHERE coalesce(m.started, false))::int,
        coalesce(sum(m.goals), 0)::int,
        coalesce(sum(m.assists), 0)::int,
        round(avg(m.rating) FILTER (
          WHERE coalesce(m.appeared, false) AND m.rating IS NOT NULL
        ), 2)
      INTO v_apps, v_starts, v_goals, v_assists, v_avg
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
      INTO v_inj, v_inj_season
      FROM public.competition_player_injuries i
      WHERE i.player_id::text = v_player_id
        AND i.season_id = v_season;
    EXCEPTION WHEN OTHERS THEN
      v_inj := 0;
    END;

    BEGIN
      SELECT
        s.mp,
        s.table_position,
        (
          SELECT count(*)::int
          FROM public.competition_standings_public s2
          WHERE s2.division = s.division
        )
      INTO v_mp, v_pos, v_places
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
  v_start_pct := CASE
    WHEN coalesce(v_mp, 0) > 0 THEN
      least(100, round(100.0 * coalesce(v_starts, 0) / v_mp))::int
    ELSE NULL
  END;

  BEGIN
    SELECT prev.division, cur.division
    INTO v_prev_div, v_cur_div
    FROM public.competition_club_seasons cur
    JOIN public.competition_seasons cs
      ON cs.id = cur.season_id AND cs.is_current
    JOIN public.competition_club_seasons prev
      ON prev.club_short_name = cur.club_short_name
     AND prev.season_id <> cur.season_id
    JOIN public.competition_seasons ps ON ps.id = prev.season_id
    WHERE cur.club_short_name = v_seller_short
    ORDER BY ps.id DESC
    LIMIT 1;
    v_relegated :=
      (v_prev_div = 'superleague' AND v_cur_div IN ('championship_a', 'championship_b'))
      OR (v_prev_div = 'championship_a' AND v_cur_div = 'championship_b');
  EXCEPTION WHEN OTHERS THEN
    v_relegated := false;
  END;

  BEGIN
    SELECT EXISTS (
      SELECT 1
      FROM public.competition_fixtures f
      WHERE f.season_id = v_season
        AND f.competition_type = 'cup'
        AND f.status = 'played'
        AND NOT coalesce(f.is_void, false)
        AND f.cup_round IS NOT NULL
        AND f.cup_round = (
          SELECT max(x.cup_round)
          FROM public.competition_fixtures x
          WHERE x.season_id = f.season_id
            AND x.cup_code = f.cup_code
            AND x.competition_type = 'cup'
        )
        AND (
          upper(btrim(coalesce(f.cup_pen_winner_club_short_name, ''))) = v_seller_short
          OR (
            coalesce(btrim(f.cup_pen_winner_club_short_name), '') = ''
            AND (
              (f.home_club_short_name = v_seller_short AND f.home_goals > f.away_goals)
              OR (f.away_club_short_name = v_seller_short AND f.away_goals > f.home_goals)
            )
          )
        )
    ) INTO v_trophy;
  EXCEPTION WHEN OTHERS THEN
    v_trophy := false;
  END;

  SELECT q.player_line, q.manager_line
  INTO v_player_quote, v_mgr_quote
  FROM public.gpsl_interest_journalist_lines(
    p_listing_id::text || ':' || v_club,
    v_pos, v_places, v_mp, v_apps, v_starts, v_goals, v_assists,
    v_avg, v_overall, v_rem, v_inj, v_inj_season,
    v_relegated, v_trophy, v_pct, v_start_pct, v_ask, v_value
  ) q;

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
