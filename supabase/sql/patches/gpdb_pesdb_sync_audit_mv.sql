-- =============================================================================
-- GPDB PESDB sync audit — add market value comparison to preview
-- =============================================================================
-- Run after patches/gpdb_pesdb_sync.sql.
-- Preview now shows old_mv → new_mv and flags rows where only market value
-- differs (so stale legacy MVs are visible before apply).
-- Apply behaviour unchanged: all matched staging rows still update MV on apply.
-- =============================================================================

DROP FUNCTION IF EXISTS public.gpdb_pesdb_sync_audit();

CREATE OR REPLACE FUNCTION public.gpdb_pesdb_sync_audit()
RETURNS TABLE (
  action text,
  konami_id text,
  player_name text,
  club text,
  detail text,
  old_rating text,
  new_rating text,
  old_mv numeric,
  new_mv numeric,
  pesdb_unavailable boolean
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  WITH staging AS (
    SELECT * FROM public.gpdb_pesdb_staging
  ),
  live AS (
    SELECT
      p."Konami_ID"::text AS kid,
      p."Name" AS player_name,
      p."Contracted_Team" AS club,
      p."Rating"::text AS rating,
      nullif(btrim(p.market_value::text), '')::numeric AS market_value,
      p.pesdb_unavailable
    FROM public."Players" p
  ),
  stats_or_mv_changed AS (
    SELECT
      s.konami_id,
      p."Konami_ID"::text IS NOT NULL AS exists_in_gpdb,
      coalesce(p.pesdb_unavailable, false) AS was_unavailable,
      (
        s.rating IS DISTINCT FROM nullif(btrim(p."Rating"::text), '')::smallint
        OR s.max_level_rating IS DISTINCT FROM nullif(btrim(p."Potential"::text), '')::smallint
        OR s.calc_potential IS DISTINCT FROM nullif(btrim(p."Calc_Potential"::text), '')::smallint
        OR s.age IS DISTINCT FROM nullif(btrim(p."Age"::text), '')::smallint
        OR coalesce(s.nationality, '') IS DISTINCT FROM coalesce(nullif(btrim(p."Nation"::text), ''), '')
        OR coalesce(s.position, '') IS DISTINCT FROM coalesce(nullif(btrim(p."Position"::text), ''), '')
        OR coalesce(s.playing_style, '') IS DISTINCT FROM coalesce(nullif(btrim(p."Playstyle"::text), ''), '')
        OR s.market_value IS DISTINCT FROM nullif(btrim(p.market_value::text), '')::numeric
        OR coalesce(p.pesdb_unavailable, false)
      ) AS will_change
    FROM staging s
    LEFT JOIN public."Players" p ON p."Konami_ID"::text = s.konami_id
  ),
  mark_unavailable AS (
    SELECT
      'mark_unavailable'::text AS action,
      l.kid AS konami_id,
      l.player_name,
      l.club,
      'Not in latest PESDB scrape — will mark legacy card (not sellable)'::text AS detail,
      l.rating AS old_rating,
      NULL::text AS new_rating,
      l.market_value AS old_mv,
      NULL::numeric AS new_mv,
      l.pesdb_unavailable
    FROM live l
    LEFT JOIN staging s ON s.konami_id = l.kid
    WHERE s.konami_id IS NULL
      AND NOT coalesce(l.pesdb_unavailable, false)
  ),
  already_unavailable AS (
    SELECT
      'already_unavailable'::text AS action,
      l.kid AS konami_id,
      l.player_name,
      l.club,
      'Still not in scrape (already legacy)'::text AS detail,
      l.rating AS old_rating,
      NULL::text AS new_rating,
      l.market_value AS old_mv,
      NULL::numeric AS new_mv,
      true AS pesdb_unavailable
    FROM live l
    LEFT JOIN staging s ON s.konami_id = l.kid
    WHERE s.konami_id IS NULL
      AND coalesce(l.pesdb_unavailable, false)
  ),
  insert_new AS (
    SELECT
      'insert_free_agent'::text AS action,
      s.konami_id,
      s.player_name,
      NULL::text AS club,
      'New PESDB card → free agent with computed MV'::text AS detail,
      NULL::text AS old_rating,
      s.rating::text AS new_rating,
      NULL::numeric AS old_mv,
      s.market_value AS new_mv,
      false AS pesdb_unavailable
    FROM staging s
    LEFT JOIN live l ON l.kid = s.konami_id
    WHERE l.kid IS NULL
  ),
  update_existing AS (
    SELECT
      CASE
        WHEN coalesce(p.pesdb_unavailable, false) THEN 'restore_and_update'
        WHEN s.rating IS DISTINCT FROM nullif(btrim(p."Rating"::text), '')::smallint
          OR s.max_level_rating IS DISTINCT FROM nullif(btrim(p."Potential"::text), '')::smallint
          OR s.calc_potential IS DISTINCT FROM nullif(btrim(p."Calc_Potential"::text), '')::smallint
          OR s.age IS DISTINCT FROM nullif(btrim(p."Age"::text), '')::smallint
          OR coalesce(s.nationality, '') IS DISTINCT FROM coalesce(nullif(btrim(p."Nation"::text), ''), '')
          OR coalesce(s.position, '') IS DISTINCT FROM coalesce(nullif(btrim(p."Position"::text), ''), '')
          OR coalesce(s.playing_style, '') IS DISTINCT FROM coalesce(nullif(btrim(p."Playstyle"::text), ''), '')
          OR coalesce(p.pesdb_unavailable, false)
          THEN 'update_stats'
        ELSE 'update_mv'
      END::text AS action,
      s.konami_id,
      coalesce(s.player_name, p."Name") AS player_name,
      p."Contracted_Team" AS club,
      CASE
        WHEN s.market_value IS DISTINCT FROM nullif(btrim(p.market_value::text), '')::numeric
         AND s.rating IS NOT DISTINCT FROM nullif(btrim(p."Rating"::text), '')::smallint
         AND s.max_level_rating IS NOT DISTINCT FROM nullif(btrim(p."Potential"::text), '')::smallint
         AND s.calc_potential IS NOT DISTINCT FROM nullif(btrim(p."Calc_Potential"::text), '')::smallint
         AND s.age IS NOT DISTINCT FROM nullif(btrim(p."Age"::text), '')::smallint
          THEN 'Market value recalc from formula (stats unchanged)'
        ELSE 'Update Rating, Potential, MV, wage, etc. from scrape'
      END::text AS detail,
      p."Rating"::text AS old_rating,
      s.rating::text AS new_rating,
      nullif(btrim(p.market_value::text), '')::numeric AS old_mv,
      s.market_value AS new_mv,
      coalesce(p.pesdb_unavailable, false) AS pesdb_unavailable
    FROM staging s
    JOIN public."Players" p ON p."Konami_ID"::text = s.konami_id
    JOIN stats_or_mv_changed c ON c.konami_id = s.konami_id AND c.will_change
  ),
  unchanged AS (
    SELECT
      'unchanged'::text AS action,
      s.konami_id,
      p."Name" AS player_name,
      p."Contracted_Team" AS club,
      'Stats and MV already match staging'::text AS detail,
      p."Rating"::text AS old_rating,
      s.rating::text AS new_rating,
      nullif(btrim(p.market_value::text), '')::numeric AS old_mv,
      s.market_value AS new_mv,
      coalesce(p.pesdb_unavailable, false) AS pesdb_unavailable
    FROM staging s
    JOIN public."Players" p ON p."Konami_ID"::text = s.konami_id
    JOIN stats_or_mv_changed c ON c.konami_id = s.konami_id AND NOT c.will_change
  ),
  combined AS (
    SELECT * FROM mark_unavailable
    UNION ALL SELECT * FROM already_unavailable
    UNION ALL SELECT * FROM insert_new
    UNION ALL SELECT * FROM update_existing
    UNION ALL SELECT * FROM unchanged
  )
  SELECT
    c.action,
    c.konami_id,
    c.player_name,
    c.club,
    c.detail,
    c.old_rating,
    c.new_rating,
    c.old_mv,
    c.new_mv,
    c.pesdb_unavailable
  FROM combined c
  ORDER BY c.action, c.konami_id;
$$;

NOTIFY pgrst, 'reload schema';
