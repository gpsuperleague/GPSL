-- =============================================================================
-- GPSL Sport — June/July: played club friendlies + internationals (+ existing)
--
-- Pre-season editions keep owners / managers / transfers, and also get:
--   • friendlies_page  — confirmed Discord friendlies (gpsl_friendlies)
--   • internationals_page — played WC/intl fixtures that month
--
-- Prerequisites:
--   gpsl_sport_internationals_july_august_20260901.sql
--   gpsl_sport_preseason_internationals_20260901.sql (optional; this replaces generate)
--
-- Then:
--   SELECT public.gpsl_sport_attach_preseason_results('july', NULL);
--   SELECT public.gpsl_sport_attach_preseason_results('june', NULL);
-- =============================================================================

CREATE OR REPLACE FUNCTION public.gpsl_sport_build_friendlies_page(
  p_season_id bigint,
  p_gpsl_month text
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_month text := lower(btrim(coalesce(p_gpsl_month, '')));
  v_month_label text;
  v_count int := 0;
  v_results jsonb := '[]'::jsonb;
  v_high jsonb := '[]'::jsonb;
  v_lead_headline text;
  v_lead_body text;
  v_top jsonb;
BEGIN
  IF to_regclass('public.gpsl_friendlies') IS NULL THEN
    RETURN jsonb_build_object('enabled', false, 'reason', 'no_friendlies_table');
  END IF;

  IF v_month IS NULL OR v_month = '' THEN
    RETURN jsonb_build_object('enabled', false, 'reason', 'no_month');
  END IF;

  v_month_label := public.gpsl_sport_month_label(v_month);

  SELECT count(*)::int INTO v_count
  FROM public.gpsl_friendlies f
  WHERE f.season_id = p_season_id
    AND lower(f.gpsl_month) = v_month;

  IF coalesce(v_count, 0) <= 0 THEN
    RETURN jsonb_build_object(
      'enabled', false,
      'reason', 'no_played_friendlies',
      'source_month', v_month,
      'played_count', 0
    );
  END IF;

  SELECT coalesce(jsonb_agg(row_to_json(x)::jsonb ORDER BY x.confirmed_at DESC NULLS LAST, x.id DESC), '[]'::jsonb)
  INTO v_results
  FROM (
    SELECT
      f.id,
      f.club_left AS home_club,
      f.club_right AS away_club,
      public.gpsl_sport_club_display_name(f.club_left) AS home_name,
      public.gpsl_sport_club_display_name(f.club_right) AS away_name,
      f.score_left AS home_goals,
      f.score_right AS away_goals,
      format('%s-%s', f.score_left, f.score_right) AS score,
      abs(f.score_left - f.score_right) AS margin,
      (f.score_left + f.score_right) AS total_goals,
      f.confirmed_at
    FROM public.gpsl_friendlies f
    WHERE f.season_id = p_season_id
      AND lower(f.gpsl_month) = v_month
  ) x;

  SELECT coalesce(jsonb_agg(r ORDER BY (r->>'total_goals')::int DESC, (r->>'margin')::int DESC), '[]'::jsonb)
  INTO v_high
  FROM (
    SELECT value AS r
    FROM jsonb_array_elements(v_results)
    ORDER BY (value->>'total_goals')::int DESC, (value->>'margin')::int DESC
    LIMIT 5
  ) s;

  SELECT value INTO v_top
  FROM jsonb_array_elements(v_high)
  LIMIT 1;

  IF v_top IS NULL THEN
    SELECT value INTO v_top FROM jsonb_array_elements(v_results) LIMIT 1;
  END IF;

  v_lead_headline := format(
    '%s FRIENDLIES: %s PLAYED',
    upper(v_month_label),
    v_count
  );

  IF v_top IS NOT NULL THEN
    v_lead_body := format(
      E'Pre-season kickabouts that counted on Discord — %s confirmed friendlies in %s.\n\n'
      || E'Headline scoreline: %s %s %s. Caps and gate money still apply; the table does not. Full list below.',
      v_count,
      v_month_label,
      v_top->>'home_name',
      v_top->>'score',
      v_top->>'away_name'
    );
  ELSE
    v_lead_body := format(
      '%s confirmed friendlies filed for %s.',
      v_count,
      v_month_label
    );
  END IF;

  RETURN jsonb_build_object(
    'enabled', true,
    'page_title', 'Friendlies',
    'source_month', v_month,
    'source_month_label', v_month_label,
    'played_count', v_count,
    'lead', jsonb_build_object(
      'headline', v_lead_headline,
      'subhead', format('%s · Discord dual-confirm', v_month_label),
      'byline', 'GPSL Sport · Friendlies desk',
      'body', v_lead_body
    ),
    'highlights', coalesce(v_high, '[]'::jsonb),
    'results', coalesce(v_results, '[]'::jsonb)
  );
END;
$function$;

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
  v_friendlies jsonb;
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

  IF to_regprocedure('public.gpsl_sport_build_internationals_page(bigint, text)') IS NOT NULL THEN
    v_intl := public.gpsl_sport_build_internationals_page(p_season_id, v_month);
  ELSE
    v_intl := jsonb_build_object('enabled', false);
  END IF;

  IF to_regprocedure('public.gpsl_sport_build_friendlies_page(bigint, text)') IS NOT NULL THEN
    v_friendlies := public.gpsl_sport_build_friendlies_page(p_season_id, v_month);
  ELSE
    v_friendlies := jsonb_build_object('enabled', false);
  END IF;

  -- Existing: refresh friendlies + internationals, keep owners/managers/transfers
  IF v_existing IS NOT NULL THEN
    UPDATE public.gpsl_sport_editions e
    SET
      detail = coalesce(e.detail, '{}'::jsonb) || jsonb_build_object(
        'internationals_page', coalesce(v_intl, jsonb_build_object('enabled', false)),
        'friendlies_page', coalesce(v_friendlies, jsonb_build_object('enabled', false)),
        'preseason_results_attached_at', now()
      ),
      published_at = coalesce(e.published_at, now())
    WHERE e.id = v_existing;
    DELETE FROM public.gpsl_sport_reads r WHERE r.edition_id = v_existing;
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
      'internationals_page', coalesce(v_intl, jsonb_build_object('enabled', false)),
      'friendlies_page', coalesce(v_friendlies, jsonb_build_object('enabled', false))
    )
  )
  RETURNING id INTO v_existing;

  RETURN v_existing;
END;
$function$;

CREATE OR REPLACE FUNCTION public.gpsl_sport_attach_preseason_results(
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
  v_friendlies jsonb;
  v_role text := coalesce(auth.jwt() ->> 'role', '');
BEGIN
  IF public.is_gpsl_admin() IS NOT TRUE
     AND current_user NOT IN ('postgres', 'service_role')
     AND v_role <> 'service_role' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'admin_only');
  END IF;

  IF v_month NOT IN ('june', 'july') THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'preseason_months_only');
  END IF;

  SELECT coalesce(
    p_season_id,
    (SELECT s.id FROM public.competition_seasons s WHERE s.is_current IS TRUE ORDER BY s.id DESC LIMIT 1)
  ) INTO v_season_id;

  IF v_season_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_season');
  END IF;

  v_edition_id := public.gpsl_sport_generate_preseason_edition(v_season_id, v_month);

  SELECT e.detail->'internationals_page', e.detail->'friendlies_page'
  INTO v_intl, v_friendlies
  FROM public.gpsl_sport_editions e
  WHERE e.id = v_edition_id;

  RETURN jsonb_build_object(
    'ok', v_edition_id IS NOT NULL,
    'edition_id', v_edition_id,
    'gpsl_month', v_month,
    'internationals_enabled', coalesce((v_intl->>'enabled')::boolean, false),
    'internationals_played', coalesce((v_intl->>'played_count')::int, 0),
    'friendlies_enabled', coalesce((v_friendlies->>'enabled')::boolean, false),
    'friendlies_played', coalesce((v_friendlies->>'played_count')::int, 0)
  );
END;
$function$;

-- Keep old name working
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
  v_month text := lower(btrim(coalesce(p_gpsl_month, '')));
BEGIN
  IF v_month IN ('june', 'july') THEN
    RETURN public.gpsl_sport_attach_preseason_results(p_gpsl_month, p_season_id);
  END IF;
  RETURN jsonb_build_object(
    'ok', false,
    'reason', 'use_regenerate_for_inseason',
    'hint', 'For August+, run competition_admin_regenerate_gpsl_sport'
  );
END;
$function$;

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
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_authenticated');
  END IF;

  SELECT * INTO v_edition FROM public.gpsl_sport_editions WHERE id = p_edition_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_found');
  END IF;

  v_month := lower(coalesce(v_edition.gpsl_month, ''));
  IF coalesce((v_edition.detail->>'inseason_rich')::boolean, false) IS NOT TRUE
     AND v_month NOT IN ('may', 'june', 'july', '')
     AND to_regprocedure('public.gpsl_sport_refresh_inseason_edition_by_id(bigint)') IS NOT NULL THEN
    BEGIN
      PERFORM public.gpsl_sport_refresh_inseason_edition_by_id(p_edition_id);
      SELECT * INTO v_edition FROM public.gpsl_sport_editions WHERE id = p_edition_id;
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
      'front_page', v_edition.front_page,
      'back_page', v_edition.back_page,
      'managers_page', coalesce(v_edition.detail->'managers_page', '{}'::jsonb),
      'owners_page', coalesce(v_edition.detail->'owners_page', '{}'::jsonb),
      'stats_page', coalesce(v_edition.detail->'stats_page', '{}'::jsonb),
      'match_page', coalesce(v_edition.detail->'match_page', '{}'::jsonb),
      'internationals_page', coalesce(v_edition.detail->'internationals_page', '{}'::jsonb),
      'friendlies_page', coalesce(v_edition.detail->'friendlies_page', '{}'::jsonb),
      'detail', v_edition.detail
    )
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.gpsl_sport_build_friendlies_page(bigint, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.gpsl_sport_generate_preseason_edition(bigint, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.gpsl_sport_generate_preseason_edition(bigint, text) TO service_role;
GRANT EXECUTE ON FUNCTION public.gpsl_sport_attach_preseason_results(text, bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.gpsl_sport_attach_internationals_to_month(text, bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.gpsl_sport_get_edition(bigint) TO authenticated;

NOTIFY pgrst, 'reload schema';

-- SELECT public.gpsl_sport_attach_preseason_results('july', NULL);
-- SELECT public.gpsl_sport_attach_preseason_results('june', NULL);
