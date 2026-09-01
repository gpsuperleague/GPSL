-- =============================================================================
-- GPSL Sport — Internationals pullout (July WC window on August edition)
--
-- • Builds internationals_page from played international fixtures
-- • For club month M: uses M if it has played intl, else previous GPSL month
--   (so August Sport picks up July internationals)
-- • Wire into in-season generate / refresh / get_edition
--
-- After run: Admin → Republish GPSL Sport → August
--   or: SELECT public.competition_admin_regenerate_gpsl_sport('august', NULL);
-- =============================================================================

CREATE OR REPLACE FUNCTION public.gpsl_sport_previous_gpsl_month(p_month text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE lower(btrim(coalesce(p_month, '')))
    WHEN 'august' THEN 'july'
    WHEN 'september' THEN 'august'
    WHEN 'october' THEN 'september'
    WHEN 'november' THEN 'october'
    WHEN 'december' THEN 'november'
    WHEN 'january' THEN 'december'
    WHEN 'february' THEN 'january'
    WHEN 'march' THEN 'february'
    WHEN 'april' THEN 'march'
    WHEN 'may' THEN 'april'
    WHEN 'july' THEN 'june'
    WHEN 'june' THEN NULL
    ELSE NULL
  END;
$$;

CREATE OR REPLACE FUNCTION public.gpsl_sport_resolve_intl_source_month(
  p_season_id bigint,
  p_club_month text
)
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := lower(btrim(coalesce(p_club_month, '')));
  v_prev text;
  v_count int;
BEGIN
  IF to_regclass('public.international_fixtures') IS NULL THEN
    RETURN NULL;
  END IF;

  SELECT count(*)::int INTO v_count
  FROM public.international_fixtures f
  WHERE f.season_id = p_season_id
    AND lower(f.gpsl_month) = v_club
    AND f.played IS TRUE;

  IF coalesce(v_count, 0) > 0 THEN
    RETURN v_club;
  END IF;

  v_prev := public.gpsl_sport_previous_gpsl_month(v_club);
  IF v_prev IS NULL THEN
    RETURN NULL;
  END IF;

  SELECT count(*)::int INTO v_count
  FROM public.international_fixtures f
  WHERE f.season_id = p_season_id
    AND lower(f.gpsl_month) = v_prev
    AND f.played IS TRUE;

  IF coalesce(v_count, 0) > 0 THEN
    RETURN v_prev;
  END IF;

  RETURN NULL;
END;
$function$;

CREATE OR REPLACE FUNCTION public.gpsl_sport_build_internationals_page(
  p_season_id bigint,
  p_club_month text
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_intl_month text;
  v_month_label text;
  v_played int := 0;
  v_results jsonb := '[]'::jsonb;
  v_shocks jsonb := '[]'::jsonb;
  v_groups jsonb := '[]'::jsonb;
  v_feats jsonb := '[]'::jsonb;
  v_lead_headline text;
  v_lead_subhead text;
  v_lead_body text;
  v_top jsonb;
  v_phase text;
BEGIN
  IF to_regclass('public.international_fixtures') IS NULL THEN
    RETURN jsonb_build_object('enabled', false, 'reason', 'no_intl_tables');
  END IF;

  v_intl_month := public.gpsl_sport_resolve_intl_source_month(p_season_id, p_club_month);
  IF v_intl_month IS NULL THEN
    RETURN jsonb_build_object('enabled', false, 'reason', 'no_played_intl');
  END IF;

  v_month_label := public.gpsl_sport_month_label(v_intl_month);

  SELECT count(*)::int INTO v_played
  FROM public.international_fixtures f
  WHERE f.season_id = p_season_id
    AND lower(f.gpsl_month) = v_intl_month
    AND f.played IS TRUE;

  -- Result cards (newest / biggest margins first)
  SELECT coalesce(jsonb_agg(row_to_json(x)::jsonb ORDER BY x.sort_score DESC, x.id), '[]'::jsonb)
  INTO v_results
  FROM (
    SELECT
      f.id,
      f.phase,
      f.home_nation,
      f.away_nation,
      hn.name AS home_name,
      an.name AS away_name,
      coalesce(hn.flag_emoji, '') AS home_flag,
      coalesce(an.flag_emoji, '') AS away_flag,
      f.home_goals,
      f.away_goals,
      format('%s-%s', f.home_goals, f.away_goals) AS score,
      coalesce(qg.group_code, fg.group_code) AS group_code,
      kn.stage AS knockout_stage,
      (
        abs(coalesce(f.home_goals, 0) - coalesce(f.away_goals, 0)) * 10
        + greatest(0, coalesce(hn.seed_rank, 50) - coalesce(an.seed_rank, 50))
          * CASE WHEN f.home_goals > f.away_goals THEN 1 ELSE 0 END
        + greatest(0, coalesce(an.seed_rank, 50) - coalesce(hn.seed_rank, 50))
          * CASE WHEN f.away_goals > f.home_goals THEN 1 ELSE 0 END
      )::numeric AS sort_score
    FROM public.international_fixtures f
    JOIN public.international_nations hn ON hn.code = f.home_nation
    JOIN public.international_nations an ON an.code = f.away_nation
    LEFT JOIN public.international_qual_groups qg
      ON qg.id = f.group_id AND f.phase = 'qualifying'
    LEFT JOIN public.international_finals_groups fg
      ON fg.id = f.group_id AND f.phase = 'finals_group'
    LEFT JOIN public.international_knockout_nodes kn ON kn.id = f.knockout_node_id
    WHERE f.season_id = p_season_id
      AND lower(f.gpsl_month) = v_intl_month
      AND f.played IS TRUE
  ) x;

  -- Shock shortlist (top 5 by margin + seed upset)
  SELECT coalesce(jsonb_agg(r ORDER BY (r->>'sort_score')::numeric DESC), '[]'::jsonb)
  INTO v_shocks
  FROM (
    SELECT value AS r
    FROM jsonb_array_elements(v_results)
    WHERE (value->>'home_goals')::int <> (value->>'away_goals')::int
    ORDER BY (value->>'sort_score')::numeric DESC
    LIMIT 5
  ) s;

  -- Group tables touched by this window
  IF to_regclass('public.international_qual_group_members') IS NOT NULL THEN
    SELECT coalesce(jsonb_agg(g ORDER BY g->>'group_code'), '[]'::jsonb)
    INTO v_groups
    FROM (
      SELECT jsonb_build_object(
        'phase', 'qualifying',
        'group_code', qg.group_code,
        'table', (
          SELECT coalesce(jsonb_agg(jsonb_build_object(
            'nation_code', m.nation_code,
            'nation_name', n.name,
            'flag', coalesce(n.flag_emoji, ''),
            'played', m.played,
            'won', m.won,
            'drawn', m.drawn,
            'lost', m.lost,
            'gf', m.goals_for,
            'ga', m.goals_against,
            'gd', m.goals_for - m.goals_against,
            'pts', m.points
          ) ORDER BY m.points DESC, (m.goals_for - m.goals_against) DESC, m.goals_for DESC, n.name), '[]'::jsonb)
          FROM public.international_qual_group_members m
          JOIN public.international_nations n ON n.code = m.nation_code
          WHERE m.group_id = qg.id
        )
      ) AS g
      FROM public.international_qual_groups qg
      WHERE EXISTS (
        SELECT 1 FROM public.international_fixtures f
        WHERE f.group_id = qg.id
          AND f.phase = 'qualifying'
          AND f.season_id = p_season_id
          AND lower(f.gpsl_month) = v_intl_month
          AND f.played IS TRUE
      )
    ) q;
  END IF;

  IF to_regclass('public.international_finals_group_members') IS NOT NULL THEN
    SELECT coalesce(v_groups, '[]'::jsonb) || coalesce(jsonb_agg(g ORDER BY g->>'group_code'), '[]'::jsonb)
    INTO v_groups
    FROM (
      SELECT jsonb_build_object(
        'phase', 'finals_group',
        'group_code', fg.group_code,
        'table', (
          SELECT coalesce(jsonb_agg(jsonb_build_object(
            'nation_code', m.nation_code,
            'nation_name', n.name,
            'flag', coalesce(n.flag_emoji, ''),
            'played', m.played,
            'won', m.won,
            'drawn', m.drawn,
            'lost', m.lost,
            'gf', m.goals_for,
            'ga', m.goals_against,
            'gd', m.goals_for - m.goals_against,
            'pts', m.points
          ) ORDER BY m.points DESC, (m.goals_for - m.goals_against) DESC, m.goals_for DESC, n.name), '[]'::jsonb)
          FROM public.international_finals_group_members m
          JOIN public.international_nations n ON n.code = m.nation_code
          WHERE m.group_id = fg.id
        )
      ) AS g
      FROM public.international_finals_groups fg
      WHERE EXISTS (
        SELECT 1 FROM public.international_fixtures f
        WHERE f.group_id = fg.id
          AND f.phase = 'finals_group'
          AND f.season_id = p_season_id
          AND lower(f.gpsl_month) = v_intl_month
          AND f.played IS TRUE
      )
    ) q;
  END IF;

  -- Brilliant performances from confirmed result submissions
  IF to_regclass('public.international_result_submissions') IS NOT NULL THEN
    SELECT coalesce(jsonb_agg(row_to_json(t)::jsonb ORDER BY t.feat_score DESC, t.player_name), '[]'::jsonb)
    INTO v_feats
    FROM (
      SELECT
        p."Name" AS player_name,
        p."Konami_ID"::text AS player_id,
        sum(coalesce((item->>'goals')::int, 0)) AS goals,
        sum(coalesce((item->>'assists')::int, 0)) AS assists,
        max(coalesce((item->>'rating')::numeric, 0)) AS best_rating,
        bool_or(
          coalesce((item->>'potm')::boolean, false)
          OR coalesce((item->>'potm')::int, 0) > 0
        ) AS potm,
        (
          sum(coalesce((item->>'goals')::int, 0)) * 5
          + sum(coalesce((item->>'assists')::int, 0)) * 3
          + CASE WHEN bool_or(
              coalesce((item->>'potm')::boolean, false)
              OR coalesce((item->>'potm')::int, 0) > 0
            ) THEN 8 ELSE 0 END
          + max(coalesce((item->>'rating')::numeric, 0))
        ) AS feat_score
      FROM public.international_result_submissions s
      JOIN public.international_fixtures f ON f.id = s.fixture_id
      CROSS JOIN LATERAL jsonb_array_elements(coalesce(s.player_stats, '[]'::jsonb)) item
      LEFT JOIN public."Players" p ON p."Konami_ID"::text = item->>'player_id'
      WHERE s.status = 'confirmed'
        AND f.season_id = p_season_id
        AND lower(f.gpsl_month) = v_intl_month
        AND f.played IS TRUE
        AND nullif(item->>'player_id', '') IS NOT NULL
      GROUP BY p."Name", p."Konami_ID"
      HAVING
        sum(coalesce((item->>'goals')::int, 0)) > 0
        OR sum(coalesce((item->>'assists')::int, 0)) > 0
        OR bool_or(
          coalesce((item->>'potm')::boolean, false)
          OR coalesce((item->>'potm')::int, 0) > 0
        )
        OR max(coalesce((item->>'rating')::numeric, 0)) >= 8.5
      ORDER BY feat_score DESC, player_name
      LIMIT 10
    ) t;
  END IF;

  SELECT value INTO v_top
  FROM jsonb_array_elements(v_shocks)
  LIMIT 1;

  IF v_top IS NULL THEN
    SELECT value INTO v_top
    FROM jsonb_array_elements(v_results)
    LIMIT 1;
  END IF;

  SELECT f.phase INTO v_phase
  FROM public.international_fixtures f
  WHERE f.season_id = p_season_id
    AND lower(f.gpsl_month) = v_intl_month
    AND f.played IS TRUE
  GROUP BY f.phase
  ORDER BY count(*) DESC
  LIMIT 1;

  IF v_top IS NOT NULL THEN
    v_lead_headline := format(
      '%s %s %s %s — WORLD STAGE',
      v_top->>'home_flag',
      v_top->>'home_name',
      v_top->>'score',
      v_top->>'away_name'
    );
    v_lead_subhead := format(
      '%s internationals · %s played · %s',
      v_month_label,
      v_played,
      coalesce(v_phase, 'window')
    );
    v_lead_body := format(
      E'GPSL Sport''s internationals desk looks back at the %s window: %s matches done.\n\n'
      || E'The splash result: %s %s %s. Seed rankings and scorelines tell you who turned the group chats upside down — full results and nation tables below.\n\n'
      || E'This pullout sits with the %s club edition so owners get league and country in one paper.',
      v_month_label,
      v_played,
      v_top->>'home_name',
      v_top->>'score',
      v_top->>'away_name',
      public.gpsl_sport_month_label(lower(btrim(p_club_month)))
    );
  ELSE
    v_lead_headline := format('%s INTERNATIONALS ROUND-UP', upper(v_month_label));
    v_lead_subhead := format('%s fixtures on the world stage', v_played);
    v_lead_body := format(
      'The %s international window is filed. GPSL Sport has the results and nation tables in this pullout.',
      v_month_label
    );
  END IF;

  RETURN jsonb_build_object(
    'enabled', true,
    'page_title', 'Internationals',
    'source_month', v_intl_month,
    'source_month_label', v_month_label,
    'club_month', lower(btrim(p_club_month)),
    'played_count', v_played,
    'phase', v_phase,
    'lead', jsonb_build_object(
      'headline', v_lead_headline,
      'subhead', v_lead_subhead,
      'byline', 'GPSL Sport · Internationals desk',
      'body', v_lead_body
    ),
    'shocks', coalesce(v_shocks, '[]'::jsonb),
    'results', coalesce(v_results, '[]'::jsonb),
    'groups', coalesce(v_groups, '[]'::jsonb),
    'brilliant_performances', coalesce(v_feats, '[]'::jsonb)
  );
END;
$function$;

-- Refresh: include internationals_page in detail
CREATE OR REPLACE FUNCTION public.gpsl_sport_refresh_inseason_edition_by_id(
  p_edition_id bigint
)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_row public.gpsl_sport_editions%ROWTYPE;
  v_built jsonb;
  v_intl jsonb;
  v_month_label text;
  v_month text;
  v_id bigint;
  v_use record;
BEGIN
  IF p_edition_id IS NULL THEN
    RETURN NULL;
  END IF;

  SELECT * INTO v_row
  FROM public.gpsl_sport_editions e
  WHERE e.id = p_edition_id;

  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  v_month := lower(btrim(v_row.gpsl_month));
  IF v_month IN ('may', 'june', 'july', '') THEN
    RETURN p_edition_id;
  END IF;

  IF to_regprocedure('public.gpsl_sport_build_inseason_month_content(bigint, text)') IS NULL THEN
    RAISE EXCEPTION 'gpsl_sport_build_inseason_month_content is not installed';
  END IF;

  v_month_label := public.gpsl_sport_month_label(v_month);
  v_built := public.gpsl_sport_build_inseason_month_content(v_row.season_id, v_month);

  IF v_built ? 'error' THEN
    RAISE EXCEPTION 'gpsl_sport_build_inseason_month_content failed: %', v_built->>'error';
  END IF;

  v_intl := public.gpsl_sport_build_internationals_page(v_row.season_id, v_month);

  UPDATE public.gpsl_sport_editions e
  SET
    edition_label = v_month_label,
    story_type = coalesce(v_built->>'story_type', 'inseason_month'),
    front_page = v_built->'front_page',
    back_page = coalesce(v_built->'back_page', '{}'::jsonb),
    detail = coalesce(e.detail, '{}'::jsonb) || jsonb_build_object(
      'generated_at', now(),
      'inseason_rich', true,
      'stats_page', coalesce(v_built->'stats_page', '{}'::jsonb),
      'match_page', coalesce(v_built->'match_page', '{}'::jsonb),
      'internationals_page', coalesce(v_intl, jsonb_build_object('enabled', false)),
      'refreshed_at', now()
    ),
    published_at = coalesce(e.published_at, now())
  WHERE e.id = p_edition_id
  RETURNING e.id INTO v_id;

  IF v_id IS NULL THEN
    RAISE EXCEPTION 'gpsl_sport_refresh_inseason_edition_by_id: edition % not updated', p_edition_id;
  END IF;

  DELETE FROM public.gpsl_sport_reads r WHERE r.edition_id = v_id;

  IF to_regclass('public.gpsl_sport_template_usage') IS NOT NULL THEN
    DELETE FROM public.gpsl_sport_template_usage u WHERE u.edition_id = v_id;
  END IF;
  IF to_regprocedure(
       'public.gpsl_sport_record_pack_usage(bigint,bigint,text,text,text,text)'
     ) IS NOT NULL THEN
    FOR v_use IN
      SELECT value AS u
      FROM jsonb_array_elements(coalesce(v_built->'front_page'->'pack_uses', '[]'::jsonb))
    LOOP
      PERFORM public.gpsl_sport_record_pack_usage(
        v_id,
        v_row.season_id,
        v_month,
        v_use.u->>'scenario',
        v_use.u->>'pack_id',
        coalesce(v_use.u->>'slot', 'lead')
      );
    END LOOP;
  END IF;

  RETURN v_id;
END;
$function$;

-- First-create path: same internationals attach
CREATE OR REPLACE FUNCTION public.gpsl_sport_generate_inseason_edition(
  p_season_id bigint,
  p_gpsl_month text
)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_month text := lower(btrim(coalesce(p_gpsl_month, '')));
  v_month_label text;
  v_built jsonb;
  v_intl jsonb;
  v_existing bigint;
  v_use record;
BEGIN
  IF p_season_id IS NULL OR v_month IS NULL OR v_month = '' THEN
    RETURN NULL;
  END IF;

  SELECT e.id INTO v_existing
  FROM public.gpsl_sport_editions e
  WHERE e.season_id = p_season_id AND lower(e.gpsl_month) = v_month;

  IF v_existing IS NOT NULL THEN
    IF coalesce(
      (SELECT (e.detail->>'inseason_rich')::boolean
       FROM public.gpsl_sport_editions e
       WHERE e.id = v_existing),
      false
    ) IS NOT TRUE
    AND to_regprocedure('public.gpsl_sport_refresh_inseason_edition_by_id(bigint)') IS NOT NULL THEN
      RETURN public.gpsl_sport_refresh_inseason_edition_by_id(v_existing);
    END IF;
    -- Existing rich edition: force refresh so internationals attach
    IF to_regprocedure('public.gpsl_sport_refresh_inseason_edition_by_id(bigint)') IS NOT NULL THEN
      RETURN public.gpsl_sport_refresh_inseason_edition_by_id(v_existing);
    END IF;
    RETURN v_existing;
  END IF;

  IF to_regprocedure('public.gpsl_sport_build_inseason_month_content(bigint, text)') IS NULL THEN
    RAISE EXCEPTION 'gpsl_sport_build_inseason_month_content is not installed';
  END IF;

  v_month_label := public.gpsl_sport_month_label(v_month);
  v_built := public.gpsl_sport_build_inseason_month_content(p_season_id, v_month);

  IF v_built ? 'error' THEN
    RAISE EXCEPTION 'gpsl_sport_build_inseason_month_content failed: %', v_built->>'error';
  END IF;

  v_intl := public.gpsl_sport_build_internationals_page(p_season_id, v_month);

  INSERT INTO public.gpsl_sport_editions (
    season_id, gpsl_month, edition_label, story_type, front_page, back_page, detail
  )
  VALUES (
    p_season_id,
    v_month,
    v_month_label,
    coalesce(v_built->>'story_type', 'inseason_month'),
    v_built->'front_page',
    coalesce(v_built->'back_page', '{}'::jsonb),
    jsonb_build_object(
      'generated_at', now(),
      'inseason_rich', true,
      'stats_page', coalesce(v_built->'stats_page', '{}'::jsonb),
      'match_page', coalesce(v_built->'match_page', '{}'::jsonb),
      'internationals_page', coalesce(v_intl, jsonb_build_object('enabled', false))
    )
  )
  RETURNING id INTO v_existing;

  IF to_regprocedure(
       'public.gpsl_sport_record_pack_usage(bigint,bigint,text,text,text,text)'
     ) IS NOT NULL THEN
    FOR v_use IN
      SELECT value AS u
      FROM jsonb_array_elements(coalesce(v_built->'front_page'->'pack_uses', '[]'::jsonb))
    LOOP
      PERFORM public.gpsl_sport_record_pack_usage(
        v_existing,
        p_season_id,
        v_month,
        v_use.u->>'scenario',
        v_use.u->>'pack_id',
        coalesce(v_use.u->>'slot', 'lead')
      );
    END LOOP;
  END IF;

  RETURN v_existing;
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
      'detail', v_edition.detail
    )
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.gpsl_sport_previous_gpsl_month(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.gpsl_sport_resolve_intl_source_month(bigint, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.gpsl_sport_build_internationals_page(bigint, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.gpsl_sport_refresh_inseason_edition_by_id(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.gpsl_sport_generate_inseason_edition(bigint, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.gpsl_sport_get_edition(bigint) TO authenticated;

NOTIFY pgrst, 'reload schema';

-- Preview (optional): SELECT public.gpsl_sport_build_internationals_page(
--   (SELECT id FROM competition_seasons WHERE is_current LIMIT 1), 'august');
-- Publish: SELECT public.competition_admin_regenerate_gpsl_sport('august', NULL);
