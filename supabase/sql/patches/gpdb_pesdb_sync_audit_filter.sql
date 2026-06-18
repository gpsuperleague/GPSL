-- =============================================================================
-- GPDB PESDB sync audit — filter + pagination for preview table
-- Run after patches/gpdb_pesdb_sync_audit_mv.sql
--
-- p_limit NULL = no row cap (used by gpdb_pesdb_sync_apply dry-run counts).
-- UI should pass p_limit := 500 and p_actions for the selected filter.
-- =============================================================================

DROP FUNCTION IF EXISTS public.gpdb_pesdb_sync_audit();

CREATE OR REPLACE FUNCTION public.gpdb_pesdb_sync_audit(
  p_actions text[] DEFAULT NULL,
  p_limit int DEFAULT NULL,
  p_offset int DEFAULT 0
)
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
  ),
  filtered AS (
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
      c.pesdb_unavailable,
      CASE c.action
        WHEN 'mark_unavailable' THEN 1
        WHEN 'already_unavailable' THEN 2
        WHEN 'restore_and_update' THEN 3
        WHEN 'update_stats' THEN 4
        WHEN 'update_mv' THEN 5
        WHEN 'insert_free_agent' THEN 6
        ELSE 50
      END AS sort_key
    FROM combined c
    WHERE p_actions IS NULL OR c.action = ANY(p_actions)
  )
  SELECT
    f.action,
    f.konami_id,
    f.player_name,
    f.club,
    f.detail,
    f.old_rating,
    f.new_rating,
    f.old_mv,
    f.new_mv,
    f.pesdb_unavailable
  FROM filtered f
  ORDER BY f.sort_key, f.konami_id
  LIMIT CASE WHEN p_limit IS NULL THEN NULL ELSE greatest(p_limit, 1) END
  OFFSET greatest(coalesce(p_offset, 0), 0);
$$;

-- Dry-run counts: include update_mv; audit() with default args = full set, no limit
CREATE OR REPLACE FUNCTION public.gpdb_pesdb_sync_apply(p_dry_run boolean DEFAULT true)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_staging int;
  v_marked int := 0;
  v_inserted int := 0;
  v_updated int := 0;
  v_mv_only int := 0;
  v_restored int := 0;
  v_unchanged int := 0;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  SELECT count(*)::int INTO v_staging FROM public.gpdb_pesdb_staging;
  IF v_staging = 0 THEN
    RAISE EXCEPTION 'Staging table is empty — upload a PESDB scrape CSV first';
  END IF;

  IF coalesce(p_dry_run, true) THEN
    SELECT
      count(*) FILTER (WHERE action = 'mark_unavailable'),
      count(*) FILTER (WHERE action = 'insert_free_agent'),
      count(*) FILTER (WHERE action IN ('update_stats', 'restore_and_update', 'update_mv')),
      count(*) FILTER (WHERE action = 'update_mv'),
      count(*) FILTER (WHERE action = 'restore_and_update'),
      count(*) FILTER (WHERE action = 'unchanged')
    INTO v_marked, v_inserted, v_updated, v_mv_only, v_restored, v_unchanged
    FROM public.gpdb_pesdb_sync_audit();

    RETURN jsonb_build_object(
      'ok', true,
      'dry_run', true,
      'staging_rows', v_staging,
      'would_mark_unavailable', v_marked,
      'would_insert_free_agents', v_inserted,
      'would_update', v_updated,
      'would_update_mv_only', v_mv_only,
      'would_restore_from_legacy', v_restored,
      'unchanged', v_unchanged
    );
  END IF;

  PERFORM set_config('statement_timeout', '900000', true);

  UPDATE public."Players" p
  SET
    pesdb_unavailable = true,
    pesdb_unavailable_since = coalesce(p.pesdb_unavailable_since, now())
  WHERE NOT EXISTS (
    SELECT 1 FROM public.gpdb_pesdb_staging s
    WHERE s.konami_id = p."Konami_ID"::text
  )
  AND NOT coalesce(p.pesdb_unavailable, false);

  GET DIAGNOSTICS v_marked = ROW_COUNT;

  SELECT count(*)::int INTO v_restored
  FROM public.gpdb_pesdb_staging s
  JOIN public."Players" p ON p."Konami_ID"::text = s.konami_id
  WHERE coalesce(p.pesdb_unavailable, false);

  UPDATE public."Players" p
  SET
    "Name" = coalesce(s.player_name, p."Name"),
    "Position" = coalesce(s.position, p."Position"),
    "Nation" = coalesce(s.nationality, p."Nation"),
    "Age" = coalesce(s.age::text, p."Age"::text),
    "Rating" = coalesce(s.rating::text, p."Rating"::text),
    "Potential" = coalesce(s.max_level_rating::text, p."Potential"::text),
    "Calc_Potential" = coalesce(s.calc_potential::text, p."Calc_Potential"::text),
    "Playstyle" = coalesce(s.playing_style, p."Playstyle"),
    market_value = coalesce(
      s.market_value,
      nullif(btrim(p.market_value::text), '')::numeric
    ),
    "Maximum_Reserve_Price" = coalesce(
      s.maximum_reserve_price,
      nullif(btrim(p."Maximum_Reserve_Price"::text), '')::numeric
    ),
    pesdb_unavailable = false,
    pesdb_unavailable_since = NULL,
    contract_wage = CASE
      WHEN public.player_contracted_club_key(p."Contracted_Team") IS NOT NULL
       AND s.market_value IS NOT NULL THEN
        round(
          public.calculate_standard_player_wage(
            s.market_value,
            public.competition_club_division_tier(
              public.player_contracted_club_key(p."Contracted_Team")
            )
          ),
          0
        )
      ELSE p.contract_wage
    END
  FROM public.gpdb_pesdb_staging s
  WHERE p."Konami_ID"::text = s.konami_id;

  GET DIAGNOSTICS v_updated = ROW_COUNT;

  INSERT INTO public."Players" (
    "Konami_ID",
    "Name",
    "Position",
    "Nation",
    "Age",
    "Rating",
    "Potential",
    "Calc_Potential",
    "Playstyle",
    market_value,
    "Maximum_Reserve_Price",
    "Contracted_Team",
    pesdb_unavailable
  )
  SELECT
    s.konami_id,
    coalesce(s.player_name, 'Unknown'),
    coalesce(s.position, 'CF'),
    coalesce(s.nationality, 'Unknown'),
    coalesce(s.age::text, '25'),
    coalesce(s.rating::text, '60'),
    coalesce(s.max_level_rating::text, s.rating::text, '60'),
    coalesce(s.calc_potential::text, s.max_level_rating::text, s.rating::text, '60'),
    coalesce(s.playing_style, 'None'),
    coalesce(s.market_value, 5000000),
    coalesce(s.maximum_reserve_price, round(coalesce(s.market_value, 5000000) * 1.5, 0)),
    NULL,
    false
  FROM public.gpdb_pesdb_staging s
  WHERE NOT EXISTS (
    SELECT 1 FROM public."Players" p
    WHERE p."Konami_ID"::text = s.konami_id
  );

  GET DIAGNOSTICS v_inserted = ROW_COUNT;

  SELECT count(*)::int INTO v_unchanged
  FROM public.gpdb_pesdb_sync_audit(ARRAY['unchanged']::text[], NULL, 0);

  RETURN jsonb_build_object(
    'ok', true,
    'dry_run', false,
    'staging_rows', v_staging,
    'marked_unavailable', v_marked,
    'inserted_free_agents', v_inserted,
    'updated', v_updated,
    'restored_from_legacy', v_restored,
    'unchanged', v_unchanged
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.gpdb_pesdb_sync_audit(text[], int, int) TO authenticated;

NOTIFY pgrst, 'reload schema';
