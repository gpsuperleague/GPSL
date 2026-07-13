-- =============================================================================
-- Natter — admin delete posts
-- Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.natter_admin_delete_post(p_post_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_role text := coalesce(auth.jwt() ->> 'role', '');
  v_row public.natter_posts%ROWTYPE;
BEGIN
  IF public.is_gpsl_admin() IS NOT TRUE
     AND current_user NOT IN ('postgres', 'service_role')
     AND v_role <> 'service_role' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'admin_only');
  END IF;

  IF p_post_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'bad_id');
  END IF;

  SELECT * INTO v_row
  FROM public.natter_posts p
  WHERE p.id = p_post_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_found');
  END IF;

  -- Remove attached media from storage (best-effort)
  IF nullif(btrim(coalesce(v_row.image_path, '')), '') IS NOT NULL THEN
    BEGIN
      DELETE FROM storage.objects o
      WHERE o.bucket_id = 'natter-media'
        AND o.name = v_row.image_path;
    EXCEPTION
      WHEN OTHERS THEN
        NULL; -- post delete still proceeds
    END;
  END IF;

  DELETE FROM public.natter_posts p WHERE p.id = p_post_id;

  RETURN jsonb_build_object(
    'ok', true,
    'post_id', p_post_id,
    'club_short_name', v_row.club_short_name,
    'gpsl_month', v_row.gpsl_month,
    'season_id', v_row.season_id,
    'had_image', nullif(btrim(coalesce(v_row.image_path, '')), '') IS NOT NULL
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.natter_admin_list_posts(
  p_season_id bigint DEFAULT NULL,
  p_gpsl_month text DEFAULT NULL,
  p_limit int DEFAULT 200
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_role text := coalesce(auth.jwt() ->> 'role', '');
  v_season bigint;
  v_month text := lower(nullif(btrim(p_gpsl_month), ''));
  v_limit int := greatest(1, least(coalesce(p_limit, 200), 500));
  v_rows jsonb;
BEGIN
  IF public.is_gpsl_admin() IS NOT TRUE
     AND current_user NOT IN ('postgres', 'service_role')
     AND v_role <> 'service_role' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'admin_only');
  END IF;

  SELECT coalesce(
    p_season_id,
    (SELECT s.id FROM public.competition_seasons s WHERE s.is_current IS TRUE ORDER BY s.id DESC LIMIT 1)
  ) INTO v_season;

  IF v_season IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_season');
  END IF;

  SELECT coalesce(jsonb_agg(row_to_json(q)::jsonb ORDER BY q.created_at DESC), '[]'::jsonb)
  INTO v_rows
  FROM (
    SELECT
      p.id,
      p.season_id,
      p.gpsl_month,
      public.competition_gpsl_month_label(p.gpsl_month) AS month_label,
      p.club_short_name AS club_short,
      public.natter_club_display_name(p.club_short_name) AS club_name,
      p.owner_tag,
      p.body,
      p.image_path,
      p.created_at
    FROM public.natter_posts p
    WHERE p.season_id = v_season
      AND (v_month IS NULL OR lower(p.gpsl_month) = v_month)
    ORDER BY p.created_at DESC
    LIMIT v_limit
  ) q;

  RETURN jsonb_build_object(
    'ok', true,
    'season_id', v_season,
    'gpsl_month', v_month,
    'posts', coalesce(v_rows, '[]'::jsonb)
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.natter_admin_delete_post(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.natter_admin_list_posts(bigint, text, int) TO authenticated;

NOTIFY pgrst, 'reload schema';
