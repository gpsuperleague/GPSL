-- =============================================================================
-- Bookies club strength — controlled friendly impact (2026-10-18)
--
-- Still uses ALL confirmed June + July friendlies pooled (both preseason months).
--
-- Changes vs prior:
--   1) Clubs with ZERO friendlies get a low fixed friendly score (not NULL / not skipped)
--   2) Minimum games before full friendly credit (blend toward the low floor)
--   3) Cap friendly separation so one hot preseason cannot dominate the market
--
-- Then recomputes open/closed club-market odds if the recompute RPC exists.
-- Safe re-run.
-- =============================================================================

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
  v_games int := 0;
  v_squad_pct numeric := 0;
  v_owner_pct numeric := NULL;
  v_prestige_pct numeric := NULL;
  v_friendly_pct numeric := NULL;
  v_credit numeric;
  -- Tunables ---------------------------------------------------------------
  -- Low fixed friendly percentile for clubs that played no June/July games
  c_no_play numeric := 0.15;
  -- Full friendly credit only after this many confirmed June/July games
  c_min_games numeric := 4;
  -- After scaling, compress friendly axis into this band (cap separation)
  c_floor numeric := 0.30;
  c_ceil  numeric := 0.70;
  -- ------------------------------------------------------------------------
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

  -- Friendlies: June + July confirmed results this season (pooled)
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
    SELECT
      club,
      count(*)::int AS games,
      avg(CASE WHEN gf > ga THEN 3 WHEN gf = ga THEN 1 ELSE 0 END)
        + 0.1 * avg(gf - ga) AS score
    FROM games
    GROUP BY club
  )
  SELECT
    (SELECT score FROM form WHERE club = v_club),
    (SELECT games FROM form WHERE club = v_club),
    min(score),
    max(score)
  INTO v_fr, v_games, v_min, v_max
  FROM form;

  v_games := coalesce(v_games, 0);

  IF v_games <= 0 OR v_fr IS NULL THEN
    -- Non-players: low fixed score (still participates on the friendly axis)
    v_friendly_pct := c_no_play;
  ELSE
    -- Among clubs that played: min–max form → 0..1
    v_friendly_pct := CASE
      WHEN v_max > v_min THEN (v_fr - v_min) / (v_max - v_min)
      ELSE 0.5
    END;
    -- Minimum games before full credit (blend toward no-play floor)
    v_credit := least(1.0, v_games::numeric / greatest(c_min_games, 1));
    v_friendly_pct := c_no_play + (v_friendly_pct - c_no_play) * v_credit;
  END IF;

  -- Cap how far friendlies can separate clubs
  v_friendly_pct := c_floor + (c_ceil - c_floor) * greatest(0, least(1, v_friendly_pct));

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

  -- Friendly axis always counts now (never skipped)
  v_total_w := w_squad + w_friendly;
  v_score := w_squad * v_squad_pct + w_friendly * v_friendly_pct;

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

-- Refresh club market odds from the new strength formula
DO $recompute$
DECLARE
  v_season bigint;
  v_res jsonb;
BEGIN
  SELECT id INTO v_season
  FROM public.competition_seasons
  WHERE is_current = true
  ORDER BY id DESC
  LIMIT 1;

  IF v_season IS NULL THEN
    RAISE NOTICE 'No current season — odds recompute skipped';
    RETURN;
  END IF;

  IF to_regprocedure('public.admin_bookies_recompute_club_odds(bigint)') IS NULL THEN
    RAISE NOTICE 'admin_bookies_recompute_club_odds missing — apply odds patch later';
    RETURN;
  END IF;

  v_res := public.admin_bookies_recompute_club_odds(v_season);
  RAISE NOTICE 'bookies club odds recomputed: %', v_res;
EXCEPTION
  WHEN OTHERS THEN
    RAISE NOTICE 'bookies recompute skipped: %', SQLERRM;
END
$recompute$;

NOTIFY pgrst, 'reload schema';

COMMENT ON FUNCTION public.bookies_club_strength(text, bigint) IS
  'Club strength for bookies. Friendlies = pooled June+July. Non-players get low fixed friendly score; <4 games blend toward that floor; friendly axis capped to ~0.30–0.70.';
