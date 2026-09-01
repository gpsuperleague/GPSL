-- =============================================================================
-- GPSL Sport — fix get_edition after friendlies patches + schema reload
-- Run if Sport opens with "Could not load this edition"
-- =============================================================================

CREATE OR REPLACE FUNCTION public.gpsl_sport_get_edition(p_edition_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_edition public.gpsl_sport_editions;
  v_month text;
  v_refresh_error text;
  v_detail jsonb;
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_authenticated');
  END IF;

  IF p_edition_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_edition_id');
  END IF;

  SELECT * INTO v_edition FROM public.gpsl_sport_editions WHERE id = p_edition_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_found', 'edition_id', p_edition_id);
  END IF;

  v_month := lower(coalesce(v_edition.gpsl_month, ''));
  v_detail := coalesce(v_edition.detail, '{}'::jsonb);

  -- Only auto-refresh non-rich in-season editions (never June/July preseason)
  IF coalesce((v_detail->>'inseason_rich')::boolean, false) IS NOT TRUE
     AND v_month NOT IN ('may', 'june', 'july', '')
     AND to_regprocedure('public.gpsl_sport_refresh_inseason_edition_by_id(bigint)') IS NOT NULL THEN
    BEGIN
      PERFORM public.gpsl_sport_refresh_inseason_edition_by_id(p_edition_id);
      SELECT * INTO v_edition FROM public.gpsl_sport_editions WHERE id = p_edition_id;
      v_detail := coalesce(v_edition.detail, '{}'::jsonb);
    EXCEPTION
      WHEN OTHERS THEN
        v_refresh_error := SQLERRM;
        RAISE WARNING 'gpsl_sport_get_edition: refresh failed for % (%): %',
          v_month, p_edition_id, SQLERRM;
    END;
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'refresh_error', v_refresh_error,
    'edition', jsonb_build_object(
      'id', v_edition.id,
      'edition_label', v_edition.edition_label,
      'gpsl_month', v_edition.gpsl_month,
      'published_at', v_edition.published_at,
      'story_type', v_edition.story_type,
      'front_page', coalesce(v_edition.front_page, '{}'::jsonb),
      'back_page', coalesce(v_edition.back_page, '{}'::jsonb),
      'managers_page', coalesce(v_detail->'managers_page', '{}'::jsonb),
      'owners_page', coalesce(v_detail->'owners_page', '{}'::jsonb),
      'stats_page', coalesce(v_detail->'stats_page', '{}'::jsonb),
      'match_page', coalesce(v_detail->'match_page', '{}'::jsonb),
      'internationals_page', coalesce(v_detail->'internationals_page', '{}'::jsonb),
      'friendlies_page', coalesce(v_detail->'friendlies_page', '{}'::jsonb),
      'detail', v_detail
    )
  );
EXCEPTION
  WHEN OTHERS THEN
    RETURN jsonb_build_object(
      'ok', false,
      'reason', 'get_edition_exception',
      'error', SQLERRM,
      'edition_id', p_edition_id
    );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.gpsl_sport_get_edition(bigint) TO authenticated;

NOTIFY pgrst, 'reload schema';

-- Quick checks:
-- SELECT public.gpsl_sport_nav_state();
-- SELECT id, gpsl_month, edition_label FROM gpsl_sport_editions ORDER BY id DESC LIMIT 5;
-- SELECT public.gpsl_sport_get_edition( (SELECT id FROM gpsl_sport_editions ORDER BY id DESC LIMIT 1) );
