-- =============================================================================
-- Manager catalog archive (import + in-game lifecycle)
--
-- Sheet upsert behaviour:
--   • New rows → insert
--   • Matched rows (slug / Previous Name) → update + un-archive if needed
--   • DB managers missing from sheet → archived (NOT deleted; history kept)
--
-- Archived managers:
--   • Hidden from MGDB / FA board / draft pool
--   • Clubs may keep them; highlighted as "no longer in game"
--   • Cannot list on Manager Transfer Market (sack only)
--   • When contract ends → full MV refund, return to DB as archived FA
--
-- Depends on: admin_managers_overload_previous_name_20260815.sql (or equivalent)
-- Safe re-run.
-- =============================================================================

ALTER TABLE public."Managers"
  ADD COLUMN IF NOT EXISTS archived boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS archived_at timestamptz;

CREATE INDEX IF NOT EXISTS managers_archived_idx
  ON public."Managers" (archived)
  WHERE archived = true;

COMMENT ON COLUMN public."Managers".archived IS
  'True when removed from the live eFootball catalog import. Kept for history; hidden from MGDB/market.';

-- ---------------------------------------------------------------------------
-- Release archived managers whose deal is over (full MV)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.manager_process_archived_exits()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_mgr record;
  v_n int := 0;
  v_rows jsonb := '[]'::jsonb;
  v_rel jsonb;
BEGIN
  FOR v_mgr IN
    SELECT m.*
    FROM public."Managers" m
    WHERE coalesce(m.archived, false) = true
      AND m.contracted_club IS NOT NULL
      AND btrim(m.contracted_club) <> ''
      -- Pending-renewal archived managers wait for the August deadline
      -- (they cannot renew); only clear deals that already hit 0 seasons.
      AND coalesce(m.pending_owner_renewal, false) = false
      AND coalesce(m.contract_seasons_remaining, 0) <= 0
    ORDER BY m.id
    FOR UPDATE OF m
  LOOP
    -- Cancel any open listing first
    UPDATE public."Manager_Transfer_Listings"
    SET status = 'Cancelled', updated_at = now()
    WHERE manager_id = v_mgr.id AND status = 'Active';

    v_rel := public.manager_release_from_club(
      v_mgr.id,
      v_mgr.contracted_club::text,
      v_mgr.market_value::numeric,
      'transfer_sale'::text,
      format(
        'Manager left game catalog — full MV refund (%s)',
        coalesce(v_mgr.name, v_mgr.id::text)
      )::text,
      jsonb_build_object(
        'archived_exit', true,
        'full_mv_refund', true,
        'manager_id', v_mgr.id
      )::jsonb
    );

    -- Stay archived free agent in the database
    UPDATE public."Managers"
    SET archived = true,
        archived_at = coalesce(archived_at, now()),
        pending_owner_renewal = false,
        updated_at = now()
    WHERE id = v_mgr.id;

    v_n := v_n + 1;
    v_rows := v_rows || jsonb_build_array(jsonb_build_object(
      'manager_id', v_mgr.id,
      'club', v_mgr.contracted_club,
      'action', 'archived_contract_ended',
      'payout', v_mgr.market_value,
      'release', v_rel
    ));
  END LOOP;

  RETURN jsonb_build_object('ok', true, 'released', v_n, 'results', v_rows);
END;
$function$;

-- ---------------------------------------------------------------------------
-- Block transfer list for archived managers
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.manager_list_for_transfer(p_manager_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text;
  v_mgr public."Managers"%rowtype;
  v_end timestamptz;
  v_listing_id bigint;
  v_season_id bigint;
  v_month text;
  v_now timestamptz := now();
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  IF NOT public.manager_list_sack_window_open() THEN
    RAISE EXCEPTION
      'Manager listing is only available in June, July, August, or the January transfer window';
  END IF;

  v_club := public.my_club_shortname();
  IF v_club IS NULL THEN
    RAISE EXCEPTION 'No club linked to your account';
  END IF;

  SELECT * INTO v_mgr FROM public."Managers" WHERE id = p_manager_id FOR UPDATE;
  IF NOT FOUND OR v_mgr.contracted_club IS DISTINCT FROM v_club THEN
    RAISE EXCEPTION 'Manager not at your club';
  END IF;

  IF coalesce(v_mgr.archived, false) THEN
    RAISE EXCEPTION
      'This manager is no longer in the game catalog — they cannot be listed. You may only sack them; when the contract ends you receive full market value.';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public."Manager_Transfer_Listings"
    WHERE manager_id = p_manager_id AND status = 'Active'
  ) THEN
    RAISE EXCEPTION 'Manager already listed';
  END IF;

  SELECT id INTO v_season_id
  FROM public.competition_seasons WHERE is_current = true ORDER BY id DESC LIMIT 1;

  v_month := lower(coalesce(public.competition_active_gpsl_month(v_season_id, v_now), ''));
  v_end := public.compute_standard_listing_end_time(v_now);

  INSERT INTO public."Manager_Transfer_Listings" (
    manager_id, seller_club_id, listing_type, status, end_time, market_value, metadata
  )
  VALUES (
    p_manager_id, v_club, 'standard', 'Active', v_end, v_mgr.market_value,
    jsonb_build_object(
      'gpsl_month', v_month,
      'season_id', v_season_id,
      'end_rule', 'standard_24h_7pm_uk'
    )
  )
  RETURNING id INTO v_listing_id;

  RETURN jsonb_build_object(
    'ok', true,
    'listing_id', v_listing_id,
    'end_time', v_end
  );
END;
$function$;

-- Block owner renew for archived (preserve august-window renew rules)
CREATE OR REPLACE FUNCTION public.manager_owner_renew()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := public.my_club_shortname();
  v_mgr public."Managers"%rowtype;
  v_season_id bigint;
  v_month text;
BEGIN
  IF v_club IS NULL OR btrim(v_club) = '' THEN
    RAISE EXCEPTION 'No club';
  END IF;

  SELECT * INTO v_mgr
  FROM public."Managers"
  WHERE contracted_club = v_club
    AND pending_owner_renewal IS TRUE
  LIMIT 1;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'No manager renewal pending for your club';
  END IF;

  IF coalesce(v_mgr.archived, false) THEN
    RAISE EXCEPTION
      'This manager is no longer in the game catalog and cannot be renewed. Keep them until the deal ends (full MV refund) or sack them.';
  END IF;

  SELECT id INTO v_season_id
  FROM public.competition_seasons
  WHERE is_current = true
  ORDER BY id DESC
  LIMIT 1;

  v_month := lower(coalesce(public.competition_active_gpsl_month(v_season_id, now()), ''));

  IF v_month <> '' AND NOT public.manager_renewal_window_open(v_month) THEN
    RAISE EXCEPTION
      'Manager renewal window closed at the start of August. Unrenewed managers are released for market value.';
  END IF;

  UPDATE public."Managers"
  SET contract_seasons_remaining = 2,
      pending_owner_renewal = false,
      signed_season_id = v_season_id,
      deal_start_season_id = v_season_id,
      weekly_wage = public.manager_weekly_wage_for(market_value),
      updated_at = now()
  WHERE id = v_mgr.id;

  RETURN jsonb_build_object(
    'ok', true,
    'action', 'renewed',
    'manager_id', v_mgr.id,
    'club', v_club,
    'contract_seasons_remaining', 2
  );
END;
$function$;

-- ---------------------------------------------------------------------------
-- FA board: never pick archived
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.manager_window_fa_pick_ids(
  p_season_id bigint,
  p_limit int DEFAULT 10
)
RETURNS bigint[]
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_limit int := greatest(0, least(coalesce(p_limit, 10), 20));
  v_ids bigint[] := ARRAY[]::bigint[];
  v_id bigint;
  v_band text;
  v_need int;
  v_bands text[] := ARRAY['low', 'mid', 'upper', 'elite'];
  v_quotas_full int[] := ARRAY[2, 3, 3, 2];
  v_quotas int[] := ARRAY[0, 0, 0, 0];
  v_i int;
  v_sum int := 0;
  v_have int;
BEGIN
  IF v_limit <= 0 THEN
    RETURN v_ids;
  END IF;

  FOR v_i IN 1..4 LOOP
    v_quotas[v_i] := greatest(
      0,
      round((v_quotas_full[v_i]::numeric / 10.0) * v_limit)::int
    );
    v_sum := v_sum + v_quotas[v_i];
  END LOOP;
  IF v_sum > v_limit THEN
    v_quotas[2] := greatest(0, v_quotas[2] - (v_sum - v_limit));
  END IF;

  FOR v_i IN 1..4 LOOP
    v_band := v_bands[v_i];
    v_have := coalesce(array_length(v_ids, 1), 0);
    EXIT WHEN v_have >= v_limit;

    v_need := least(v_quotas[v_i], v_limit - v_have);
    IF v_need <= 0 THEN CONTINUE; END IF;

    FOR v_id IN
      SELECT m.id
      FROM public."Managers" m
      WHERE coalesce(m.archived, false) = false
        AND (m.contracted_club IS NULL OR btrim(m.contracted_club) = '')
        AND NOT EXISTS (
          SELECT 1
          FROM public."Manager_Transfer_Listings" l
          WHERE l.manager_id = m.id
            AND l.status = 'Active'
            AND l.listing_type IN ('window_fa', 'standard', 'direct')
        )
        AND NOT (m.id = ANY (v_ids))
        AND (
          (v_band = 'low' AND coalesce(m.rating, 0) <= 65)
          OR (v_band = 'mid' AND coalesce(m.rating, 0) BETWEEN 66 AND 72)
          OR (v_band = 'upper' AND coalesce(m.rating, 0) BETWEEN 73 AND 78)
          OR (v_band = 'elite' AND coalesce(m.rating, 0) >= 79)
        )
      ORDER BY random()
      LIMIT v_need
    LOOP
      v_ids := array_append(v_ids, v_id);
      EXIT WHEN coalesce(array_length(v_ids, 1), 0) >= v_limit;
    END LOOP;
  END LOOP;

  WHILE coalesce(array_length(v_ids, 1), 0) < v_limit LOOP
    SELECT m.id INTO v_id
    FROM public."Managers" m
    WHERE coalesce(m.archived, false) = false
      AND (m.contracted_club IS NULL OR btrim(m.contracted_club) = '')
      AND NOT EXISTS (
        SELECT 1
        FROM public."Manager_Transfer_Listings" l
        WHERE l.manager_id = m.id
          AND l.status = 'Active'
          AND l.listing_type IN ('window_fa', 'standard', 'direct')
      )
      AND NOT (m.id = ANY (v_ids))
    ORDER BY random()
    LIMIT 1;

    EXIT WHEN v_id IS NULL;
    v_ids := array_append(v_ids, v_id);
  END LOOP;

  RETURN v_ids;
END;
$function$;

-- ---------------------------------------------------------------------------
-- Catalog upsert with archive-missing
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.admin_managers_catalog_upsert(
  p_rows jsonb,
  p_archive_missing boolean DEFAULT true
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_elem jsonb;
  v_norm jsonb;
  v_slug text;
  v_id bigint;
  v_was_club text;
  v_insert int := 0;
  v_update int := 0;
  v_rename int := 0;
  v_unchanged int := 0;
  v_archived int := 0;
  v_unarchived int := 0;
  v_errors jsonb := '[]'::jsonb;
  v_seen text[] := ARRAY[]::text[];
  v_seen_ids bigint[] := ARRAY[]::bigint[];
  v_dupes int := 0;
  v_i int := 0;
  v_wage bigint;
  v_wage_pct numeric;
  v_rating int;
  v_clubs_synced int := 0;
  v_conflict bigint;
  v_old_name text;
  v_old_slug text;
  v_was_archived boolean;
  v_exit jsonb;
BEGIN
  IF NOT public.is_gpsl_admin()
     AND current_user NOT IN ('postgres', 'supabase_admin', 'service_role') THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF p_rows IS NULL OR jsonb_typeof(p_rows) <> 'array' THEN
    RAISE EXCEPTION 'p_rows must be a JSON array';
  END IF;

  SELECT coalesce(manager_wage_pct, 50) INTO v_wage_pct
  FROM public.global_settings WHERE id = 1;
  IF v_wage_pct IS NULL OR v_wage_pct <= 0 THEN
    v_wage_pct := 50;
  END IF;

  FOR v_elem IN SELECT * FROM jsonb_array_elements(p_rows)
  LOOP
    v_i := v_i + 1;
    v_norm := public.admin_managers_normalize_row(v_elem);
    IF coalesce((v_norm->>'ok')::boolean, false) IS NOT TRUE THEN
      v_errors := v_errors || jsonb_build_array(
        jsonb_build_object('row', v_i, 'error', v_norm->>'error', 'name', v_norm->>'name')
      );
      CONTINUE;
    END IF;

    v_slug := v_norm->>'slug';
    IF v_slug = ANY (v_seen) THEN
      v_dupes := v_dupes + 1;
      CONTINUE;
    END IF;
    v_seen := array_append(v_seen, v_slug);

    v_rating := (v_norm->>'rating')::int;
    v_wage := greatest(
      0,
      round(
        ((v_norm->>'market_value')::numeric) * (v_wage_pct / 100.0) / 52.0
      )::bigint
    );

    v_id := public.admin_managers_resolve_existing_id(
      v_slug, v_norm->>'previous_slug', v_norm->>'previous_name'
    );

    IF v_id IS NULL THEN
      INSERT INTO public."Managers" (
        slug, name, nation, possession, quick_counter, long_ball_counter,
        out_wide, long_ball, overload, age, rating, market_value, weekly_wage,
        contracted_club, contract_seasons_remaining, archived, archived_at
      )
      VALUES (
        v_slug,
        v_norm->>'name',
        v_norm->>'nation',
        (v_norm->>'possession')::smallint,
        (v_norm->>'quick_counter')::smallint,
        (v_norm->>'long_ball_counter')::smallint,
        (v_norm->>'out_wide')::smallint,
        (v_norm->>'long_ball')::smallint,
        coalesce((v_norm->>'overload')::smallint, 0),
        nullif(v_norm->>'age', '')::smallint,
        v_rating::smallint,
        (v_norm->>'market_value')::bigint,
        v_wage,
        NULL,
        0,
        false,
        NULL
      )
      RETURNING id INTO v_id;
      v_insert := v_insert + 1;
      v_seen_ids := array_append(v_seen_ids, v_id);
      CONTINUE;
    END IF;

    SELECT id INTO v_conflict
    FROM public."Managers"
    WHERE slug = v_slug AND id <> v_id
    LIMIT 1;
    IF v_conflict IS NOT NULL THEN
      v_errors := v_errors || jsonb_build_array(jsonb_build_object(
        'row', v_i,
        'error', 'New slug already belongs to another manager',
        'name', v_norm->>'name',
        'slug', v_slug
      ));
      CONTINUE;
    END IF;

    SELECT name, slug, contracted_club, coalesce(archived, false)
    INTO v_old_name, v_old_slug, v_was_club, v_was_archived
    FROM public."Managers"
    WHERE id = v_id;

    UPDATE public."Managers" m
    SET
      slug = v_slug,
      name = v_norm->>'name',
      nation = v_norm->>'nation',
      possession = (v_norm->>'possession')::smallint,
      quick_counter = (v_norm->>'quick_counter')::smallint,
      long_ball_counter = (v_norm->>'long_ball_counter')::smallint,
      out_wide = (v_norm->>'out_wide')::smallint,
      long_ball = (v_norm->>'long_ball')::smallint,
      overload = coalesce((v_norm->>'overload')::smallint, 0),
      age = coalesce(nullif(v_norm->>'age', '')::smallint, m.age),
      rating = v_rating::smallint,
      market_value = (v_norm->>'market_value')::bigint,
      weekly_wage = CASE
        WHEN m.contracted_club IS NULL OR btrim(m.contracted_club) = '' THEN v_wage
        ELSE m.weekly_wage
      END,
      archived = false,
      archived_at = NULL,
      updated_at = now()
    WHERE m.id = v_id;

    IF v_was_archived THEN
      v_unarchived := v_unarchived + 1;
    END IF;

    IF v_old_name IS DISTINCT FROM (v_norm->>'name')
       OR v_old_slug IS DISTINCT FROM v_slug THEN
      v_rename := v_rename + 1;
      v_update := v_update + 1;
    ELSE
      v_update := v_update + 1;
    END IF;

    IF v_was_club IS NOT NULL AND btrim(v_was_club) <> '' THEN
      UPDATE public."Clubs" c
      SET manager_rating = v_rating::smallint
      WHERE c."ShortName" = v_was_club
        AND c.manager_id = v_id
        AND c.manager_rating IS DISTINCT FROM v_rating::smallint;
      IF FOUND THEN
        v_clubs_synced := v_clubs_synced + 1;
      END IF;
    END IF;

    v_seen_ids := array_append(v_seen_ids, v_id);
  END LOOP;

  -- Never archive-everyone if the sheet produced zero successful rows
  IF coalesce(p_archive_missing, true)
     AND coalesce(array_length(v_seen, 1), 0) > 0 THEN
    UPDATE public."Managers" m
    SET archived = true,
        archived_at = coalesce(m.archived_at, now()),
        updated_at = now()
    WHERE coalesce(m.archived, false) = false
      AND NOT (m.id = ANY (v_seen_ids));

    GET DIAGNOSTICS v_archived = ROW_COUNT;

    -- Cancel market listings for newly archived managers
    UPDATE public."Manager_Transfer_Listings" l
    SET status = 'Cancelled', updated_at = now()
    WHERE l.status = 'Active'
      AND l.listing_type IN ('standard', 'direct', 'window_fa', 'draft')
      AND EXISTS (
        SELECT 1 FROM public."Managers" m
        WHERE m.id = l.manager_id AND coalesce(m.archived, false) = true
      );
  END IF;

  v_exit := public.manager_process_archived_exits();

  RETURN jsonb_build_object(
    'ok', true,
    'input_rows', v_i,
    'unique_slugs', coalesce(array_length(v_seen, 1), 0),
    'duplicate_slugs_skipped', v_dupes,
    'inserted', v_insert,
    'updated', v_update,
    'renamed', v_rename,
    'unarchived', v_unarchived,
    'archived_missing', v_archived,
    'archive_missing_enabled', coalesce(p_archive_missing, true),
    'clubs_manager_rating_synced', v_clubs_synced,
    'archived_exits', v_exit,
    'errors', v_errors,
    'retained', jsonb_build_object(
      'ids', true,
      'contracts_while_signed', true,
      'career_stints', true,
      'history', true
    )
  );
END;
$function$;

-- Core preview (insert/update samples) — extracted so 2-arg preview can wrap it
CREATE OR REPLACE FUNCTION public.admin_managers_catalog_preview_core(p_rows jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_elem jsonb;
  v_norm jsonb;
  v_slug text;
  v_id bigint;
  v_existing record;
  v_insert int := 0;
  v_update int := 0;
  v_rename int := 0;
  v_unchanged int := 0;
  v_errors jsonb := '[]'::jsonb;
  v_samples jsonb := '[]'::jsonb;
  v_seen text[] := ARRAY[]::text[];
  v_dupes int := 0;
  v_i int := 0;
  v_will_change boolean;
  v_conflict bigint;
BEGIN
  IF p_rows IS NULL OR jsonb_typeof(p_rows) <> 'array' THEN
    RAISE EXCEPTION 'p_rows must be a JSON array';
  END IF;

  FOR v_elem IN SELECT * FROM jsonb_array_elements(p_rows)
  LOOP
    v_i := v_i + 1;
    v_norm := public.admin_managers_normalize_row(v_elem);
    IF coalesce((v_norm->>'ok')::boolean, false) IS NOT TRUE THEN
      v_errors := v_errors || jsonb_build_array(
        jsonb_build_object('row', v_i, 'error', v_norm->>'error', 'name', v_norm->>'name')
      );
      CONTINUE;
    END IF;

    v_slug := v_norm->>'slug';
    IF v_slug = ANY (v_seen) THEN
      v_dupes := v_dupes + 1;
      CONTINUE;
    END IF;
    v_seen := array_append(v_seen, v_slug);

    v_id := public.admin_managers_resolve_existing_id(
      v_slug, v_norm->>'previous_slug', v_norm->>'previous_name'
    );

    IF v_id IS NULL THEN
      v_insert := v_insert + 1;
      IF jsonb_array_length(v_samples) < 20 THEN
        v_samples := v_samples || jsonb_build_array(jsonb_build_object(
          'action', 'insert',
          'slug', v_slug,
          'name', v_norm->>'name',
          'rating', (v_norm->>'rating')::int,
          'overload', coalesce((v_norm->>'overload')::int, 0),
          'market_value', (v_norm->>'market_value')::bigint
        ));
      END IF;
      CONTINUE;
    END IF;

    SELECT id INTO v_conflict
    FROM public."Managers" WHERE slug = v_slug AND id <> v_id LIMIT 1;
    IF v_conflict IS NOT NULL THEN
      v_errors := v_errors || jsonb_build_array(jsonb_build_object(
        'row', v_i, 'error', 'New slug already belongs to another manager',
        'name', v_norm->>'name', 'slug', v_slug
      ));
      CONTINUE;
    END IF;

    SELECT m.id, m.name, m.slug, m.rating, m.market_value, m.contracted_club,
           m.possession, m.quick_counter, m.long_ball_counter, m.out_wide,
           m.long_ball, coalesce(m.overload, 0) AS overload, m.age, m.nation,
           coalesce(m.archived, false) AS archived
    INTO v_existing
    FROM public."Managers" m WHERE m.id = v_id;

    v_will_change :=
      v_existing.name IS DISTINCT FROM (v_norm->>'name')
      OR v_existing.slug IS DISTINCT FROM v_slug
      OR v_existing.nation IS DISTINCT FROM (v_norm->>'nation')
      OR v_existing.age IS DISTINCT FROM nullif(v_norm->>'age', '')::int
      OR v_existing.possession IS DISTINCT FROM (v_norm->>'possession')::int
      OR v_existing.quick_counter IS DISTINCT FROM (v_norm->>'quick_counter')::int
      OR v_existing.long_ball_counter IS DISTINCT FROM (v_norm->>'long_ball_counter')::int
      OR v_existing.out_wide IS DISTINCT FROM (v_norm->>'out_wide')::int
      OR v_existing.long_ball IS DISTINCT FROM (v_norm->>'long_ball')::int
      OR v_existing.overload IS DISTINCT FROM coalesce((v_norm->>'overload')::int, 0)
      OR v_existing.rating IS DISTINCT FROM (v_norm->>'rating')::int
      OR v_existing.market_value IS DISTINCT FROM (v_norm->>'market_value')::bigint
      OR v_existing.archived = true;

    IF v_will_change THEN
      v_update := v_update + 1;
      IF v_existing.name IS DISTINCT FROM (v_norm->>'name')
         OR v_existing.slug IS DISTINCT FROM v_slug THEN
        v_rename := v_rename + 1;
      END IF;
      IF jsonb_array_length(v_samples) < 20 THEN
        v_samples := v_samples || jsonb_build_array(jsonb_build_object(
          'action', 'update',
          'id', v_existing.id,
          'slug', v_slug,
          'name', v_norm->>'name',
          'name_before', v_existing.name,
          'was_archived', v_existing.archived,
          'contracted_club', v_existing.contracted_club,
          'rating_before', v_existing.rating,
          'rating_after', (v_norm->>'rating')::int,
          'overload_before', v_existing.overload,
          'overload_after', coalesce((v_norm->>'overload')::int, 0),
          'mv_before', v_existing.market_value,
          'mv_after', (v_norm->>'market_value')::bigint
        ));
      END IF;
    ELSE
      v_unchanged := v_unchanged + 1;
    END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true,
    'input_rows', v_i,
    'unique_slugs', coalesce(array_length(v_seen, 1), 0),
    'duplicate_slugs_skipped', v_dupes,
    'would_insert', v_insert,
    'would_update', v_update,
    'would_rename', v_rename,
    'unchanged', v_unchanged,
    'errors', v_errors,
    'samples', v_samples
  );
END;
$function$;

-- Fix preview: don't recurse — call core only
CREATE OR REPLACE FUNCTION public.admin_managers_catalog_preview(
  p_rows jsonb,
  p_archive_missing boolean DEFAULT true
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_base jsonb;
  v_elem jsonb;
  v_norm jsonb;
  v_slug text;
  v_id bigint;
  v_seen_ids bigint[] := ARRAY[]::bigint[];
  v_seen text[] := ARRAY[]::text[];
  v_would_archive int := 0;
BEGIN
  IF NOT public.is_gpsl_admin()
     AND current_user NOT IN ('postgres', 'supabase_admin', 'service_role') THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  v_base := public.admin_managers_catalog_preview_core(p_rows);

  FOR v_elem IN SELECT * FROM jsonb_array_elements(coalesce(p_rows, '[]'::jsonb))
  LOOP
    v_norm := public.admin_managers_normalize_row(v_elem);
    IF coalesce((v_norm->>'ok')::boolean, false) IS NOT TRUE THEN CONTINUE; END IF;
    v_slug := v_norm->>'slug';
    IF v_slug = ANY (v_seen) THEN CONTINUE; END IF;
    v_seen := array_append(v_seen, v_slug);
    v_id := public.admin_managers_resolve_existing_id(
      v_slug, v_norm->>'previous_slug', v_norm->>'previous_name'
    );
    IF v_id IS NOT NULL THEN
      v_seen_ids := array_append(v_seen_ids, v_id);
    END IF;
  END LOOP;

  IF coalesce(p_archive_missing, true)
     AND coalesce(array_length(v_seen, 1), 0) > 0 THEN
    SELECT count(*)::int INTO v_would_archive
    FROM public."Managers" m
    WHERE coalesce(m.archived, false) = false
      AND NOT (m.id = ANY (v_seen_ids));
  END IF;

  RETURN v_base || jsonb_build_object(
    'would_archive', v_would_archive,
    'archive_missing_enabled', coalesce(p_archive_missing, true),
    'note', 'New → insert. Matched → update (un-archive). Missing from sheet → archive (kept). Signed archived: keep/sack only; full MV when contract ends.'
  );
END;
$function$;

-- Keep 1-arg upsert/preview working (PostgREST)
CREATE OR REPLACE FUNCTION public.admin_managers_catalog_upsert(p_rows jsonb)
RETURNS jsonb
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT public.admin_managers_catalog_upsert(p_rows, true);
$$;

CREATE OR REPLACE FUNCTION public.admin_managers_catalog_preview(p_rows jsonb)
RETURNS jsonb
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT public.admin_managers_catalog_preview(p_rows, true);
$$;

-- ---------------------------------------------------------------------------
-- Views: hide archived from MGDB; expose flag on club status
-- ---------------------------------------------------------------------------

DROP VIEW IF EXISTS public.managers_gpdb_public;

CREATE VIEW public.managers_gpdb_public
WITH (security_invoker = true)
AS
SELECT
  m.id,
  m.slug,
  m.name,
  m.nation,
  m.possession,
  m.quick_counter,
  m.long_ball_counter,
  m.out_wide,
  m.long_ball,
  coalesce(m.overload, 0) AS overload,
  m.age,
  m.rating,
  m.market_value,
  m.contracted_club,
  m.contract_seasons_remaining,
  m.weekly_wage,
  CASE
    WHEN m.contracted_club IS NULL OR btrim(m.contracted_club) = '' THEN 'FREE AGENT'
    ELSE m.contracted_club
  END AS contracted_display,
  public.manager_boost_band_label(1, e.boost1_min, e.boost1_max) AS boost1_label,
  public.manager_boost_band_label(2, e.boost2_min, e.boost2_max) AS boost2_label,
  public.manager_boost_band_label(3, e.boost3_min, e.boost3_max) AS boost3_label,
  (SELECT tf.label FROM public.manager_target_for(m.rating, 'superleague') tf) AS target_superleague,
  (SELECT tf.label FROM public.manager_target_for(m.rating, 'championship_a') tf) AS target_championship_a,
  (SELECT tf.label FROM public.manager_target_for(m.rating, 'championship_b') tf) AS target_championship_b
FROM public."Managers" m
LEFT JOIN public.manager_proficiency_expectancy e
  ON e.proficiency = public.manager_proficiency_clamp(m.rating)
WHERE coalesce(m.archived, false) = false;

GRANT SELECT ON public.managers_gpdb_public TO authenticated;
GRANT SELECT ON public.managers_gpdb_public TO anon;

DROP VIEW IF EXISTS public.manager_club_status_public;

CREATE VIEW public.manager_club_status_public
WITH (security_invoker = true)
AS
SELECT
  c."ShortName" AS club_short_name,
  m.id AS manager_id,
  m.name AS manager_name,
  m.rating AS manager_rating,
  m.market_value,
  m.contract_seasons_remaining,
  m.weekly_wage,
  m.pending_owner_renewal,
  m.deal_start_season_id,
  coalesce(m.archived, false) AS manager_archived,
  c.manager_sacks_remaining,
  coalesce(pos.division, ccs.division) AS division,
  pos.season_position,
  t.target_kind,
  t.target_value,
  t.label AS target_label,
  public.manager_target_met(
    t,
    pos.season_position,
    coalesce(pos.division, ccs.division)
  ) AS target_met,
  public.manager_boost_band_label(1, e.boost1_min, e.boost1_max) AS boost1_label,
  public.manager_boost_band_label(2, e.boost2_min, e.boost2_max) AS boost2_label,
  public.manager_boost_band_label(3, e.boost3_min, e.boost3_max) AS boost3_label,
  (
    SELECT count(*)::int
    FROM public.manager_deal_season_results r
    WHERE r.manager_id = m.id
      AND r.club_short_name = c."ShortName"
      AND r.deal_start_season_id = coalesce(m.deal_start_season_id, m.signed_season_id)
      AND r.target_met IS TRUE
  ) AS deal_target_hits,
  (
    SELECT count(*)::int
    FROM public.manager_deal_season_results r
    WHERE r.manager_id = m.id
      AND r.club_short_name = c."ShortName"
      AND r.deal_start_season_id = coalesce(m.deal_start_season_id, m.signed_season_id)
      AND r.target_met IS FALSE
  ) AS deal_target_misses
FROM public."Clubs" c
LEFT JOIN public."Managers" m ON m.id = c.manager_id
LEFT JOIN public.competition_seasons s ON s.is_current = true
LEFT JOIN public.competition_club_seasons ccs
  ON ccs.club_short_name = c."ShortName" AND ccs.season_id = s.id
LEFT JOIN LATERAL public.manager_club_season_position(s.id, c."ShortName") pos ON s.id IS NOT NULL
LEFT JOIN public.manager_rating_targets t
  ON m.id IS NOT NULL
  AND coalesce(pos.division, ccs.division) IS NOT NULL
  AND m.rating BETWEEN t.min_rating AND t.max_rating
  AND t.division = coalesce(pos.division, ccs.division)
  AND t.id = (
    SELECT t2.id
    FROM public.manager_rating_targets t2
    WHERE t2.division = coalesce(pos.division, ccs.division)
      AND m.rating BETWEEN t2.min_rating AND t2.max_rating
    ORDER BY t2.sort_order, t2.id
    LIMIT 1
  )
LEFT JOIN public.manager_proficiency_expectancy e
  ON m.id IS NOT NULL
  AND e.proficiency = public.manager_proficiency_clamp(m.rating);

GRANT SELECT ON public.manager_club_status_public TO authenticated;

-- Hook archived exits after season-end processing (keep inbox notify)
CREATE OR REPLACE FUNCTION public.manager_process_season_end_with_inbox()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_result jsonb;
  v_archived jsonb;
BEGIN
  v_result := public.manager_process_season_end();
  v_archived := public.manager_process_archived_exits();

  IF to_regprocedure('public.owner_inbox_notify_manager_season_end(jsonb)') IS NOT NULL THEN
    PERFORM public.owner_inbox_notify_manager_season_end(
      coalesce(v_result->'results', '[]'::jsonb)
      || coalesce(v_archived->'results', '[]'::jsonb)
    );
  END IF;

  RETURN coalesce(v_result, '{}'::jsonb) || jsonb_build_object('archived_exits', v_archived);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.manager_process_archived_exits() TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_managers_catalog_preview_core(jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_managers_catalog_preview(jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_managers_catalog_preview(jsonb, boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_managers_catalog_upsert(jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_managers_catalog_upsert(jsonb, boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.manager_list_for_transfer(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.manager_owner_renew() TO authenticated;
GRANT EXECUTE ON FUNCTION public.manager_process_season_end_with_inbox() TO authenticated;

NOTIFY pgrst, 'reload schema';
