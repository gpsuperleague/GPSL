-- =============================================================================
-- Bookies: much shorter starting odds on every market
--
-- Markets were priced as total weight ÷ own weight across the whole field,
-- so most selections opened at very long prices. Every market now opens on a
-- rank ladder (rank by the selection's weight).
--
-- Player markets (top scorers):
--   1st 3-1 · 2nd 7-2 · 3rd 4-1 · 4th 9-2 · 5th 5-1 · 6-7th 6-1 · 8-10th 8-1
--   11-15th 10-1 · 16-20th 14-1 · 21-30th 20-1 · 31st+ 25-1
-- Club markets (league champions, cup winners):
--   1st 2-1 · 2nd 5-2 · 3rd 3-1 · 4th 7-2 · 5th 4-1 · 6th 5-1 · 7-8th 6-1
--   9-10th 8-1 · 11-14th 10-1 · 15-20th 14-1 · 21st+ 20-1
--   Cup markets rank only clubs in the draw (when bookies_market_state exists);
--   clubs outside the draw sit at 50-1 and can't be backed anyway.
-- Club strength (who is favourite), each part scored 0–1 against all clubs:
--   Season 1:        60% friendlies · 20% squad · 20% prestige · 0% owner
--   Season 2 onward: 50% owner ranking · 20% friendlies · 15% squad · 15% prestige
--   Friendlies = June + July confirmed results (points per game, then goal
--   difference per game). Squad = average rating of best 16 players.
--   Owner = rolling-4 owner ranking. Prestige = club prestige rank.
--   A club missing a part (no friendlies / no owner history) has that part's
--   share spread across the parts it does have.
-- Money on a selection still shortens its price (same ₿20 ≈ +1 weight steam).
-- Safe re-run. Re-prices every open/closed market at the end.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.bookies_player_rank_price(p_rank int)
RETURNS numeric
LANGUAGE sql
IMMUTABLE
AS $function$
  SELECT CASE
    WHEN p_rank <= 1 THEN 4.00   -- 3-1
    WHEN p_rank = 2 THEN 4.50    -- 7-2
    WHEN p_rank = 3 THEN 5.00    -- 4-1
    WHEN p_rank = 4 THEN 5.50    -- 9-2
    WHEN p_rank = 5 THEN 6.00    -- 5-1
    WHEN p_rank <= 7 THEN 7.00   -- 6-1
    WHEN p_rank <= 10 THEN 9.00  -- 8-1
    WHEN p_rank <= 15 THEN 11.00 -- 10-1
    WHEN p_rank <= 20 THEN 15.00 -- 14-1
    WHEN p_rank <= 30 THEN 21.00 -- 20-1
    ELSE 26.00                   -- 25-1
  END::numeric;
$function$;

CREATE OR REPLACE FUNCTION public.bookies_club_rank_price(p_rank int)
RETURNS numeric
LANGUAGE sql
IMMUTABLE
AS $function$
  SELECT CASE
    WHEN p_rank IS NULL THEN 51.00 -- 50-1 (not in the draw)
    WHEN p_rank <= 1 THEN 3.00   -- 2-1
    WHEN p_rank = 2 THEN 3.50    -- 5-2
    WHEN p_rank = 3 THEN 4.00    -- 3-1
    WHEN p_rank = 4 THEN 4.50    -- 7-2
    WHEN p_rank = 5 THEN 5.00    -- 4-1
    WHEN p_rank = 6 THEN 6.00    -- 5-1
    WHEN p_rank <= 8 THEN 7.00   -- 6-1
    WHEN p_rank <= 10 THEN 9.00  -- 8-1
    WHEN p_rank <= 14 THEN 11.00 -- 10-1
    WHEN p_rank <= 20 THEN 15.00 -- 14-1
    ELSE 21.00                   -- 20-1
  END::numeric;
$function$;

-- Weight 1 (weakest) … 40 (strongest), comparable across all clubs
CREATE OR REPLACE FUNCTION public.bookies_club_strength(
  p_club_short_name text,
  p_season_id bigint
)
RETURNS numeric
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := upper(btrim(coalesce(p_club_short_name, '')));
  v_first_season boolean;
  v_avg numeric;
  v_min numeric;
  v_max numeric;
  v_rank int;
  v_n int;
  v_fr numeric;
  v_squad_pct numeric := 0;
  v_owner_pct numeric := NULL;
  v_prestige_pct numeric := NULL;
  v_friendly_pct numeric := NULL;
  w_owner numeric;
  w_friendly numeric;
  w_squad numeric;
  w_prestige numeric;
  v_total_w numeric := 0;
  v_score numeric := 0;
BEGIN
  v_first_season := NOT EXISTS (
    SELECT 1 FROM public.competition_seasons s
    WHERE s.status = 'complete'
      AND s.id < coalesce(p_season_id, 9223372036854775807)
  );

  IF v_first_season THEN
    w_owner := 0;    w_friendly := 0.60; w_squad := 0.20; w_prestige := 0.20;
  ELSE
    w_owner := 0.50; w_friendly := 0.20; w_squad := 0.15; w_prestige := 0.15;
  END IF;

  -- Friendlies: June + July confirmed results this season
  WITH games AS (
    SELECT upper(btrim(f.club_left)) AS club, f.score_left AS gf, f.score_right AS ga
    FROM public.gpsl_friendlies f
    WHERE f.season_id = p_season_id AND lower(f.gpsl_month) IN ('june', 'july')
    UNION ALL
    SELECT upper(btrim(f.club_right)), f.score_right, f.score_left
    FROM public.gpsl_friendlies f
    WHERE f.season_id = p_season_id AND lower(f.gpsl_month) IN ('june', 'july')
  ),
  form AS (
    SELECT club,
           avg(CASE WHEN gf > ga THEN 3 WHEN gf = ga THEN 1 ELSE 0 END)
             + 0.1 * avg(gf - ga) AS score
    FROM games
    GROUP BY club
  )
  SELECT (SELECT score FROM form WHERE club = v_club), min(score), max(score)
  INTO v_fr, v_min, v_max
  FROM form;

  IF v_fr IS NOT NULL THEN
    v_friendly_pct := CASE WHEN v_max > v_min THEN (v_fr - v_min) / (v_max - v_min) ELSE 0.5 END;
  END IF;

  -- Prestige: rank 1 = best
  SELECT p.prestige_rank::int INTO v_rank
  FROM public.competition_club_prestige_public p
  WHERE upper(p.club_short_name) = v_club
  LIMIT 1;
  IF v_rank IS NOT NULL THEN
    SELECT greatest(max(p.prestige_rank)::int, 2) INTO v_n
    FROM public.competition_club_prestige_public p;
    v_prestige_pct := greatest(0, least(1, (v_n - v_rank)::numeric / (v_n - 1)));
  END IF;
  v_rank := NULL;

  -- Squad: average rating of the best 16 contracted players
  WITH rated AS (
    SELECT
      upper(btrim(public.player_contracted_club_key(p."Contracted_Team"))) AS club,
      public.bookies_player_rating_num(p."Rating"::text) AS rating
    FROM public."Players" p
    WHERE coalesce(btrim(public.player_contracted_club_key(p."Contracted_Team")), '') <> ''
  ),
  ranked AS (
    SELECT r.club, r.rating,
           row_number() OVER (PARTITION BY r.club ORDER BY r.rating DESC) AS rn
    FROM rated r
    WHERE EXISTS (SELECT 1 FROM public."Clubs" c WHERE upper(c."ShortName") = r.club)
  ),
  squads AS (
    SELECT club, avg(rating) AS avg_r
    FROM ranked
    WHERE rn <= 16
    GROUP BY club
  )
  SELECT
    (SELECT avg_r FROM squads WHERE club = v_club),
    min(avg_r),
    max(avg_r)
  INTO v_avg, v_min, v_max
  FROM squads;

  IF v_avg IS NOT NULL AND v_max > v_min THEN
    v_squad_pct := (v_avg - v_min) / (v_max - v_min);
  ELSIF v_avg IS NOT NULL THEN
    v_squad_pct := 0.5;
  END IF;

  -- Owner: rolling-4 owner ranking (only weighted after Season 1)
  IF w_owner > 0 THEN
    SELECT r.rank_position::int INTO v_rank
    FROM public.competition_owner_ranking_rolling4_public r
    WHERE upper(r.club_short_name) = v_club
    ORDER BY r.rank_position
    LIMIT 1;
    IF v_rank IS NOT NULL THEN
      SELECT greatest(max(r.rank_position)::int, 2) INTO v_n
      FROM public.competition_owner_ranking_rolling4_public r;
      v_owner_pct := greatest(0, least(1, (v_n - v_rank)::numeric / (v_n - 1)));
    END IF;
  END IF;

  v_total_w := w_squad;
  v_score := w_squad * v_squad_pct;
  IF v_friendly_pct IS NOT NULL THEN
    v_total_w := v_total_w + w_friendly;
    v_score := v_score + w_friendly * v_friendly_pct;
  END IF;
  IF v_prestige_pct IS NOT NULL THEN
    v_total_w := v_total_w + w_prestige;
    v_score := v_score + w_prestige * v_prestige_pct;
  END IF;
  IF v_owner_pct IS NOT NULL THEN
    v_total_w := v_total_w + w_owner;
    v_score := v_score + w_owner * v_owner_pct;
  END IF;

  RETURN round(1 + 39 * (v_score / greatest(v_total_w, 0.01)), 2);
END;
$function$;

-- Old one-argument form (used by admin_bookies_open_markets) → current season
CREATE OR REPLACE FUNCTION public.bookies_club_strength(p_club_short_name text)
RETURNS numeric
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
  SELECT public.bookies_club_strength(
    p_club_short_name,
    (SELECT id FROM public.competition_seasons WHERE is_current = true ORDER BY id DESC LIMIT 1)
  );
$function$;

GRANT EXECUTE ON FUNCTION public.bookies_club_strength(text, bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.bookies_club_strength(text) TO authenticated;

-- Recompute club strengths in place (keeps bets) and reprice. Admin or SQL editor.
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
           public.bookies_club_strength(s.selection_key, m.season_id) AS strength
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
      sort_order = o.so
  FROM o
  WHERE s.id = o.id;

  FOR r IN
    SELECT id FROM public.bookies_markets
    WHERE season_id = v_season AND status IN ('open', 'closed')
  LOOP
    PERFORM public.bookies_apply_odds_from_weights(r.id);
    v_n := v_n + 1;
  END LOOP;

  RETURN jsonb_build_object('season_id', v_season, 'markets_repriced', v_n);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.admin_bookies_recompute_club_odds(bigint) TO authenticated;

-- Each confirmed June/July friendly re-prices that season's club markets.
-- Never blocks the friendly itself.
CREATE OR REPLACE FUNCTION public.trg_gpsl_friendlies_bookies_reprice()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF lower(coalesce(NEW.gpsl_month, '')) IN ('june', 'july')
     AND EXISTS (
       SELECT 1 FROM public.bookies_markets m
       WHERE m.season_id = NEW.season_id
         AND m.market_kind = 'club'
         AND m.status IN ('open', 'closed')
     ) THEN
    BEGIN
      PERFORM public.admin_bookies_recompute_club_odds(NEW.season_id);
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'bookies reprice after friendly % failed: %', NEW.id, SQLERRM;
    END;
  END IF;
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS gpsl_friendlies_bookies_reprice ON public.gpsl_friendlies;
CREATE TRIGGER gpsl_friendlies_bookies_reprice
  AFTER INSERT ON public.gpsl_friendlies
  FOR EACH ROW EXECUTE FUNCTION public.trg_gpsl_friendlies_bookies_reprice();

CREATE OR REPLACE FUNCTION public.bookies_apply_odds_from_weights(p_market_id bigint)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  -- Every ₿20 matched ≈ +1 weight (shortens that selection)
  v_steam_div numeric := 20;
  v_kind text;
  v_draw jsonb := NULL;
  r record;
  v_eff numeric;
  v_raw numeric;
  v_odds numeric;
BEGIN
  SELECT lower(coalesce(market_kind, '')) INTO v_kind
  FROM public.bookies_markets WHERE id = p_market_id;

  IF v_kind = 'player' THEN
    FOR r IN
      SELECT
        s.id,
        greatest(s.weight, 0.25) AS base_w,
        public.bookies_selection_open_stakes(s.id) AS steam,
        row_number() OVER (ORDER BY s.weight DESC NULLS LAST, s.sort_order, s.id)::int AS rnk
      FROM public.bookies_selections s
      WHERE s.market_id = p_market_id
    LOOP
      v_eff := r.base_w + (r.steam / v_steam_div);
      -- Rank price, then steam shortens the profit part in proportion
      v_raw := 1 + (public.bookies_player_rank_price(r.rnk) - 1) * (r.base_w / v_eff);
      v_odds := public.bookies_snap_uk_odds(v_raw);

      UPDATE public.bookies_selections
      SET odds_decimal = v_odds,
          metadata = coalesce(metadata, '{}'::jsonb) || jsonb_build_object(
            'steam_stakes', r.steam,
            'effective_weight', round(v_eff, 2),
            'odds_ladder', 'uk_player_rank',
            'price_rank', r.rnk,
            'odds_moved', true
          )
      WHERE id = r.id;
    END LOOP;
    RETURN;
  END IF;

  IF to_regprocedure('public.bookies_market_state(bigint)') IS NOT NULL THEN
    EXECUTE 'SELECT public.bookies_market_state($1)->''cup_clubs''' INTO v_draw USING p_market_id;
    IF jsonb_typeof(v_draw) IS DISTINCT FROM 'array' THEN
      v_draw := NULL;
    ELSIF jsonb_array_length(v_draw) = 0 THEN
      v_draw := NULL;
    END IF;
  END IF;

  FOR r IN
    WITH sel AS (
      SELECT
        s.id,
        s.weight,
        s.sort_order,
        greatest(s.weight, 0.25) AS base_w,
        public.bookies_selection_open_stakes(s.id) AS steam,
        (v_draw IS NULL OR v_draw ? upper(btrim(s.selection_key))) AS in_draw
      FROM public.bookies_selections s
      WHERE s.market_id = p_market_id
    )
    SELECT
      sel.*,
      CASE WHEN sel.in_draw THEN
        row_number() OVER (
          PARTITION BY sel.in_draw
          ORDER BY sel.weight DESC NULLS LAST, sel.sort_order, sel.id
        )::int
      END AS rnk
    FROM sel
  LOOP
    v_eff := r.base_w + (r.steam / v_steam_div);
    v_raw := 1 + (public.bookies_club_rank_price(r.rnk) - 1) * (r.base_w / v_eff);
    v_odds := public.bookies_snap_uk_odds(v_raw);

    UPDATE public.bookies_selections
    SET odds_decimal = v_odds,
        metadata = coalesce(metadata, '{}'::jsonb) || jsonb_build_object(
          'steam_stakes', r.steam,
          'effective_weight', round(v_eff, 2),
          'odds_ladder', 'uk_club_rank',
          'price_rank', r.rnk,
          'odds_moved', true
        )
    WHERE id = r.id;
  END LOOP;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.bookies_apply_odds_from_weights(bigint) TO authenticated;

-- Recompute club weights on the current season's club markets
SELECT public.admin_bookies_recompute_club_odds(NULL);

DO $$
DECLARE
  r record;
BEGIN
  FOR r IN
    SELECT id FROM public.bookies_markets WHERE status IN ('open', 'closed')
  LOOP
    PERFORM public.bookies_apply_odds_from_weights(r.id);
  END LOOP;
END $$;

NOTIFY pgrst, 'reload schema';

-- Report: top 8 prices in each market
SELECT m.title, m.market_kind, s.label,
       public.bookies_fractional_odds_label(s.odds_decimal) AS odds,
       (s.metadata->>'price_rank')::int AS price_rank,
       s.weight AS strength
FROM public.bookies_markets m
JOIN public.bookies_selections s ON s.market_id = m.id
WHERE m.status IN ('open', 'closed')
  AND coalesce((s.metadata->>'price_rank')::int, 99) <= 8
ORDER BY m.market_kind, m.id, (s.metadata->>'price_rank')::int;
