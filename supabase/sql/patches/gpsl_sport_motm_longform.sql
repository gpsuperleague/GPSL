-- =============================================================================
-- GPSL Sport — Match of the Month (long-form report)
-- Renames/enhances the match tab narrative. Safe re-run.
-- After apply: rebuild the month via admin calendar → Rebuild GPSL Sport edition.
-- =============================================================================

-- Golden boot: season-to-date through edition month — exactly top 10
-- Tie-break on equal goals: average goals per appearance
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
  v_month_sort smallint;
  v_out jsonb;
BEGIN
  IF p_season_id IS NULL OR v_month = '' THEN
    RETURN '{}'::jsonb;
  END IF;

  v_month_sort := public.competition_gpsl_month_sort(v_month);
  IF v_month_sort IS NULL THEN
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
          AND public.competition_gpsl_month_sort(lower(f.gpsl_month)) <= v_month_sort
        GROUP BY m.player_id, p."Name", m.club_short_name, c."Club", ccs.division
        HAVING sum(m.goals) > 0
      ) g
    ) r
    WHERE r.place <= 10
    GROUP BY r.division
  ) sc;

  RETURN coalesce(v_out, '{}'::jsonb);
END;
$function$;

CREATE OR REPLACE FUNCTION public.gpsl_sport_build_motm_report(
  p_season_id bigint,
  p_gpsl_month text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_month text := lower(btrim(coalesce(p_gpsl_month, '')));
  v_month_label text;
  v_fx record;
  v_home_st record;
  v_away_st record;
  v_home_prestige int;
  v_away_prestige int;
  v_home_fav boolean;
  v_upset boolean;
  v_home_cs boolean;
  v_away_cs boolean;
  v_scorers_home text;
  v_scorers_away text;
  v_assists_home text;
  v_assists_away text;
  v_feat_home record;
  v_feat_away record;
  v_home_owner_hist text;
  v_away_owner_hist text;
  v_home_owner text;
  v_away_owner text;
  v_home_name text;
  v_away_name text;
  v_div_label text;
  v_total_goals int;
  v_crowd text;
  v_preamble text;
  v_preview text;
  v_players text;
  v_action text;
  v_stakes text;
  v_table_bit text;
  v_body text;
  v_pull text;
  v_seed int;
  v_home_form text;
  v_away_form text;
  v_home_expect int;
  v_away_expect int;
  v_home_pressure boolean;
  v_away_pressure boolean;
  v_home_rank_note text;
  v_away_rank_note text;
BEGIN
  IF p_season_id IS NULL OR v_month = '' THEN
    RETURN jsonb_build_object('enabled', false);
  END IF;

  v_month_label := public.gpsl_sport_month_label(v_month);

  -- Entertaining MotM: highest total goals among played fixtures this month
  SELECT
    f.id,
    f.home_club_short_name,
    f.away_club_short_name,
    f.home_goals,
    f.away_goals,
    f.division,
    f.competition_type,
    f.cup_code
  INTO v_fx
  FROM public.competition_fixtures f
  WHERE f.season_id = p_season_id
    AND lower(f.gpsl_month) = v_month
    AND f.status = 'played'
    AND f.home_goals IS NOT NULL
    AND f.away_goals IS NOT NULL
  ORDER BY (coalesce(f.home_goals, 0) + coalesce(f.away_goals, 0)) DESC,
           abs(coalesce(f.home_goals, 0) - coalesce(f.away_goals, 0)) ASC,
           f.id
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('enabled', false, 'page_title', 'Match of the Month');
  END IF;

  v_home_name := public.gpsl_sport_club_display_name(v_fx.home_club_short_name);
  v_away_name := public.gpsl_sport_club_display_name(v_fx.away_club_short_name);
  v_home_owner := public.gpsl_sport_owner_byline(v_fx.home_club_short_name);
  v_away_owner := public.gpsl_sport_owner_byline(v_fx.away_club_short_name);
  v_div_label := public.gpsl_sport_fixture_division_label(
    v_fx.division, v_fx.cup_code, v_fx.competition_type
  );
  v_total_goals := coalesce(v_fx.home_goals, 0) + coalesce(v_fx.away_goals, 0);
  v_home_cs := coalesce(v_fx.away_goals, 0) = 0;
  v_away_cs := coalesce(v_fx.home_goals, 0) = 0;
  v_seed := abs(hashtext(v_fx.id::text || ':' || v_month));

  -- Live table rows
  SELECT * INTO v_home_st
  FROM public.competition_standings_public s
  WHERE s.season_id = p_season_id
    AND s.club_short_name = v_fx.home_club_short_name
  LIMIT 1;

  SELECT * INTO v_away_st
  FROM public.competition_standings_public s
  WHERE s.season_id = p_season_id
    AND s.club_short_name = v_fx.away_club_short_name
  LIMIT 1;

  SELECT p.prestige_rank INTO v_home_prestige
  FROM public.competition_club_prestige_public p
  WHERE p.club_short_name = v_fx.home_club_short_name
  LIMIT 1;

  SELECT p.prestige_rank INTO v_away_prestige
  FROM public.competition_club_prestige_public p
  WHERE p.club_short_name = v_fx.away_club_short_name
  LIMIT 1;

  v_home_fav := coalesce(v_home_prestige, 99) <= coalesce(v_away_prestige, 99);
  -- Upset if lower-prestige side won (or drew while away underdog)
  IF coalesce(v_fx.home_goals, 0) > coalesce(v_fx.away_goals, 0) THEN
    v_upset := NOT v_home_fav;
  ELSIF coalesce(v_fx.away_goals, 0) > coalesce(v_fx.home_goals, 0) THEN
    v_upset := v_home_fav;
  ELSE
    v_upset := abs(coalesce(v_home_prestige, 50) - coalesce(v_away_prestige, 50)) >= 8;
  END IF;

  v_home_form := nullif(btrim(coalesce(v_home_st.form_last10, '')), '');
  v_away_form := nullif(btrim(coalesce(v_away_st.form_last10, '')), '');

  IF to_regprocedure('public.competition_club_baseline_expected_position(smallint, smallint)') IS NOT NULL THEN
    v_home_expect := public.competition_club_baseline_expected_position(
      coalesce(v_home_prestige, 20)::smallint,
      20::smallint
    );
    v_away_expect := public.competition_club_baseline_expected_position(
      coalesce(v_away_prestige, 20)::smallint,
      20::smallint
    );
  END IF;

  v_home_pressure := v_home_st.table_position IS NOT NULL
    AND v_home_expect IS NOT NULL
    AND v_home_st.table_position > v_home_expect + 3;
  v_away_pressure := v_away_st.table_position IS NOT NULL
    AND v_away_expect IS NOT NULL
    AND v_away_st.table_position > v_away_expect + 3;

  -- Goal scorers (with multi-goal counts)
  SELECT coalesce(string_agg(
    p."Name" || CASE WHEN m.goals > 1 THEN ' (' || m.goals::text || ')' ELSE '' END,
    ', ' ORDER BY m.goals DESC, p."Name"
  ), NULL)
  INTO v_scorers_home
  FROM public.competition_match_player_stats m
  JOIN public."Players" p ON p."Konami_ID"::text = m.player_id::text
  WHERE m.fixture_id = v_fx.id
    AND m.club_short_name = v_fx.home_club_short_name
    AND m.goals > 0;

  SELECT coalesce(string_agg(
    p."Name" || CASE WHEN m.goals > 1 THEN ' (' || m.goals::text || ')' ELSE '' END,
    ', ' ORDER BY m.goals DESC, p."Name"
  ), NULL)
  INTO v_scorers_away
  FROM public.competition_match_player_stats m
  JOIN public."Players" p ON p."Konami_ID"::text = m.player_id::text
  WHERE m.fixture_id = v_fx.id
    AND m.club_short_name = v_fx.away_club_short_name
    AND m.goals > 0;

  -- Assists
  SELECT coalesce(string_agg(
    p."Name" || CASE WHEN m.assists > 1 THEN ' (' || m.assists::text || ')' ELSE '' END,
    ', ' ORDER BY m.assists DESC, p."Name"
  ), NULL)
  INTO v_assists_home
  FROM public.competition_match_player_stats m
  JOIN public."Players" p ON p."Konami_ID"::text = m.player_id::text
  WHERE m.fixture_id = v_fx.id
    AND m.club_short_name = v_fx.home_club_short_name
    AND m.assists > 0;

  SELECT coalesce(string_agg(
    p."Name" || CASE WHEN m.assists > 1 THEN ' (' || m.assists::text || ')' ELSE '' END,
    ', ' ORDER BY m.assists DESC, p."Name"
  ), NULL)
  INTO v_assists_away
  FROM public.competition_match_player_stats m
  JOIN public."Players" p ON p."Konami_ID"::text = m.player_id::text
  WHERE m.fixture_id = v_fx.id
    AND m.club_short_name = v_fx.away_club_short_name
    AND m.assists > 0;

  -- Featured player each side (season league goals so far, then rating)
  SELECT
    p."Name" AS player_name,
    m.player_id,
    sum(m.goals)::int AS season_goals,
    sum(m.assists)::int AS season_assists,
    round(avg(m.rating)::numeric, 1) AS avg_rating,
    max(CASE WHEN m.fixture_id = v_fx.id THEN m.goals ELSE 0 END)::int AS match_goals,
    max(CASE WHEN m.fixture_id = v_fx.id THEN m.assists ELSE 0 END)::int AS match_assists,
    max(CASE WHEN m.fixture_id = v_fx.id THEN m.rating ELSE NULL END) AS match_rating
  INTO v_feat_home
  FROM public.competition_match_player_stats m
  JOIN public.competition_fixtures f ON f.id = m.fixture_id
  JOIN public."Players" p ON p."Konami_ID"::text = m.player_id::text
  WHERE f.season_id = p_season_id
    AND m.club_short_name = v_fx.home_club_short_name
    AND f.competition_type = 'league'
    AND f.status = 'played'
  GROUP BY p."Name", m.player_id
  ORDER BY sum(m.goals) DESC, avg(m.rating) DESC NULLS LAST, p."Name"
  LIMIT 1;

  SELECT
    p."Name" AS player_name,
    m.player_id,
    sum(m.goals)::int AS season_goals,
    sum(m.assists)::int AS season_assists,
    round(avg(m.rating)::numeric, 1) AS avg_rating,
    max(CASE WHEN m.fixture_id = v_fx.id THEN m.goals ELSE 0 END)::int AS match_goals,
    max(CASE WHEN m.fixture_id = v_fx.id THEN m.assists ELSE 0 END)::int AS match_assists,
    max(CASE WHEN m.fixture_id = v_fx.id THEN m.rating ELSE NULL END) AS match_rating
  INTO v_feat_away
  FROM public.competition_match_player_stats m
  JOIN public.competition_fixtures f ON f.id = m.fixture_id
  JOIN public."Players" p ON p."Konami_ID"::text = m.player_id::text
  WHERE f.season_id = p_season_id
    AND m.club_short_name = v_fx.away_club_short_name
    AND f.competition_type = 'league'
    AND f.status = 'played'
  GROUP BY p."Name", m.player_id
  ORDER BY sum(m.goals) DESC, avg(m.rating) DESC NULLS LAST, p."Name"
  LIMIT 1;

  -- Owner backstory snippets from rolling rank if present
  SELECT CASE
    WHEN r.rank_position IS NULL THEN format('%s has been navigating the GPSL inbox with %s this season', v_home_owner, v_home_name)
    WHEN r.rank_position <= 10 THEN format('%s sits among the stronger recent GPSL owner ranks (around #%s on the rolling board) and expects %s to compete', v_home_owner, r.rank_position, v_home_name)
    WHEN r.rank_position <= 30 THEN format('%s is a mid-table presence on the rolling owner board (#%s) — steady rather than splashy, and %s reflects that brief', v_home_owner, r.rank_position, v_home_name)
    ELSE format('%s is still writing their GPSL chapter with %s, sitting further down the rolling owner ranks (#%s) and hunting a statement result', v_home_owner, v_home_name, r.rank_position)
  END
  INTO v_home_owner_hist
  FROM public.competition_owner_ranking_rolling4_public r
  WHERE r.club_short_name = v_fx.home_club_short_name
  LIMIT 1;

  IF v_home_owner_hist IS NULL THEN
    v_home_owner_hist := format('%s continues the %s project in GPSL, one inbox notification at a time', v_home_owner, v_home_name);
  END IF;

  SELECT CASE
    WHEN r.rank_position IS NULL THEN format('%s has been shaping %s through the GPSL calendar', v_away_owner, v_away_name)
    WHEN r.rank_position <= 10 THEN format('%s brings heavyweight owner pedigree (rolling rank ~#%s) to %s', v_away_owner, r.rank_position, v_away_name)
    WHEN r.rank_position <= 30 THEN format('%s is a familiar name on the rolling owner board (#%s), building %s week by week', v_away_owner, r.rank_position, v_away_name)
    ELSE format('%s is grinding upward with %s from further down the rolling owner list (#%s)', v_away_owner, v_away_name, r.rank_position)
  END
  INTO v_away_owner_hist
  FROM public.competition_owner_ranking_rolling4_public r
  WHERE r.club_short_name = v_fx.away_club_short_name
  LIMIT 1;

  IF v_away_owner_hist IS NULL THEN
    v_away_owner_hist := format('%s keeps %s moving through GPSL''s long season', v_away_owner, v_away_name);
  END IF;

  v_home_rank_note := CASE
    WHEN v_home_st.table_position IS NULL THEN 'yet to settle in the table'
    ELSE format('%s on %s points (GD %s)',
      CASE
        WHEN v_home_st.table_position % 100 BETWEEN 11 AND 13 THEN v_home_st.table_position::text || 'th'
        WHEN v_home_st.table_position % 10 = 1 THEN v_home_st.table_position::text || 'st'
        WHEN v_home_st.table_position % 10 = 2 THEN v_home_st.table_position::text || 'nd'
        WHEN v_home_st.table_position % 10 = 3 THEN v_home_st.table_position::text || 'rd'
        ELSE v_home_st.table_position::text || 'th'
      END,
      v_home_st.pts,
      CASE
        WHEN coalesce(v_home_st.gd, 0) > 0 THEN '+' || coalesce(v_home_st.gd, 0)::text
        ELSE coalesce(v_home_st.gd, 0)::text
      END)
  END;
  v_away_rank_note := CASE
    WHEN v_away_st.table_position IS NULL THEN 'still finding their level'
    ELSE format('%s on %s points (GD %s)',
      CASE
        WHEN v_away_st.table_position % 100 BETWEEN 11 AND 13 THEN v_away_st.table_position::text || 'th'
        WHEN v_away_st.table_position % 10 = 1 THEN v_away_st.table_position::text || 'st'
        WHEN v_away_st.table_position % 10 = 2 THEN v_away_st.table_position::text || 'nd'
        WHEN v_away_st.table_position % 10 = 3 THEN v_away_st.table_position::text || 'rd'
        ELSE v_away_st.table_position::text || 'th'
      END,
      v_away_st.pts,
      CASE
        WHEN coalesce(v_away_st.gd, 0) > 0 THEN '+' || coalesce(v_away_st.gd, 0)::text
        ELSE coalesce(v_away_st.gd, 0)::text
      END)
  END;

  -- Crowd colour
  IF coalesce(v_fx.home_goals, 0) > coalesce(v_fx.away_goals, 0) THEN
    IF v_upset THEN
      v_crowd := format(
        'The home end found its voice early and never really stopped — when the underdogs sniff blood, GPSL stadiums get loud. %s supporters poured belief into every duel, and by full time the noise felt like an extra player.',
        v_home_name
      );
    ELSIF v_home_pressure THEN
      v_crowd := format(
        'Relief rolled around the stands in waves. %s fans had been restless with the league position, but a home win buys breathing space — and tonight the applause at the whistle sounded more grateful than triumphant.',
        v_home_name
      );
    ELSE
      v_crowd := format(
        'A contented home crowd filed out into the virtual night. Nothing flashy, just the familiar satisfaction of three points secured in front of their own.',
        v_home_name
      );
    END IF;
  ELSIF coalesce(v_fx.away_goals, 0) > coalesce(v_fx.home_goals, 0) THEN
    IF v_home_st.table_position IS NOT NULL AND v_home_st.table_position >= 12 THEN
      v_crowd := format(
        'It was a quiet house for long stretches. When your league form is already heavy, a home defeat lands harder — %s fans drifted toward the exits early, the songs dying long before the referee did.',
        v_home_name
      );
    ELSIF v_upset THEN
      v_crowd := format(
        'Shock hung in the air. Favourites on paper, %s were second-best on the night, and the home support turned from expectant to anxious to flat. The away end, meanwhile, bounced through the final minutes.',
        v_home_name
      );
    ELSE
      v_crowd := format(
        'The travelling %s support made themselves heard; the home sections grew restless as the scoreboard refused to budge their way. By full time the stadium felt drained.',
        v_away_name
      );
    END IF;
  ELSE
    v_crowd := format(
      'A shared point left both sets of fans arguing on the way out — some saw a missed chance, others a hard-earned draw. The atmosphere never quite caught fire, but it never went cold either.',
      v_home_name
    );
  END IF;

  -- Build long-form body
  v_preamble := format(
    E'MATCH OF THE MONTH — %s\n\n' ||
    E'%s (%s) welcomed %s (%s) in the %s during %s, a fixture GPSL Sport selects for the entertainment, the stakes, and the storylines that followed the whistle.\n\n' ||
    E'Full-time: %s %s–%s %s.',
    v_month_label,
    v_home_name, v_home_owner,
    v_away_name, v_away_owner,
    v_div_label, v_month_label,
    v_home_name, v_fx.home_goals, v_fx.away_goals, v_away_name
  );

  v_preview := format(
    E'\n\nTHE BUILD-UP\n\n' ||
    E'On paper the favourites were %s (prestige rank %s) against %s (prestige rank %s). %s\n\n' ||
    E'In the league table going into this chapter of the season, %s sit %s, while %s are %s.%s%s',
    CASE WHEN v_home_fav THEN v_home_name ELSE v_away_name END,
    coalesce(v_home_prestige::text, '?'),
    CASE WHEN v_home_fav THEN v_away_name ELSE v_home_name END,
    coalesce(v_away_prestige::text, '?'),
    CASE
      WHEN v_home_fav AND coalesce(v_fx.home_goals,0) >= coalesce(v_fx.away_goals,0)
        THEN format('Most expected %s to control the match — and the script largely obeyed.', v_home_name)
      WHEN v_home_fav AND coalesce(v_fx.away_goals,0) > coalesce(v_fx.home_goals,0)
        THEN format('Most tipped %s; instead the visitors rewrote the evening.', v_home_name)
      WHEN NOT v_home_fav AND coalesce(v_fx.away_goals,0) >= coalesce(v_fx.home_goals,0)
        THEN format('The money would have been on %s, and they left with something to show for it.', v_away_name)
      ELSE format('The money would have been on %s — but %s had other ideas.', v_away_name, v_home_name)
    END,
    v_home_name, v_home_rank_note,
    v_away_name, v_away_rank_note,
    CASE WHEN v_home_form IS NOT NULL THEN format(E'\n\nRecent home form string: %s.', v_home_form) ELSE '' END,
    CASE WHEN v_away_form IS NOT NULL THEN format(E' Away form string: %s.', v_away_form) ELSE '' END
  );

  v_players := format(
    E'\n\nOWNERS & KEY MEN\n\n' ||
    E'%s.\n\n%s.\n\n',
    v_home_owner_hist,
    v_away_owner_hist
  );

  IF v_feat_home.player_name IS NOT NULL THEN
    v_players := v_players || format(
      E'For %s, eyes were on %s — %s league goals and %s assists this season (avg rating %s). Pre-match, the brief was simple: occupy the opposition, take the big chances, and set the tone. On the night: %s.',
      v_home_name,
      v_feat_home.player_name,
      coalesce(v_feat_home.season_goals, 0),
      coalesce(v_feat_home.season_assists, 0),
      coalesce(v_feat_home.avg_rating::text, '—'),
      CASE
        WHEN coalesce(v_feat_home.match_goals, 0) > 0 OR coalesce(v_feat_home.match_assists, 0) > 0
          THEN format(
            '%s goal%s, %s assist%s%s',
            coalesce(v_feat_home.match_goals, 0),
            CASE WHEN coalesce(v_feat_home.match_goals, 0) = 1 THEN '' ELSE 's' END,
            coalesce(v_feat_home.match_assists, 0),
            CASE WHEN coalesce(v_feat_home.match_assists, 0) = 1 THEN '' ELSE 's' END,
            CASE WHEN v_feat_home.match_rating IS NOT NULL THEN format(', match rating %s', v_feat_home.match_rating) ELSE '' END
          )
        WHEN v_feat_home.match_rating IS NOT NULL
          THEN format('no goal contribution, but a %s rating that kept them honest', v_feat_home.match_rating)
        ELSE 'a quieter shift than the season numbers promised — one of those nights where the spotlight moved on'
      END
    );
  END IF;

  IF v_feat_away.player_name IS NOT NULL THEN
    v_players := v_players || format(
      E'\n\nAcross the halfway line, %s carried the burden of expectation for %s — %s goals and %s assists in the league so far (avg %s). The scouting note said they would stretch the home back line. Match return: %s.',
      v_feat_away.player_name,
      v_away_name,
      coalesce(v_feat_away.season_goals, 0),
      coalesce(v_feat_away.season_assists, 0),
      coalesce(v_feat_away.avg_rating::text, '—'),
      CASE
        WHEN coalesce(v_feat_away.match_goals, 0) > 0 OR coalesce(v_feat_away.match_assists, 0) > 0
          THEN format(
            '%s goal%s and %s assist%s%s — exactly the kind of night that keeps a dressing room happy',
            coalesce(v_feat_away.match_goals, 0),
            CASE WHEN coalesce(v_feat_away.match_goals, 0) = 1 THEN '' ELSE 's' END,
            coalesce(v_feat_away.match_assists, 0),
            CASE WHEN coalesce(v_feat_away.match_assists, 0) = 1 THEN '' ELSE 's' END,
            CASE WHEN v_feat_away.match_rating IS NOT NULL THEN format(' (rating %s)', v_feat_away.match_rating) ELSE '' END
          )
        WHEN v_feat_away.match_rating IS NOT NULL
          THEN format('blunted in open play (rating %s), the sort of shift that fuels dressing-room debates on Discord later', v_feat_away.match_rating)
        ELSE 'not the headline act this time'
      END
    );
  END IF;

  v_action := E'\n\nHOW THE GOALS ARRIVED\n\n';
  IF v_total_goals = 0 THEN
    v_action := v_action ||
      'A rare MotM stalemate without a goal — two goalkeepers earning their keep, two midfields cancelling each other out, and a clean sheet at both ends. Nights like this decide little on the scoreboard and everything about mentality.';
  ELSE
    v_action := v_action || format(
      'This was a %s-goal affair. ',
      v_total_goals
    );
    IF v_scorers_home IS NOT NULL THEN
      v_action := v_action || format('For %s the scorers were %s. ', v_home_name, v_scorers_home);
    ELSIF coalesce(v_fx.home_goals, 0) > 0 THEN
      v_action := v_action || format('%s found the net, though the scorer card in the stats feed was incomplete. ', v_home_name);
    END IF;
    IF v_assists_home IS NOT NULL THEN
      v_action := v_action || format('Home assists: %s. ', v_assists_home);
    END IF;
    IF v_scorers_away IS NOT NULL THEN
      v_action := v_action || format('For %s the scorers were %s. ', v_away_name, v_scorers_away);
    ELSIF coalesce(v_fx.away_goals, 0) > 0 THEN
      v_action := v_action || format('%s replied on the scoresheet. ', v_away_name);
    END IF;
    IF v_assists_away IS NOT NULL THEN
      v_action := v_action || format('Away assists: %s. ', v_assists_away);
    END IF;
    IF v_home_cs THEN
      v_action := v_action || format('%s kept a clean sheet — the sort of defensive night that calms owners and irritates opposing forwards in equal measure. ', v_home_name);
    END IF;
    IF v_away_cs THEN
      v_action := v_action || format('%s also shut up shop at the back. ', v_away_name);
    END IF;
  END IF;

  v_action := v_action || E'\n\n' || v_crowd;

  v_stakes := E'\n\nWHAT IT MEANS\n\n';
  IF coalesce(v_fx.home_goals, 0) > coalesce(v_fx.away_goals, 0) THEN
    v_stakes := v_stakes || format(
      '%s take the points and the narrative. In a GPSL month that never stops, three points at home are oxygen — especially with the Friday lock always looming on the calendar.',
      v_home_name
    );
  ELSIF coalesce(v_fx.away_goals, 0) > coalesce(v_fx.home_goals, 0) THEN
    v_stakes := v_stakes || format(
      'The spoils travel with %s. Away wins rewrite weeks: suddenly the table looks kinder, the inbox feels lighter, and the next opponent studies the tape a little more carefully.',
      v_away_name
    );
  ELSE
    v_stakes := v_stakes ||
      'A draw keeps both seasons moving without a dramatic swing — useful for the side under the cosh, frustrating for the one that sensed a gap.';
  END IF;

  IF v_home_pressure THEN
    v_stakes := v_stakes || format(
      E'\n\nThere is pressure around the %s dugout. Expected to sit nearer %s and currently %s, the manager''s seat is warmer than the standings suggest. Nights like this %s.',
      v_home_name,
      CASE
        WHEN v_home_expect % 100 BETWEEN 11 AND 13 THEN v_home_expect::text || 'th'
        WHEN v_home_expect % 10 = 1 THEN v_home_expect::text || 'st'
        WHEN v_home_expect % 10 = 2 THEN v_home_expect::text || 'nd'
        WHEN v_home_expect % 10 = 3 THEN v_home_expect::text || 'rd'
        ELSE v_home_expect::text || 'th'
      END,
      v_home_rank_note,
      CASE
        WHEN coalesce(v_fx.home_goals,0) > coalesce(v_fx.away_goals,0)
          THEN 'buy a little time — happy enough players, quieter boardroom talk for a week'
        WHEN coalesce(v_fx.home_goals,0) < coalesce(v_fx.away_goals,0)
          THEN 'only turn up the heat — expect restless senior players and sharper questions in the Discord'
        ELSE 'solve nothing, which is almost worse'
      END
    );
  END IF;

  IF v_away_pressure THEN
    v_stakes := v_stakes || format(
      E'\n\n%s are living with similar scrutiny. Prestige says they should be higher; the table says otherwise. After this result the dressing room is %s.',
      v_away_name,
      CASE
        WHEN coalesce(v_fx.away_goals,0) > coalesce(v_fx.home_goals,0)
          THEN 'buoyant — the kind of away performance that makes veterans clap each other into the tunnel'
        WHEN coalesce(v_fx.away_goals,0) < coalesce(v_fx.home_goals,0)
          THEN 'bruised — another night that feeds the rumour mill about who wants out and who still believes'
        ELSE 'unsettled, arguing about whether a point on the road was progress or paralysis'
      END
    );
  END IF;

  IF NOT v_home_pressure AND NOT v_away_pressure THEN
    v_stakes := v_stakes || E'\n\nNeither manager looks in immediate crisis, but GPSL seasons are long — keep winning and the squad stays smiling; drift and the transfer market starts listening.';
  END IF;

  v_table_bit := format(
    E'\n\nTABLE SNAPSHOT\n\n' ||
    E'%s — %s\n%s — %s\n\n' ||
    E'Those two lines will keep shifting every time a result is confirmed. For now, this Match of the Month is etched into the %s edition of GPSL Sport.',
    v_home_name, v_home_rank_note,
    v_away_name, v_away_rank_note,
    v_month_label
  );

  v_body := v_preamble || v_preview || v_players || v_action || v_stakes || v_table_bit;

  v_pull := CASE (v_seed % 4)
    WHEN 0 THEN format('"%s vs %s felt like a proper GPSL occasion — noise, nerves, and a result that will linger."', v_home_name, v_away_name)
    WHEN 1 THEN format('"You could feel what it meant in the stands. %s will remember this one."',
      CASE WHEN coalesce(v_fx.home_goals,0) >= coalesce(v_fx.away_goals,0) THEN v_home_name ELSE v_away_name END)
    WHEN 2 THEN '"Match of the Month is not always the biggest clubs — it is the biggest story."'
    ELSE format('"From the first whistle the %s looked like a fixture with consequences."', v_div_label)
  END;

  RETURN jsonb_build_object(
    'enabled', true,
    'page_title', 'Match of the Month',
    'fixture', jsonb_build_object(
      'fixture_id', v_fx.id,
      'home_club', v_fx.home_club_short_name,
      'away_club', v_fx.away_club_short_name,
      'home_name', v_home_name,
      'away_name', v_away_name,
      'home_owner', v_home_owner,
      'away_owner', v_away_owner,
      'home_goals', v_fx.home_goals,
      'away_goals', v_fx.away_goals,
      'division', v_div_label,
      'scorers_home', coalesce(v_scorers_home, '—'),
      'scorers_away', coalesce(v_scorers_away, '—'),
      'assists_home', v_assists_home,
      'assists_away', v_assists_away,
      'clean_sheet_home', v_home_cs,
      'clean_sheet_away', v_away_cs,
      'home_table', CASE WHEN v_home_st.table_position IS NULL THEN NULL ELSE jsonb_build_object(
        'position', v_home_st.table_position,
        'pts', v_home_st.pts,
        'gd', v_home_st.gd,
        'mp', v_home_st.mp,
        'form', v_home_st.form_last10
      ) END,
      'away_table', CASE WHEN v_away_st.table_position IS NULL THEN NULL ELSE jsonb_build_object(
        'position', v_away_st.table_position,
        'pts', v_away_st.pts,
        'gd', v_away_st.gd,
        'mp', v_away_st.mp,
        'form', v_away_st.form_last10
      ) END,
      'featured_home', CASE WHEN v_feat_home.player_name IS NULL THEN NULL ELSE to_jsonb(v_feat_home) END,
      'featured_away', CASE WHEN v_feat_away.player_name IS NULL THEN NULL ELSE to_jsonb(v_feat_away) END
    ),
    'lead', jsonb_build_object(
      'headline', format('MATCH OF THE MONTH: %s %s–%s %s', v_home_name, v_fx.home_goals, v_fx.away_goals, v_away_name),
      'byline', 'GPSL Sport · Match of the Month desk',
      'body', v_body,
      'pull_quote', v_pull,
      'club_short', CASE
        WHEN coalesce(v_fx.home_goals, 0) >= coalesce(v_fx.away_goals, 0)
          THEN v_fx.home_club_short_name
        ELSE v_fx.away_club_short_name
      END
    )
  );
END;
$function$;

-- Hook into refresh so rebuilt editions get the long MotM
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
  v_motm jsonb;
  v_standings jsonb;
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

  IF to_regprocedure('public.gpsl_sport_month_top_scorers(bigint, text)') IS NOT NULL THEN
    v_scorers := public.gpsl_sport_month_top_scorers(v_row.season_id, v_month);
    v_built := jsonb_set(
      v_built,
      '{stats_page,top_scorers}',
      coalesce(v_scorers, '{}'::jsonb),
      true
    );
  END IF;

  IF to_regprocedure('public.gpsl_sport_build_standings_page(bigint, text)') IS NOT NULL THEN
    v_standings := public.gpsl_sport_build_standings_page(v_row.season_id, v_month);
    v_built := jsonb_set(
      v_built,
      '{stats_page,standings}',
      coalesce(v_standings, '{}'::jsonb),
      true
    );
    IF v_built ? 'front_page' THEN
      v_built := jsonb_set(
        v_built,
        '{front_page,standings_snapshot}',
        coalesce(v_standings, '{}'::jsonb),
        true
      );
    END IF;
  END IF;

  IF to_regprocedure('public.gpsl_sport_build_motm_report(bigint, text)') IS NOT NULL THEN
    v_motm := public.gpsl_sport_build_motm_report(v_row.season_id, v_month);
    IF coalesce((v_motm->>'enabled')::boolean, false) THEN
      v_built := jsonb_set(v_built, '{match_page}', v_motm, true);
    END IF;
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

-- First-time generate: apply MotM/dense scorers via refresh after insert
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

  IF to_regprocedure('public.gpsl_sport_refresh_inseason_edition_by_id(bigint)') IS NOT NULL THEN
    RETURN public.gpsl_sport_refresh_inseason_edition_by_id(v_existing);
  END IF;

  RETURN v_existing;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.gpsl_sport_build_motm_report(bigint, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.gpsl_sport_month_top_scorers(bigint, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.gpsl_sport_refresh_inseason_edition_by_id(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.gpsl_sport_refresh_inseason_edition_by_id(bigint) TO service_role;
GRANT EXECUTE ON FUNCTION public.gpsl_sport_generate_inseason_edition(bigint, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.gpsl_sport_generate_inseason_edition(bigint, text) TO service_role;

NOTIFY pgrst, 'reload schema';
