-- =============================================================================
-- GPSL Sport golden boot: dense places 1–10 (ties share a place), include rank
-- Post-processes scorers on refresh so existing editions pick this up when rebuilt.
-- Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.gpsl_sport_month_top_scorers(
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
  v_out jsonb;
BEGIN
  IF p_season_id IS NULL OR v_month = '' THEN
    RETURN '{}'::jsonb;
  END IF;

  SELECT coalesce(jsonb_object_agg(div_key, scorer_rows), '{}'::jsonb)
  INTO v_out
  FROM (
    SELECT
      r.division AS div_key,
      coalesce(jsonb_agg(
        jsonb_build_object(
          'player_id', r.player_id,
          'player_name', coalesce(r.player_name, 'Unknown player'),
          'club_short', r.club_short_name,
          'club_name', r.club_name,
          'owner', public.gpsl_sport_owner_byline(r.club_short_name),
          'goals', r.goals,
          'assists', r.assists,
          'rank', r.dense_place
        )
        ORDER BY r.dense_place ASC, r.goals DESC, r.assists DESC, r.player_name ASC
      ), '[]'::jsonb) AS scorer_rows
    FROM (
      SELECT
        g.*,
        dense_rank() OVER (
          PARTITION BY g.division
          ORDER BY g.goals DESC
        ) AS dense_place
      FROM (
        SELECT
          m.player_id,
          p."Name" AS player_name,
          m.club_short_name,
          c."Club" AS club_name,
          ccs.division,
          sum(m.goals)::int AS goals,
          sum(m.assists)::int AS assists
        FROM public.competition_match_player_stats m
        JOIN public.competition_fixtures f ON f.id = m.fixture_id
        JOIN public.competition_club_seasons ccs
          ON ccs.season_id = f.season_id AND ccs.club_short_name = m.club_short_name
        JOIN public."Clubs" c ON c."ShortName" = m.club_short_name
        LEFT JOIN public."Players" p ON p."Konami_ID"::text = m.player_id::text
        WHERE f.season_id = p_season_id
          AND lower(f.gpsl_month) = v_month
          AND f.competition_type = 'league'
          AND f.status = 'played'
        GROUP BY m.player_id, p."Name", m.club_short_name, c."Club", ccs.division
        HAVING sum(m.goals) > 0
      ) g
    ) r
    WHERE r.dense_place <= 10
    GROUP BY r.division
  ) sc;

  RETURN coalesce(v_out, '{}'::jsonb);
END;
$function$;

-- Refresh path: overwrite top_scorers with dense-ranked chart after build
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
  v_month text;
  v_month_label text;
  v_built jsonb;
  v_id bigint;
  v_scorers jsonb;
BEGIN
  SELECT * INTO v_row
  FROM public.gpsl_sport_editions
  WHERE id = p_edition_id
  FOR UPDATE;

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

  -- Prefer dense-ranked golden boot (places 1–10 with ties)
  IF to_regprocedure('public.gpsl_sport_month_top_scorers(bigint, text)') IS NOT NULL THEN
    v_scorers := public.gpsl_sport_month_top_scorers(v_row.season_id, v_month);
    v_built := jsonb_set(
      v_built,
      '{stats_page,top_scorers}',
      coalesce(v_scorers, '{}'::jsonb),
      true
    );
  END IF;

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
      'refreshed_at', now()
    ),
    published_at = coalesce(e.published_at, now())
  WHERE e.id = p_edition_id
  RETURNING e.id INTO v_id;

  IF v_id IS NULL THEN
    RAISE EXCEPTION 'gpsl_sport_refresh_inseason_edition_by_id: edition % not updated', p_edition_id;
  END IF;

  DELETE FROM public.gpsl_sport_reads r WHERE r.edition_id = v_id;
  RETURN v_id;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.gpsl_sport_month_top_scorers(bigint, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.gpsl_sport_refresh_inseason_edition_by_id(bigint) TO service_role;
GRANT EXECUTE ON FUNCTION public.gpsl_sport_refresh_inseason_edition_by_id(bigint) TO authenticated;

NOTIFY pgrst, 'reload schema';
