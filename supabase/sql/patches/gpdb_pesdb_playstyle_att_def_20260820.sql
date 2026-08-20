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
-- Queue: players needing a playstyle refresh (resume via p_after_konami_id)
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.gpdb_pesdb_playstyle_refresh_queue(int, int, boolean);
DROP FUNCTION IF EXISTS public.gpdb_pesdb_playstyle_refresh_queue(int, int, boolean, text);

CREATE OR REPLACE FUNCTION public.gpdb_pesdb_playstyle_refresh_queue(
  p_limit int DEFAULT 100,
  p_force_all boolean DEFAULT false,
  p_after_konami_id text DEFAULT NULL
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
  v_after text := nullif(btrim(coalesce(p_after_konami_id, '')), '');
  v_total bigint;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF coalesce(p_force_all, false) THEN
    SELECT count(*) INTO v_total
    FROM public."Players" p
    WHERE v_after IS NULL OR p."Konami_ID"::text > v_after;

    RETURN QUERY
    SELECT
      p."Konami_ID"::text,
      p."Name"::text,
      p."Playstyle"::text,
      v_total
    FROM public."Players" p
    WHERE v_after IS NULL OR p."Konami_ID"::text > v_after
    ORDER BY p."Konami_ID"
    LIMIT v_limit;
  ELSE
    SELECT count(*) INTO v_total
    FROM public."Players" p
    WHERE (v_after IS NULL OR p."Konami_ID"::text > v_after)
      AND (
        nullif(btrim(p."Playstyle"::text), '') IS NULL
        OR lower(btrim(p."Playstyle"::text)) IN ('none', 'basic', 'unknown')
        OR btrim(p."Playstyle"::text) ~* '^(att|def)\s*:'
      );

    RETURN QUERY
    SELECT
      p."Konami_ID"::text,
      p."Name"::text,
      p."Playstyle"::text,
      v_total
    FROM public."Players" p
    WHERE (v_after IS NULL OR p."Konami_ID"::text > v_after)
      AND (
        nullif(btrim(p."Playstyle"::text), '') IS NULL
        OR lower(btrim(p."Playstyle"::text)) IN ('none', 'basic', 'unknown')
        OR btrim(p."Playstyle"::text) ~* '^(att|def)\s*:'
      )
    ORDER BY p."Konami_ID"
    LIMIT v_limit;
  END IF;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.gpdb_pesdb_playstyle_refresh_queue(int, boolean, text)
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

-- ---------------------------------------------------------------------------
-- Playstyle refresh checkpoint (survives browser crash / refresh)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.gpdb_pesdb_playstyle_jobs (
  job_key text PRIMARY KEY DEFAULT 'active',
  status text NOT NULL DEFAULT 'idle',
  force_all boolean NOT NULL DEFAULT false,
  player_delay_sec numeric NOT NULL DEFAULT 3.5,
  last_konami_id text,
  last_player_name text,
  processed_count int NOT NULL DEFAULT 0,
  updated_count int NOT NULL DEFAULT 0,
  skipped_count int NOT NULL DEFAULT 0,
  total_count int,
  last_error text,
  started_at timestamptz,
  updated_at timestamptz NOT NULL DEFAULT now()
);

INSERT INTO public.gpdb_pesdb_playstyle_jobs (job_key)
VALUES ('active')
ON CONFLICT (job_key) DO NOTHING;

ALTER TABLE public.gpdb_pesdb_playstyle_jobs ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS gpdb_pesdb_playstyle_jobs_admin ON public.gpdb_pesdb_playstyle_jobs;
CREATE POLICY gpdb_pesdb_playstyle_jobs_admin ON public.gpdb_pesdb_playstyle_jobs
  FOR ALL TO authenticated
  USING (public.is_gpsl_admin())
  WITH CHECK (public.is_gpsl_admin());

GRANT SELECT, INSERT, UPDATE, DELETE ON public.gpdb_pesdb_playstyle_jobs TO authenticated;

CREATE OR REPLACE FUNCTION public.gpdb_pesdb_playstyle_job_get()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_row public.gpdb_pesdb_playstyle_jobs%rowtype;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  SELECT * INTO v_row FROM public.gpdb_pesdb_playstyle_jobs WHERE job_key = 'active';
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', true, 'status', 'idle');
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'status', v_row.status,
    'force_all', v_row.force_all,
    'player_delay_sec', v_row.player_delay_sec,
    'last_konami_id', v_row.last_konami_id,
    'last_player_name', v_row.last_player_name,
    'processed_count', v_row.processed_count,
    'updated_count', v_row.updated_count,
    'skipped_count', v_row.skipped_count,
    'total_count', v_row.total_count,
    'last_error', v_row.last_error,
    'started_at', v_row.started_at,
    'updated_at', v_row.updated_at
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.gpdb_pesdb_playstyle_job_save(p_patch jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  INSERT INTO public.gpdb_pesdb_playstyle_jobs (job_key)
  VALUES ('active')
  ON CONFLICT (job_key) DO NOTHING;

  UPDATE public.gpdb_pesdb_playstyle_jobs j
  SET
    status = coalesce(nullif(btrim(p_patch->>'status'), ''), j.status),
    force_all = coalesce((p_patch->>'force_all')::boolean, j.force_all),
    player_delay_sec = coalesce((p_patch->>'player_delay_sec')::numeric, j.player_delay_sec),
    last_konami_id = CASE
      WHEN p_patch ? 'last_konami_id' THEN nullif(btrim(p_patch->>'last_konami_id'), '')
      ELSE j.last_konami_id
    END,
    last_player_name = CASE
      WHEN p_patch ? 'last_player_name' THEN nullif(btrim(p_patch->>'last_player_name'), '')
      ELSE j.last_player_name
    END,
    processed_count = coalesce((p_patch->>'processed_count')::int, j.processed_count),
    updated_count = coalesce((p_patch->>'updated_count')::int, j.updated_count),
    skipped_count = coalesce((p_patch->>'skipped_count')::int, j.skipped_count),
    total_count = CASE
      WHEN p_patch ? 'total_count' THEN (p_patch->>'total_count')::int
      ELSE j.total_count
    END,
    last_error = CASE
      WHEN p_patch ? 'last_error' THEN nullif(btrim(p_patch->>'last_error'), '')
      ELSE j.last_error
    END,
    started_at = coalesce(
      NULLIF(p_patch->>'started_at', '')::timestamptz,
      j.started_at,
      CASE WHEN coalesce(p_patch->>'status', '') = 'running' THEN now() ELSE NULL END
    ),
    updated_at = now()
  WHERE j.job_key = 'active';

  RETURN public.gpdb_pesdb_playstyle_job_get();
END;
$function$;

CREATE OR REPLACE FUNCTION public.gpdb_pesdb_playstyle_job_clear()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  UPDATE public.gpdb_pesdb_playstyle_jobs
  SET
    status = 'idle',
    force_all = false,
    last_konami_id = NULL,
    last_player_name = NULL,
    processed_count = 0,
    updated_count = 0,
    skipped_count = 0,
    total_count = NULL,
    last_error = NULL,
    started_at = NULL,
    updated_at = now()
  WHERE job_key = 'active';

  RETURN public.gpdb_pesdb_playstyle_job_get();
END;
$function$;

GRANT EXECUTE ON FUNCTION public.gpdb_pesdb_playstyle_job_get() TO authenticated;
GRANT EXECUTE ON FUNCTION public.gpdb_pesdb_playstyle_job_save(jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.gpdb_pesdb_playstyle_job_clear() TO authenticated;

NOTIFY pgrst, 'reload schema';

-- How many still need a playstyle scrape (blank / None / Basic)
SELECT
  count(*) FILTER (
    WHERE nullif(btrim("Playstyle"::text), '') IS NULL
       OR lower(btrim("Playstyle"::text)) IN ('none', 'basic', 'unknown')
  ) AS needs_refresh,
  count(*) AS total_players
FROM public."Players";
