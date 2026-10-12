-- =============================================================================
-- Bookies: player market eligibility by position + new markets
--
--   • Top scorer markets  → no GK, CB, LB, RB, LWB, RWB, DMF, CMF
--   • Most assists        → no GK, CB, LB, RB, LWB, RWB, DMF
--   • Most clean sheets   → goalkeepers only (best keeper per league club)
-- New markets (current season, created now and on every Open / Refresh):
--   assists_overall   "Most assists (all divisions)"
--   clean_sheets_gk   "Most clean sheets — goalkeepers (all divisions)"
-- Both run once league fixtures are drawn; settle like scorer markets
-- (admin enters the winning player id).
-- Clean-up of existing markets: ineligible players removed (or hidden if they
-- have bet history), their open bets voided and refunded, each market topped
-- back up to 40 and re-priced.
-- Run AFTER bookies_scorer_markets_attackers_only_20261011.sql and
-- bookies_open_august_20261012.sql. Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.bookies_position_can_score(p_position text)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
AS $function$
  SELECT upper(btrim(coalesce(p_position, '')))
    NOT IN ('GK', 'CB', 'LB', 'RB', 'LWB', 'RWB', 'DMF', 'CMF');
$function$;

CREATE OR REPLACE FUNCTION public.bookies_position_eligible(p_market_code text, p_position text)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
AS $function$
  SELECT CASE
    WHEN lower(coalesce(p_market_code, '')) LIKE 'clean_sheets%'
      THEN upper(btrim(coalesce(p_position, ''))) = 'GK'
    WHEN lower(coalesce(p_market_code, '')) LIKE 'assists%'
      THEN upper(btrim(coalesce(p_position, '')))
        NOT IN ('GK', 'CB', 'LB', 'RB', 'LWB', 'RWB', 'DMF')
    ELSE public.bookies_position_can_score(p_position)
  END;
$function$;

CREATE OR REPLACE FUNCTION public.bookies_player_eligible(p_market_code text, p_player_id text)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
  SELECT coalesce(
    (SELECT public.bookies_position_eligible(p_market_code, p."Position"::text)
     FROM public."Players" p
     WHERE p."Konami_ID"::text = btrim(coalesce(p_player_id, ''))
     LIMIT 1),
    lower(coalesce(p_market_code, '')) NOT LIKE 'clean_sheets%'
  );
$function$;

CREATE OR REPLACE FUNCTION public.trg_bookies_selections_attackers_only()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_code text;
BEGIN
  SELECT m.market_code INTO v_code
  FROM public.bookies_markets m
  WHERE m.id = NEW.market_id AND m.market_kind = 'player';

  IF v_code IS NOT NULL AND NOT public.bookies_player_eligible(v_code, NEW.selection_key) THEN
    RETURN NULL;
  END IF;
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS bookies_selections_00_attackers_only ON public.bookies_selections;
CREATE TRIGGER bookies_selections_00_attackers_only
  BEFORE INSERT ON public.bookies_selections
  FOR EACH ROW EXECUTE FUNCTION public.trg_bookies_selections_attackers_only();

-- Candidate pool for a player market (eligible, club-contracted), strongest first
CREATE OR REPLACE FUNCTION public.bookies_stat_market_pool(p_season_id bigint, p_code text)
RETURNS TABLE (player_id text, player_name text, club text, stat int, w numeric)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
  WITH st AS (
    SELECT s.player_id,
           sum(s.assists)::int AS assists,
           sum(s.clean_sheets)::int AS clean_sheets,
           sum(s.appearances)::int AS apps
    FROM public.competition_player_season_stats_public s
    WHERE s.season_id = p_season_id
    GROUP BY s.player_id
  ),
  base AS (
    SELECT
      p."Konami_ID"::text AS player_id,
      p."Name"::text AS player_name,
      public.player_contracted_club_key(p."Contracted_Team") AS club,
      p."Position"::text AS pos,
      public.bookies_player_rating_num(p."Rating"::text) AS rating,
      coalesce(st.assists, 0) AS assists,
      coalesce(st.clean_sheets, 0) AS clean_sheets,
      coalesce(st.apps, 0) AS apps
    FROM public."Players" p
    LEFT JOIN st ON st.player_id = p."Konami_ID"::text
    WHERE coalesce(btrim(public.player_contracted_club_key(p."Contracted_Team")), '') <> ''
  ),
  league_clubs AS (
    SELECT ccs.club_short_name
    FROM public.competition_club_seasons ccs
    WHERE ccs.season_id = p_season_id
      AND ccs.division IN ('superleague', 'championship_a', 'championship_b')
  ),
  scored AS (
    SELECT b.*,
      CASE
        WHEN lower(p_code) LIKE 'clean_sheets%' THEN
          greatest(0.5, b.clean_sheets * 3 + b.apps * 0.15 + b.rating / 40.0
            + public.bookies_club_strength(b.club) / 8.0)
        ELSE
          greatest(0.5, b.assists * 3 + b.apps * 0.15 + b.rating / 40.0)
      END AS w
    FROM base b
    WHERE b.club IN (SELECT club_short_name FROM league_clubs)
      AND public.bookies_position_eligible(p_code, b.pos)
  ),
  picked AS (
    -- Clean sheets: one keeper per club (the strongest); others: everyone
    SELECT DISTINCT ON (CASE WHEN lower(p_code) LIKE 'clean_sheets%' THEN s.club ELSE s.player_id END)
      s.*
    FROM scored s
    ORDER BY CASE WHEN lower(p_code) LIKE 'clean_sheets%' THEN s.club ELSE s.player_id END,
             s.w DESC, s.player_name
  )
  SELECT player_id, player_name, club,
         CASE WHEN lower(p_code) LIKE 'clean_sheets%' THEN clean_sheets ELSE assists END,
         w
  FROM picked
  ORDER BY w DESC, player_name
  LIMIT 40;
$function$;

-- Market-create block: allow the stat-markets builder to list markets pre-open
CREATE OR REPLACE FUNCTION public.trg_bookies_markets_block_before_july()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF coalesce(current_setting('gpsl.bookies_preopen_ok', true), '') = 'on' THEN
    RETURN NEW;
  END IF;
  IF NOT public.bookies_shop_open(NEW.season_id) THEN
    RAISE EXCEPTION 'The bookies opens in GPSL August — markets can''t be opened before then';
  END IF;
  RETURN NEW;
END;
$function$;

-- Create (or refresh) the assists + clean sheets markets for a season
CREATE OR REPLACE FUNCTION public.bookies_open_stat_markets(
  p_season_id bigint DEFAULT NULL,
  p_refresh boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season bigint := p_season_id;
  v_market bigint;
  v_status text;
  v_have int;
  v_out jsonb := '[]'::jsonb;
  r record;
BEGIN
  IF v_season IS NULL THEN
    SELECT id INTO v_season FROM public.competition_seasons
    WHERE is_current = true ORDER BY id DESC LIMIT 1;
  END IF;
  IF v_season IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'No season');
  END IF;

  -- Markets may be listed before the shop opens; bets stay blocked until then
  PERFORM set_config('gpsl.bookies_preopen_ok', 'on', true);

  FOR r IN
    SELECT * FROM (VALUES
      ('assists_overall', 'Most assists (all divisions)', 'assists'),
      ('clean_sheets_gk', 'Most clean sheets — goalkeepers (all divisions)', 'clean_sheets')
    ) AS t(code, title, stat_key)
  LOOP
    v_market := NULL;
    SELECT id, status INTO v_market, v_status
    FROM public.bookies_markets
    WHERE season_id = v_season AND market_code = r.code;

    IF v_market IS NULL THEN
      INSERT INTO public.bookies_markets (season_id, market_code, title, market_kind, status, metadata)
      VALUES (v_season, r.code, r.title, 'player', 'open',
              jsonb_build_object('division', NULL, 'play_money_only', true))
      RETURNING id INTO v_market;
    ELSIF v_status = 'settled' OR NOT coalesce(p_refresh, false) THEN
      v_out := v_out || jsonb_build_object('code', r.code, 'market_id', v_market, 'action', 'kept');
      CONTINUE;
    ELSE
      DELETE FROM public.bookies_selections s
      WHERE s.market_id = v_market
        AND NOT EXISTS (SELECT 1 FROM public.bookies_bets b WHERE b.selection_id = s.id);
      UPDATE public.bookies_markets SET title = r.title, updated_at = now() WHERE id = v_market;
    END IF;

    SELECT count(*) INTO v_have FROM public.bookies_selections WHERE market_id = v_market;

    INSERT INTO public.bookies_selections
      (market_id, selection_key, label, odds_decimal, sort_order, weight, metadata)
    SELECT
      v_market,
      x.player_id,
      x.player_name || ' (' || x.club || ')',
      10.00,
      v_have + row_number() OVER (ORDER BY x.w DESC, x.player_name)::int,
      x.w,
      jsonb_build_object('club', x.club, r.stat_key, x.stat)
    FROM public.bookies_stat_market_pool(v_season, r.code) x
    WHERE NOT EXISTS (
      SELECT 1 FROM public.bookies_selections s2
      WHERE s2.market_id = v_market AND s2.selection_key = x.player_id
    );

    PERFORM public.bookies_apply_odds_from_weights(v_market);
    v_out := v_out || jsonb_build_object('code', r.code, 'market_id', v_market, 'action', 'built');
  END LOOP;

  PERFORM set_config('gpsl.bookies_preopen_ok', 'off', true);

  RETURN jsonb_build_object('ok', true, 'season_id', v_season, 'markets', v_out);
END;
$function$;

REVOKE ALL ON FUNCTION public.bookies_open_stat_markets(bigint, boolean) FROM PUBLIC;

-- Running state: new markets run once any league fixtures exist
CREATE OR REPLACE FUNCTION public.bookies_market_state(p_market_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  m public.bookies_markets%rowtype;
  v_code text;
  v_div text;
  v_cup text;
  v_running boolean := true;
  v_reason text := NULL;
  v_clubs text[] := NULL;
BEGIN
  SELECT * INTO m FROM public.bookies_markets WHERE id = p_market_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('market_id', p_market_id, 'running', false, 'reason', 'Market not found');
  END IF;

  v_code := lower(coalesce(m.market_code, ''));
  v_div := nullif(btrim(coalesce(m.metadata->>'division', '')), '');

  IF NOT public.bookies_shop_open(m.season_id) THEN
    v_running := false;
    v_reason := 'Betting opens in GPSL August';

  ELSIF v_code LIKE 'league_%' AND v_div IS NOT NULL THEN
    v_running := EXISTS (
      SELECT 1 FROM public.competition_fixtures f
      WHERE f.season_id = m.season_id
        AND coalesce(f.competition_type, 'league') = 'league'
        AND f.division = v_div
    );
    v_reason := CASE WHEN v_running THEN NULL ELSE 'League not drawn yet' END;

  ELSIF v_code LIKE 'cup_%' THEN
    v_cup := substring(v_code FROM 5);
    SELECT array_agg(DISTINCT upper(x))
    INTO v_clubs
    FROM (
      SELECT f.home_club_short_name AS x FROM public.competition_fixtures f
      WHERE f.season_id = m.season_id AND f.competition_type = 'cup'
        AND lower(coalesce(f.cup_code, '')) = v_cup
      UNION ALL
      SELECT f.away_club_short_name FROM public.competition_fixtures f
      WHERE f.season_id = m.season_id AND f.competition_type = 'cup'
        AND lower(coalesce(f.cup_code, '')) = v_cup
    ) s
    WHERE nullif(btrim(coalesce(x, '')), '') IS NOT NULL;
    v_running := coalesce(cardinality(v_clubs), 0) > 0;
    v_reason := CASE WHEN v_running THEN NULL ELSE 'Cup draw not made yet' END;

  ELSIF v_code IN ('scorer_overall', 'assists_overall', 'clean_sheets_gk') THEN
    v_running := EXISTS (
      SELECT 1 FROM public.competition_fixtures f
      WHERE f.season_id = m.season_id
        AND coalesce(f.competition_type, 'league') = 'league'
    );
    v_reason := CASE WHEN v_running THEN NULL ELSE 'Leagues not drawn yet' END;

  ELSIF v_code = 'scorer_league_cup' THEN
    v_running := EXISTS (
      SELECT 1 FROM public.competition_fixtures f
      WHERE f.season_id = m.season_id AND f.competition_type = 'cup'
        AND lower(coalesce(f.cup_code, '')) = 'league_cup'
    );
    v_reason := CASE WHEN v_running THEN NULL ELSE 'League Cup draw not made yet' END;

  ELSIF v_code = 'scorer_prestige' THEN
    v_running := EXISTS (
      SELECT 1 FROM public.competition_fixtures f
      WHERE f.season_id = m.season_id AND f.competition_type = 'cup'
        AND lower(coalesce(f.cup_code, '')) IN ('super8', 'plate', 'shield', 'bowl')
    );
    v_reason := CASE WHEN v_running THEN NULL ELSE 'Prestige cup draws not made yet' END;

  ELSIF v_code = 'scorer_world_cup' THEN
    IF to_regclass('public.international_fixtures') IS NOT NULL THEN
      EXECUTE 'SELECT EXISTS (SELECT 1 FROM public.international_fixtures WHERE season_id = $1)'
        INTO v_running USING m.season_id;
    ELSE
      v_running := false;
    END IF;
    v_reason := CASE WHEN v_running THEN NULL ELSE 'World Cup not running this season' END;
  END IF;

  RETURN jsonb_build_object(
    'market_id', m.id,
    'running', coalesce(v_running, false),
    'reason', v_reason,
    'cup_clubs', to_jsonb(v_clubs)
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.bookies_market_state(bigint) FROM PUBLIC;

-- Admin "Open / create markets" and "Refresh odds" also build the new markets
DO $wire$
DECLARE
  v_def text;
  v_marker text := 'bookies_open_stat_markets';
  v_old text := E'  RETURN jsonb_build_object(\n    ''ok'', true,\n    ''season_id'', v_season_id,';
  v_new text;
BEGIN
  SELECT pg_get_functiondef('public.admin_bookies_open_markets(bigint,boolean)'::regprocedure)
  INTO v_def;

  IF v_def IS NULL OR position(v_marker IN v_def) > 0 THEN
    RAISE NOTICE 'admin_bookies_open_markets already builds stat markets (or is missing)';
    RETURN;
  END IF;

  IF position(v_old IN v_def) = 0 THEN
    RAISE NOTICE 'Could not locate final RETURN in admin_bookies_open_markets — stat markets wire skipped';
    RETURN;
  END IF;

  v_new :=
    E'  BEGIN\n'
    || E'    PERFORM public.bookies_open_stat_markets(v_season_id, coalesce(p_refresh, false));\n'
    || E'  EXCEPTION WHEN OTHERS THEN\n'
    || E'    RAISE NOTICE ''bookies_open_stat_markets failed: %'', SQLERRM;\n'
    || E'  END;\n\n'
    || v_old;

  EXECUTE replace(v_def, v_old, v_new);
  RAISE NOTICE 'Wired stat markets into admin_bookies_open_markets';
EXCEPTION
  WHEN OTHERS THEN
    RAISE NOTICE 'Stat markets wire failed: %', SQLERRM;
END;
$wire$;

-- Clean up existing player markets, then create the new ones
DO $$
DECLARE
  b record;
  v_ledger bigint;
  m record;
  v_have int;
BEGIN
  -- 1) Void + refund open bets on ineligible players
  FOR b IN
    SELECT bb.*, mk.title AS market_title, s.label AS sel_label
    FROM public.bookies_bets bb
    JOIN public.bookies_markets mk ON mk.id = bb.market_id
    JOIN public.bookies_selections s ON s.id = bb.selection_id
    WHERE mk.market_kind = 'player'
      AND bb.status = 'open'
      AND NOT public.bookies_player_eligible(mk.market_code, s.selection_key)
    ORDER BY bb.id
    FOR UPDATE OF bb
  LOOP
    v_ledger := public._post_owner_ledger_internal(
      b.owner_id,
      'bookies_expenditure',
      abs(b.stake),
      format('Bookies bet void (player not eligible for market): %s — %s (stake ₿%s)',
             b.market_title, b.sel_label, to_char(b.stake, 'FM999999990.00')),
      jsonb_build_object(
        'bookies', true, 'bet_id', b.id, 'market_id', b.market_id,
        'refund', true, 'reason', 'ineligible_position',
        'club_short_name', b.club_short_name
      ),
      b.season_id
    );
    UPDATE public.bookies_bets
    SET status = 'void',
        settled_at = now(),
        metadata = coalesce(metadata, '{}'::jsonb) || jsonb_build_object(
          'void_reason', 'ineligible_position',
          'refund_ledger_id', v_ledger
        )
    WHERE id = b.id;
  END LOOP;

  -- 2) Remove ineligible selections; keep (hidden) the ones with bet history
  DELETE FROM public.bookies_selections s
  USING public.bookies_markets mk
  WHERE mk.id = s.market_id
    AND mk.market_kind = 'player'
    AND mk.status IN ('open', 'closed')
    AND NOT public.bookies_player_eligible(mk.market_code, s.selection_key)
    AND NOT EXISTS (SELECT 1 FROM public.bookies_bets bb WHERE bb.selection_id = s.id);

  UPDATE public.bookies_selections s
  SET metadata = coalesce(s.metadata, '{}'::jsonb) || jsonb_build_object('withdrawn', true)
  FROM public.bookies_markets mk
  WHERE mk.id = s.market_id
    AND mk.market_kind = 'player'
    AND mk.status IN ('open', 'closed')
    AND NOT public.bookies_player_eligible(mk.market_code, s.selection_key);

  -- 3) Top scorer markets back up to 40 eligible players (by rating)
  FOR m IN
    SELECT * FROM public.bookies_markets
    WHERE market_kind = 'player' AND status IN ('open', 'closed')
      AND market_code LIKE 'scorer%'
  LOOP
    SELECT count(*) INTO v_have
    FROM public.bookies_selections s
    WHERE s.market_id = m.id
      AND NOT coalesce((s.metadata->>'withdrawn')::boolean, false);

    IF v_have < 40 THEN
      INSERT INTO public.bookies_selections
        (market_id, selection_key, label, odds_decimal, sort_order, weight, metadata)
      SELECT
        m.id,
        x.player_id,
        x.player_name || ' (' || x.club || ')',
        10.00,
        v_have + row_number() OVER (ORDER BY x.w DESC, x.player_name)::int,
        x.w,
        jsonb_build_object('club', x.club, 'backfill', true)
      FROM (
        SELECT
          p."Konami_ID"::text AS player_id,
          p."Name" AS player_name,
          public.player_contracted_club_key(p."Contracted_Team") AS club,
          greatest(0.5, public.bookies_player_rating_num(p."Rating"::text) / 40.0) AS w
        FROM public."Players" p
        WHERE coalesce(btrim(public.player_contracted_club_key(p."Contracted_Team")), '') <> ''
          AND EXISTS (
            SELECT 1 FROM public."Clubs" c
            WHERE c."ShortName" = public.player_contracted_club_key(p."Contracted_Team")
          )
          AND public.bookies_position_eligible(m.market_code, p."Position"::text)
          AND NOT EXISTS (
            SELECT 1 FROM public.bookies_selections s2
            WHERE s2.market_id = m.id AND s2.selection_key = p."Konami_ID"::text
          )
        ORDER BY w DESC, p."Name"
        LIMIT (40 - v_have)
      ) x;
    END IF;

    PERFORM public.bookies_apply_odds_from_weights(m.id);
  END LOOP;

  -- 4) New markets for the current season (refreshes them if they already exist)
  PERFORM public.bookies_open_stat_markets(NULL, true);
END $$;

NOTIFY pgrst, 'reload schema';

-- Report: each player market — options, withdrawn, positions still offered
SELECT mk.market_code, mk.title,
       (public.bookies_market_state(mk.id)->>'running')::boolean AS running,
       count(s.id) FILTER (WHERE NOT coalesce((s.metadata->>'withdrawn')::boolean, false)) AS options,
       count(s.id) FILTER (WHERE coalesce((s.metadata->>'withdrawn')::boolean, false)) AS withdrawn,
       string_agg(DISTINCT upper(p."Position"::text), ', ')
         FILTER (WHERE NOT coalesce((s.metadata->>'withdrawn')::boolean, false)) AS positions,
       (SELECT count(*) FROM public.bookies_bets bb
        WHERE bb.market_id = mk.id
          AND bb.metadata->>'void_reason' IN ('non_scoring_position', 'ineligible_position')) AS bets_refunded
FROM public.bookies_markets mk
LEFT JOIN public.bookies_selections s ON s.market_id = mk.id
LEFT JOIN public."Players" p ON p."Konami_ID"::text = s.selection_key
WHERE mk.market_kind = 'player' AND mk.status IN ('open', 'closed')
  AND mk.season_id = (SELECT id FROM public.competition_seasons WHERE is_current ORDER BY id DESC LIMIT 1)
GROUP BY mk.id, mk.market_code, mk.title
ORDER BY mk.id;
