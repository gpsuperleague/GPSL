-- =============================================================================
-- GPSL Sport — rich in-season monthly edition (August–April)
-- TOTM, monthly top scorers, standings/owners, shock results, match report
-- Run after gpsl_sport_inseason_v_u_fix.sql + competition_totm patches
-- =============================================================================

CREATE OR REPLACE FUNCTION public.gpsl_sport_owner_byline(p_club_short text)
RETURNS text
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT coalesce(
    nullif(btrim(public.owner_registry_resolve_tag(c.owner_id)), ''),
    nullif(btrim(public.competition_owner_display_name(c.owner_id)), ''),
    'the ' || coalesce(c."Club", p_club_short) || ' owner'
  )
  FROM public."Clubs" c
  WHERE c."ShortName" = p_club_short;
$$;

CREATE OR REPLACE FUNCTION public.gpsl_sport_build_inseason_month_content(
  p_season_id bigint,
  p_gpsl_month text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_month_label text;
  v_seed text;
  v_month_start timestamptz;
  v_month_end timestamptz;
  v_shocks jsonb := '[]'::jsonb;
  v_stories jsonb := '[]'::jsonb;
  v_standings jsonb := '{}'::jsonb;
  v_scorers jsonb := '{}'::jsonb;
  v_totm_super jsonb := '[]'::jsonb;
  v_totm_champ jsonb := '[]'::jsonb;
  v_match jsonb;
  v_front jsonb;
  v_back jsonb := jsonb_build_object('enabled', false);
  v_stats_page jsonb;
  v_match_page jsonb;
  v_headline text;
  v_subhead text;
  v_lead text;
  v_vars jsonb;
  v_best_shock numeric := 0;
  v_f record;
  v_shock_row record;
  v_winner text;
  v_loser text;
  v_winner_name text;
  v_loser_name text;
  v_winner_owner text;
  v_loser_owner text;
  v_win int;
  v_lose int;
  v_gap int;
  v_shock numeric;
  v_division text;
  v_story_type text := 'inseason_month';
  v_cal record;
  v_transfer_stories jsonb := '[]'::jsonb;
  v_i int := 0;
BEGIN
  v_month_label := public.gpsl_sport_month_label(p_gpsl_month);
  v_seed := p_season_id::text || ':' || p_gpsl_month || ':inseason';

  SELECT c.unlock_at, c.lock_at
  INTO v_month_start, v_month_end
  FROM public.competition_season_calendar c
  WHERE c.season_id = p_season_id AND c.gpsl_month = p_gpsl_month;

  -- Shock results (up to 5) with owner names
  FOR v_f IN
    SELECT
      f.id,
      f.home_club_short_name,
      f.away_club_short_name,
      f.home_goals,
      f.away_goals,
      f.division,
      f.cup_code,
      f.competition_type,
      ph.prestige_rank AS home_prestige,
      pa.prestige_rank AS away_prestige
    FROM public.competition_fixtures f
    LEFT JOIN public.competition_club_prestige_public ph
      ON ph.club_short_name = f.home_club_short_name
    LEFT JOIN public.competition_club_prestige_public pa
      ON pa.club_short_name = f.away_club_short_name
    WHERE f.season_id = p_season_id
      AND f.gpsl_month = p_gpsl_month
      AND f.status = 'played'
      AND f.home_goals IS NOT NULL
      AND f.away_goals IS NOT NULL
      AND f.home_goals <> f.away_goals
  LOOP
    IF v_f.home_goals > v_f.away_goals THEN
      v_winner := v_f.home_club_short_name;
      v_loser := v_f.away_club_short_name;
      v_win := v_f.home_goals;
      v_lose := v_f.away_goals;
      v_gap := coalesce(v_f.away_prestige, 99) - coalesce(v_f.home_prestige, 99);
    ELSE
      v_winner := v_f.away_club_short_name;
      v_loser := v_f.home_club_short_name;
      v_win := v_f.away_goals;
      v_lose := v_f.home_goals;
      v_gap := coalesce(v_f.home_prestige, 99) - coalesce(v_f.away_prestige, 99);
    END IF;

    v_shock := greatest(0, v_gap) * greatest(1, v_win - v_lose + 1);
    IF coalesce(v_f.competition_type, 'league') = 'cup' OR v_f.cup_code IS NOT NULL THEN
      v_shock := v_shock + 5;
    END IF;

    IF v_shock <= 0 THEN
      CONTINUE;
    END IF;

    v_winner_name := public.gpsl_sport_club_display_name(v_winner);
    v_loser_name := public.gpsl_sport_club_display_name(v_loser);
    v_winner_owner := public.gpsl_sport_owner_byline(v_winner);
    v_loser_owner := public.gpsl_sport_owner_byline(v_loser);
    v_division := public.gpsl_sport_fixture_division_label(v_f.division, v_f.cup_code, v_f.competition_type);

    v_shocks := v_shocks || jsonb_build_array(jsonb_build_object(
      'fixture_id', v_f.id,
      'shock_score', v_shock,
      'winner_club', v_winner,
      'loser_club', v_loser,
      'winner_name', v_winner_name,
      'loser_name', v_loser_name,
      'winner_owner', v_winner_owner,
      'loser_owner', v_loser_owner,
      'score', v_win::text || '–' || v_lose::text,
      'division', v_division,
      'competition_type', coalesce(v_f.competition_type, 'league'),
      'cup_code', v_f.cup_code
    ));

    IF v_shock > v_best_shock THEN
      v_best_shock := v_shock;
    END IF;
  END LOOP;

  SELECT coalesce(jsonb_agg(x ORDER BY (x->>'shock_score')::numeric DESC), '[]'::jsonb)
  INTO v_shocks
  FROM (
    SELECT value AS x
    FROM jsonb_array_elements(v_shocks)
    ORDER BY (value->>'shock_score')::numeric DESC
    LIMIT 5
  ) q;

  -- Division standings: leader + challengers (with owners)
  SELECT jsonb_object_agg(div_key, div_data)
  INTO v_standings
  FROM (
    SELECT
      s.division AS div_key,
      jsonb_build_object(
        'division_label', CASE s.division
          WHEN 'superleague' THEN 'SuperLeague'
          WHEN 'championship_a' THEN 'Championship A'
          WHEN 'championship_b' THEN 'Championship B'
          ELSE initcap(replace(s.division, '_', ' '))
        END,
        'leader', (
          SELECT jsonb_build_object(
            'club_short', l.club_short_name,
            'club_name', l.club_name,
            'owner', public.gpsl_sport_owner_byline(l.club_short_name),
            'pts', l.pts,
            'position', l.table_position
          )
          FROM public.competition_standings_public l
          WHERE l.season_id = p_season_id AND l.division = s.division
          ORDER BY l.table_position
          LIMIT 1
        ),
        'chasers', coalesce((
          SELECT jsonb_agg(jsonb_build_object(
            'club_short', c.club_short_name,
            'club_name', c.club_name,
            'owner', public.gpsl_sport_owner_byline(c.club_short_name),
            'pts', c.pts,
            'position', c.table_position,
            'pts_behind', (
              SELECT l2.pts FROM public.competition_standings_public l2
              WHERE l2.season_id = p_season_id AND l2.division = s.division
              ORDER BY l2.table_position LIMIT 1
            ) - c.pts
          ) ORDER BY c.table_position)
          FROM public.competition_standings_public c
          WHERE c.season_id = p_season_id
            AND c.division = s.division
            AND c.table_position BETWEEN 2 AND 3
        ), '[]'::jsonb),
        'flying', coalesce((
          SELECT jsonb_agg(jsonb_build_object(
            'club_short', fl.club_short_name,
            'club_name', fl.club_name,
            'owner', public.gpsl_sport_owner_byline(fl.club_short_name),
            'pts', fl.pts,
            'position', fl.table_position,
            'form', fl.form_last10
          ) ORDER BY fl.table_position)
          FROM public.competition_standings_public fl
          WHERE fl.season_id = p_season_id
            AND fl.division = s.division
            AND fl.table_position <= 3
        ), '[]'::jsonb)
      ) AS div_data
    FROM (
      SELECT DISTINCT division
      FROM public.competition_club_seasons
      WHERE season_id = p_season_id
        AND division IN ('superleague', 'championship_a', 'championship_b')
    ) s
  ) standings_wrap;

  -- Monthly top scorers per division (top 3)
  SELECT jsonb_object_agg(div_key, scorer_rows)
  INTO v_scorers
  FROM (
    SELECT
      g.division AS div_key,
      coalesce(jsonb_agg(
        jsonb_build_object(
          'player_id', g.player_id,
          'player_name', g.player_name,
          'club_short', g.club_short_name,
          'club_name', g.club_name,
          'owner', public.gpsl_sport_owner_byline(g.club_short_name),
          'goals', g.goals,
          'assists', g.assists
        )
        ORDER BY g.goals DESC, g.assists DESC
      ), '[]'::jsonb) AS scorer_rows
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
      JOIN public."Players" p ON p."Konami_ID"::text = m.player_id
      JOIN public."Clubs" c ON c."ShortName" = m.club_short_name
      WHERE f.season_id = p_season_id
        AND f.gpsl_month = p_gpsl_month
        AND f.competition_type = 'league'
        AND f.status = 'played'
      GROUP BY m.player_id, p."Name", m.club_short_name, c."Club", ccs.division
      HAVING sum(m.goals) > 0
    ) g
    GROUP BY g.division
  ) sc;

  -- Team of the Month (Super League + Championship)
  SELECT coalesce(jsonb_agg(
    jsonb_build_object(
      'pitch_slot', m.pitch_slot,
      'slot_label', m.slot_label,
      'player_id', m.player_id,
      'player_name', m.player_name,
      'club_short', m.club_short_name,
      'club_name', m.club_name,
      'goals', m.goals,
      'assists', m.assists,
      'appearances', m.appearances,
      'avg_rating', m.avg_rating
    )
    ORDER BY m.pitch_slot
  ), '[]'::jsonb)
  INTO v_totm_super
  FROM public.competition_period_team_public m
  WHERE m.season_id = p_season_id
    AND m.gpsl_month = p_gpsl_month
    AND m.period_kind = 'month'
    AND m.division_scope = 'superleague';

  SELECT coalesce(jsonb_agg(
    jsonb_build_object(
      'pitch_slot', m.pitch_slot,
      'slot_label', m.slot_label,
      'player_id', m.player_id,
      'player_name', m.player_name,
      'club_short', m.club_short_name,
      'club_name', m.club_name,
      'goals', m.goals,
      'assists', m.assists,
      'appearances', m.appearances,
      'avg_rating', m.avg_rating
    )
    ORDER BY m.pitch_slot
  ), '[]'::jsonb)
  INTO v_totm_champ
  FROM public.competition_period_team_public m
  WHERE m.season_id = p_season_id
    AND m.gpsl_month = p_gpsl_month
    AND m.period_kind = 'month'
    AND m.division_scope = 'championship';

  -- Match of the Month + fictional report
  SELECT jsonb_build_object(
    'fixture_id', x.id,
    'home_club', x.home_club_short_name,
    'away_club', x.away_club_short_name,
    'home_name', public.gpsl_sport_club_display_name(x.home_club_short_name),
    'away_name', public.gpsl_sport_club_display_name(x.away_club_short_name),
    'home_owner', public.gpsl_sport_owner_byline(x.home_club_short_name),
    'away_owner', public.gpsl_sport_owner_byline(x.away_club_short_name),
    'home_goals', x.home_goals,
    'away_goals', x.away_goals,
    'division', public.gpsl_sport_fixture_division_label(x.division, x.cup_code, x.competition_type),
    'scorers_home', x.scorers_home,
    'scorers_away', x.scorers_away
  )
  INTO v_match
  FROM (
    SELECT
      f.*,
      (
        SELECT coalesce(string_agg(
          p."Name" || CASE WHEN m.goals > 1 THEN ' (' || m.goals::text || ')' ELSE '' END,
          ', ' ORDER BY m.goals DESC
        ), '—')
        FROM public.competition_match_player_stats m
        JOIN public."Players" p ON p."Konami_ID"::text = m.player_id
        WHERE m.fixture_id = f.id
          AND m.club_short_name = f.home_club_short_name
          AND m.goals > 0
      ) AS scorers_home,
      (
        SELECT coalesce(string_agg(
          p."Name" || CASE WHEN m.goals > 1 THEN ' (' || m.goals::text || ')' ELSE '' END,
          ', ' ORDER BY m.goals DESC
        ), '—')
        FROM public.competition_match_player_stats m
        JOIN public."Players" p ON p."Konami_ID"::text = m.player_id
        WHERE m.fixture_id = f.id
          AND m.club_short_name = f.away_club_short_name
          AND m.goals > 0
      ) AS scorers_away
    FROM public.competition_fixtures f
    WHERE f.season_id = p_season_id
      AND f.gpsl_month = p_gpsl_month
      AND f.status = 'played'
      AND f.home_goals IS NOT NULL
      AND f.away_goals IS NOT NULL
    ORDER BY (coalesce(f.home_goals, 0) + coalesce(f.away_goals, 0)) DESC,
      f.id
    LIMIT 1
  ) x;

  -- Front-page secondary stories: shocks + table lines
  FOR v_shock_row IN
    SELECT value AS shock
    FROM jsonb_array_elements(v_shocks)
    LIMIT 4
  LOOP
    v_stories := v_stories || jsonb_build_array(jsonb_build_object(
      'kicker', v_shock_row.shock->>'division',
      'headline', (v_shock_row.shock->>'winner_name') || ' ' || (v_shock_row.shock->>'score') || ' ' || (v_shock_row.shock->>'loser_name'),
      'body', format(
        E'%s''s %s stunned %s''s %s in %s — GPSL Sport has it as one of the shock results of %s.',
        v_shock_row.shock->>'winner_owner',
        v_shock_row.shock->>'winner_name',
        v_shock_row.shock->>'loser_owner',
        v_shock_row.shock->>'loser_name',
        v_shock_row.shock->>'division',
        v_month_label
      ),
      'club_short', v_shock_row.shock->>'winner_club',
      'story_kind', 'shock_result'
    ));
  END LOOP;

  -- Lead headline
  IF jsonb_array_length(v_shocks) > 0 THEN
    v_vars := jsonb_build_object(
      'winner', (v_shocks->0)->>'winner_name',
      'loser', (v_shocks->0)->>'loser_name',
      'winner_owner', (v_shocks->0)->>'winner_owner',
      'loser_owner', (v_shocks->0)->>'loser_owner',
      'score', (v_shocks->0)->>'score',
      'division', (v_shocks->0)->>'division',
      'month', v_month_label
    );
    v_headline := public.gpsl_sport_apply_template(
      public.gpsl_sport_pick_template(v_seed || ':h', ARRAY[
        '{{WINNER_OWNER}}''S {{WINNER}} STUN {{LOSER}} IN {{SCORE}} SHOCKER',
        'UPSET OF {{MONTH}}: {{WINNER}} BEAT {{LOSER}} {{SCORE}}',
        '{{LOSER_OWNER}} LEFT REELING AS {{WINNER}} PULL OFF {{DIVISION}} SHOCK'
      ]),
      v_vars
    );
    v_subhead := format('%s leads our %s review — plus TOTM, top scorers and match report',
      (v_shocks->0)->>'division', v_month_label);
    v_lead := format(
      E'It was the result that set the inbox alight. %s''s %s beat %s''s %s %s in %s — and GPSL Sport has plenty more from a hectic %s across the league.\n\nInside: Team of the Month, division leaders, monthly golden boot charts, and our Match of the Month report.',
      (v_shocks->0)->>'winner_owner',
      (v_shocks->0)->>'winner_name',
      (v_shocks->0)->>'loser_owner',
      (v_shocks->0)->>'loser_name',
      (v_shocks->0)->>'score',
      (v_shocks->0)->>'division',
      v_month_label
    );
  ELSIF v_match IS NOT NULL THEN
    v_headline := format('MATCH OF THE MONTH: %s %s-%s %s',
      v_match->>'home_name', v_match->>'home_goals', v_match->>'away_goals', v_match->>'away_name');
    v_subhead := v_month_label || ' — stats, standings and the full match report inside';
    v_lead := format(
      E'The GPSL month belonged to %s and %s — our Match of the Month finished %s-%s with goals from %s and %s.\n\nTurn inside for Team of the Month, top scorers in all three divisions, and who is flying high at the top of the tables.',
      v_match->>'home_owner', v_match->>'away_owner',
      v_match->>'home_goals', v_match->>'away_goals',
      coalesce(v_match->>'scorers_home', 'the home side'),
      coalesce(v_match->>'scorers_away', 'the visitors')
    );
  ELSE
    v_story_type := 'roundup';
    v_headline := v_month_label || ' GPSL ROUND-UP: TABLES TAKE SHAPE';
    v_subhead := 'Team of the Month, top scorers and division leaders';
    v_lead := format(
      E'%s is in the books. GPSL Sport rounds up the Team of the Month, golden boot charts for SuperLeague and both Championships, and the owners leading the charge at the top of the tables.',
      v_month_label
    );
  END IF;

  v_front := jsonb_build_object(
    'masthead', 'GPSL Sport',
    'edition_label', v_month_label,
    'gpsl_month', p_gpsl_month,
    'headline', v_headline,
    'subhead', v_subhead,
    'lead_paragraph', v_lead,
    'stories', v_stories,
    'story_type', v_story_type,
    'shock_results', v_shocks,
    'standings_snapshot', v_standings,
    'hero', CASE
      WHEN jsonb_array_length(v_shocks) > 0 THEN jsonb_build_object(
        'kind', 'stadium',
        'club_short', (v_shocks->0)->>'winner_club',
        'caption', (v_shocks->0)->>'winner_name' || ' — ' || (v_shocks->0)->>'score'
      )
      WHEN v_match IS NOT NULL THEN jsonb_build_object(
        'kind', 'stadium',
        'club_short', CASE
          WHEN (v_match->>'home_goals')::int >= (v_match->>'away_goals')::int
            THEN v_match->>'home_club'
          ELSE v_match->>'away_club'
        END,
        'caption', 'Match of the Month'
      )
      ELSE jsonb_build_object('kind', 'generic', 'caption', v_month_label || ' round-up')
    END
  );

  v_stats_page := jsonb_build_object(
    'enabled', true,
    'page_title', 'Stats special',
    'totm_super', v_totm_super,
    'totm_championship', v_totm_champ,
    'top_scorers', coalesce(v_scorers, '{}'::jsonb),
    'standings', coalesce(v_standings, '{}'::jsonb),
    'lead', jsonb_build_object(
      'headline', 'Team of the Month & golden boot charts',
      'body', format(
        E'Confirmed league stats for %s. Super League and Championship Teams of the Month are picked from confirmed results when the month locks — minimum two appearances required.',
        v_month_label
      )
    )
  );

  v_match_page := jsonb_build_object(
    'enabled', v_match IS NOT NULL,
    'page_title', 'Match of the Month',
    'fixture', v_match,
    'lead', CASE WHEN v_match IS NULL THEN NULL ELSE jsonb_build_object(
      'headline', format('%s %s-%s %s', v_match->>'home_name', v_match->>'home_goals', v_match->>'away_goals', v_match->>'away_name'),
      'byline', 'GPSL Sport match reporter · fictional match report',
      'body', format(
        E'%s (%s) hosted %s (%s) in %s with both owners watching on from the virtual touchline.\n\n' ||
        E'What followed was a %s-goal thriller that GPSL Sport selects as Match of the Month. The hosts'' goals came from %s; %s replied through %s.\n\n' ||
        E'Full-time: %s %s-%s %s. The result sends ripples through the inbox — and the table will not look the same come next Friday.',
        v_match->>'home_name', v_match->>'home_owner',
        v_match->>'away_name', v_match->>'away_owner',
        v_match->>'division',
        (v_match->>'home_goals')::int + (v_match->>'away_goals')::int,
        coalesce(v_match->>'scorers_home', 'their forwards'),
        v_match->>'away_name',
        coalesce(v_match->>'scorers_away', 'their attack'),
        v_match->>'home_name', v_match->>'home_goals', v_match->>'away_goals', v_match->>'away_name'
      ),
      'pull_quote', format('"%s will be talking about this one for weeks."', v_match->>'home_owner'),
      'club_short', v_match->>'home_club'
    ) END
  );

  -- Transfer back page if deals in month window
  IF v_month_start IS NOT NULL AND v_month_end IS NOT NULL THEN
    FOR v_cal IN
      SELECT h.id, h.player_id, h.seller_club_id, h.buyer_club_id, h.fee,
             p."Name" AS player_name, nullif(btrim(p."Rating"::text), '')::int AS rating
      FROM public."Transfer_History" h
      LEFT JOIN public."Players" p ON p."Konami_ID"::text = h.player_id::text
      WHERE h.transfer_time >= v_month_start
        AND h.transfer_time < v_month_end
        AND coalesce(h.buyer_club_id, '') <> ''
        AND h.buyer_club_id <> 'FOREIGN'
        AND coalesce(h.fee, 0) > 0
      ORDER BY h.fee DESC NULLS LAST, h.transfer_time DESC
      LIMIT 6
    LOOP
      v_i := v_i + 1;
      IF v_i = 1 THEN
        v_back := jsonb_build_object(
          'enabled', true,
          'page_title', 'Transfer round-up',
          'lead', jsonb_build_object(
            'headline', public.gpsl_sport_club_display_name(v_cal.buyer_club_id)
              || ' sign ' || coalesce(v_cal.player_name, 'star') || ' ('
              || public.gpsl_sport_format_fee(v_cal.fee) || ')',
            'body', format('%s completed the headline deal of %s.',
              public.gpsl_sport_owner_byline(v_cal.buyer_club_id), v_month_label),
            'player_id', v_cal.player_id::text,
            'buyer_club_short', v_cal.buyer_club_id
          ),
          'stories', '[]'::jsonb
        );
      ELSE
        v_transfer_stories := v_transfer_stories || jsonb_build_array(jsonb_build_object(
          'headline', public.gpsl_sport_club_display_name(v_cal.buyer_club_id)
            || ' sign ' || coalesce(v_cal.player_name, 'player'),
          'body', public.gpsl_sport_format_fee(v_cal.fee) || ' · seller '
            || public.gpsl_sport_club_display_name(v_cal.seller_club_id),
          'player_id', v_cal.player_id::text,
          'club_short', v_cal.buyer_club_id
        ));
      END IF;
    END LOOP;
    IF (v_back->>'enabled')::boolean IS TRUE THEN
      v_back := v_back || jsonb_build_object('stories', v_transfer_stories);
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'story_type', v_story_type,
    'front_page', v_front,
    'back_page', v_back,
    'stats_page', v_stats_page,
    'match_page', v_match_page
  );
END;
$function$;

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
  v_existing bigint;
  v_built jsonb;
  v_month_label text;
BEGIN
  IF p_season_id IS NULL OR p_gpsl_month IS NULL OR btrim(p_gpsl_month) = '' THEN
    RETURN NULL;
  END IF;

  SELECT e.id INTO v_existing
  FROM public.gpsl_sport_editions e
  WHERE e.season_id = p_season_id AND e.gpsl_month = p_gpsl_month;

  IF v_existing IS NOT NULL THEN
    RETURN v_existing;
  END IF;

  v_month_label := public.gpsl_sport_month_label(p_gpsl_month);
  v_built := public.gpsl_sport_build_inseason_month_content(p_season_id, p_gpsl_month);

  INSERT INTO public.gpsl_sport_editions (
    season_id, gpsl_month, edition_label, story_type, front_page, back_page, detail
  )
  VALUES (
    p_season_id,
    p_gpsl_month,
    v_month_label,
    coalesce(v_built->>'story_type', 'inseason_month'),
    v_built->'front_page',
    coalesce(v_built->'back_page', '{}'::jsonb),
    jsonb_build_object(
      'generated_at', now(),
      'inseason_rich', true,
      'stats_page', coalesce(v_built->'stats_page', '{}'::jsonb),
      'match_page', coalesce(v_built->'match_page', '{}'::jsonb)
    )
  )
  RETURNING id INTO v_existing;

  RETURN v_existing;
END;
$function$;

CREATE OR REPLACE FUNCTION public.gpsl_sport_get_edition(p_edition_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_edition public.gpsl_sport_editions;
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_authenticated');
  END IF;

  SELECT * INTO v_edition FROM public.gpsl_sport_editions WHERE id = p_edition_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_found');
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
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
      'detail', v_edition.detail
    )
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.gpsl_sport_owner_byline(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.gpsl_sport_build_inseason_month_content(bigint, text) TO service_role;
GRANT EXECUTE ON FUNCTION public.gpsl_sport_generate_inseason_edition(bigint, text) TO service_role;
GRANT EXECUTE ON FUNCTION public.gpsl_sport_get_edition(bigint) TO authenticated;

NOTIFY pgrst, 'reload schema';
