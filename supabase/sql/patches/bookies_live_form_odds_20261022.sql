-- =============================================================================
-- Bookies: in-season board odds (table / cup / stats) — 2026-10-22
-- =============================================================================
-- Early bets already lock slip odds at place time. This patch moves the *board*
-- as the season progresses:
--   • League title markets → current table position takes over friendlies
--   • Cup winner markets   → cup progress (alive + round) takes over
--   • Player markets       → current goals / assists / clean sheets charts
--   • Friendlies fade once competitive matches are played (share scales with
--     games played; ~8 league games ≈ 90% live form)
-- Reprice runs after each competitive result and via admin Refresh odds.
-- Safe re-run.
-- =============================================================================

-- Share of weight that comes from live form (0 = preseason only, ~0.9 mid season)
CREATE OR REPLACE FUNCTION public.bookies_live_share(
  p_season_id bigint,
  p_division text DEFAULT NULL
)
RETURNS numeric
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_avg_mp numeric := 0;
BEGIN
  IF p_division IS NOT NULL AND btrim(p_division) <> '' THEN
    SELECT coalesce(avg(s.mp), 0) INTO v_avg_mp
    FROM public.competition_standings_public s
    WHERE s.season_id = p_season_id
      AND s.division = p_division;
  ELSE
    SELECT coalesce(avg(s.mp), 0) INTO v_avg_mp
    FROM public.competition_standings_public s
    WHERE s.season_id = p_season_id;
  END IF;

  -- No league games yet: keep preseason (friendlies / squad / prestige)
  IF v_avg_mp <= 0 THEN
    RETURN 0;
  END IF;

  -- After ~8 games played on average, live form is ~90% of the price
  RETURN least(0.90, greatest(0, v_avg_mp / 8.0));
END;
$function$;

GRANT EXECUTE ON FUNCTION public.bookies_live_share(bigint, text) TO authenticated;

-- 0..1 from current league table (1st ≈ 1.0)
CREATE OR REPLACE FUNCTION public.bookies_league_table_pct(
  p_season_id bigint,
  p_division text,
  p_club_short_name text
)
RETURNS numeric
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := upper(btrim(coalesce(p_club_short_name, '')));
  v_pos int;
  v_n int;
  v_pts numeric;
  v_min numeric;
  v_max numeric;
  v_rank_pct numeric;
  v_pts_pct numeric;
BEGIN
  IF v_club = '' OR p_division IS NULL THEN
    RETURN NULL;
  END IF;

  SELECT s.table_position, s.pts
  INTO v_pos, v_pts
  FROM public.competition_standings_public s
  WHERE s.season_id = p_season_id
    AND s.division = p_division
    AND upper(btrim(s.club_short_name)) = v_club
  LIMIT 1;

  IF v_pos IS NULL THEN
    RETURN NULL;
  END IF;

  SELECT count(*)::int, min(s.pts), max(s.pts)
  INTO v_n, v_min, v_max
  FROM public.competition_standings_public s
  WHERE s.season_id = p_season_id AND s.division = p_division;

  v_n := greatest(coalesce(v_n, 1), 2);
  v_rank_pct := greatest(0, least(1, (v_n - v_pos)::numeric / (v_n - 1)));

  IF v_max IS DISTINCT FROM v_min AND v_max > v_min THEN
    v_pts_pct := greatest(0, least(1, (v_pts - v_min) / (v_max - v_min)));
  ELSE
    v_pts_pct := v_rank_pct;
  END IF;

  -- Rank matters most for title odds; points gap still moves the board
  RETURN round(0.65 * v_rank_pct + 0.35 * v_pts_pct, 4);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.bookies_league_table_pct(bigint, text, text) TO authenticated;

-- 0..1 from cup progress (eliminated low; deeper + still alive high)
CREATE OR REPLACE FUNCTION public.bookies_cup_progress_pct(
  p_season_id bigint,
  p_cup_code text,
  p_club_short_name text
)
RETURNS numeric
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := upper(btrim(coalesce(p_club_short_name, '')));
  v_cup text := lower(btrim(coalesce(p_cup_code, '')));
  v_max_round int := 0;
  v_cup_max int := 0;
  v_alive boolean := false;
  v_in_draw boolean := false;
  v_round_pct numeric;
BEGIN
  IF v_club = '' OR v_cup = '' THEN
    RETURN NULL;
  END IF;

  SELECT EXISTS (
    SELECT 1
    FROM public.competition_fixtures f
    WHERE f.season_id = p_season_id
      AND f.competition_type = 'cup'
      AND lower(coalesce(f.cup_code, '')) = v_cup
      AND (
        upper(btrim(f.home_club_short_name)) = v_club
        OR upper(btrim(f.away_club_short_name)) = v_club
      )
  ) INTO v_in_draw;

  IF NOT v_in_draw THEN
    RETURN NULL;
  END IF;

  SELECT coalesce(max(f.cup_round), 0)
  INTO v_max_round
  FROM public.competition_fixtures f
  WHERE f.season_id = p_season_id
    AND f.competition_type = 'cup'
    AND lower(coalesce(f.cup_code, '')) = v_cup
    AND (
      upper(btrim(f.home_club_short_name)) = v_club
      OR upper(btrim(f.away_club_short_name)) = v_club
    );

  SELECT coalesce(max(f.cup_round), 1)
  INTO v_cup_max
  FROM public.competition_fixtures f
  WHERE f.season_id = p_season_id
    AND f.competition_type = 'cup'
    AND lower(coalesce(f.cup_code, '')) = v_cup;

  v_cup_max := greatest(v_cup_max, 1);
  v_round_pct := greatest(0, least(1, v_max_round::numeric / v_cup_max::numeric));

  SELECT EXISTS (
    SELECT 1
    FROM public.competition_fixtures f
    WHERE f.season_id = p_season_id
      AND f.competition_type = 'cup'
      AND lower(coalesce(f.cup_code, '')) = v_cup
      AND coalesce(f.status, '') <> 'played'
      AND (
        upper(btrim(f.home_club_short_name)) = v_club
        OR upper(btrim(f.away_club_short_name)) = v_club
      )
  ) INTO v_alive;

  -- Won the cup (appeared in final round, no pending ties, and marked winner if available)
  IF NOT v_alive AND v_max_round >= v_cup_max THEN
    IF EXISTS (
      SELECT 1
      FROM public.competition_fixtures f
      WHERE f.season_id = p_season_id
        AND f.competition_type = 'cup'
        AND lower(coalesce(f.cup_code, '')) = v_cup
        AND f.cup_round = v_cup_max
        AND f.status = 'played'
        AND (
          (upper(btrim(f.home_club_short_name)) = v_club
            AND coalesce(f.home_goals, -1) > coalesce(f.away_goals, -1))
          OR (upper(btrim(f.away_club_short_name)) = v_club
            AND coalesce(f.away_goals, -1) > coalesce(f.home_goals, -1))
          OR upper(btrim(coalesce(f.cup_pen_winner_club_short_name, ''))) = v_club
        )
    ) THEN
      RETURN 1.0;
    END IF;
  END IF;

  IF v_alive THEN
    RETURN round(0.45 + 0.55 * v_round_pct, 4);
  END IF;

  -- Eliminated: deep run still better than early exit, but far below survivors
  RETURN round(0.04 + 0.18 * v_round_pct, 4);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.bookies_cup_progress_pct(bigint, text, text) TO authenticated;

-- Market-aware club weight (preseason strength blended with live form)
CREATE OR REPLACE FUNCTION public.bookies_club_market_weight(
  p_market_id bigint,
  p_club_short_name text
)
RETURNS numeric
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
  v_pre numeric;
  v_live_pct numeric := NULL;
  v_share numeric := 0;
  v_live numeric;
BEGIN
  SELECT * INTO m FROM public.bookies_markets WHERE id = p_market_id;
  IF NOT FOUND THEN
    RETURN public.bookies_club_strength(p_club_short_name);
  END IF;

  v_pre := public.bookies_club_strength(p_club_short_name, m.season_id);
  v_code := lower(coalesce(m.market_code, ''));
  v_div := nullif(btrim(coalesce(m.metadata->>'division', '')), '');

  IF v_code LIKE 'league_%' AND v_div IS NOT NULL THEN
    v_live_pct := public.bookies_league_table_pct(m.season_id, v_div, p_club_short_name);
    v_share := public.bookies_live_share(m.season_id, v_div);
  ELSIF v_code LIKE 'cup_%' THEN
    v_cup := substring(v_code FROM 5);
    v_live_pct := public.bookies_cup_progress_pct(m.season_id, v_cup, p_club_short_name);
    -- Cup share: how far the competition has progressed
    SELECT least(
      0.92,
      greatest(
        0,
        (
          SELECT count(*) FILTER (WHERE f.status = 'played')::numeric
                 / greatest(count(*)::numeric, 1)
          FROM public.competition_fixtures f
          WHERE f.season_id = m.season_id
            AND f.competition_type = 'cup'
            AND lower(coalesce(f.cup_code, '')) = v_cup
        )
      )
    ) INTO v_share;
    -- Until the cup has results, lean on preseason; once ties are played, progress dominates
    v_share := greatest(v_share, public.bookies_live_share(m.season_id, NULL) * 0.5);
  ELSE
    -- Generic club market: mild league-form blend
    v_live_pct := public.bookies_league_table_pct(
      m.season_id,
      coalesce(
        (SELECT ccs.division
         FROM public.competition_club_seasons ccs
         WHERE ccs.season_id = m.season_id
           AND upper(btrim(ccs.club_short_name)) = upper(btrim(p_club_short_name))
         LIMIT 1),
        'superleague'
      ),
      p_club_short_name
    );
    v_share := public.bookies_live_share(m.season_id, NULL) * 0.75;
  END IF;

  IF v_live_pct IS NULL OR v_share <= 0 THEN
    RETURN v_pre;
  END IF;

  v_live := 1 + 39 * greatest(0, least(1, v_live_pct));
  RETURN round((1 - v_share) * v_pre + v_share * v_live, 2);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.bookies_club_market_weight(bigint, text) TO authenticated;

-- Player chart weight for an existing selection (goals / assists / CS)
CREATE OR REPLACE FUNCTION public.bookies_player_live_weight(
  p_market_id bigint,
  p_player_id text
)
RETURNS numeric
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  m public.bookies_markets%rowtype;
  v_code text;
  v_stat numeric := 0;
  v_rating numeric := 0;
  v_club text;
BEGIN
  SELECT * INTO m FROM public.bookies_markets WHERE id = p_market_id;
  IF NOT FOUND THEN
    RETURN 0.5;
  END IF;

  v_code := lower(coalesce(m.market_code, ''));

  SELECT public.bookies_player_rating_num(p."Rating"::text),
         public.player_contracted_club_key(p."Contracted_Team")
  INTO v_rating, v_club
  FROM public."Players" p
  WHERE p."Konami_ID"::text = p_player_id
  LIMIT 1;

  IF v_code LIKE 'assists%' THEN
    SELECT coalesce(sum(st.assists), 0)::numeric INTO v_stat
    FROM public.competition_player_season_stats_public st
    WHERE st.season_id = m.season_id AND st.player_id = p_player_id;
    RETURN greatest(0.5, v_stat * 4 + coalesce(v_rating, 0) / 50.0);
  END IF;

  IF v_code LIKE 'clean_sheets%' THEN
    SELECT coalesce(sum(st.clean_sheets), 0)::numeric INTO v_stat
    FROM public.competition_player_season_stats_public st
    WHERE st.season_id = m.season_id AND st.player_id = p_player_id;
    RETURN greatest(0.5, v_stat * 5 + coalesce(v_rating, 0) / 55.0);
  END IF;

  IF v_code = 'scorer_overall' THEN
    SELECT coalesce(st.goals, 0)::numeric INTO v_stat
    FROM public.competition_player_season_stats_public st
    WHERE st.season_id = m.season_id AND st.player_id = p_player_id
    LIMIT 1;
    RETURN greatest(0.5, coalesce(v_stat, 0) * 3 + coalesce(v_rating, 0) / 40.0);
  END IF;

  IF v_code = 'scorer_league_cup' THEN
    SELECT coalesce(sum(mps.goals), 0)::numeric INTO v_stat
    FROM public.competition_match_player_stats mps
    JOIN public.competition_fixtures f ON f.id = mps.fixture_id
    WHERE mps.season_id = m.season_id
      AND mps.player_id = p_player_id
      AND f.competition_type = 'cup'
      AND lower(coalesce(f.cup_code, '')) = 'league_cup';
    RETURN greatest(0.5, v_stat * 4 + coalesce(v_rating, 0) / 50.0);
  END IF;

  IF v_code = 'scorer_prestige' THEN
    SELECT coalesce(sum(mps.goals), 0)::numeric INTO v_stat
    FROM public.competition_match_player_stats mps
    JOIN public.competition_fixtures f ON f.id = mps.fixture_id
    WHERE mps.season_id = m.season_id
      AND mps.player_id = p_player_id
      AND f.competition_type = 'cup'
      AND lower(coalesce(f.cup_code, '')) IN ('super8', 'plate', 'shield', 'bowl');
    RETURN greatest(0.5, v_stat * 4 + coalesce(v_rating, 0) / 50.0);
  END IF;

  -- Fallback: overall goals + rating
  SELECT coalesce(st.goals, 0)::numeric INTO v_stat
  FROM public.competition_player_season_stats_public st
  WHERE st.season_id = m.season_id AND st.player_id = p_player_id
  LIMIT 1;
  RETURN greatest(0.5, coalesce(v_stat, 0) * 3 + coalesce(v_rating, 0) / 40.0);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.bookies_player_live_weight(bigint, text) TO authenticated;

-- Recompute club markets with market-aware live weights (keeps bets / selections)
CREATE OR REPLACE FUNCTION public.admin_bookies_recompute_club_odds(p_season_id bigint DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season bigint := p_season_id;
  v_n int := 0;
  r record;
BEGIN
  IF NOT public.is_gpsl_admin()
     AND current_user NOT IN ('postgres', 'supabase_admin', 'service_role') THEN
    RAISE EXCEPTION 'Admin only';
  END IF;
  IF v_season IS NULL THEN
    SELECT id INTO v_season FROM public.competition_seasons
    WHERE is_current = true ORDER BY id DESC LIMIT 1;
  END IF;

  WITH w AS (
    SELECT s.id, s.market_id,
           public.bookies_club_market_weight(s.market_id, s.selection_key) AS strength
    FROM public.bookies_selections s
    JOIN public.bookies_markets m ON m.id = s.market_id
    WHERE m.market_kind = 'club'
      AND m.season_id = v_season
      AND m.status IN ('open', 'closed')
  ),
  o AS (
    SELECT w.*,
           row_number() OVER (PARTITION BY w.market_id ORDER BY w.strength DESC, w.id)::int AS so
    FROM w
  )
  UPDATE public.bookies_selections s
  SET weight = o.strength,
      sort_order = o.so,
      metadata = coalesce(s.metadata, '{}'::jsonb) || jsonb_build_object(
        'live_form', true,
        'weight_source', 'club_market_weight'
      )
  FROM o
  WHERE s.id = o.id;

  FOR r IN
    SELECT id FROM public.bookies_markets
    WHERE season_id = v_season
      AND market_kind = 'club'
      AND status IN ('open', 'closed')
  LOOP
    PERFORM public.bookies_apply_odds_from_weights(r.id);
    v_n := v_n + 1;
  END LOOP;

  RETURN jsonb_build_object('season_id', v_season, 'markets_repriced', v_n);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.admin_bookies_recompute_club_odds(bigint) TO authenticated;

-- Recompute player-market weights from live charts (keeps bets)
CREATE OR REPLACE FUNCTION public.admin_bookies_recompute_player_odds(p_season_id bigint DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season bigint := p_season_id;
  v_n int := 0;
  r record;
BEGIN
  IF NOT public.is_gpsl_admin()
     AND current_user NOT IN ('postgres', 'supabase_admin', 'service_role') THEN
    RAISE EXCEPTION 'Admin only';
  END IF;
  IF v_season IS NULL THEN
    SELECT id INTO v_season FROM public.competition_seasons
    WHERE is_current = true ORDER BY id DESC LIMIT 1;
  END IF;

  WITH w AS (
    SELECT s.id, s.market_id,
           public.bookies_player_live_weight(s.market_id, s.selection_key) AS strength
    FROM public.bookies_selections s
    JOIN public.bookies_markets m ON m.id = s.market_id
    WHERE m.market_kind = 'player'
      AND m.season_id = v_season
      AND m.status IN ('open', 'closed')
      AND coalesce((s.metadata->>'withdrawn')::boolean, false) IS NOT TRUE
  ),
  o AS (
    SELECT w.*,
           row_number() OVER (PARTITION BY w.market_id ORDER BY w.strength DESC, w.id)::int AS so
    FROM w
  )
  UPDATE public.bookies_selections s
  SET weight = o.strength,
      sort_order = o.so,
      metadata = coalesce(s.metadata, '{}'::jsonb) || jsonb_build_object(
        'live_form', true,
        'weight_source', 'player_live_weight'
      )
  FROM o
  WHERE s.id = o.id;

  -- Pull in new chart leaders who are not on the board yet (assists / CS / scorers)
  BEGIN
    PERFORM set_config('gpsl.bookies_preopen_ok', 'on', true);
    IF to_regprocedure('public.bookies_open_stat_markets(bigint,boolean)') IS NOT NULL THEN
      PERFORM public.bookies_open_stat_markets(v_season, true);
    END IF;
    PERFORM set_config('gpsl.bookies_preopen_ok', 'off', true);
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'bookies_open_stat_markets during player recompute: %', SQLERRM;
  END;

  FOR r IN
    SELECT id FROM public.bookies_markets
    WHERE season_id = v_season
      AND market_kind = 'player'
      AND status IN ('open', 'closed')
  LOOP
    PERFORM public.bookies_apply_odds_from_weights(r.id);
    v_n := v_n + 1;
  END LOOP;

  RETURN jsonb_build_object('season_id', v_season, 'markets_repriced', v_n);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.admin_bookies_recompute_player_odds(bigint) TO authenticated;

-- One-shot admin / auto reprice for all open markets
CREATE OR REPLACE FUNCTION public.admin_bookies_recompute_all_odds(p_season_id bigint DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season bigint := p_season_id;
  v_club jsonb;
  v_player jsonb;
BEGIN
  IF NOT public.is_gpsl_admin()
     AND current_user NOT IN ('postgres', 'supabase_admin', 'service_role') THEN
    RAISE EXCEPTION 'Admin only';
  END IF;
  IF v_season IS NULL THEN
    SELECT id INTO v_season FROM public.competition_seasons
    WHERE is_current = true ORDER BY id DESC LIMIT 1;
  END IF;

  v_club := public.admin_bookies_recompute_club_odds(v_season);
  v_player := public.admin_bookies_recompute_player_odds(v_season);

  RETURN jsonb_build_object(
    'ok', true,
    'season_id', v_season,
    'markets_repriced',
      coalesce((v_club->>'markets_repriced')::int, 0)
      + coalesce((v_player->>'markets_repriced')::int, 0),
    'club', v_club,
    'player', v_player
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.admin_bookies_recompute_all_odds(bigint) TO authenticated;

-- After a competitive result, move the board (never blocks the result)
CREATE OR REPLACE FUNCTION public.trg_competition_fixtures_bookies_reprice()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF NEW.status = 'played'
     AND coalesce(OLD.status, '') IS DISTINCT FROM 'played'
     AND coalesce(NEW.competition_type, 'league') IN ('league', 'cup')
     AND EXISTS (
       SELECT 1 FROM public.bookies_markets m
       WHERE m.season_id = NEW.season_id
         AND m.status IN ('open', 'closed')
     ) THEN
    BEGIN
      PERFORM public.admin_bookies_recompute_all_odds(NEW.season_id);
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'bookies reprice after fixture % failed: %', NEW.id, SQLERRM;
    END;
  END IF;
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS competition_fixtures_bookies_reprice ON public.competition_fixtures;
CREATE TRIGGER competition_fixtures_bookies_reprice
  AFTER UPDATE OF status ON public.competition_fixtures
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_competition_fixtures_bookies_reprice();

COMMENT ON FUNCTION public.admin_bookies_recompute_all_odds(bigint) IS
  'Reprice open Bookies markets from live league table, cup progress, and player charts. Placed bets keep slip odds.';
