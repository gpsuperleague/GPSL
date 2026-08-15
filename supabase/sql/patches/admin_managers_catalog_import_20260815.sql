-- =============================================================================
-- Admin: upsert manager catalog from CSV / JSON (retain contracts & history)
--
-- Upserts by slug. NEVER clears:
--   contracted_club, contract_seasons_remaining, weekly_wage (if contracted),
--   signed_season_id, signed_gpsl_month, id
-- Career stints / listings / bids stay linked via manager id.
--
-- Free agents: weekly_wage recalculated from new MV (50% / 52).
-- Contracted: weekly_wage left as-is (deal already signed).
-- Clubs.manager_rating synced when a club's manager rating changes.
--
-- RPCs:
--   admin_managers_catalog_preview(jsonb)
--   admin_managers_catalog_upsert(jsonb)
--
-- Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.admin_managers_slugify(p_name text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT nullif(
    trim(both '-' FROM regexp_replace(lower(btrim(coalesce(p_name, ''))), '[^a-z0-9]+', '-', 'g')),
    ''
  );
$$;

CREATE OR REPLACE FUNCTION public.admin_managers_normalize_row(p_row jsonb)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v jsonb := coalesce(p_row, '{}'::jsonb);
  v_name text;
  v_slug text;
  v_nation text;
  v_age int;
  v_pos int;
  v_qc int;
  v_lbc int;
  v_ow int;
  v_lb int;
  v_rating int;
  v_mv bigint;
BEGIN
  v_name := nullif(btrim(coalesce(
    v->>'name', v->>'Manager Name', v->>'manager_name', v->>'Name', ''
  )), '');
  v_slug := nullif(btrim(coalesce(v->>'slug', '')), '');
  IF v_slug IS NULL THEN
    v_slug := public.admin_managers_slugify(v_name);
  ELSE
    v_slug := public.admin_managers_slugify(v_slug);
  END IF;

  v_nation := nullif(btrim(coalesce(v->>'nation', v->>'Nation', '')), '');

  BEGIN
    v_age := nullif(btrim(coalesce(v->>'age', v->>'Age', '')), '')::int;
  EXCEPTION WHEN others THEN
    v_age := NULL;
  END;

  BEGIN
    v_pos := greatest(0, least(99, coalesce(
      nullif(btrim(coalesce(v->>'possession', v->>'Possession', '')), '')::int, 0
    )));
    v_qc := greatest(0, least(99, coalesce(
      nullif(btrim(coalesce(
        v->>'quick_counter', v->>'Quick Counter', v->>'quickCounter', ''
      )), '')::int, 0
    )));
    v_lbc := greatest(0, least(99, coalesce(
      nullif(btrim(coalesce(
        v->>'long_ball_counter', v->>'Long Ball Counter', v->>'longBallCounter', ''
      )), '')::int, 0
    )));
    v_ow := greatest(0, least(99, coalesce(
      nullif(btrim(coalesce(v->>'out_wide', v->>'Out Wide', v->>'outWide', '')), '')::int, 0
    )));
    v_lb := greatest(0, least(99, coalesce(
      nullif(btrim(coalesce(v->>'long_ball', v->>'Long Ball', v->>'longBall', '')), '')::int, 0
    )));
  EXCEPTION WHEN others THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Invalid playstyle numbers', 'raw', v);
  END;

  IF v_name IS NULL OR v_slug IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Missing name/slug', 'raw', v);
  END IF;

  IF v_age IS NOT NULL AND (v_age < 16 OR v_age > 99) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Age out of range', 'name', v_name);
  END IF;

  v_rating := greatest(v_pos, v_qc, v_lbc, v_ow, v_lb);
  IF v_rating < 1 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Rating would be 0', 'name', v_name);
  END IF;

  IF to_regprocedure(
    'public.manager_market_value_from_playstyles(smallint,smallint,smallint,smallint,smallint)'
  ) IS NOT NULL THEN
    v_mv := public.manager_market_value_from_playstyles(
      v_pos::smallint, v_qc::smallint, v_lbc::smallint, v_ow::smallint, v_lb::smallint
    );
  ELSE
    v_mv := 0;
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'slug', v_slug,
    'name', v_name,
    'nation', v_nation,
    'age', v_age,
    'possession', v_pos,
    'quick_counter', v_qc,
    'long_ball_counter', v_lbc,
    'out_wide', v_ow,
    'long_ball', v_lb,
    'rating', v_rating,
    'market_value', v_mv
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_managers_catalog_preview(p_rows jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_elem jsonb;
  v_norm jsonb;
  v_slug text;
  v_existing record;
  v_insert int := 0;
  v_update int := 0;
  v_unchanged int := 0;
  v_errors jsonb := '[]'::jsonb;
  v_samples jsonb := '[]'::jsonb;
  v_seen text[] := ARRAY[]::text[];
  v_dupes int := 0;
  v_i int := 0;
  v_will_change boolean;
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

    SELECT m.id, m.name, m.rating, m.market_value, m.contracted_club,
           m.possession, m.quick_counter, m.long_ball_counter, m.out_wide, m.long_ball, m.age, m.nation
    INTO v_existing
    FROM public."Managers" m
    WHERE m.slug = v_slug;

    IF NOT FOUND THEN
      v_insert := v_insert + 1;
      IF jsonb_array_length(v_samples) < 15 THEN
        v_samples := v_samples || jsonb_build_array(jsonb_build_object(
          'action', 'insert',
          'slug', v_slug,
          'name', v_norm->>'name',
          'rating', (v_norm->>'rating')::int,
          'market_value', (v_norm->>'market_value')::bigint
        ));
      END IF;
    ELSE
      v_will_change :=
        v_existing.name IS DISTINCT FROM (v_norm->>'name')
        OR v_existing.nation IS DISTINCT FROM (v_norm->>'nation')
        OR v_existing.age IS DISTINCT FROM nullif(v_norm->>'age', '')::int
        OR v_existing.possession IS DISTINCT FROM (v_norm->>'possession')::int
        OR v_existing.quick_counter IS DISTINCT FROM (v_norm->>'quick_counter')::int
        OR v_existing.long_ball_counter IS DISTINCT FROM (v_norm->>'long_ball_counter')::int
        OR v_existing.out_wide IS DISTINCT FROM (v_norm->>'out_wide')::int
        OR v_existing.long_ball IS DISTINCT FROM (v_norm->>'long_ball')::int
        OR v_existing.rating IS DISTINCT FROM (v_norm->>'rating')::int
        OR v_existing.market_value IS DISTINCT FROM (v_norm->>'market_value')::bigint;

      IF v_will_change THEN
        v_update := v_update + 1;
        IF jsonb_array_length(v_samples) < 15 THEN
          v_samples := v_samples || jsonb_build_array(jsonb_build_object(
            'action', 'update',
            'slug', v_slug,
            'name', v_norm->>'name',
            'id', v_existing.id,
            'contracted_club', v_existing.contracted_club,
            'rating_before', v_existing.rating,
            'rating_after', (v_norm->>'rating')::int,
            'mv_before', v_existing.market_value,
            'mv_after', (v_norm->>'market_value')::bigint
          ));
        END IF;
      ELSE
        v_unchanged := v_unchanged + 1;
      END IF;
    END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true,
    'input_rows', v_i,
    'unique_slugs', coalesce(array_length(v_seen, 1), 0),
    'duplicate_slugs_skipped', v_dupes,
    'would_insert', v_insert,
    'would_update', v_update,
    'unchanged', v_unchanged,
    'errors', v_errors,
    'samples', v_samples,
    'note', 'Contracts, wages (if signed), stints, and listings are retained. Ids stay stable on slug match.'
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_managers_catalog_upsert(p_rows jsonb)
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
  v_unchanged int := 0;
  v_errors jsonb := '[]'::jsonb;
  v_seen text[] := ARRAY[]::text[];
  v_dupes int := 0;
  v_i int := 0;
  v_wage bigint;
  v_wage_pct numeric;
  v_rating int;
  v_clubs_synced int := 0;
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

    SELECT id, contracted_club INTO v_id, v_was_club
    FROM public."Managers"
    WHERE slug = v_slug;

    IF v_id IS NULL THEN
      INSERT INTO public."Managers" (
        slug, name, nation, possession, quick_counter, long_ball_counter,
        out_wide, long_ball, age, rating, market_value, weekly_wage,
        contracted_club, contract_seasons_remaining
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
        nullif(v_norm->>'age', '')::smallint,
        v_rating::smallint,
        (v_norm->>'market_value')::bigint,
        v_wage,
        NULL,
        0
      )
      RETURNING id INTO v_id;
      v_insert := v_insert + 1;
    ELSE
      UPDATE public."Managers" m
      SET
        name = v_norm->>'name',
        nation = v_norm->>'nation',
        possession = (v_norm->>'possession')::smallint,
        quick_counter = (v_norm->>'quick_counter')::smallint,
        long_ball_counter = (v_norm->>'long_ball_counter')::smallint,
        out_wide = (v_norm->>'out_wide')::smallint,
        long_ball = (v_norm->>'long_ball')::smallint,
        age = coalesce(nullif(v_norm->>'age', '')::smallint, m.age),
        rating = v_rating::smallint,
        market_value = (v_norm->>'market_value')::bigint,
        -- Only refresh wage for free agents; signed deals keep their weekly wage
        weekly_wage = CASE
          WHEN m.contracted_club IS NULL OR btrim(m.contracted_club) = '' THEN v_wage
          ELSE m.weekly_wage
        END,
        updated_at = now()
      WHERE m.id = v_id
        AND (
          m.name IS DISTINCT FROM (v_norm->>'name')
          OR m.nation IS DISTINCT FROM (v_norm->>'nation')
          OR m.age IS DISTINCT FROM coalesce(nullif(v_norm->>'age', '')::smallint, m.age)
          OR m.possession IS DISTINCT FROM (v_norm->>'possession')::smallint
          OR m.quick_counter IS DISTINCT FROM (v_norm->>'quick_counter')::smallint
          OR m.long_ball_counter IS DISTINCT FROM (v_norm->>'long_ball_counter')::smallint
          OR m.out_wide IS DISTINCT FROM (v_norm->>'out_wide')::smallint
          OR m.long_ball IS DISTINCT FROM (v_norm->>'long_ball')::smallint
          OR m.rating IS DISTINCT FROM v_rating::smallint
          OR m.market_value IS DISTINCT FROM (v_norm->>'market_value')::bigint
        );

      IF FOUND THEN
        v_update := v_update + 1;
      ELSE
        v_unchanged := v_unchanged + 1;
      END IF;

      -- Keep club attendance helper in sync when this manager is signed
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
    END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true,
    'input_rows', v_i,
    'unique_slugs', coalesce(array_length(v_seen, 1), 0),
    'duplicate_slugs_skipped', v_dupes,
    'inserted', v_insert,
    'updated', v_update,
    'unchanged', v_unchanged,
    'clubs_manager_rating_synced', v_clubs_synced,
    'errors', v_errors,
    'retained', jsonb_build_object(
      'contracted_club', true,
      'contract_seasons_remaining', true,
      'weekly_wage_if_signed', true,
      'signed_season_id', true,
      'manager_id', true,
      'career_stints', true,
      'transfer_listings_bids', true
    )
  );
END;
$function$;

COMMENT ON FUNCTION public.admin_managers_catalog_upsert(jsonb) IS
  'Admin upsert of Managers catalog by slug. Retains contracts, wages if signed, ids, and career history.';

GRANT EXECUTE ON FUNCTION public.admin_managers_slugify(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_managers_normalize_row(jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_managers_catalog_preview(jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_managers_catalog_upsert(jsonb) TO authenticated;

NOTIFY pgrst, 'reload schema';
