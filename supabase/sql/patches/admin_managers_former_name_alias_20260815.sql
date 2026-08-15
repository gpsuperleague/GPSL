-- =============================================================================
-- Accept "Former Name" as Previous Name on manager catalog import
-- (sheet: Manager Name = current, Former Name = old DB name)
-- Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.admin_managers_normalize_row(v jsonb)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_name text;
  v_prev text;
  v_slug text;
  v_prev_slug text;
  v_nation text;
  v_age int;
  v_pos int;
  v_qc int;
  v_lbc int;
  v_ow int;
  v_lb int;
  v_ov int;
  v_rating int;
  v_mv bigint;
BEGIN
  v_name := nullif(btrim(coalesce(
    v->>'name', v->>'Manager Name', v->>'manager_name', v->>'Name', ''
  )), '');
  v_prev := nullif(btrim(coalesce(
    v->>'previous_name', v->>'Previous Name', v->>'previousName',
    v->>'former_name', v->>'Former Name', v->>'Former name', v->>'formerName',
    v->>'old_name', v->>'Old Name', ''
  )), '');

  v_slug := nullif(btrim(coalesce(v->>'slug', '')), '');
  IF v_slug IS NULL THEN
    v_slug := public.admin_managers_slugify(v_name);
  ELSE
    v_slug := public.admin_managers_slugify(v_slug);
  END IF;
  v_prev_slug := public.admin_managers_slugify(v_prev);

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
    v_ov := greatest(0, least(99, coalesce(
      nullif(btrim(coalesce(v->>'overload', v->>'Overload', '')), '')::int, 0
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

  v_rating := greatest(v_pos, v_qc, v_lbc, v_ow, v_lb, v_ov);
  IF v_rating < 1 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Rating would be 0', 'name', v_name);
  END IF;

  v_mv := public.manager_market_value_from_playstyles(
    v_pos::smallint, v_qc::smallint, v_lbc::smallint,
    v_ow::smallint, v_lb::smallint, v_ov::smallint
  );

  RETURN jsonb_build_object(
    'ok', true,
    'slug', v_slug,
    'previous_name', v_prev,
    'previous_slug', v_prev_slug,
    'name', v_name,
    'nation', v_nation,
    'age', v_age,
    'possession', v_pos,
    'quick_counter', v_qc,
    'long_ball_counter', v_lbc,
    'out_wide', v_ow,
    'long_ball', v_lb,
    'overload', v_ov,
    'rating', v_rating,
    'market_value', v_mv
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.admin_managers_normalize_row(jsonb) TO authenticated;

NOTIFY pgrst, 'reload schema';
