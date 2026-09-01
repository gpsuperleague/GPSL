-- =============================================================================
-- GPSL Sport — mention standout June/July friendlies (+ intl) on the FRONT page
--
-- Keeps Friendlies / Internationals tabs, and also injects punchy front stories
-- when results are particularly good (high scoring / thrashing / intl splash).
--
-- Run after gpsl_sport_preseason_friendlies_intl_20260901.sql
-- Then: SELECT public.gpsl_sport_attach_preseason_results('july', NULL);
-- =============================================================================

CREATE OR REPLACE FUNCTION public.gpsl_sport_build_preseason_front_mentions(
  p_friendlies jsonb,
  p_internationals jsonb,
  p_month_label text
)
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE
AS $function$
DECLARE
  v_stories jsonb := '[]'::jsonb;
  v_row jsonb;
  v_goals int;
  v_margin int;
  v_home text;
  v_away text;
  v_score text;
  v_n int := 0;
  v_f_count int;
  v_i_count int;
  v_blurb text := '';
BEGIN
  v_f_count := coalesce((p_friendlies->>'played_count')::int, 0);
  v_i_count := coalesce((p_internationals->>'played_count')::int, 0);

  -- Standout friendlies: 5+ goals or margin 4+, else top 2 by total goals
  IF coalesce((p_friendlies->>'enabled')::boolean, false) THEN
    FOR v_row IN
      SELECT value
      FROM jsonb_array_elements(coalesce(p_friendlies->'results', '[]'::jsonb))
      ORDER BY
        CASE
          WHEN (value->>'total_goals')::int >= 5 OR (value->>'margin')::int >= 4 THEN 0
          ELSE 1
        END,
        (value->>'total_goals')::int DESC,
        (value->>'margin')::int DESC
      LIMIT 4
    LOOP
      v_goals := coalesce((v_row->>'total_goals')::int, 0);
      v_margin := coalesce((v_row->>'margin')::int, 0);
      IF v_n >= 2 AND v_goals < 5 AND v_margin < 4 THEN
        EXIT;
      END IF;

      v_home := coalesce(v_row->>'home_name', 'Home');
      v_away := coalesce(v_row->>'away_name', 'Away');
      v_score := coalesce(v_row->>'score', '?-?');

      IF v_goals >= 6 THEN
        v_stories := v_stories || jsonb_build_array(jsonb_build_object(
          'headline', format('FRIENDLY GOAL FEST: %s %s %s', v_home, v_score, v_away),
          'body', format(
            E'%s goals in a %s kickabout — the sort of scoreline that fills the Discord channel before breakfast. Not in the table. Still very much in the chat.',
            v_goals, p_month_label
          ),
          'club_short', v_row->>'home_club',
          'story_kind', 'friendly_highlight',
          'page_link', 'friendlies'
        ));
      ELSIF v_margin >= 4 THEN
        v_stories := v_stories || jsonb_build_array(jsonb_build_object(
          'headline', format('FRIENDLY THRASHING: %s %s %s', v_home, v_score, v_away),
          'body', format(
            E'A %s-goal swing in pre-season. Friendly or not, that margin gets screenshotted. Full friendlies list inside this edition.',
            v_margin
          ),
          'club_short', CASE
            WHEN coalesce((v_row->>'home_goals')::int, 0) > coalesce((v_row->>'away_goals')::int, 0)
              THEN v_row->>'home_club'
            ELSE v_row->>'away_club'
          END,
          'story_kind', 'friendly_highlight',
          'page_link', 'friendlies'
        ));
      ELSIF v_goals >= 5 THEN
        v_stories := v_stories || jsonb_build_array(jsonb_build_object(
          'headline', format('FIVE-PLUS IN A FRIENDLY — %s %s %s', v_home, v_score, v_away),
          'body', format(
            E'%s put on a show in %s friendlies. The league does not care. The owners'' group chats do.',
            v_home, p_month_label
          ),
          'club_short', v_row->>'home_club',
          'story_kind', 'friendly_highlight',
          'page_link', 'friendlies'
        ));
      ELSE
        -- Still mention the best of a quieter month (top 1–2)
        v_stories := v_stories || jsonb_build_array(jsonb_build_object(
          'headline', format('FRIENDLY WATCH: %s %s %s', v_home, v_score, v_away),
          'body', format(
            E'Among %s confirmed friendlies in %s, this was one of the sharper scorelines. See the Friendlies tab for the full sheet.',
            v_f_count, p_month_label
          ),
          'club_short', v_row->>'home_club',
          'story_kind', 'friendly_highlight',
          'page_link', 'friendlies'
        ));
      END IF;

      v_n := v_n + 1;
      EXIT WHEN v_n >= 3;
    END LOOP;
  END IF;

  -- Top international splash (1–2)
  IF coalesce((p_internationals->>'enabled')::boolean, false) THEN
    v_n := 0;
    FOR v_row IN
      SELECT value
      FROM jsonb_array_elements(coalesce(p_internationals->'shocks', p_internationals->'results', '[]'::jsonb))
      ORDER BY coalesce((value->>'sort_score')::numeric, 0) DESC
      LIMIT 2
    LOOP
      v_home := coalesce(v_row->>'home_name', 'Home');
      v_away := coalesce(v_row->>'away_name', 'Away');
      v_score := coalesce(v_row->>'score', '?-?');
      v_stories := v_stories || jsonb_build_array(jsonb_build_object(
        'headline', format(
          'WORLD STAGE: %s %s %s',
          v_home,
          v_score,
          v_away
        ),
        'body', format(
          E'%s internationals — %s %s %s made the cut for the front. Full nation tables and results on the Internationals tab.',
          p_month_label, v_home, v_score, v_away
        ),
        'story_kind', 'intl_highlight',
        'page_link', 'internationals'
      ));
      v_n := v_n + 1;
    END LOOP;
  END IF;

  IF v_f_count > 0 OR v_i_count > 0 THEN
    v_blurb := format(
      E'\n\nAlso in %s: %s confirmed club friendlies%s.',
      p_month_label,
      v_f_count,
      CASE
        WHEN v_i_count > 0 THEN format(' and %s international matches on the world stage', v_i_count)
        ELSE ''
      END
    );
  END IF;

  RETURN jsonb_build_object(
    'stories', coalesce(v_stories, '[]'::jsonb),
    'section_title', CASE
      WHEN jsonb_array_length(coalesce(v_stories, '[]'::jsonb)) > 0
        THEN 'Pre-season scorelines worth mentioning'
      ELSE NULL
    END,
    'lead_appendix', nullif(v_blurb, '')
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.gpsl_sport_merge_preseason_front_mentions(
  p_front jsonb,
  p_mentions jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE
AS $function$
DECLARE
  v_front jsonb := coalesce(p_front, '{}'::jsonb);
  v_existing jsonb;
  v_new jsonb;
  v_merged jsonb;
  v_appendix text;
  v_lead text;
BEGIN
  v_existing := coalesce(v_front->'stories', '[]'::jsonb);
  -- Drop previous auto mentions so re-attach does not duplicate
  SELECT coalesce(jsonb_agg(s), '[]'::jsonb)
  INTO v_existing
  FROM jsonb_array_elements(v_existing) s
  WHERE coalesce(s->>'story_kind', '') NOT IN ('friendly_highlight', 'intl_highlight');

  v_new := coalesce(p_mentions->'stories', '[]'::jsonb);
  v_merged := coalesce(v_new, '[]'::jsonb) || coalesce(v_existing, '[]'::jsonb);

  v_front := v_front || jsonb_build_object(
    'stories', v_merged,
    'result_mentions_title', p_mentions->>'section_title'
  );

  v_appendix := nullif(p_mentions->>'lead_appendix', '');
  IF v_appendix IS NOT NULL THEN
    v_lead := coalesce(v_front->>'lead_paragraph', '');
    -- Strip prior appendix marker block if re-running
    v_lead := regexp_replace(
      v_lead,
      E'\\n\\nAlso in [^.]+\.$',
      '',
      'n'
    );
    IF position('confirmed club friendlies' IN v_lead) = 0
       AND position('international matches on the world stage' IN v_lead) = 0 THEN
      v_front := jsonb_set(v_front, '{lead_paragraph}', to_jsonb(v_lead || v_appendix));
    END IF;
  END IF;

  RETURN v_front;
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
  v_mentions jsonb;
  v_front jsonb;
  v_seed text;
BEGIN
  IF v_month NOT IN ('june', 'july') THEN
    RETURN NULL;
  END IF;

  v_month_label := public.gpsl_sport_month_label(v_month);

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

  v_mentions := public.gpsl_sport_build_preseason_front_mentions(
    v_friendlies, v_intl, v_month_label
  );

  -- Existing: refresh extras + front mentions
  IF v_existing IS NOT NULL THEN
    SELECT e.front_page INTO v_front
    FROM public.gpsl_sport_editions e
    WHERE e.id = v_existing;

    v_front := public.gpsl_sport_merge_preseason_front_mentions(v_front, v_mentions);

    UPDATE public.gpsl_sport_editions e
    SET
      front_page = v_front,
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

  v_seed := p_season_id::text || ':' || v_month || ':preseason';

  v_built := public.gpsl_sport_build_transfer_edition(
    v_seed,
    v_month_label,
    v_bounds.window_start,
    v_bounds.window_end,
    true
  );

  v_front := public.gpsl_sport_merge_preseason_front_mentions(
    v_built->'front_page',
    v_mentions
  );

  INSERT INTO public.gpsl_sport_editions (
    season_id, gpsl_month, edition_label, story_type, front_page, back_page, detail
  )
  VALUES (
    p_season_id,
    v_month,
    v_month_label,
    v_built->>'story_type',
    v_front,
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

GRANT EXECUTE ON FUNCTION public.gpsl_sport_build_preseason_front_mentions(jsonb, jsonb, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.gpsl_sport_merge_preseason_front_mentions(jsonb, jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.gpsl_sport_generate_preseason_edition(bigint, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.gpsl_sport_generate_preseason_edition(bigint, text) TO service_role;

NOTIFY pgrst, 'reload schema';

-- SELECT public.gpsl_sport_attach_preseason_results('july', NULL);
-- SELECT public.gpsl_sport_attach_preseason_results('june', NULL);
