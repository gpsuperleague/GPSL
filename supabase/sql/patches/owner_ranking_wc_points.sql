-- =============================================================================
-- All-time owner ranking: World Cup national team performance points
-- Run after competition_owner_ranking.sql and competition_international.sql
--
-- Tiers (best result per nation per WC cycle — not cumulative):
--   Winner 10 · Runner-up 8 · Semi-finals 5 · Quarters 3 · Last 16 2 · Finals groups 1
-- =============================================================================

CREATE OR REPLACE FUNCTION public.competition_international_wc_achievement_points(
  p_cycle_id bigint,
  p_nation_code text
)
RETURNS smallint
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_nation text := upper(btrim(p_nation_code));
BEGIN
  IF p_cycle_id IS NULL OR v_nation IS NULL OR v_nation = '' THEN
    RETURN 0;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.international_knockout_nodes kn
    WHERE kn.cycle_id = p_cycle_id
      AND kn.stage = 'final'
      AND kn.played
      AND kn.winner_nation = v_nation
  ) THEN
    RETURN 10;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.international_knockout_nodes kn
    WHERE kn.cycle_id = p_cycle_id
      AND kn.stage = 'final'
      AND kn.played
      AND v_nation IN (kn.nation_a, kn.nation_b)
      AND kn.winner_nation IS DISTINCT FROM v_nation
  ) THEN
    RETURN 8;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.international_knockout_nodes kn
    WHERE kn.cycle_id = p_cycle_id
      AND kn.stage = 'sf'
      AND kn.played
      AND v_nation IN (kn.nation_a, kn.nation_b)
      AND kn.winner_nation IS DISTINCT FROM v_nation
  ) THEN
    RETURN 5;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.international_knockout_nodes kn
    WHERE kn.cycle_id = p_cycle_id
      AND kn.stage = 'qf'
      AND kn.played
      AND v_nation IN (kn.nation_a, kn.nation_b)
      AND kn.winner_nation IS DISTINCT FROM v_nation
  ) THEN
    RETURN 3;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.international_knockout_nodes kn
    WHERE kn.cycle_id = p_cycle_id
      AND kn.stage = 'r16'
      AND kn.played
      AND v_nation IN (kn.nation_a, kn.nation_b)
      AND kn.winner_nation IS DISTINCT FROM v_nation
  ) THEN
    RETURN 2;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.international_finals_group_members m
    JOIN public.international_finals_groups g ON g.id = m.group_id
    WHERE g.cycle_id = p_cycle_id
      AND m.nation_code = v_nation
  ) THEN
    RETURN 1;
  END IF;

  RETURN 0;
END;
$function$;

CREATE OR REPLACE FUNCTION public.competition_owner_id_for_wc_nation(
  p_cycle_id bigint,
  p_club_short_name text
)
RETURNS uuid
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT coalesce(
    (
      SELECT r.owner_id
      FROM public.international_wc_cycles wc
      JOIN public.competition_owner_season_ranking r
        ON r.club_short_name = upper(btrim(p_club_short_name))
       AND r.season_id IN (wc.qual_season_id_1, wc.qual_season_id_2, wc.finals_after_season_id)
      WHERE wc.id = p_cycle_id
        AND r.owner_id IS NOT NULL
      ORDER BY r.season_id DESC
      LIMIT 1
    ),
    (
      SELECT r.owner_id
      FROM public.competition_owner_season_ranking r
      WHERE r.club_short_name = upper(btrim(p_club_short_name))
        AND r.owner_id IS NOT NULL
      ORDER BY r.season_id DESC
      LIMIT 1
    ),
    (
      SELECT c.owner_id
      FROM public."Clubs" c
      WHERE c."ShortName" = upper(btrim(p_club_short_name))
      LIMIT 1
    )
  );
$$;

DROP VIEW IF EXISTS public.competition_owner_ranking_alltime_public;
CREATE VIEW public.competition_owner_ranking_alltime_public
WITH (security_invoker = false)
AS
WITH club_totals AS (
  SELECT
    r.owner_id,
    round(sum(r.season_total), 2) AS club_points,
    count(DISTINCT r.season_id)::integer AS seasons_count,
    min(r.season_label) AS first_season_label,
    max(r.season_label) AS last_season_label
  FROM public.competition_owner_season_ranking r
  WHERE r.owner_id IS NOT NULL
  GROUP BY r.owner_id
),
wc_rows AS (
  SELECT DISTINCT ON (wc.id, ion.nation_code)
    wc.id AS cycle_id,
    wc.label AS cycle_label,
    ion.nation_code,
    ion.club_short_name,
    public.competition_international_wc_achievement_points(wc.id, ion.nation_code) AS wc_points
  FROM public.international_wc_cycles wc
  JOIN public.international_owner_nations ion
    ON ion.cycle_id = wc.id
  WHERE public.competition_international_wc_achievement_points(wc.id, ion.nation_code) > 0
  ORDER BY wc.id, ion.nation_code, ion.assigned_at DESC
),
wc_scored AS (
  SELECT
    public.competition_owner_id_for_wc_nation(w.cycle_id, w.club_short_name) AS owner_id,
    w.cycle_id,
    w.cycle_label,
    w.nation_code,
    w.wc_points
  FROM wc_rows w
),
wc_totals AS (
  SELECT
    s.owner_id,
    round(sum(s.wc_points), 2) AS wc_points,
    jsonb_agg(
      jsonb_build_object(
        'cycle_label', s.cycle_label,
        'nation_code', s.nation_code,
        'points', s.wc_points
      )
      ORDER BY s.cycle_id DESC
    ) AS wc_breakdown
  FROM wc_scored s
  WHERE s.owner_id IS NOT NULL
  GROUP BY s.owner_id
),
combined AS (
  SELECT
    coalesce(c.owner_id, w.owner_id) AS owner_id,
    coalesce(c.club_points, 0)::numeric AS club_points,
    coalesce(w.wc_points, 0)::numeric AS wc_points,
    coalesce(c.club_points, 0) + coalesce(w.wc_points, 0) AS total_points,
    coalesce(c.seasons_count, 0) AS seasons_count,
    c.first_season_label,
    c.last_season_label,
    coalesce(w.wc_breakdown, '[]'::jsonb) AS wc_breakdown
  FROM club_totals c
  FULL OUTER JOIN wc_totals w ON w.owner_id = c.owner_id
)
SELECT
  row_number() OVER (
    ORDER BY total_points DESC,
      public.competition_owner_display_name(owner_id)
  )::integer AS rank_position,
  owner_id,
  public.competition_owner_display_name(owner_id) AS owner_name,
  club_points,
  wc_points,
  round(total_points, 2) AS total_points,
  seasons_count,
  first_season_label,
  last_season_label,
  wc_breakdown
FROM combined
WHERE owner_id IS NOT NULL
ORDER BY rank_position;

GRANT EXECUTE ON FUNCTION public.competition_international_wc_achievement_points(bigint, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.competition_owner_id_for_wc_nation(bigint, text) TO authenticated;

NOTIFY pgrst, 'reload schema';
