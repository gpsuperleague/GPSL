-- Add current national team to World Cup (rolling 4) owner ranking view
-- Run once in Supabase SQL Editor after competition_international.sql

DROP VIEW IF EXISTS public.competition_owner_ranking_rolling4_public;
CREATE VIEW public.competition_owner_ranking_rolling4_public
WITH (security_invoker = false)
AS
WITH last_four AS (
  SELECT s.season_id AS id
  FROM (
    SELECT DISTINCT season_id
    FROM public.competition_owner_season_ranking
    ORDER BY season_id DESC
    LIMIT 4
  ) s
),
totals AS (
  SELECT
    r.owner_id,
    r.club_short_name,
    sum(r.season_total) AS rolling_points,
    count(*)::integer AS seasons_count,
    jsonb_agg(
      jsonb_build_object(
        'season_id', r.season_id,
        'season_label', r.season_label,
        'season_total', r.season_total
      )
      ORDER BY r.season_id DESC
    ) AS season_breakdown
  FROM public.competition_owner_season_ranking r
  WHERE r.season_id IN (SELECT id FROM last_four)
    AND r.owner_id IS NOT NULL
  GROUP BY r.owner_id, r.club_short_name
)
SELECT
  row_number() OVER (
    ORDER BY coalesce(t.rolling_points, 0) DESC,
      public.competition_owner_display_name(c.owner_id),
      c."ShortName"
  )::smallint AS rank_position,
  c.owner_id,
  public.competition_owner_display_name(c.owner_id) AS owner_name,
  c."ShortName" AS club_short_name,
  c."Club" AS club_name,
  public.owner_registry_resolve_tag(c.owner_id) AS owner_tag,
  ion.nation_code,
  n.name AS nation_name,
  n.flag_emoji,
  round(coalesce(t.rolling_points, 0), 2) AS rolling_points,
  coalesce(t.seasons_count, 0) AS seasons_count,
  coalesce(t.season_breakdown, '[]'::jsonb) AS season_breakdown
FROM public."Clubs" c
LEFT JOIN totals t ON t.club_short_name = c."ShortName"
LEFT JOIN public.international_owner_nations ion
  ON ion.club_short_name = c."ShortName" AND ion.is_active = true
LEFT JOIN public.international_nations n ON n.code = ion.nation_code
WHERE c.owner_id IS NOT NULL
ORDER BY rank_position;

NOTIFY pgrst, 'reload schema';
