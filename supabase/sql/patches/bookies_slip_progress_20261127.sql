-- =============================================================================
-- Bookies: live "on course / how far off" for the signed-in owner's open slips
-- =============================================================================
-- League: table position and points (goal difference when level).
-- Cups: still in, through, won, or knocked out.
-- Players: goals, assists, or clean sheets against the current lead.
-- A tie is level, not a payout — settlement still picks one selection.
-- Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.bookies_slip_count_label(p_n int, p_singular text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT coalesce(p_n, 0)::text || ' ' || p_singular
    || CASE WHEN coalesce(p_n, 0) = 1 THEN '' ELSE 's' END;
$$;

REVOKE ALL ON FUNCTION public.bookies_slip_count_label(int, text) FROM PUBLIC;

CREATE OR REPLACE FUNCTION public.bookies_selection_run(
  p_market_id bigint,
  p_selection_key text
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  m public.bookies_markets%rowtype;
  v_code text;
  v_key text := btrim(coalesce(p_selection_key, ''));
  v_div text;
  v_cup text;
  v_pos int;
  v_pts int;
  v_mp int;
  v_gd int;
  v_club_name text;
  v_lead_pos int;
  v_lead_pts int;
  v_lead_mp int;
  v_lead_name text;
  v_second_pts int;
  v_second_mp int;
  v_gap int;
  v_hand int;
  v_line text;
  v_round int;
  v_sched_max int;
  v_winner text;
  v_round_label text;
  v_alive int;
  v_in_draw boolean;
  v_stat text;
  v_unit text;
  v_mine int;
  v_max int;
  v_tied int;
  v_second int;
  v_lead_id text;
  v_lead_player text;
  v_clear int;
BEGIN
  IF v_key = '' THEN
    RETURN jsonb_build_object('tone', 'wait', 'line', 'No selection on this slip.');
  END IF;

  SELECT * INTO m FROM public.bookies_markets WHERE id = p_market_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('tone', 'wait', 'line', 'Market not found.');
  END IF;

  v_code := lower(coalesce(m.market_code, ''));
  v_div := nullif(btrim(coalesce(m.metadata->>'division', '')), '');

  -- -------------------------------------------------------------------------
  -- League title
  -- -------------------------------------------------------------------------
  IF v_code LIKE 'league_%' AND v_div IS NOT NULL THEN
    SELECT s.table_position, s.pts, s.mp, s.gd, s.club_name
    INTO v_pos, v_pts, v_mp, v_gd, v_club_name
    FROM public.competition_standings_public s
    WHERE s.season_id = m.season_id
      AND s.division = v_div
      AND upper(btrim(s.club_short_name)) = upper(v_key)
    LIMIT 1;

    IF v_pos IS NULL THEN
      RETURN jsonb_build_object('tone', 'off', 'line', 'Not on this division''s table.');
    END IF;

    IF NOT EXISTS (
      SELECT 1 FROM public.competition_standings_public s
      WHERE s.season_id = m.season_id AND s.division = v_div AND s.mp > 0
    ) THEN
      RETURN jsonb_build_object('tone', 'wait', 'line', 'No games played yet.');
    END IF;

    SELECT s.table_position, s.pts, s.mp, s.club_name
    INTO v_lead_pos, v_lead_pts, v_lead_mp, v_lead_name
    FROM public.competition_standings_public s
    WHERE s.season_id = m.season_id
      AND s.division = v_div
      AND s.table_position = 1
    LIMIT 1;

    SELECT s.pts, s.mp
    INTO v_second_pts, v_second_mp
    FROM public.competition_standings_public s
    WHERE s.season_id = m.season_id
      AND s.division = v_div
      AND s.table_position = 2
    LIMIT 1;

    v_gap := coalesce(v_lead_pts, 0) - coalesce(v_pts, 0);

    IF v_pos = 1 AND coalesce(v_second_pts, v_pts) < v_pts THEN
      v_line := 'On course. 1st on ' || public.bookies_slip_count_label(v_pts, 'point')
        || ', ' || public.bookies_slip_count_label(v_pts - coalesce(v_second_pts, 0), 'point')
        || ' clear of 2nd.';
      v_hand := coalesce(v_mp, 0) - coalesce(v_second_mp, v_mp);
      IF v_hand > 0 THEN
        v_line := v_line || ' 2nd has '
          || CASE WHEN v_hand = 1 THEN 'a game' ELSE public.bookies_slip_count_label(v_hand, 'game') END
          || ' in hand.';
      END IF;
      RETURN jsonb_build_object('tone', 'on', 'line', v_line);
    END IF;

    IF v_pos = 1 AND coalesce(v_second_pts, v_pts) = v_pts THEN
      RETURN jsonb_build_object(
        'tone', 'on',
        'line', 'On course on goal difference. 1st, level on '
          || public.bookies_slip_count_label(v_pts, 'point') || '.'
      );
    END IF;

    IF v_gap = 0 THEN
      RETURN jsonb_build_object(
        'tone', 'level',
        'line', 'Level on points with ' || coalesce(v_lead_name, 'the leader')
          || ', behind on goal difference. '
          || public.bookies_slip_ordinal(v_pos) || '.'
      );
    END IF;

    v_line := 'Off it. ' || public.bookies_slip_ordinal(v_pos) || ', '
      || public.bookies_slip_count_label(v_gap, 'point') || ' behind '
      || coalesce(v_lead_name, 'the leader')
      || ' (' || coalesce(v_lead_pts, 0)::text || '). You have ' || coalesce(v_pts, 0)::text || '.';
    v_hand := coalesce(v_lead_mp, 0) - coalesce(v_mp, 0);
    IF v_hand > 0 THEN
      v_line := v_line || ' You have '
        || CASE WHEN v_hand = 1 THEN 'a game' ELSE public.bookies_slip_count_label(v_hand, 'game') END
        || ' in hand.';
    ELSIF v_hand < 0 THEN
      v_line := v_line || ' The leader has '
        || CASE WHEN v_hand = -1 THEN 'a game' ELSE public.bookies_slip_count_label(-v_hand, 'game') END
        || ' in hand.';
    END IF;
    RETURN jsonb_build_object('tone', 'off', 'line', v_line);
  END IF;

  -- -------------------------------------------------------------------------
  -- Cup winner
  -- -------------------------------------------------------------------------
  IF v_code LIKE 'cup_%' THEN
    v_cup := substring(v_code FROM 5);

    IF NOT EXISTS (
      SELECT 1 FROM public.competition_cup_bracket_nodes n
      WHERE n.season_id = m.season_id AND lower(n.cup_code) = v_cup
    ) THEN
      IF NOT EXISTS (
        SELECT 1 FROM public.competition_fixtures f
        WHERE f.season_id = m.season_id
          AND f.competition_type = 'cup'
          AND lower(coalesce(f.cup_code, '')) = v_cup
      ) THEN
        RETURN jsonb_build_object('tone', 'wait', 'line', 'Draw not made yet.');
      END IF;
      RETURN jsonb_build_object('tone', 'wait', 'line', 'Cup progress is not on the bracket yet.');
    END IF;

    SELECT EXISTS (
      SELECT 1
      FROM public.competition_cup_bracket_nodes n
      WHERE n.season_id = m.season_id
        AND lower(n.cup_code) = v_cup
        AND (
          upper(btrim(n.home_club_short_name)) = upper(v_key)
          OR upper(btrim(n.away_club_short_name)) = upper(v_key)
        )
    ) INTO v_in_draw;

    IF NOT v_in_draw THEN
      RETURN jsonb_build_object('tone', 'off', 'line', 'Not in this cup.');
    END IF;

    SELECT x.round_no, x.winner_u
    INTO v_round, v_winner
    FROM (
      SELECT
        n.round_no,
        upper(btrim(coalesce(n.winner_club_short_name, ''))) AS winner_u
      FROM public.competition_cup_bracket_nodes n
      WHERE n.season_id = m.season_id
        AND lower(n.cup_code) = v_cup
        AND (
          upper(btrim(n.home_club_short_name)) = upper(v_key)
          OR upper(btrim(n.away_club_short_name)) = upper(v_key)
        )
      ORDER BY n.round_no DESC,
        (btrim(coalesce(n.winner_club_short_name, '')) <> '') DESC,
        (n.leg1_node_id IS NOT NULL) DESC,
        n.id DESC
      LIMIT 1
    ) x;

    SELECT s.round_label
    INTO v_round_label
    FROM public.competition_cup_round_schedule s
    WHERE s.cup_code = v_cup AND s.round_no = v_round
    ORDER BY s.cup_leg DESC
    LIMIT 1;
    v_round_label := coalesce(v_round_label, 'round ' || coalesce(v_round, 0)::text);

    v_sched_max := public.competition_cup_scheduled_round_count(v_cup);

    WITH clubs AS (
      SELECT upper(btrim(n.home_club_short_name)) AS club
      FROM public.competition_cup_bracket_nodes n
      WHERE n.season_id = m.season_id AND lower(n.cup_code) = v_cup
        AND btrim(coalesce(n.home_club_short_name, '')) <> ''
      UNION
      SELECT upper(btrim(n.away_club_short_name))
      FROM public.competition_cup_bracket_nodes n
      WHERE n.season_id = m.season_id AND lower(n.cup_code) = v_cup
        AND btrim(coalesce(n.away_club_short_name, '')) <> ''
    ),
    latest AS (
      SELECT DISTINCT ON (c.club)
        c.club,
        upper(btrim(coalesce(n.winner_club_short_name, ''))) AS winner_u
      FROM clubs c
      JOIN public.competition_cup_bracket_nodes n
        ON n.season_id = m.season_id
       AND lower(n.cup_code) = v_cup
       AND (
         upper(btrim(n.home_club_short_name)) = c.club
         OR upper(btrim(n.away_club_short_name)) = c.club
       )
      ORDER BY c.club, n.round_no DESC,
        (btrim(coalesce(n.winner_club_short_name, '')) <> '') DESC,
        (n.leg1_node_id IS NOT NULL) DESC,
        n.id DESC
    )
    SELECT count(*)::int
    INTO v_alive
    FROM latest
    WHERE winner_u = '' OR winner_u = club;

    IF v_winner = upper(v_key) AND v_sched_max IS NOT NULL AND v_round >= v_sched_max THEN
      RETURN jsonb_build_object(
        'tone', 'on',
        'line', 'On course. Won the cup. Pays when this market is settled.'
      );
    END IF;

    IF v_winner = '' OR v_winner IS NULL THEN
      RETURN jsonb_build_object(
        'tone', 'on',
        'line', 'On course. Still in the ' || v_round_label || '. '
          || public.bookies_slip_count_label(v_alive, 'club') || ' still in.'
      );
    END IF;

    IF v_winner = upper(v_key) THEN
      RETURN jsonb_build_object(
        'tone', 'on',
        'line', 'On course. Through the ' || v_round_label
          || '. Next round is not drawn yet. '
          || public.bookies_slip_count_label(v_alive, 'club') || ' still in.'
      );
    END IF;

    RETURN jsonb_build_object(
      'tone', 'off',
      'line', 'Out. Knocked out in the ' || v_round_label || '. '
        || public.bookies_slip_count_label(v_alive, 'club') || ' still in.'
    );
  END IF;

  -- -------------------------------------------------------------------------
  -- Player charts
  -- -------------------------------------------------------------------------
  IF v_code LIKE 'assists%' THEN
    v_stat := 'assists';
    v_unit := 'assist';
  ELSIF v_code LIKE 'clean_sheets%' THEN
    v_stat := 'clean_sheets';
    v_unit := 'clean sheet';
  ELSIF v_code = 'scorer_world_cup' THEN
    v_stat := 'world_cup';
    v_unit := 'goal';
  ELSIF v_code IN ('scorer_overall', 'scorer_league_cup', 'scorer_prestige') OR v_code LIKE 'scorer%' THEN
    v_stat := 'goals';
    v_unit := 'goal';
  ELSE
    RETURN jsonb_build_object('tone', 'wait', 'line', 'No live position for this market.');
  END IF;

  IF v_stat = 'world_cup' THEN
    IF to_regclass('public.international_result_submissions') IS NULL THEN
      RETURN jsonb_build_object('tone', 'wait', 'line', 'No World Cup goals recorded yet.');
    END IF;
    EXECUTE $q$
      WITH goals AS (
        SELECT
          coalesce(
            nullif(btrim(elem->>'player_id'), ''),
            nullif(btrim(elem->>'Konami_ID'), '')
          ) AS player_id,
          CASE
            WHEN coalesce(elem->>'goals', '') ~ '^[0-9]+$' THEN (elem->>'goals')::int
            ELSE 0
          END AS goals
        FROM public.international_result_submissions s
        JOIN public.international_fixtures f ON f.id = s.fixture_id
        CROSS JOIN LATERAL jsonb_array_elements(
          CASE WHEN jsonb_typeof(s.player_stats) = 'array' THEN s.player_stats ELSE '[]'::jsonb END
        ) elem
        WHERE s.status = 'confirmed'
          AND f.season_id = $1
      ),
      chart AS (
        SELECT player_id, sum(goals)::int AS stat
        FROM goals
        WHERE player_id IS NOT NULL
        GROUP BY player_id
      )
      SELECT
        coalesce((SELECT stat FROM chart WHERE player_id = $2), 0),
        coalesce((SELECT max(stat) FROM chart), 0),
        coalesce((SELECT count(*) FROM chart WHERE stat = (SELECT max(stat) FROM chart) AND stat > 0), 0)::int,
        coalesce((SELECT player_id FROM chart WHERE stat = (SELECT max(stat) FROM chart) AND stat > 0 ORDER BY player_id LIMIT 1), ''),
        coalesce((SELECT max(stat) FROM chart WHERE stat < (SELECT max(stat) FROM chart)), 0)
    $q$
    INTO v_mine, v_max, v_tied, v_lead_id, v_second
    USING m.season_id, v_key;
  ELSIF v_code = 'scorer_league_cup' OR v_code = 'scorer_prestige' THEN
    WITH chart AS (
      SELECT mps.player_id, coalesce(sum(mps.goals), 0)::int AS stat
      FROM public.competition_match_player_stats mps
      JOIN public.competition_fixtures f ON f.id = mps.fixture_id
      WHERE mps.season_id = m.season_id
        AND f.status = 'played'
        AND f.competition_type = 'cup'
        AND (
          (v_code = 'scorer_league_cup' AND lower(coalesce(f.cup_code, '')) = 'league_cup')
          OR (
            v_code = 'scorer_prestige'
            AND lower(coalesce(f.cup_code, '')) IN ('super8', 'plate', 'shield', 'bowl')
          )
        )
      GROUP BY mps.player_id
    )
    SELECT
      coalesce((SELECT stat FROM chart WHERE player_id = v_key), 0),
      coalesce((SELECT max(stat) FROM chart), 0),
      coalesce((SELECT count(*) FROM chart WHERE stat = (SELECT max(stat) FROM chart) AND stat > 0), 0)::int,
      coalesce((SELECT player_id FROM chart WHERE stat = (SELECT max(stat) FROM chart) AND stat > 0 ORDER BY player_id LIMIT 1), ''),
      coalesce((SELECT max(stat) FROM chart WHERE stat < (SELECT max(stat) FROM chart)), 0)
    INTO v_mine, v_max, v_tied, v_lead_id, v_second;
  ELSE
    WITH chart AS (
      SELECT
        st.player_id,
        coalesce(sum(
          CASE v_stat
            WHEN 'assists' THEN st.assists
            WHEN 'clean_sheets' THEN st.clean_sheets
            ELSE st.goals
          END
        ), 0)::int AS stat
      FROM public.competition_player_season_stats_public st
      WHERE st.season_id = m.season_id
      GROUP BY st.player_id
    )
    SELECT
      coalesce((SELECT stat FROM chart WHERE player_id = v_key), 0),
      coalesce((SELECT max(stat) FROM chart), 0),
      coalesce((SELECT count(*) FROM chart WHERE stat = (SELECT max(stat) FROM chart) AND stat > 0), 0)::int,
      coalesce((SELECT player_id FROM chart WHERE stat = (SELECT max(stat) FROM chart) AND stat > 0 ORDER BY player_id LIMIT 1), ''),
      coalesce((SELECT max(stat) FROM chart WHERE stat < (SELECT max(stat) FROM chart)), 0)
    INTO v_mine, v_max, v_tied, v_lead_id, v_second;
  END IF;

  IF coalesce(v_max, 0) <= 0 THEN
    RETURN jsonb_build_object(
      'tone', 'wait',
      'line', 'No ' || CASE WHEN v_unit = 'assist' THEN 'assists' WHEN v_unit = 'clean sheet' THEN 'clean sheets' ELSE 'goals' END || ' yet.'
    );
  END IF;

  IF v_mine = v_max AND v_tied = 1 THEN
    v_clear := v_max - coalesce(v_second, 0);
    RETURN jsonb_build_object(
      'tone', 'on',
      'line', 'On course. Leading on ' || public.bookies_slip_count_label(v_mine, v_unit)
        || CASE WHEN v_clear > 0
          THEN ', ' || public.bookies_slip_count_label(v_clear, v_unit) || ' clear.'
          ELSE '.' END
    );
  END IF;

  IF v_mine = v_max THEN
    RETURN jsonb_build_object(
      'tone', 'level',
      'line', 'Level. Joint top on ' || public.bookies_slip_count_label(v_mine, v_unit)
        || '. A tie does not pay until one player finishes ahead.'
    );
  END IF;

  v_lead_player := NULL;
  IF v_tied = 1 AND v_lead_id <> '' THEN
    SELECT p."Name" INTO v_lead_player
    FROM public."Players" p
    WHERE p."Konami_ID"::text = v_lead_id
    LIMIT 1;
  END IF;

  IF v_tied = 1 AND v_lead_player IS NOT NULL THEN
    v_line := 'Off it. ' || public.bookies_slip_count_label(v_max - v_mine, v_unit)
      || ' behind ' || v_lead_player
      || ' (' || v_max::text || '). You have ' || v_mine::text || '.';
  ELSE
    v_line := 'Off it. ' || public.bookies_slip_count_label(v_max - v_mine, v_unit)
      || ' behind the lead (' || v_max::text
      || ', shared by ' || v_tied::text || ' players). You have ' || v_mine::text || '.';
  END IF;

  RETURN jsonb_build_object('tone', 'off', 'line', v_line);
END;
$function$;

-- Ordinal used by the league branch. Created after the first draft referenced it,
-- so replace the league function body is already in bookies_selection_run above.
-- bookies_slip_ordinal must exist before bookies_selection_run runs.
CREATE OR REPLACE FUNCTION public.bookies_slip_ordinal(p_n int)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE
    WHEN p_n % 100 IN (11, 12, 13) THEN p_n::text || 'th'
    WHEN p_n % 10 = 1 THEN p_n::text || 'st'
    WHEN p_n % 10 = 2 THEN p_n::text || 'nd'
    WHEN p_n % 10 = 3 THEN p_n::text || 'rd'
    ELSE coalesce(p_n, 0)::text || 'th'
  END;
$$;

REVOKE ALL ON FUNCTION public.bookies_slip_ordinal(int) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.bookies_selection_run(bigint, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.bookies_selection_run(bigint, text) TO authenticated;

CREATE OR REPLACE FUNCTION public.bookies_my_slip_progress()
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
  SELECT coalesce(jsonb_agg(
    jsonb_build_object(
      'bet_id', b.id,
      'tone', run.j->>'tone',
      'line', run.j->>'line'
    )
    ORDER BY b.placed_at DESC
  ), '[]'::jsonb)
  FROM public.bookies_bets b
  JOIN public.bookies_selections s ON s.id = b.selection_id
  CROSS JOIN LATERAL (
    SELECT public.bookies_selection_run(b.market_id, s.selection_key) AS j
  ) run
  WHERE b.owner_id = auth.uid()
    AND b.status = 'open';
$function$;

REVOKE ALL ON FUNCTION public.bookies_my_slip_progress() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.bookies_my_slip_progress() TO authenticated;

NOTIFY pgrst, 'reload schema';
