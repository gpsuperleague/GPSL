-- =============================================================================
-- Club prestige carry-over (2026-10-03)
--
-- Prestige (→ expected finish, stadium tier, commercial band) no longer resets to
-- "results only" after one season. Each new season's rank blends:
--
--   carry-over %  × last season's prestige rank
--   (100 − carry-over %) × results rank (rolling league + cup points, as before)
--
-- Default carry-over 85%. Example: Barca rank 1 finish 18th (results rank ~18)
--   → 0.85 × 1 + 0.15 × 18 = 3.55 → about 4th next season, not mid-table.
--   Santos rank 20 win the league (results rank ~1) → ~17th next season.
-- Repeated bad (or good) seasons keep moving the club, so change is gradual.
--
-- "Last season's prestige" = the locked snapshot of the most recent completed
-- season; Season 1 falls back to the manual seed rank. Admin → Stadium settings.
-- Safe to re-run.
-- =============================================================================

ALTER TABLE public.global_settings
  ADD COLUMN IF NOT EXISTS prestige_carryover_pct numeric(5, 2) NOT NULL DEFAULT 85;

ALTER TABLE public.global_settings
  ALTER COLUMN prestige_carryover_pct SET DEFAULT 85;

-- Move the earlier 70% default to 85% (leaves any other admin-chosen value alone).
UPDATE public.global_settings
SET prestige_carryover_pct = 85
WHERE id = 1 AND prestige_carryover_pct = 70;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'public.global_settings'::regclass
      AND conname = 'global_settings_prestige_carryover_pct_check'
  ) THEN
    ALTER TABLE public.global_settings
      ADD CONSTRAINT global_settings_prestige_carryover_pct_check
      CHECK (prestige_carryover_pct >= 0 AND prestige_carryover_pct <= 95);
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.competition_club_prestige_computed()
RETURNS TABLE (
  club_short_name text,
  club_name text,
  capacity integer,
  rolling_points numeric,
  seasons_count integer,
  composite_score numeric,
  prestige_seed_rank smallint,
  prestige_rank smallint
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  WITH cfg AS (
    SELECT * FROM public.global_settings WHERE id = 1
  ),
  last_n AS (
    SELECT s.season_id AS id
    FROM (
      SELECT DISTINCT r.season_id
      FROM public.competition_club_season_ranking r
      JOIN public.competition_seasons cs ON cs.id = r.season_id
      WHERE cs.status = 'complete'
      ORDER BY r.season_id DESC
      LIMIT (SELECT greatest(stadium_rolling_seasons, 1) FROM cfg)
    ) s
  ),
  rolling AS (
    SELECT
      r.club_short_name,
      sum(r.season_total) AS rolling_points,
      count(*)::integer AS seasons_count
    FROM public.competition_club_season_ranking r
    WHERE r.season_id IN (SELECT id FROM last_n)
    GROUP BY r.club_short_name
  ),
  scored AS (
    SELECT
      c."ShortName" AS club_short_name,
      c."Club" AS club_name,
      coalesce(c."Capacity", 0)::int AS capacity,
      coalesce(r.rolling_points, 0) AS rolling_points,
      coalesce(r.seasons_count, 0) AS seasons_count,
      ps.seed_rank AS prestige_seed_rank,
      round(
        CASE
          WHEN coalesce(r.rolling_points, 0) > 0 THEN
            coalesce(r.rolling_points, 0)
            + (coalesce(c."Capacity", 0)::numeric / greatest(cfg.stadium_capacity_prestige_ref, 1))
              * cfg.stadium_capacity_prestige_weight
              * greatest(coalesce(r.rolling_points, 0), 1)
          WHEN ps.seed_rank IS NOT NULL THEN
            (61 - ps.seed_rank)::numeric * 100000
            + coalesce(c."Capacity", 0)::numeric / 1000
          ELSE
            (coalesce(c."Capacity", 0)::numeric / greatest(cfg.stadium_capacity_prestige_ref, 1))
              * cfg.stadium_capacity_prestige_weight
        END,
        2
      ) AS composite_score
    FROM public."Clubs" c
    CROSS JOIN cfg
    LEFT JOIN rolling r ON r.club_short_name = c."ShortName"
    LEFT JOIN public.competition_club_prestige_seed ps ON ps.club_short_name = c."ShortName"
    WHERE c."ShortName" <> 'FOREIGN'
  ),
  results_ranked AS (
    SELECT
      s.*,
      row_number() OVER (ORDER BY s.composite_score DESC, s.club_short_name) AS results_rank
    FROM scored s
  ),
  prev_season AS (
    SELECT max(snap.season_id) AS season_id
    FROM public.competition_club_prestige_snapshot snap
    JOIN public.competition_seasons cs ON cs.id = snap.season_id
    WHERE cs.status = 'complete'
  ),
  blended AS (
    SELECT
      rr.*,
      CASE
        WHEN rr.seasons_count = 0 THEN rr.results_rank::numeric
        ELSE
          (coalesce(cfg.prestige_carryover_pct, 85) / 100.0)
            * coalesce(snap.prestige_rank, rr.prestige_seed_rank, rr.results_rank)
          + (1 - coalesce(cfg.prestige_carryover_pct, 85) / 100.0) * rr.results_rank
      END AS blend_rank
    FROM results_ranked rr
    CROSS JOIN cfg
    LEFT JOIN prev_season pv ON true
    LEFT JOIN public.competition_club_prestige_snapshot snap
      ON snap.season_id = pv.season_id
     AND snap.club_short_name = rr.club_short_name
  )
  SELECT
    b.club_short_name,
    b.club_name,
    b.capacity,
    b.rolling_points,
    b.seasons_count,
    b.composite_score,
    b.prestige_seed_rank,
    row_number() OVER (
      ORDER BY b.blend_rank, b.results_rank, b.club_short_name
    )::smallint AS prestige_rank
  FROM blended b;
$$;

GRANT EXECUTE ON FUNCTION public.competition_club_prestige_computed() TO authenticated;

CREATE OR REPLACE FUNCTION public.admin_set_prestige_carryover_pct(p_pct numeric)
RETURNS numeric
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;
  IF p_pct IS NULL OR p_pct < 0 OR p_pct > 95 THEN
    RAISE EXCEPTION 'Carry-over must be between 0 and 95%%';
  END IF;

  UPDATE public.global_settings
  SET prestige_carryover_pct = round(p_pct, 2)
  WHERE id = 1;

  RETURN (SELECT prestige_carryover_pct FROM public.global_settings WHERE id = 1);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.admin_set_prestige_carryover_pct(numeric) TO authenticated;

NOTIFY pgrst, 'reload schema';

-- Preview: how next season's prestige would look right now (does not change the
-- locked rank of the season in progress).
-- SELECT prestige_rank, club_short_name, club_name, seasons_count, composite_score
-- FROM public.competition_club_prestige_computed()
-- ORDER BY prestige_rank;
