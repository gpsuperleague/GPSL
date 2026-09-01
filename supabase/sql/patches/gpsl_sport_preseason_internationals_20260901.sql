-- =============================================================================
-- GPSL Sport — attach Internationals pullout to June/July (pre-season) editions
--
-- July club Sport was owners/managers/transfers only. International fixtures in
-- July now appear on an Internationals tab on that same July edition.
--
-- Prerequisite: gpsl_sport_internationals_july_august_20260901.sql
-- Then republish July:
--   SELECT public.competition_admin_regenerate_gpsl_sport('july', NULL);
-- =============================================================================

CREATE OR REPLACE FUNCTION public.gpsl_sport_generate_preseason_edition(
  p_season_id bigint,
  p_gpsl_month text
)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_existing bigint;
  v_month text := lower(btrim(p_gpsl_month));
  v_month_label text;
  v_win record;
  v_bounds record;
  v_built jsonb;
  v_intl jsonb;
  v_seed text;
BEGIN
  IF v_month NOT IN ('june', 'july') THEN
    RETURN NULL;
  END IF;

  SELECT e.id INTO v_existing
  FROM public.gpsl_sport_editions e
  WHERE e.season_id = p_season_id AND lower(e.gpsl_month) = v_month
  ORDER BY e.id DESC
  LIMIT 1;

  -- Existing edition: refresh internationals pullout in place (keep preseason pages)
  IF v_existing IS NOT NULL THEN
    IF to_regprocedure('public.gpsl_sport_build_internationals_page(bigint, text)') IS NOT NULL THEN
      v_intl := public.gpsl_sport_build_internationals_page(p_season_id, v_month);
      UPDATE public.gpsl_sport_editions e
      SET
        detail = coalesce(e.detail, '{}'::jsonb) || jsonb_build_object(
          'internationals_page', coalesce(v_intl, jsonb_build_object('enabled', false)),
          'intl_attached_at', now()
        ),
        published_at = coalesce(e.published_at, now())
      WHERE e.id = v_existing;
      DELETE FROM public.gpsl_sport_reads r WHERE r.edition_id = v_existing;
    END IF;
    RETURN v_existing;
  END IF;

  SELECT * INTO v_win
  FROM public.gpsl_sport_preseason_window(p_season_id);

  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  IF v_month = 'june' AND NOT coalesce(v_win.include_june, false) THEN
    RETURN NULL;
  END IF;

  IF to_regprocedure('public.gpsl_sport_preseason_data_bounds(bigint, text)') IS NOT NULL THEN
    SELECT * INTO v_bounds
    FROM public.gpsl_sport_preseason_data_bounds(p_season_id, v_month);
  ELSE
    RETURN NULL;
  END IF;

  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  v_month_label := public.gpsl_sport_month_label(v_month);
  v_seed := p_season_id::text || ':' || v_month || ':preseason';

  v_built := public.gpsl_sport_build_transfer_edition(
    v_seed,
    v_month_label,
    v_bounds.window_start,
    v_bounds.window_end,
    true
  );

  IF to_regprocedure('public.gpsl_sport_build_internationals_page(bigint, text)') IS NOT NULL THEN
    v_intl := public.gpsl_sport_build_internationals_page(p_season_id, v_month);
  ELSE
    v_intl := jsonb_build_object('enabled', false, 'reason', 'intl_builder_missing');
  END IF;

  INSERT INTO public.gpsl_sport_editions (
    season_id, gpsl_month, edition_label, story_type, front_page, back_page, detail
  )
  VALUES (
    p_season_id,
    v_month,
    v_month_label,
    v_built->>'story_type',
    v_built->'front_page',
    coalesce(v_built->'back_page', '{}'::jsonb),
    jsonb_build_object(
      'generated_at', now(),
      'preseason', true,
      'preseason_weeks', v_win.preseason_weeks,
      'data_window_start', v_bounds.window_start,
      'data_window_end', v_bounds.window_end,
      'august_start', v_win.august_start,
      'managers_page', coalesce(v_built->'managers_page', '{}'::jsonb),
      'owners_page', coalesce(v_built->'owners_page', '{}'::jsonb),
      'internationals_page', coalesce(v_intl, jsonb_build_object('enabled', false))
    )
  )
  RETURNING id INTO v_existing;

  RETURN v_existing;
END;
$function$;

-- Soft attach for an already-published July/June without full wipe
CREATE OR REPLACE FUNCTION public.gpsl_sport_attach_internationals_to_month(
  p_gpsl_month text,
  p_season_id bigint DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season_id bigint;
  v_month text := lower(btrim(coalesce(p_gpsl_month, '')));
  v_edition_id bigint;
  v_intl jsonb;
  v_role text := coalesce(auth.jwt() ->> 'role', '');
BEGIN
  IF public.is_gpsl_admin() IS NOT TRUE
     AND current_user NOT IN ('postgres', 'service_role')
     AND v_role <> 'service_role' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'admin_only');
  END IF;

  IF v_month IS NULL OR v_month = '' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_month');
  END IF;

  SELECT coalesce(
    p_season_id,
    (SELECT s.id FROM public.competition_seasons s WHERE s.is_current IS TRUE ORDER BY s.id DESC LIMIT 1)
  ) INTO v_season_id;

  IF v_season_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_season');
  END IF;

  IF to_regprocedure('public.gpsl_sport_build_internationals_page(bigint, text)') IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'run_intl_builder_patch_first');
  END IF;

  v_intl := public.gpsl_sport_build_internationals_page(v_season_id, v_month);

  SELECT e.id INTO v_edition_id
  FROM public.gpsl_sport_editions e
  WHERE e.season_id = v_season_id
    AND lower(e.gpsl_month) = v_month
  ORDER BY e.id DESC
  LIMIT 1;

  IF v_edition_id IS NULL THEN
    -- Create via normal generator (preseason or in-season)
    v_edition_id := public.gpsl_sport_generate_edition(v_season_id, v_month);
  ELSE
    UPDATE public.gpsl_sport_editions e
    SET
      detail = coalesce(e.detail, '{}'::jsonb) || jsonb_build_object(
        'internationals_page', coalesce(v_intl, jsonb_build_object('enabled', false)),
        'intl_attached_at', now()
      )
    WHERE e.id = v_edition_id;
    DELETE FROM public.gpsl_sport_reads r WHERE r.edition_id = v_edition_id;
  END IF;

  RETURN jsonb_build_object(
    'ok', v_edition_id IS NOT NULL,
    'edition_id', v_edition_id,
    'gpsl_month', v_month,
    'internationals_enabled', coalesce((v_intl->>'enabled')::boolean, false),
    'source_month', v_intl->>'source_month',
    'played_count', coalesce((v_intl->>'played_count')::int, 0)
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.gpsl_sport_generate_preseason_edition(bigint, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.gpsl_sport_generate_preseason_edition(bigint, text) TO service_role;
GRANT EXECUTE ON FUNCTION public.gpsl_sport_attach_internationals_to_month(text, bigint) TO authenticated;

NOTIFY pgrst, 'reload schema';

-- Quick attach July intl onto the live July edition:
-- SELECT public.gpsl_sport_attach_internationals_to_month('july', NULL);
--
-- Or full republish:
-- SELECT public.competition_admin_regenerate_gpsl_sport('july', NULL);
