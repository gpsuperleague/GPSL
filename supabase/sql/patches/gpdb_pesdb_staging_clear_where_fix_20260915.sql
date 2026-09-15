-- =============================================================================
-- Fix: gpdb_pesdb_staging_clear — "DELETE requires a WHERE clause"
-- Supabase rejects unqualified DELETE FROM table;
-- Use WHERE true (same effect: clears all staging rows).
-- Also fixes the replace-path DELETE inside gpdb_pesdb_staging_import.
-- Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.gpdb_pesdb_staging_clear()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_deleted int;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  DELETE FROM public.gpdb_pesdb_staging WHERE true;
  GET DIAGNOSTICS v_deleted = ROW_COUNT;

  RETURN jsonb_build_object('ok', true, 'cleared', v_deleted);
END;
$function$;

-- Patch only the DELETE inside import (body otherwise unchanged from gpdb_pesdb_sync.sql)
CREATE OR REPLACE FUNCTION public.gpdb_pesdb_staging_import(
  p_rows jsonb,
  p_replace boolean DEFAULT true
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_batch uuid := gen_random_uuid();
  v_inserted int := 0;
  v_new int := 0;
  v_updated int := 0;
  v_row jsonb;
  v_kid text;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF p_rows IS NULL OR jsonb_typeof(p_rows) <> 'array' THEN
    RAISE EXCEPTION 'p_rows must be a JSON array';
  END IF;

  IF coalesce(p_replace, true) THEN
    DELETE FROM public.gpdb_pesdb_staging WHERE true;
  END IF;

  FOR v_row IN SELECT value FROM jsonb_array_elements(p_rows)
  LOOP
    v_kid := btrim(coalesce(v_row->>'konami_id', v_row->>'player_id', ''));
    IF v_kid = '' THEN
      CONTINUE;
    END IF;

    IF EXISTS (SELECT 1 FROM public.gpdb_pesdb_staging s WHERE s.konami_id = v_kid) THEN
      v_updated := v_updated + 1;
    ELSE
      v_new := v_new + 1;
    END IF;

    INSERT INTO public.gpdb_pesdb_staging (
      konami_id,
      player_name,
      position,
      nationality,
      age,
      rating,
      max_level_rating,
      playing_style,
      calc_potential,
      market_value,
      maximum_reserve_price,
      sync_batch_id
    ) VALUES (
      v_kid,
      nullif(btrim(v_row->>'player_name'), ''),
      nullif(btrim(coalesce(v_row->>'position', v_row->>'Position')), ''),
      nullif(btrim(coalesce(v_row->>'nationality', v_row->>'nation')), ''),
      nullif(btrim(v_row->>'age'), '')::smallint,
      nullif(btrim(v_row->>'rating'), '')::smallint,
      nullif(btrim(coalesce(v_row->>'max_level_rating', v_row->>'potential')), '')::smallint,
      nullif(btrim(coalesce(v_row->>'playing_style', v_row->>'playstyle')), ''),
      nullif(btrim(v_row->>'calc_potential'), '')::smallint,
      nullif(btrim(v_row->>'market_value'), '')::numeric,
      nullif(btrim(v_row->>'maximum_reserve_price'), '')::numeric,
      v_batch
    )
    ON CONFLICT (konami_id) DO UPDATE SET
      player_name = EXCLUDED.player_name,
      position = EXCLUDED.position,
      nationality = EXCLUDED.nationality,
      age = EXCLUDED.age,
      rating = EXCLUDED.rating,
      max_level_rating = EXCLUDED.max_level_rating,
      playing_style = EXCLUDED.playing_style,
      calc_potential = EXCLUDED.calc_potential,
      market_value = EXCLUDED.market_value,
      maximum_reserve_price = EXCLUDED.maximum_reserve_price,
      loaded_at = now(),
      sync_batch_id = EXCLUDED.sync_batch_id;

    v_inserted := v_inserted + 1;
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true,
    'batch_id', v_batch,
    'rows_imported', v_inserted,
    'rows_new', v_new,
    'rows_updated', v_updated,
    'staging_count', (SELECT count(*)::int FROM public.gpdb_pesdb_staging)
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.gpdb_pesdb_staging_clear() TO authenticated;
GRANT EXECUTE ON FUNCTION public.gpdb_pesdb_staging_import(jsonb, boolean) TO authenticated;

NOTIFY pgrst, 'reload schema';
