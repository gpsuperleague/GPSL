-- =============================================================================
-- Playstyle-only tooling (eFootball Att/Def dual styles)
-- =============================================================================
-- Run in Supabase SQL Editor BEFORE using Admin → Refresh playstyles.
--
-- This does NOT undo your PESDB sync. It does not touch Age, Rating, MV,
-- contracts, clubs, or any other column.
--
-- What this patch DOES:
--   • RPCs for playstyle-only live updates (Admin scrape refresh)
--   • Helper so a future full sync won't wipe a real Playstyle with None/Basic
--
-- Att + Def both set to the same real style (e.g. both Goal Poacher) is fine —
-- GPSL stores that name once.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- OPTIONAL restore from Players_backup_20260820 (Playstyle column ONLY)
-- Left disabled by default — scrape refresh is preferred after the Att/Def fix.
-- Uncomment only if you want a quick fill from pre-sync playstyles.
-- ---------------------------------------------------------------------------
/*
DO $$
BEGIN
  IF to_regclass('public."Players_backup_20260820"') IS NULL THEN
    RAISE NOTICE 'Players_backup_20260820 not found — skip restore.';
    RETURN;
  END IF;

  UPDATE public."Players" p
  SET "Playstyle" = b."Playstyle"
  FROM public."Players_backup_20260820" b
  WHERE p."Konami_ID" = b."Konami_ID"
    AND nullif(btrim(b."Playstyle"::text), '') IS NOT NULL
    AND lower(btrim(b."Playstyle"::text)) NOT IN ('none', 'basic', 'unknown')
    AND (
      nullif(btrim(p."Playstyle"::text), '') IS NULL
      OR lower(btrim(p."Playstyle"::text)) IN ('none', 'basic', 'unknown')
    );

  RAISE NOTICE 'Playstyle-only restore from backup finished.';
END;
$$;
*/

-- ---------------------------------------------------------------------------
-- Prefer staging style only when it is a real (non-Basic/None) value
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.gpdb_pesdb_coalesce_playstyle(
  p_staging text,
  p_current text
)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE
    WHEN nullif(btrim(p_staging), '') IS NULL THEN p_current
    WHEN lower(btrim(p_staging)) IN ('none', 'basic', 'unknown')
         AND nullif(btrim(p_current), '') IS NOT NULL
         AND lower(btrim(p_current)) NOT IN ('none', 'basic', 'unknown')
      THEN p_current
    ELSE btrim(p_staging)
  END;
$$;

COMMENT ON FUNCTION public.gpdb_pesdb_coalesce_playstyle(text, text) IS
  'PESDB sync: keep current Playstyle when staging is blank/None/Basic.';

-- ---------------------------------------------------------------------------
-- Queue: players needing a playstyle refresh
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.gpdb_pesdb_playstyle_refresh_queue(
  p_offset int DEFAULT 0,
  p_limit int DEFAULT 100,
  p_force_all boolean DEFAULT false
)
RETURNS TABLE (
  konami_id text,
  player_name text,
  playstyle text,
  total_count bigint
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_limit int := greatest(least(coalesce(p_limit, 100), 500), 1);
  v_offset int := greatest(coalesce(p_offset, 0), 0);
  v_total bigint;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF coalesce(p_force_all, false) THEN
    SELECT count(*) INTO v_total FROM public."Players";
    RETURN QUERY
    SELECT
      p."Konami_ID"::text,
      p."Name"::text,
      p."Playstyle"::text,
      v_total
    FROM public."Players" p
    ORDER BY p."Konami_ID"
    LIMIT v_limit
    OFFSET v_offset;
  ELSE
    SELECT count(*) INTO v_total
    FROM public."Players" p
    WHERE nullif(btrim(p."Playstyle"::text), '') IS NULL
       OR lower(btrim(p."Playstyle"::text)) IN ('none', 'basic', 'unknown')
       OR btrim(p."Playstyle"::text) ~* '^(att|def)\s*:';

    RETURN QUERY
    SELECT
      p."Konami_ID"::text,
      p."Name"::text,
      p."Playstyle"::text,
      v_total
    FROM public."Players" p
    WHERE nullif(btrim(p."Playstyle"::text), '') IS NULL
       OR lower(btrim(p."Playstyle"::text)) IN ('none', 'basic', 'unknown')
       OR btrim(p."Playstyle"::text) ~* '^(att|def)\s*:'
    ORDER BY p."Konami_ID"
    LIMIT v_limit
    OFFSET v_offset;
  END IF;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.gpdb_pesdb_playstyle_refresh_queue(int, int, boolean)
  TO authenticated;

-- ---------------------------------------------------------------------------
-- Apply playstyle-only updates to live Players (from scrape results)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.gpdb_pesdb_apply_playstyles(p_rows jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_row jsonb;
  v_kid text;
  v_style text;
  v_updated int := 0;
  v_skipped int := 0;
  v_seen int := 0;
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
    -- Distinguish missing key / scrape miss ("None") from intentional blank ("").
    v_style := CASE
      WHEN NOT (v_row ? 'playing_style' OR v_row ? 'Playstyle') THEN NULL
      ELSE btrim(coalesce(v_row->>'playing_style', v_row->>'Playstyle', ''))
    END;

    IF v_kid IS NULL THEN
      v_skipped := v_skipped + 1;
      CONTINUE;
    END IF;

    -- Scrape miss — do not wipe a real style
    IF v_style IS NULL OR lower(v_style) IN ('none', 'unknown') THEN
      v_skipped := v_skipped + 1;
      CONTINUE;
    END IF;

    -- Real style, or intentional blank (both Att/Def were Basic → '')
    IF lower(v_style) = 'basic' THEN
      v_style := '';
    END IF;

    UPDATE public."Players" p
    SET "Playstyle" = nullif(v_style, '')
    WHERE p."Konami_ID"::text = v_kid
      AND coalesce(nullif(btrim(p."Playstyle"::text), ''), '') IS DISTINCT FROM v_style;

    IF FOUND THEN
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

GRANT EXECUTE ON FUNCTION public.gpdb_pesdb_apply_playstyles(jsonb) TO authenticated;

-- ---------------------------------------------------------------------------
-- Harden batched sync apply Playstyle assignment (if function present)
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_src text;
  v_new text;
BEGIN
  SELECT pg_get_functiondef('public.gpdb_pesdb_sync_apply(boolean, text, int, int)'::regprocedure)
  INTO v_src;

  IF v_src IS NULL THEN
    RAISE NOTICE 'gpdb_pesdb_sync_apply not found — skip harden.';
    RETURN;
  END IF;

  IF position('gpdb_pesdb_coalesce_playstyle' IN v_src) > 0 THEN
    RAISE NOTICE 'gpdb_pesdb_sync_apply already uses coalesce_playstyle.';
    RETURN;
  END IF;

  v_new := replace(
    v_src,
    '"Playstyle" = coalesce(s.playing_style, p."Playstyle")',
    '"Playstyle" = public.gpdb_pesdb_coalesce_playstyle(s.playing_style, p."Playstyle"::text)'
  );

  IF v_new = v_src THEN
    RAISE NOTICE 'Playstyle assignment pattern not found — patch apply_batch.sql manually.';
    RETURN;
  END IF;

  EXECUTE v_new;
  RAISE NOTICE 'gpdb_pesdb_sync_apply Playstyle harden applied.';
END;
$$;

NOTIFY pgrst, 'reload schema';

-- How many still need a playstyle scrape (blank / None / Basic)
SELECT
  count(*) FILTER (
    WHERE nullif(btrim("Playstyle"::text), '') IS NULL
       OR lower(btrim("Playstyle"::text)) IN ('none', 'basic', 'unknown')
  ) AS needs_refresh,
  count(*) AS total_players
FROM public."Players";
