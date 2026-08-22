-- =============================================================================
-- One-off PESDB player field apply (admin GPDB sync UI)
-- Safe re-run. Does not touch bulk playstyle refresh checkpoint.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.gpdb_pesdb_apply_player_fields(p_rows jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_row jsonb;
  v_kid text;
  v_style text;
  v_rating text;
  v_age text;
  v_position text;
  v_nation text;
  v_updated int := 0;
  v_skipped int := 0;
  v_seen int := 0;
  v_set_parts text[];
  v_sql text;
  v_rowcount int;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF p_rows IS NULL OR jsonb_typeof(p_rows) <> 'array' THEN
    RAISE EXCEPTION 'p_rows must be a JSON array';
  END IF;

  FOR v_row IN SELECT * FROM jsonb_array_elements(p_rows)
  LOOP
    v_seen := v_seen + 1;
    v_kid := nullif(btrim(coalesce(v_row->>'konami_id', v_row->>'Konami_ID', '')), '');
    IF v_kid IS NULL THEN
      v_skipped := v_skipped + 1;
      CONTINUE;
    END IF;

    v_set_parts := ARRAY[]::text[];

    IF v_row ? 'playing_style' OR v_row ? 'Playstyle' THEN
      v_style := btrim(coalesce(v_row->>'playing_style', v_row->>'Playstyle', ''));
      IF lower(coalesce(v_style, 'none')) IN ('none', 'unknown') THEN
        NULL; -- scrape miss — do not wipe
      ELSE
        IF lower(v_style) = 'basic' THEN
          v_style := '';
        END IF;
        v_set_parts := array_append(
          v_set_parts,
          format('"Playstyle" = %L', nullif(v_style, ''))
        );
      END IF;
    END IF;

    IF v_row ? 'rating' OR v_row ? 'Rating' OR v_row ? 'max_level_rating' THEN
      v_rating := nullif(btrim(coalesce(
        v_row->>'rating', v_row->>'Rating', v_row->>'max_level_rating', ''
      )), '');
      IF v_rating IS NOT NULL AND v_rating ~ '^\d{1,3}$' THEN
        v_set_parts := array_append(
          v_set_parts,
          format('"Rating" = %L', v_rating)
        );
      END IF;
    END IF;

    IF v_row ? 'age' OR v_row ? 'Age' THEN
      v_age := nullif(btrim(coalesce(v_row->>'age', v_row->>'Age', '')), '');
      IF v_age IS NOT NULL AND v_age ~ '^\d{1,3}$' THEN
        v_set_parts := array_append(v_set_parts, format('"Age" = %L', v_age));
      END IF;
    END IF;

    IF v_row ? 'position' OR v_row ? 'Position' THEN
      v_position := nullif(btrim(coalesce(v_row->>'position', v_row->>'Position', '')), '');
      IF v_position IS NOT NULL THEN
        v_set_parts := array_append(
          v_set_parts,
          format('"Position" = %L', left(v_position, 8))
        );
      END IF;
    END IF;

    IF v_row ? 'nation' OR v_row ? 'Nation' OR v_row ? 'nationality' THEN
      v_nation := nullif(btrim(coalesce(
        v_row->>'nation', v_row->>'Nation', v_row->>'nationality', ''
      )), '');
      IF v_nation IS NOT NULL THEN
        v_set_parts := array_append(
          v_set_parts,
          format('"Nation" = %L', left(v_nation, 64))
        );
      END IF;
    END IF;

    IF coalesce(array_length(v_set_parts, 1), 0) = 0 THEN
      v_skipped := v_skipped + 1;
      CONTINUE;
    END IF;

    v_sql := format(
      'UPDATE public."Players" SET %s WHERE "Konami_ID"::text = %L',
      array_to_string(v_set_parts, ', '),
      v_kid
    );
    EXECUTE v_sql;
    GET DIAGNOSTICS v_rowcount = ROW_COUNT;
    IF v_rowcount > 0 THEN
      v_updated := v_updated + 1;
    ELSE
      v_skipped := v_skipped + 1;
    END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true,
    'rows_seen', v_seen,
    'updated', v_updated,
    'skipped', v_skipped
  );
END;
$function$;

COMMENT ON FUNCTION public.gpdb_pesdb_apply_player_fields(jsonb) IS
  'Admin one-off: apply selected PESDB fields (playstyle/rating/age/position/nation) to live Players.';

GRANT EXECUTE ON FUNCTION public.gpdb_pesdb_apply_player_fields(jsonb) TO authenticated;

NOTIFY pgrst, 'reload schema';
