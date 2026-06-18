-- =============================================================================
-- GPDB ↔ PESDB sync — staging table, preview/apply, legacy-card flag
-- Run AFTER players_economics_columns.sql + player_wage_settings.sql
-- Admin UI: admin_gpdb_sync.html
--
-- Flow:
--   1. Scrape pesdb.net → CSV (scripts/pesdb_scrape.py)
--   2. Admin uploads CSV → staging (economics precomputed in browser)
--   3. gpdb_pesdb_sync_preview / gpdb_pesdb_sync_apply
--
-- Players in GPSL but not in scrape → pesdb_unavailable = true (stay at club, not sellable)
-- Players in scrape but not GPSL → inserted as free agents
-- Matched → update stats + economics; clear pesdb_unavailable if returning
-- =============================================================================

ALTER TABLE public."Players"
  ADD COLUMN IF NOT EXISTS pesdb_unavailable boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS pesdb_unavailable_since timestamptz;

COMMENT ON COLUMN public."Players".pesdb_unavailable IS
  'Card removed from pesdb.net — owner may keep legacy card; not sellable; renew 1 season only.';

COMMENT ON COLUMN public."Players".pesdb_unavailable_since IS
  'When the player was last marked unavailable (not in latest PESDB scrape).';

-- ---------------------------------------------------------------------------
-- Staging (replicated scrape + precomputed economics from admin import)
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.gpdb_pesdb_staging (
  konami_id text PRIMARY KEY,
  player_name text,
  position text,
  nationality text,
  age smallint,
  rating smallint,
  max_level_rating smallint,
  playing_style text,
  calc_potential smallint,
  market_value numeric,
  maximum_reserve_price numeric,
  loaded_at timestamptz NOT NULL DEFAULT now(),
  sync_batch_id uuid
);

CREATE INDEX IF NOT EXISTS gpdb_pesdb_staging_loaded_at_idx
  ON public.gpdb_pesdb_staging (loaded_at DESC);

ALTER TABLE public.gpdb_pesdb_staging ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS gpdb_pesdb_staging_admin ON public.gpdb_pesdb_staging;
CREATE POLICY gpdb_pesdb_staging_admin ON public.gpdb_pesdb_staging
  FOR ALL TO authenticated
  USING (public.is_gpsl_admin())
  WITH CHECK (public.is_gpsl_admin());

GRANT SELECT, INSERT, UPDATE, DELETE ON public.gpdb_pesdb_staging TO authenticated;

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.gpdb_pesdb_player_is_unavailable(p_player_id text)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT coalesce(
    (SELECT p.pesdb_unavailable
     FROM public."Players" p
     WHERE p."Konami_ID"::text = btrim(p_player_id)),
    false
  );
$$;

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

  DELETE FROM public.gpdb_pesdb_staging;
  GET DIAGNOSTICS v_deleted = ROW_COUNT;

  RETURN jsonb_build_object('ok', true, 'cleared', v_deleted);
END;
$function$;

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
    DELETE FROM public.gpdb_pesdb_staging;
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

-- Staging summary for admin progress panel
CREATE OR REPLACE FUNCTION public.gpdb_pesdb_staging_stats()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_count int;
  v_last timestamptz;
  v_first timestamptz;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  SELECT count(*)::int, max(loaded_at), min(loaded_at)
  INTO v_count, v_last, v_first
  FROM public.gpdb_pesdb_staging;

  RETURN jsonb_build_object(
    'ok', true,
    'staging_count', coalesce(v_count, 0),
    'last_loaded_at', v_last,
    'first_loaded_at', v_first
  );
END;
$function$;

-- ---------------------------------------------------------------------------
-- Scrape job (survives browser refresh — admin UI auto-resumes)
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.gpdb_pesdb_scrape_jobs (
  job_key text PRIMARY KEY DEFAULT 'active',
  status text NOT NULL DEFAULT 'idle',
  start_page int NOT NULL DEFAULT 1,
  end_page int NOT NULL DEFAULT 1,
  next_page int NOT NULL DEFAULT 1,
  last_completed_page int NOT NULL DEFAULT 0,
  in_progress_page int NOT NULL DEFAULT 0,
  players_completed_on_page int NOT NULL DEFAULT 0,
  page_player_total int NOT NULL DEFAULT 0,
  pages_per_batch int NOT NULL DEFAULT 2,
  batch_cooldown_sec int NOT NULL DEFAULT 20,
  player_delay_sec numeric NOT NULL DEFAULT 3.5,
  staging_count int NOT NULL DEFAULT 0,
  last_error text,
  started_at timestamptz,
  updated_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.gpdb_pesdb_scrape_jobs
  ADD COLUMN IF NOT EXISTS in_progress_page int NOT NULL DEFAULT 0;

ALTER TABLE public.gpdb_pesdb_scrape_jobs
  ADD COLUMN IF NOT EXISTS players_completed_on_page int NOT NULL DEFAULT 0;

ALTER TABLE public.gpdb_pesdb_scrape_jobs
  ADD COLUMN IF NOT EXISTS page_player_total int NOT NULL DEFAULT 0;

INSERT INTO public.gpdb_pesdb_scrape_jobs (job_key)
VALUES ('active')
ON CONFLICT (job_key) DO NOTHING;

ALTER TABLE public.gpdb_pesdb_scrape_jobs ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS gpdb_pesdb_scrape_jobs_admin ON public.gpdb_pesdb_scrape_jobs;
CREATE POLICY gpdb_pesdb_scrape_jobs_admin ON public.gpdb_pesdb_scrape_jobs
  FOR ALL TO authenticated
  USING (public.is_gpsl_admin())
  WITH CHECK (public.is_gpsl_admin());

GRANT SELECT, INSERT, UPDATE, DELETE ON public.gpdb_pesdb_scrape_jobs TO authenticated;

CREATE OR REPLACE FUNCTION public.gpdb_pesdb_scrape_job_get()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_row public.gpdb_pesdb_scrape_jobs%rowtype;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  SELECT * INTO v_row FROM public.gpdb_pesdb_scrape_jobs WHERE job_key = 'active';

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', true, 'status', 'idle');
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'status', v_row.status,
    'start_page', v_row.start_page,
    'end_page', v_row.end_page,
    'next_page', v_row.next_page,
    'last_completed_page', v_row.last_completed_page,
    'in_progress_page', v_row.in_progress_page,
    'players_completed_on_page', v_row.players_completed_on_page,
    'page_player_total', v_row.page_player_total,
    'pages_per_batch', v_row.pages_per_batch,
    'batch_cooldown_sec', v_row.batch_cooldown_sec,
    'player_delay_sec', v_row.player_delay_sec,
    'staging_count', v_row.staging_count,
    'last_error', v_row.last_error,
    'started_at', v_row.started_at,
    'updated_at', v_row.updated_at
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.gpdb_pesdb_scrape_job_save(p_patch jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  INSERT INTO public.gpdb_pesdb_scrape_jobs (job_key)
  VALUES ('active')
  ON CONFLICT (job_key) DO NOTHING;

  UPDATE public.gpdb_pesdb_scrape_jobs j
  SET
    status = coalesce(nullif(p_patch->>'status', ''), j.status),
    start_page = coalesce((p_patch->>'start_page')::int, j.start_page),
    end_page = coalesce((p_patch->>'end_page')::int, j.end_page),
    next_page = coalesce((p_patch->>'next_page')::int, j.next_page),
    last_completed_page = coalesce((p_patch->>'last_completed_page')::int, j.last_completed_page),
    in_progress_page = coalesce((p_patch->>'in_progress_page')::int, j.in_progress_page),
    players_completed_on_page = coalesce((p_patch->>'players_completed_on_page')::int, j.players_completed_on_page),
    page_player_total = coalesce((p_patch->>'page_player_total')::int, j.page_player_total),
    pages_per_batch = coalesce((p_patch->>'pages_per_batch')::int, j.pages_per_batch),
    batch_cooldown_sec = coalesce((p_patch->>'batch_cooldown_sec')::int, j.batch_cooldown_sec),
    player_delay_sec = coalesce((p_patch->>'player_delay_sec')::numeric, j.player_delay_sec),
    staging_count = coalesce((p_patch->>'staging_count')::int, j.staging_count),
    last_error = CASE
      WHEN p_patch ? 'last_error' THEN nullif(p_patch->>'last_error', '')
      ELSE j.last_error
    END,
    started_at = CASE
      WHEN p_patch ? 'started_at' THEN (p_patch->>'started_at')::timestamptz
      ELSE j.started_at
    END,
    updated_at = now()
  WHERE j.job_key = 'active';

  RETURN public.gpdb_pesdb_scrape_job_get();
END;
$function$;

CREATE OR REPLACE FUNCTION public.gpdb_pesdb_scrape_job_clear()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  UPDATE public.gpdb_pesdb_scrape_jobs
  SET
    status = 'idle',
    start_page = 1,
    end_page = 1,
    next_page = 1,
    last_completed_page = 0,
    in_progress_page = 0,
    players_completed_on_page = 0,
    page_player_total = 0,
    staging_count = 0,
    last_error = NULL,
    started_at = NULL,
    updated_at = now()
  WHERE job_key = 'active';

  RETURN jsonb_build_object('ok', true, 'status', 'idle');
END;
$function$;

-- ---------------------------------------------------------------------------
-- Preview audit (table)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.gpdb_pesdb_sync_audit()
RETURNS TABLE (
  action text,
  konami_id text,
  player_name text,
  club text,
  detail text,
  old_rating text,
  new_rating text,
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
      p.pesdb_unavailable
    FROM public."Players" p
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
      'New PESDB card → free agent at end of GPDB'::text AS detail,
      NULL::text AS old_rating,
      s.rating::text AS new_rating,
      false AS pesdb_unavailable
    FROM staging s
    LEFT JOIN live l ON l.kid = s.konami_id
    WHERE l.kid IS NULL
  ),
  update_existing AS (
    SELECT
      CASE
        WHEN coalesce(p.pesdb_unavailable, false) THEN 'restore_and_update'
        ELSE 'update_stats'
      END::text AS action,
      s.konami_id,
      coalesce(s.player_name, p."Name") AS player_name,
      p."Contracted_Team" AS club,
      'Update Rating, Potential, MV, wage, etc. from scrape'::text AS detail,
      p."Rating"::text AS old_rating,
      s.rating::text AS new_rating,
      coalesce(p.pesdb_unavailable, false) AS pesdb_unavailable
    FROM staging s
    JOIN public."Players" p ON p."Konami_ID"::text = s.konami_id
    WHERE s.rating IS DISTINCT FROM nullif(btrim(p."Rating"::text), '')::smallint
       OR s.max_level_rating IS DISTINCT FROM nullif(btrim(p."Potential"::text), '')::smallint
       OR s.calc_potential IS DISTINCT FROM nullif(btrim(p."Calc_Potential"::text), '')::smallint
       OR s.age IS DISTINCT FROM nullif(btrim(p."Age"::text), '')::smallint
       OR coalesce(s.nationality, '') IS DISTINCT FROM coalesce(nullif(btrim(p."Nation"::text), ''), '')
       OR coalesce(s.position, '') IS DISTINCT FROM coalesce(nullif(btrim(p."Position"::text), ''), '')
       OR coalesce(s.playing_style, '') IS DISTINCT FROM coalesce(nullif(btrim(p."Playstyle"::text), ''), '')
       OR coalesce(p.pesdb_unavailable, false)
  ),
  unchanged AS (
    SELECT
      'unchanged'::text AS action,
      s.konami_id,
      p."Name" AS player_name,
      p."Contracted_Team" AS club,
      'Stats already match staging'::text AS detail,
      p."Rating"::text AS old_rating,
      s.rating::text AS new_rating,
      coalesce(p.pesdb_unavailable, false) AS pesdb_unavailable
    FROM staging s
    JOIN public."Players" p ON p."Konami_ID"::text = s.konami_id
    WHERE NOT (
      s.rating IS DISTINCT FROM nullif(btrim(p."Rating"::text), '')::smallint
      OR s.max_level_rating IS DISTINCT FROM nullif(btrim(p."Potential"::text), '')::smallint
      OR s.calc_potential IS DISTINCT FROM nullif(btrim(p."Calc_Potential"::text), '')::smallint
      OR s.age IS DISTINCT FROM nullif(btrim(p."Age"::text), '')::smallint
      OR coalesce(s.nationality, '') IS DISTINCT FROM coalesce(nullif(btrim(p."Nation"::text), ''), '')
      OR coalesce(s.position, '') IS DISTINCT FROM coalesce(nullif(btrim(p."Position"::text), ''), '')
      OR coalesce(s.playing_style, '') IS DISTINCT FROM coalesce(nullif(btrim(p."Playstyle"::text), ''), '')
      OR coalesce(p.pesdb_unavailable, false)
    )
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
    c.pesdb_unavailable
  FROM combined c
  ORDER BY c.action, c.konami_id;
$$;

-- ---------------------------------------------------------------------------
-- Apply sync
-- ---------------------------------------------------------------------------

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
  v_restored int := 0;
  v_unchanged int := 0;
  v_rec record;
  v_club text;
  v_wage numeric;
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
      count(*) FILTER (WHERE action IN ('update_stats', 'restore_and_update')),
      count(*) FILTER (WHERE action = 'restore_and_update'),
      count(*) FILTER (WHERE action = 'unchanged')
    INTO v_marked, v_inserted, v_updated, v_restored, v_unchanged
    FROM public.gpdb_pesdb_sync_audit();

    RETURN jsonb_build_object(
      'ok', true,
      'dry_run', true,
      'staging_rows', v_staging,
      'would_mark_unavailable', v_marked,
      'would_insert_free_agents', v_inserted,
      'would_update', v_updated,
      'would_restore_from_legacy', v_restored,
      'unchanged', v_unchanged
    );
  END IF;

  -- 1. Mark legacy cards (in GPSL, not in scrape)
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

  -- 2. Update matched players from staging
  FOR v_rec IN
    SELECT
      s.*,
      p."Konami_ID"::text AS kid,
      p."Contracted_Team" AS club,
      p.pesdb_unavailable AS was_unavailable
    FROM public.gpdb_pesdb_staging s
    JOIN public."Players" p ON p."Konami_ID"::text = s.konami_id
  LOOP
    v_club := public.player_contracted_club_key(v_rec.club);
    v_wage := NULL;

    IF v_club IS NOT NULL AND v_rec.market_value IS NOT NULL THEN
      v_wage := round(
        public.calculate_player_wage_for_club(v_rec.kid, v_club),
        0
      );
      -- Recalc wage from NEW market value (function reads player row — update MV first in same statement)
    END IF;

    UPDATE public."Players" p
    SET
      "Name" = coalesce(v_rec.player_name, p."Name"),
      "Position" = coalesce(v_rec.position, p."Position"),
      "Nation" = coalesce(v_rec.nationality, p."Nation"),
      "Age" = coalesce(v_rec.age::text, p."Age"::text),
      "Rating" = coalesce(v_rec.rating::text, p."Rating"::text),
      "Potential" = coalesce(v_rec.max_level_rating::text, p."Potential"::text),
      "Calc_Potential" = coalesce(v_rec.calc_potential::text, p."Calc_Potential"::text),
      "Playstyle" = coalesce(v_rec.playing_style, p."Playstyle"),
      market_value = coalesce(
        v_rec.market_value,
        nullif(btrim(p.market_value::text), '')::numeric
      ),
      "Maximum_Reserve_Price" = coalesce(
        v_rec.maximum_reserve_price,
        nullif(btrim(p."Maximum_Reserve_Price"::text), '')::numeric
      ),
      pesdb_unavailable = false,
      pesdb_unavailable_since = NULL,
      contract_wage = CASE
        WHEN v_club IS NOT NULL AND v_rec.market_value IS NOT NULL THEN
          round(
            public.calculate_standard_player_wage(
              v_rec.market_value,
              public.competition_club_division_tier(v_club)
            ),
            0
          )
        ELSE p.contract_wage
      END
    WHERE p."Konami_ID"::text = v_rec.kid;

    v_updated := v_updated + 1;
    IF coalesce(v_rec.was_unavailable, false) THEN
      v_restored := v_restored + 1;
    END IF;
  END LOOP;

  -- 3. Insert new free agents
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
  FROM public.gpdb_pesdb_sync_audit()
  WHERE action = 'unchanged';

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

-- Admin restore single player (returned to pesdb manually before next full sync)
CREATE OR REPLACE FUNCTION public.gpdb_pesdb_restore_player(p_player_id text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_pid text := btrim(p_player_id);
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  UPDATE public."Players" p
  SET
    pesdb_unavailable = false,
    pesdb_unavailable_since = NULL
  WHERE p."Konami_ID"::text = v_pid;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Player not found: %', v_pid;
  END IF;

  RETURN jsonb_build_object('ok', true, 'player_id', v_pid, 'pesdb_unavailable', false);
END;
$function$;

CREATE OR REPLACE FUNCTION public.gpdb_pesdb_unavailable_list()
RETURNS TABLE (
  konami_id text,
  player_name text,
  club text,
  position text,
  rating text,
  contract_seasons_remaining smallint,
  unavailable_since timestamptz
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    p."Konami_ID"::text,
    p."Name",
    p."Contracted_Team",
    p."Position",
    p."Rating"::text,
    p.contract_seasons_remaining,
    p.pesdb_unavailable_since
  FROM public."Players" p
  WHERE coalesce(p.pesdb_unavailable, false)
  ORDER BY p."Contracted_Team" NULLS LAST, p."Name";
$$;

-- ---------------------------------------------------------------------------
-- Transfer + contract rules for legacy (pesdb_unavailable) cards
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.assert_player_transferable(p_player_id text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_signed   text;
  v_seasons  smallint;
  v_legacy   boolean;
BEGIN
  SELECT p."Season_Signed", p.contract_seasons_remaining, p.pesdb_unavailable
  INTO v_signed, v_seasons, v_legacy
  FROM public."Players" p
  WHERE p."Konami_ID"::text = btrim(p_player_id);

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Player not found';
  END IF;

  IF coalesce(v_legacy, false) THEN
    RAISE EXCEPTION
      'This player card is no longer on pesdb.net (legacy card). It cannot be sold or listed. Renew for one season at a time from your squad.';
  END IF;

  IF public.player_signed_this_season(v_signed) THEN
    RAISE EXCEPTION
      'This player was signed in the current season and cannot be sold or listed until the next season.';
  END IF;

  IF v_seasons IS NOT NULL AND v_seasons <= 1 THEN
    RAISE EXCEPTION
      'Player is in the final year of their contract and cannot be sold or listed. Renew or expire the contract from your squad page.';
  END IF;
END;
$function$;

CREATE OR REPLACE FUNCTION public.player_expiry_auction_applies(p_player_id text)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_player public."Players"%rowtype;
  v_club text;
BEGIN
  SELECT * INTO v_player
  FROM public."Players" p
  WHERE p."Konami_ID"::text = btrim(p_player_id);

  IF NOT FOUND THEN
    RETURN false;
  END IF;

  IF coalesce(v_player.pesdb_unavailable, false) THEN
    RETURN false;
  END IF;

  v_club := public.player_contracted_club_key(v_player."Contracted_Team");
  IF v_club IS NULL THEN
    RETURN false;
  END IF;

  IF coalesce(v_player.contract_seasons_remaining, 0) <> 1 THEN
    RETURN false;
  END IF;

  IF public.is_player_homegrown_u23(btrim(p_player_id), v_club) THEN
    RETURN false;
  END IF;

  RETURN true;
END;
$function$;

CREATE OR REPLACE FUNCTION public.player_contract_renew(
  p_player_id text,
  p_wage numeric DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club    text;
  v_player  public."Players"%rowtype;
  v_pid     text := btrim(p_player_id);
  v_wage    numeric;
  v_hg_u23  boolean;
  v_season  text;
  v_years   smallint;
  v_legacy  boolean;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  v_club := public.my_club_shortname();
  IF v_club IS NULL OR btrim(v_club) = '' THEN
    RAISE EXCEPTION 'No club linked to this account';
  END IF;

  SELECT *
  INTO v_player
  FROM public."Players"
  WHERE "Konami_ID"::text = v_pid
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Player not found';
  END IF;

  IF public.player_contracted_club_key(v_player."Contracted_Team") IS DISTINCT FROM v_club THEN
    RAISE EXCEPTION 'Player is not at your club';
  END IF;

  IF coalesce(v_player.contract_seasons_remaining, 0) <> 1 THEN
    RAISE EXCEPTION 'Renewal is only available in the final contract year (1 season remaining)';
  END IF;

  v_legacy := coalesce(v_player.pesdb_unavailable, false);
  v_years := CASE WHEN v_legacy THEN 1::smallint ELSE 3::smallint END;

  v_hg_u23 := public.is_player_homegrown_u23(v_pid, v_club);
  v_wage := coalesce(p_wage, v_player.contract_wage);

  IF v_hg_u23 THEN
    v_wage := coalesce(v_player.contract_wage, v_wage);
  ELSE
    IF v_wage IS NULL OR v_wage < coalesce(v_player.contract_wage, 0) THEN
      RAISE EXCEPTION
        'Renewal wage must be at least the current contract wage (₿ %)',
        coalesce(v_player.contract_wage, 0);
    END IF;
  END IF;

  v_season := public.current_gpsl_season_label();

  UPDATE public."Players"
  SET
    contract_seasons_remaining = v_years,
    contract_wage = round(v_wage, 0),
    "Season_Signed" = v_season
  WHERE "Konami_ID"::text = v_pid;

  RETURN jsonb_build_object(
    'ok', true,
    'player_id', v_pid,
    'contract_seasons_remaining', v_years,
    'contract_wage', round(v_wage, 0),
    'homegrown_u23', v_hg_u23,
    'pesdb_legacy', v_legacy
  );
END;
$function$;

-- ---------------------------------------------------------------------------
-- Grants
-- ---------------------------------------------------------------------------

GRANT EXECUTE ON FUNCTION public.gpdb_pesdb_staging_clear() TO authenticated;
GRANT EXECUTE ON FUNCTION public.gpdb_pesdb_staging_import(jsonb, boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.gpdb_pesdb_staging_stats() TO authenticated;
GRANT EXECUTE ON FUNCTION public.gpdb_pesdb_scrape_job_get() TO authenticated;
GRANT EXECUTE ON FUNCTION public.gpdb_pesdb_scrape_job_save(jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.gpdb_pesdb_scrape_job_clear() TO authenticated;
GRANT EXECUTE ON FUNCTION public.gpdb_pesdb_sync_audit() TO authenticated;
GRANT EXECUTE ON FUNCTION public.gpdb_pesdb_sync_apply(boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.gpdb_pesdb_restore_player(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.gpdb_pesdb_unavailable_list() TO authenticated;
GRANT EXECUTE ON FUNCTION public.gpdb_pesdb_player_is_unavailable(text) TO authenticated;

NOTIFY pgrst, 'reload schema';
