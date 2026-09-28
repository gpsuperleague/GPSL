-- =============================================================================
-- Manager catalog import: "In Game" column (YES / NEW / NO)
--
--   YES → keep manager untouched (stats, MV, wage, contract). Only a rename
--         via Former/Previous Name is applied; un-archived if it was archived.
--   NEW → insert with rating / market value / wage calculated from playstyles.
--         If the name already exists (e.g. sheet re-run) it is updated instead.
--   NO  → archive (hidden from MGDB, FA board and market; active listings
--         cancelled). Signed clubs keep them until the deal ends (full MV).
--   blank / column absent → previous behaviour (full update or insert).
--
-- Matching is unchanged: slug of Manager Name → slug of Former/Previous Name
-- → exact Former/Previous Name. When found via the old name, the manager is
-- renamed to Manager Name (same id / contract / history).
--
-- Depends on: admin_managers_overload_previous_name_20260815.sql,
--             admin_managers_archive_catalog_20260815.sql,
--             admin_managers_former_name_alias_20260815.sql
-- Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.admin_managers_row_in_game(p_row jsonb)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE
AS $function$
DECLARE
  v_raw text;
BEGIN
  SELECT e.value INTO v_raw
  FROM jsonb_each_text(coalesce(p_row, '{}'::jsonb)) e
  WHERE regexp_replace(lower(e.key), '[^a-z]', '', 'g') = 'ingame'
  LIMIT 1;

  v_raw := lower(btrim(coalesce(v_raw, '')));
  IF v_raw = '' THEN
    RETURN NULL;
  ELSIF v_raw IN ('yes', 'y', 'true', '1') THEN
    RETURN 'yes';
  ELSIF v_raw IN ('new') THEN
    RETURN 'new';
  ELSIF v_raw IN ('no', 'false', '0') THEN
    RETURN 'no';
  END IF;
  RETURN 'invalid:' || v_raw;
END;
$function$;

-- Decide what one sheet row will do (shared by preview + apply)
CREATE OR REPLACE FUNCTION public.admin_managers_catalog_plan_row(p_row jsonb)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v jsonb := coalesce(p_row, '{}'::jsonb);
  v_in_game text;
  v_name text;
  v_prev text;
  v_slug text;
  v_prev_slug text;
  v_norm jsonb;
  v_id bigint;
  v_conflict bigint;
  v_ex record;
BEGIN
  v_in_game := public.admin_managers_row_in_game(v);

  v_name := nullif(btrim(coalesce(
    v->>'name', v->>'Manager Name', v->>'manager_name', v->>'Name', ''
  )), '');
  v_prev := nullif(btrim(coalesce(
    v->>'previous_name', v->>'Previous Name', v->>'previousName',
    v->>'former_name', v->>'Former Name', v->>'Former name', v->>'formerName',
    v->>'old_name', v->>'Old Name', ''
  )), '');
  v_slug := public.admin_managers_slugify(coalesce(nullif(btrim(coalesce(v->>'slug', '')), ''), v_name));
  v_prev_slug := public.admin_managers_slugify(v_prev);

  IF v_name IS NULL OR v_slug IS NULL THEN
    RETURN jsonb_build_object('action', 'error', 'error', 'Missing name/slug');
  END IF;

  IF v_in_game LIKE 'invalid:%' THEN
    RETURN jsonb_build_object(
      'action', 'error', 'name', v_name, 'slug', v_slug,
      'error', format('In Game must be YES, NEW or NO (got "%s")', substr(v_in_game, 9))
    );
  END IF;

  v_id := public.admin_managers_resolve_existing_id(v_slug, v_prev_slug, v_prev);

  IF v_id IS NOT NULL THEN
    SELECT m.id, m.name, m.slug, m.rating, m.market_value, m.contracted_club,
           m.possession, m.quick_counter, m.long_ball_counter, m.out_wide,
           m.long_ball, coalesce(m.overload, 0) AS overload, m.age, m.nation,
           coalesce(m.archived, false) AS archived
    INTO v_ex
    FROM public."Managers" m WHERE m.id = v_id;
  END IF;

  -- NO → archive
  IF v_in_game = 'no' THEN
    IF v_id IS NULL THEN
      RETURN jsonb_build_object('action', 'no_absent', 'name', v_name, 'slug', v_slug);
    END IF;
    RETURN jsonb_build_object(
      'action', CASE WHEN v_ex.archived THEN 'already_archived' ELSE 'archive' END,
      'id', v_id, 'name', v_ex.name, 'slug', v_ex.slug,
      'contracted_club', v_ex.contracted_club
    );
  END IF;

  -- Rename target slug must not belong to someone else
  IF v_id IS NOT NULL THEN
    SELECT id INTO v_conflict
    FROM public."Managers" WHERE slug = v_slug AND id <> v_id LIMIT 1;
    IF v_conflict IS NOT NULL THEN
      RETURN jsonb_build_object(
        'action', 'error', 'name', v_name, 'slug', v_slug,
        'error', 'New slug already belongs to another manager'
      );
    END IF;
  END IF;

  -- YES → untouched (rename / un-archive only)
  IF v_in_game = 'yes' THEN
    IF v_id IS NULL THEN
      RETURN jsonb_build_object(
        'action', 'error', 'name', v_name, 'slug', v_slug,
        'error', 'Marked YES but not found in database — mark NEW to add, or fill Former Name'
      );
    END IF;
    RETURN jsonb_build_object(
      'action', CASE
        WHEN v_ex.name IS DISTINCT FROM v_name OR v_ex.slug IS DISTINCT FROM v_slug THEN 'rename'
        WHEN v_ex.archived THEN 'unarchive'
        ELSE 'keep'
      END,
      'id', v_id, 'name', v_name, 'slug', v_slug,
      'name_before', v_ex.name, 'was_archived', v_ex.archived,
      'contracted_club', v_ex.contracted_club
    );
  END IF;

  -- NEW / blank → full calculate
  v_norm := public.admin_managers_normalize_row(v);
  IF coalesce((v_norm->>'ok')::boolean, false) IS NOT TRUE THEN
    RETURN jsonb_build_object(
      'action', 'error', 'name', coalesce(v_norm->>'name', v_name), 'slug', v_slug,
      'error', v_norm->>'error'
    );
  END IF;

  IF v_id IS NULL THEN
    RETURN jsonb_build_object(
      'action', 'insert', 'in_game', v_in_game, 'name', v_norm->>'name', 'slug', v_slug,
      'norm', v_norm
    );
  END IF;

  RETURN jsonb_build_object(
    'action', CASE
      WHEN v_ex.name IS DISTINCT FROM (v_norm->>'name')
        OR v_ex.slug IS DISTINCT FROM v_slug
        OR v_ex.nation IS DISTINCT FROM (v_norm->>'nation')
        OR v_ex.age IS DISTINCT FROM nullif(v_norm->>'age', '')::int
        OR v_ex.possession IS DISTINCT FROM (v_norm->>'possession')::int
        OR v_ex.quick_counter IS DISTINCT FROM (v_norm->>'quick_counter')::int
        OR v_ex.long_ball_counter IS DISTINCT FROM (v_norm->>'long_ball_counter')::int
        OR v_ex.out_wide IS DISTINCT FROM (v_norm->>'out_wide')::int
        OR v_ex.long_ball IS DISTINCT FROM (v_norm->>'long_ball')::int
        OR v_ex.overload IS DISTINCT FROM coalesce((v_norm->>'overload')::int, 0)
        OR v_ex.rating IS DISTINCT FROM (v_norm->>'rating')::int
        OR v_ex.market_value IS DISTINCT FROM (v_norm->>'market_value')::bigint
        OR v_ex.archived
      THEN 'update' ELSE 'keep'
    END,
    'in_game', v_in_game,
    'id', v_id, 'name', v_norm->>'name', 'slug', v_slug,
    'name_before', v_ex.name, 'was_archived', v_ex.archived,
    'contracted_club', v_ex.contracted_club,
    'rating_before', v_ex.rating, 'rating_after', (v_norm->>'rating')::int,
    'overload_before', v_ex.overload, 'overload_after', coalesce((v_norm->>'overload')::int, 0),
    'mv_before', v_ex.market_value, 'mv_after', (v_norm->>'market_value')::bigint,
    'norm', v_norm
  );
END;
$function$;

-- ---------------------------------------------------------------------------
-- Apply
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
  v_plan jsonb;
  v_norm jsonb;
  v_action text;
  v_slug text;
  v_id bigint;
  v_i int := 0;
  v_seen text[] := ARRAY[]::text[];
  v_seen_ids bigint[] := ARRAY[]::bigint[];
  v_dupes int := 0;
  v_insert int := 0;
  v_update int := 0;
  v_rename int := 0;
  v_kept int := 0;
  v_unarchived int := 0;
  v_archived_no int := 0;
  v_no_absent int := 0;
  v_archived_missing int := 0;
  v_clubs_synced int := 0;
  v_errors jsonb := '[]'::jsonb;
  v_wage_pct numeric;
  v_wage bigint;
  v_rating int;
  v_club text;
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
    v_plan := public.admin_managers_catalog_plan_row(v_elem);
    v_action := v_plan->>'action';

    IF v_action = 'error' THEN
      v_errors := v_errors || jsonb_build_array(jsonb_build_object(
        'row', v_i, 'error', v_plan->>'error', 'name', v_plan->>'name'
      ));
      CONTINUE;
    END IF;

    v_slug := v_plan->>'slug';
    IF v_slug = ANY (v_seen) THEN
      v_dupes := v_dupes + 1;
      CONTINUE;
    END IF;
    v_seen := array_append(v_seen, v_slug);

    v_id := nullif(v_plan->>'id', '')::bigint;
    IF v_id IS NOT NULL THEN
      v_seen_ids := array_append(v_seen_ids, v_id);
    END IF;

    IF v_action = 'no_absent' THEN
      v_no_absent := v_no_absent + 1;

    ELSIF v_action IN ('archive', 'already_archived') THEN
      IF v_action = 'archive' THEN
        UPDATE public."Managers"
        SET archived = true,
            archived_at = coalesce(archived_at, now()),
            updated_at = now()
        WHERE id = v_id;
        v_archived_no := v_archived_no + 1;
      END IF;

    ELSIF v_action = 'keep' THEN
      v_kept := v_kept + 1;

    ELSIF v_action IN ('rename', 'unarchive') THEN
      UPDATE public."Managers"
      SET name = v_plan->>'name',
          slug = v_slug,
          archived = false,
          archived_at = NULL,
          updated_at = now()
      WHERE id = v_id;
      IF v_action = 'rename' THEN
        v_rename := v_rename + 1;
      END IF;
      IF coalesce((v_plan->>'was_archived')::boolean, false) THEN
        v_unarchived := v_unarchived + 1;
      END IF;

    ELSIF v_action IN ('insert', 'update') THEN
      v_norm := v_plan->'norm';
      v_rating := (v_norm->>'rating')::int;
      v_wage := greatest(0, round(
        ((v_norm->>'market_value')::numeric) * (v_wage_pct / 100.0) / 52.0
      )::bigint);

      IF v_action = 'insert' THEN
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
          NULL, 0, false, NULL
        )
        RETURNING id INTO v_id;
        v_seen_ids := array_append(v_seen_ids, v_id);
        v_insert := v_insert + 1;
      ELSE
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

        v_update := v_update + 1;
        IF v_plan->>'name_before' IS DISTINCT FROM v_plan->>'name' THEN
          v_rename := v_rename + 1;
        END IF;
        IF coalesce((v_plan->>'was_archived')::boolean, false) THEN
          v_unarchived := v_unarchived + 1;
        END IF;

        v_club := v_plan->>'contracted_club';
        IF v_club IS NOT NULL AND btrim(v_club) <> '' THEN
          UPDATE public."Clubs" c
          SET manager_rating = v_rating::smallint
          WHERE c."ShortName" = v_club
            AND c.manager_id = v_id
            AND c.manager_rating IS DISTINCT FROM v_rating::smallint;
          IF FOUND THEN
            v_clubs_synced := v_clubs_synced + 1;
          END IF;
        END IF;
      END IF;
    END IF;
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
    GET DIAGNOSTICS v_archived_missing = ROW_COUNT;
  END IF;

  UPDATE public."Manager_Transfer_Listings" l
  SET status = 'Cancelled', updated_at = now()
  WHERE l.status = 'Active'
    AND l.listing_type IN ('standard', 'direct', 'window_fa', 'draft')
    AND EXISTS (
      SELECT 1 FROM public."Managers" m
      WHERE m.id = l.manager_id AND coalesce(m.archived, false) = true
    );

  v_exit := public.manager_process_archived_exits();

  RETURN jsonb_build_object(
    'ok', true,
    'input_rows', v_i,
    'unique_slugs', coalesce(array_length(v_seen, 1), 0),
    'duplicate_slugs_skipped', v_dupes,
    'inserted', v_insert,
    'updated', v_update,
    'renamed', v_rename,
    'unchanged', v_kept,
    'unarchived', v_unarchived,
    'archived_in_game_no', v_archived_no,
    'in_game_no_not_in_db', v_no_absent,
    'archived_missing', v_archived_missing,
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

-- ---------------------------------------------------------------------------
-- Preview (same planner, no writes)
-- ---------------------------------------------------------------------------
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
  v_elem jsonb;
  v_plan jsonb;
  v_action text;
  v_slug text;
  v_id bigint;
  v_i int := 0;
  v_seen text[] := ARRAY[]::text[];
  v_seen_ids bigint[] := ARRAY[]::bigint[];
  v_dupes int := 0;
  v_insert int := 0;
  v_update int := 0;
  v_rename int := 0;
  v_kept int := 0;
  v_unarchive int := 0;
  v_archive_no int := 0;
  v_no_absent int := 0;
  v_would_archive int := 0;
  v_errors jsonb := '[]'::jsonb;
  v_samples jsonb := '[]'::jsonb;
BEGIN
  IF NOT public.is_gpsl_admin()
     AND current_user NOT IN ('postgres', 'supabase_admin', 'service_role') THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF p_rows IS NULL OR jsonb_typeof(p_rows) <> 'array' THEN
    RAISE EXCEPTION 'p_rows must be a JSON array';
  END IF;

  FOR v_elem IN SELECT * FROM jsonb_array_elements(p_rows)
  LOOP
    v_i := v_i + 1;
    v_plan := public.admin_managers_catalog_plan_row(v_elem);
    v_action := v_plan->>'action';

    IF v_action = 'error' THEN
      v_errors := v_errors || jsonb_build_array(jsonb_build_object(
        'row', v_i, 'error', v_plan->>'error', 'name', v_plan->>'name'
      ));
      CONTINUE;
    END IF;

    v_slug := v_plan->>'slug';
    IF v_slug = ANY (v_seen) THEN
      v_dupes := v_dupes + 1;
      CONTINUE;
    END IF;
    v_seen := array_append(v_seen, v_slug);

    v_id := nullif(v_plan->>'id', '')::bigint;
    IF v_id IS NOT NULL THEN
      v_seen_ids := array_append(v_seen_ids, v_id);
    END IF;

    CASE v_action
      WHEN 'insert' THEN v_insert := v_insert + 1;
      WHEN 'update' THEN
        v_update := v_update + 1;
        IF v_plan->>'name_before' IS DISTINCT FROM v_plan->>'name' THEN
          v_rename := v_rename + 1;
        END IF;
      WHEN 'rename' THEN v_rename := v_rename + 1;
      WHEN 'unarchive' THEN v_unarchive := v_unarchive + 1;
      WHEN 'keep' THEN v_kept := v_kept + 1;
      WHEN 'archive' THEN v_archive_no := v_archive_no + 1;
      WHEN 'no_absent' THEN v_no_absent := v_no_absent + 1;
      ELSE NULL;
    END CASE;

    IF v_action IN ('insert', 'update', 'rename', 'unarchive', 'archive')
       AND jsonb_array_length(v_samples) < 30 THEN
      v_samples := v_samples || jsonb_build_array(jsonb_build_object(
        'action', v_action,
        'name', v_plan->>'name',
        'name_before', v_plan->>'name_before',
        'slug', v_slug,
        'contracted_club', v_plan->>'contracted_club',
        'rating', (v_plan->'norm'->>'rating')::int,
        'market_value', (v_plan->'norm'->>'market_value')::bigint,
        'rating_before', (v_plan->>'rating_before')::int,
        'rating_after', (v_plan->>'rating_after')::int,
        'overload_before', (v_plan->>'overload_before')::int,
        'overload_after', (v_plan->>'overload_after')::int,
        'mv_before', (v_plan->>'mv_before')::bigint,
        'mv_after', (v_plan->>'mv_after')::bigint
      ));
    END IF;
  END LOOP;

  IF coalesce(p_archive_missing, true)
     AND coalesce(array_length(v_seen, 1), 0) > 0 THEN
    SELECT count(*)::int INTO v_would_archive
    FROM public."Managers" m
    WHERE coalesce(m.archived, false) = false
      AND NOT (m.id = ANY (v_seen_ids));
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'input_rows', v_i,
    'unique_slugs', coalesce(array_length(v_seen, 1), 0),
    'duplicate_slugs_skipped', v_dupes,
    'would_insert', v_insert,
    'would_update', v_update,
    'would_rename', v_rename,
    'would_unarchive', v_unarchive,
    'unchanged', v_kept,
    'would_archive_in_game_no', v_archive_no,
    'in_game_no_not_in_db', v_no_absent,
    'would_archive', v_would_archive,
    'archive_missing_enabled', coalesce(p_archive_missing, true),
    'errors', v_errors,
    'samples', v_samples,
    'note', 'In Game: YES = untouched (rename only), NEW = add with calculated values, NO = archive. Blank = full update.'
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.admin_managers_row_in_game(jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_managers_catalog_plan_row(jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_managers_catalog_upsert(jsonb, boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_managers_catalog_preview(jsonb, boolean) TO authenticated;

NOTIFY pgrst, 'reload schema';
