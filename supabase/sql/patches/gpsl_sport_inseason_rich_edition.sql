-- =============================================================================
-- GPSL Sport — rich in-season monthly edition (August–April)
-- TOTM, monthly top scorers, standings/owners, shock results, match report
-- Run gpsl_sport_inseason_rich_edition.sql THEN gpsl_sport_inseason_refresh.sql
-- Do NOT re-run gpsl_sport_inseason_v_u_fix.sql (deprecated; reverts rich generator).
-- =============================================================================

CREATE OR REPLACE FUNCTION public.gpsl_sport_owner_byline(p_club_short text)
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_owner_id uuid;
  v_club_name text;
BEGIN
  SELECT c.owner_id, c."Club"
  INTO v_owner_id, v_club_name
  FROM public."Clubs" c
  WHERE c."ShortName" = p_club_short;

  IF NOT FOUND THEN
    RETURN 'the club owner';
  END IF;

  RETURN coalesce(
    nullif(btrim(public.owner_registry_resolve_tag(v_owner_id)), ''),
    nullif(btrim(public.competition_owner_display_name(v_owner_id)), ''),
    'the ' || coalesce(v_club_name, p_club_short) || ' owner'
  );
EXCEPTION
  WHEN OTHERS THEN
    RETURN 'the ' || coalesce(v_club_name, p_club_short, 'club') || ' owner';
END;
$function$;

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
  v_gpsl_month text := lower(btrim(p_gpsl_month));
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
  v_first_shock jsonb;
  v_club_news jsonb := '[]'::jsonb;
BEGIN
  IF p_season_id IS NULL OR v_gpsl_month IS NULL OR v_gpsl_month = '' THEN
    RETURN jsonb_build_object('error', 'invalid_args');
  END IF;

  v_month_label := public.gpsl_sport_month_label(v_gpsl_month);
  v_seed := p_season_id::text || ':' || v_gpsl_month || ':inseason';

  SELECT c.unlock_at, c.lock_at
  INTO v_month_start, v_month_end
  FROM public.competition_season_calendar c
  WHERE c.season_id = p_season_id AND lower(c.gpsl_month) = v_gpsl_month;

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
      AND lower(f.gpsl_month) = v_gpsl_month
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

  IF coalesce(jsonb_array_length(v_shocks), 0) > 0 THEN
    v_first_shock := jsonb_array_element(v_shocks, 0);
  END IF;

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
            'position', l.table_position,
            'form', l.form_last10,
            'pts_ahead', l.pts - coalesce((
              SELECT c2.pts
              FROM public.competition_standings_public c2
              WHERE c2.season_id = p_season_id
                AND c2.division = s.division
                AND c2.table_position = 2
            ), l.pts),
            'mp', l.mp,
            'gd', l.gd
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

  v_standings := coalesce(v_standings, '{}'::jsonb);

  -- Top 10 scorers per division (season-to-date through month; GPG tie-break)
  SELECT jsonb_object_agg(div_key, scorer_rows)
  INTO v_scorers
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
          'appearances', r.appearances,
          'goals_per_game', r.goals_per_game,
          'rank', r.place
        )
        ORDER BY r.place ASC
      ), '[]'::jsonb) AS scorer_rows
    FROM (
      SELECT
        g.*,
        row_number() OVER (
          PARTITION BY g.division
          ORDER BY g.goals DESC, g.goals_per_game DESC, g.assists DESC, g.player_name ASC
        ) AS place
      FROM (
        SELECT
          m.player_id,
          p."Name" AS player_name,
          m.club_short_name,
          c."Club" AS club_name,
          ccs.division,
          sum(m.goals)::int AS goals,
          sum(m.assists)::int AS assists,
          count(*) FILTER (WHERE coalesce(m.appeared, true))::int AS appearances,
          round(
            (sum(m.goals)::numeric
              / nullif(count(*) FILTER (WHERE coalesce(m.appeared, true)), 0)),
            3
          ) AS goals_per_game
        FROM public.competition_match_player_stats m
        JOIN public.competition_fixtures f ON f.id = m.fixture_id
        JOIN public.competition_club_seasons ccs
          ON ccs.season_id = f.season_id AND ccs.club_short_name = m.club_short_name
        JOIN public."Clubs" c ON c."ShortName" = m.club_short_name
        LEFT JOIN public."Players" p ON p."Konami_ID"::text = m.player_id::text
        WHERE f.season_id = p_season_id
          AND f.competition_type = 'league'
          AND f.status = 'played'
          AND f.gpsl_month IS NOT NULL
          AND public.competition_gpsl_month_sort(lower(f.gpsl_month))
            <= public.competition_gpsl_month_sort(v_gpsl_month)
        GROUP BY m.player_id, p."Name", m.club_short_name, c."Club", ccs.division
        HAVING sum(m.goals) > 0
      ) g
    ) r
    WHERE r.place <= 10
    GROUP BY r.division
  ) sc;

  v_scorers := coalesce(v_scorers, '{}'::jsonb);

  -- Team of the Month (Super League + Championship)
  SELECT coalesce(jsonb_agg(
    jsonb_build_object(
      'pitch_slot', m.pitch_slot,
      'slot_label', m.slot_label,
      'formation_id', m.formation_id,
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
    AND lower(m.gpsl_month) = v_gpsl_month
    AND m.period_kind = 'month'
    AND m.division_scope = 'superleague';

  SELECT coalesce(jsonb_agg(
    jsonb_build_object(
      'pitch_slot', m.pitch_slot,
      'slot_label', m.slot_label,
      'formation_id', m.formation_id,
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
    AND lower(m.gpsl_month) = v_gpsl_month
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
      AND lower(f.gpsl_month) = v_gpsl_month
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
  IF v_first_shock IS NOT NULL THEN
    v_vars := jsonb_build_object(
      'winner', v_first_shock->>'winner_name',
      'loser', v_first_shock->>'loser_name',
      'winner_owner', v_first_shock->>'winner_owner',
      'loser_owner', v_first_shock->>'loser_owner',
      'score', v_first_shock->>'score',
      'division', v_first_shock->>'division',
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
      v_first_shock->>'division', v_month_label);
    v_lead := format(
      E'It was the result that set the inbox alight. %s''s %s beat %s''s %s %s in %s — and GPSL Sport has plenty more from a hectic %s across the league.\n\nInside: Team of the Month, division leaders, monthly golden boot charts, and our Match of the Month report.',
      v_first_shock->>'winner_owner',
      v_first_shock->>'winner_name',
      v_first_shock->>'loser_owner',
      v_first_shock->>'loser_name',
      v_first_shock->>'score',
      v_first_shock->>'division',
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

  IF to_regprocedure('public.gpsl_sport_fetch_club_news(bigint,text)') IS NOT NULL THEN
    v_club_news := public.gpsl_sport_fetch_club_news(p_season_id, v_gpsl_month);
  END IF;

  v_front := jsonb_build_object(
    'masthead', 'GPSL Sport',
    'edition_label', v_month_label,
    'gpsl_month', v_gpsl_month,
    'headline', v_headline,
    'subhead', v_subhead,
    'lead_paragraph', v_lead,
    'stories', v_stories,
    'story_type', v_story_type,
    'shock_results', v_shocks,
    'standings_snapshot', v_standings,
    'club_news', coalesce(v_club_news, '[]'::jsonb),
    'hero', CASE
      WHEN v_first_shock IS NOT NULL THEN jsonb_build_object(
        'kind', 'stadium',
        'club_short', v_first_shock->>'winner_club',
        'caption', format('%s — %s', v_first_shock->>'winner_name', v_first_shock->>'score')
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
  v_month_label text;
  v_month text;
  v_id bigint;
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

CREATE OR REPLACE FUNCTION public.gpsl_sport_refresh_inseason_edition(
  p_season_id bigint,
  p_gpsl_month text
)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_month text := lower(btrim(p_gpsl_month));
  v_edition_id bigint;
BEGIN
  SELECT e.id INTO v_edition_id
  FROM public.gpsl_sport_editions e
  WHERE e.season_id = p_season_id
    AND lower(e.gpsl_month) = v_month
  ORDER BY e.published_at DESC NULLS LAST, e.id DESC
  LIMIT 1;

  IF v_edition_id IS NULL THEN
    RETURN NULL;
  END IF;

  RETURN public.gpsl_sport_refresh_inseason_edition_by_id(v_edition_id);
END;
$function$;

CREATE OR REPLACE FUNCTION public.gpsl_sport_regenerate_edition(
  p_season_id bigint,
  p_gpsl_month text
)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_month text := lower(btrim(p_gpsl_month));
  v_role text := coalesce(auth.jwt() ->> 'role', '');
BEGIN
  IF auth.uid() IS NULL
     AND current_user NOT IN ('postgres', 'service_role')
     AND v_role <> 'service_role' THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  IF public.is_gpsl_admin() IS NOT TRUE
     AND current_user NOT IN ('postgres', 'service_role')
     AND v_role <> 'service_role' THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  DELETE FROM public.gpsl_sport_reads r
  WHERE r.edition_id IN (
    SELECT e.id FROM public.gpsl_sport_editions e
    WHERE e.season_id = p_season_id AND lower(e.gpsl_month) = v_month
  );

  DELETE FROM public.gpsl_sport_editions e
  WHERE e.season_id = p_season_id AND lower(e.gpsl_month) = v_month;

  RETURN public.gpsl_sport_generate_edition(p_season_id, v_month);
END;
$function$;

CREATE OR REPLACE FUNCTION public.competition_admin_regenerate_gpsl_sport(
  p_gpsl_month text DEFAULT NULL,
  p_season_id bigint DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season_id bigint;
  v_month text;
  v_edition_id bigint;
  v_role text := coalesce(auth.jwt() ->> 'role', '');
BEGIN
  IF public.is_gpsl_admin() IS NOT TRUE
     AND current_user NOT IN ('postgres', 'service_role')
     AND v_role <> 'service_role' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'admin_only');
  END IF;

  SELECT coalesce(
    p_season_id,
    (SELECT s.id FROM public.competition_seasons s WHERE s.is_current IS TRUE ORDER BY s.id DESC LIMIT 1)
  ) INTO v_season_id;

  IF v_season_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_season');
  END IF;

  v_month := lower(nullif(btrim(p_gpsl_month), ''));
  IF v_month IS NULL THEN
    SELECT c.gpsl_month INTO v_month
    FROM public.competition_season_calendar c
    WHERE c.season_id = v_season_id
      AND c.lock_at IS NOT NULL
      AND c.lock_at <= now()
    ORDER BY public.competition_gpsl_month_sort(c.gpsl_month) DESC
    LIMIT 1;
  END IF;

  IF v_month IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_month');
  END IF;

  IF to_regprocedure('public.gpsl_sport_refresh_inseason_edition(bigint, text)') IS NOT NULL
     AND v_month NOT IN ('may', 'june', 'july') THEN
    v_edition_id := public.gpsl_sport_refresh_inseason_edition(v_season_id, v_month);
  ELSE
    v_edition_id := public.gpsl_sport_regenerate_edition(v_season_id, v_month);
  END IF;

  RETURN jsonb_build_object(
    'ok', v_edition_id IS NOT NULL,
    'edition_id', v_edition_id,
    'season_id', v_season_id,
    'gpsl_month', v_month,
    'edition_label', public.gpsl_sport_month_label(v_month)
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
  v_month text := lower(btrim(p_gpsl_month));
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
    RETURN v_existing;
  END IF;

  v_month_label := public.gpsl_sport_month_label(v_month);
  v_built := public.gpsl_sport_build_inseason_month_content(p_season_id, v_month);

  IF v_built ? 'error' THEN
    RAISE EXCEPTION 'gpsl_sport_build_inseason_month_content failed: %', v_built->>'error';
  END IF;

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
      'detail', v_edition.detail
    )
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.competition_admin_gpsl_sport_diagnose(
  p_gpsl_month text DEFAULT 'august',
  p_season_id bigint DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season_id bigint;
  v_month text := lower(btrim(p_gpsl_month));
  v_edition public.gpsl_sport_editions;
  v_build_error text;
  v_sample jsonb;
  v_role text := coalesce(auth.jwt() ->> 'role', '');
BEGIN
  IF public.is_gpsl_admin() IS NOT TRUE
     AND current_user NOT IN ('postgres', 'service_role')
     AND v_role <> 'service_role' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'admin_only');
  END IF;

  SELECT coalesce(
    p_season_id,
    (SELECT s.id FROM public.competition_seasons s WHERE s.is_current IS TRUE ORDER BY s.id DESC LIMIT 1)
  ) INTO v_season_id;

  SELECT * INTO v_edition
  FROM public.gpsl_sport_editions e
  WHERE e.season_id = v_season_id AND lower(e.gpsl_month) = v_month
  ORDER BY e.id DESC
  LIMIT 1;

  IF to_regprocedure('public.gpsl_sport_build_inseason_month_content(bigint, text)') IS NOT NULL THEN
    BEGIN
      v_sample := public.gpsl_sport_build_inseason_month_content(v_season_id, v_month);
    EXCEPTION
      WHEN OTHERS THEN
        v_build_error := SQLERRM;
    END;
  ELSE
    v_build_error := 'gpsl_sport_build_inseason_month_content not installed';
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'season_id', v_season_id,
    'gpsl_month', v_month,
    'edition_id', v_edition.id,
    'inseason_rich', coalesce((v_edition.detail->>'inseason_rich')::boolean, false),
    'story_type', v_edition.story_type,
    'headline', v_edition.front_page->>'headline',
    'has_stats_page', (v_edition.detail->'stats_page') IS NOT NULL
      AND coalesce((v_edition.detail->'stats_page'->>'enabled')::boolean, false),
    'build_ok', v_build_error IS NULL,
    'build_error', v_build_error,
    'sample_story_type', v_sample->>'story_type',
    'sample_headline', v_sample->'front_page'->>'headline'
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_admin_gpsl_sport_diagnose(text, bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.gpsl_sport_owner_byline(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.gpsl_sport_build_inseason_month_content(bigint, text) TO service_role;
GRANT EXECUTE ON FUNCTION public.gpsl_sport_refresh_inseason_edition_by_id(bigint) TO service_role;
GRANT EXECUTE ON FUNCTION public.gpsl_sport_refresh_inseason_edition(bigint, text) TO service_role;
GRANT EXECUTE ON FUNCTION public.gpsl_sport_regenerate_edition(bigint, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.competition_admin_regenerate_gpsl_sport(text, bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.gpsl_sport_generate_inseason_edition(bigint, text) TO service_role;
GRANT EXECUTE ON FUNCTION public.gpsl_sport_get_edition(bigint) TO authenticated;

NOTIFY pgrst, 'reload schema';
