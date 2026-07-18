-- =============================================================================
-- Fix: May GPSL Sport listed 17th as "relegated"
--
-- Correct rules:
--   • Auto-relegated = SuperLeague 18–20 only
--   • 16th vs 17th = relegation playoff in Playoffs week (loser also goes down)
--
-- Also: manager avoid_relegation treated 18th as success — now requires ≤16.
-- After apply: republish May Sport (Admin → regenerate GPSL Sport for may).
-- Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.gpsl_sport_generate_may_edition(p_season_id bigint)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_existing bigint;
  v_month_label text := 'May';
  v_seed text;
  v_front jsonb;
  v_back jsonb := jsonb_build_object('enabled', false);
  v_stories jsonb := '[]'::jsonb;
  v_champion text;
  v_champion_name text;
  v_story record;
  v_award record;
  v_cup record;
  v_club_player record;
  v_headline text;
  v_subhead text;
  v_lead text;
  v_lines text[] := ARRAY[]::text[];
  v_promoted text := '';
  v_relegated text := '';
  v_rel_playoff text := '';
  v_cup_lines text := '';
  v_award_lines text := '';
  v_season_label text;
BEGIN
  SELECT e.id INTO v_existing
  FROM public.gpsl_sport_editions e
  WHERE e.season_id = p_season_id AND e.gpsl_month = 'may';

  IF v_existing IS NOT NULL THEN
    RETURN v_existing;
  END IF;

  SELECT s.label INTO v_season_label
  FROM public.competition_seasons s
  WHERE s.id = p_season_id;

  v_seed := p_season_id::text || ':may:season_review';

  SELECT a.club_short_name, public.gpsl_sport_club_display_name(a.club_short_name)
  INTO v_champion, v_champion_name
  FROM public.competition_club_season_archive a
  WHERE a.season_id = p_season_id
    AND a.division = 'superleague'
    AND a.final_position = 1
  LIMIT 1;

  IF v_champion IS NULL THEN
    SELECT s.club_short_name, public.gpsl_sport_club_display_name(s.club_short_name)
    INTO v_champion, v_champion_name
    FROM public.competition_standings_public s
    WHERE s.season_id = p_season_id
      AND s.division = 'superleague'
      AND s.table_position = 1
    LIMIT 1;
  END IF;

  SELECT string_agg(public.gpsl_sport_club_display_name(x.club_short_name), ', ' ORDER BY x.division, x.final_position)
  INTO v_promoted
  FROM public.competition_club_season_archive x
  WHERE x.season_id = p_season_id
    AND x.division IN ('championship_a', 'championship_b')
    AND x.final_position <= 2;

  IF v_promoted IS NULL THEN
    SELECT string_agg(public.gpsl_sport_club_display_name(x.club_short_name), ', ' ORDER BY x.division, x.table_position)
    INTO v_promoted
    FROM public.competition_standings_public x
    WHERE x.season_id = p_season_id
      AND x.division IN ('championship_a', 'championship_b')
      AND x.table_position <= 2;
  END IF;

  -- Auto-relegated = bottom 3 only (18–20). 16th vs 17th is the Playoffs week match.
  SELECT string_agg(
    public.gpsl_sport_club_display_name(x.club_short_name) || ' (' || x.final_position::text || 'th)',
    ', ' ORDER BY x.final_position DESC
  )
  INTO v_relegated
  FROM public.competition_club_season_archive x
  WHERE x.season_id = p_season_id
    AND x.division = 'superleague'
    AND x.final_position >= 18;

  IF v_relegated IS NULL THEN
    SELECT string_agg(
      public.gpsl_sport_club_display_name(x.club_short_name) || ' (' || x.table_position::text || 'th)',
      ', ' ORDER BY x.table_position DESC
    )
    INTO v_relegated
    FROM public.competition_standings_public x
    WHERE x.season_id = p_season_id
      AND x.division = 'superleague'
      AND x.table_position >= 18;
  END IF;

  SELECT string_agg(
    public.gpsl_sport_club_display_name(x.club_short_name) || ' (' || x.final_position::text || 'th)',
    ' vs ' ORDER BY x.final_position
  )
  INTO v_rel_playoff
  FROM public.competition_club_season_archive x
  WHERE x.season_id = p_season_id
    AND x.division = 'superleague'
    AND x.final_position IN (16, 17);

  IF v_rel_playoff IS NULL THEN
    SELECT string_agg(
      public.gpsl_sport_club_display_name(x.club_short_name) || ' (' || x.table_position::text || 'th)',
      ' vs ' ORDER BY x.table_position
    )
    INTO v_rel_playoff
    FROM public.competition_standings_public x
    WHERE x.season_id = p_season_id
      AND x.division = 'superleague'
      AND x.table_position IN (16, 17);
  END IF;

  FOR v_cup IN
    SELECT w.cup_code, public.gpsl_sport_club_display_name(w.winner_club_short_name) AS winner_name
    FROM public.competition_cup_season_winner w
    WHERE w.season_id = p_season_id
    ORDER BY w.cup_code
  LOOP
    v_cup_lines := v_cup_lines || CASE WHEN v_cup_lines = '' THEN '' ELSE E'\n' END
      || initcap(replace(v_cup.cup_code, '_', ' ')) || ': ' || v_cup.winner_name;
  END LOOP;

  FOR v_award IN
    SELECT
      a.award_type,
      a.stat_value,
      p."Name" AS player_name,
      public.gpsl_sport_club_display_name(a.club_short_name) AS club_name
    FROM public.competition_season_award a
    LEFT JOIN public."Players" p ON p."Konami_ID"::text = a.player_id
    WHERE a.season_id = p_season_id
      AND a.award_type IN (
        'ballon_dor',
        'golden_boot',
        'golden_playmaker',
        'golden_glove',
        'championship_player_of_season',
        'season_potm'
      )
    ORDER BY CASE a.award_type
      WHEN 'ballon_dor' THEN 1
      WHEN 'championship_player_of_season' THEN 2
      WHEN 'golden_boot' THEN 3
      WHEN 'golden_playmaker' THEN 4
      WHEN 'golden_glove' THEN 5
      ELSE 9
    END
  LOOP
    v_award_lines := v_award_lines || CASE WHEN v_award_lines = '' THEN '' ELSE E'\n' END
      || replace(initcap(replace(v_award.award_type, '_', ' ')), 'Championship Player Of Season', 'Championship Player of the Season')
      || ': ' || coalesce(v_award.player_name, 'TBC')
      || ' (' || coalesce(v_award.club_name, 'GPSL') || ') — ' || v_award.stat_value::text;
  END LOOP;

  v_headline := CASE
    WHEN v_champion_name IS NOT NULL THEN v_champion_name || ' CROWNED GPSL CHAMPIONS'
    ELSE 'SEASON REVIEW: MAY EDITION'
  END;

  v_subhead := coalesce(v_season_label, 'GPSL') || ' honours, heartbreak and history';

  v_lead := concat_ws(
    E'\n\n',
    CASE WHEN v_champion_name IS NOT NULL THEN
      format('%s finish top of the SuperLeague to lift the title. The May edition of GPSL Sport wraps the campaign.', v_champion_name)
    ELSE
      'Another GPSL season reaches its conclusion. GPSL Sport reviews the month that settled the table.'
    END,
    CASE WHEN coalesce(v_promoted, '') <> '' THEN
      'Automatically promoted: ' || v_promoted
    ELSE NULL END,
    CASE WHEN coalesce(v_relegated, '') <> '' THEN
      'Automatically relegated from SuperLeague: ' || v_relegated
    ELSE NULL END,
    CASE WHEN coalesce(v_rel_playoff, '') <> '' THEN
      'SuperLeague relegation playoff (Playoffs week): ' || v_rel_playoff
        || ' — loser also relegated'
    ELSE NULL END,
    CASE WHEN coalesce(v_cup_lines, '') <> '' THEN E'Cup winners:\n' || v_cup_lines ELSE NULL END,
    CASE WHEN coalesce(v_award_lines, '') <> '' THEN E'Season awards:\n' || v_award_lines ELSE NULL END
  );

  FOR v_story IN
    SELECT
      ps.player_id,
      ps.club_short_name,
      p."Name" AS player_name,
      public.gpsl_sport_club_display_name(ps.club_short_name) AS club_name,
      ps.goals,
      ps.assists
    FROM public.competition_player_season_archive ps
    JOIN public."Players" p ON p."Konami_ID"::text = ps.player_id
    WHERE ps.season_id = p_season_id
    ORDER BY ps.goals DESC NULLS LAST, ps.assists DESC NULLS LAST
    LIMIT 3
  LOOP
    v_stories := v_stories || jsonb_build_array(
      jsonb_build_object(
        'kicker', 'Golden boot race',
        'headline', v_story.player_name || ' — ' || coalesce(v_story.goals, 0)::text || ' goals',
        'body', format('%s for %s (%s assists).', v_story.player_name, v_story.club_name, coalesce(v_story.assists, 0)),
        'player_id', v_story.player_id,
        'club_short', v_story.club_short_name
      )
    );
  END LOOP;

  FOR v_club_player IN
    SELECT DISTINCT ON (ps.club_short_name)
      ps.club_short_name,
      ps.player_id,
      public.gpsl_sport_club_display_name(ps.club_short_name) AS club_name,
      p."Name" AS player_name,
      ps.ballon_points
    FROM public.competition_player_season_archive ps
    JOIN public."Players" p ON p."Konami_ID"::text = ps.player_id
    WHERE ps.season_id = p_season_id
    ORDER BY ps.club_short_name, ps.ballon_points DESC NULLS LAST, ps.goals DESC NULLS LAST
    LIMIT 6
  LOOP
    EXIT WHEN jsonb_array_length(v_stories) >= 6;
    v_stories := v_stories || jsonb_build_array(
      jsonb_build_object(
        'kicker', 'Club player of the season',
        'headline', v_club_player.club_name || ': ' || v_club_player.player_name,
        'body', format('Stand-out performer at %s on Ballon points.', v_club_player.club_name),
        'player_id', v_club_player.player_id,
        'club_short', v_club_player.club_short_name
      )
    );
  END LOOP;

  v_front := jsonb_build_object(
    'masthead', 'GPSL Sport',
    'edition_label', v_month_label,
    'gpsl_month', 'may',
    'headline', v_headline,
    'subhead', v_subhead,
    'lead_paragraph', v_lead,
    'stories', v_stories,
    'story_type', 'season_review',
    'hero', CASE
      WHEN v_champion IS NOT NULL THEN jsonb_build_object(
        'kind', 'champion',
        'club_short', v_champion,
        'trophy', 'superleague',
        'caption', coalesce(v_champion_name, 'GPSL') || ' — SuperLeague champions'
      )
      ELSE jsonb_build_object('kind', 'generic', 'caption', 'Season review')
    END
  );

  INSERT INTO public.gpsl_sport_editions (
    season_id, gpsl_month, edition_label, story_type, front_page, back_page, detail
  )
  VALUES (
    p_season_id,
    'may',
    v_month_label,
    'season_review',
    v_front,
    v_back,
    jsonb_build_object('generated_at', now(), 'season_label', v_season_label, 'champion_club_short', v_champion)
  )
  RETURNING id INTO v_existing;

  RETURN v_existing;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.gpsl_sport_generate_may_edition(bigint) TO service_role;

-- Manager "avoid relegation": 18th is auto-relegated. Safe finish = 16th or better.
CREATE OR REPLACE FUNCTION public.manager_target_met(
  p_target public.manager_rating_targets,
  p_actual_position smallint,
  p_division text
)
RETURNS boolean
LANGUAGE plpgsql
IMMUTABLE
AS $function$
BEGIN
  IF p_target IS NULL OR p_actual_position IS NULL THEN
    RETURN NULL;
  END IF;

  IF p_target.target_kind = 'max_position' THEN
    RETURN p_actual_position <= p_target.target_value;
  END IF;

  IF p_target.target_kind = 'promotion' THEN
    RETURN p_actual_position <= 2;
  END IF;

  IF p_target.target_kind = 'avoid_relegation' THEN
    -- SuperLeague: 18–20 auto down; 16–17 playoff. "Avoided" = finished 16th or better.
    RETURN p_actual_position <= 16;
  END IF;

  RETURN NULL;
END;
$function$;

NOTIFY pgrst, 'reload schema';
