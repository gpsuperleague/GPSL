-- =============================================================================
-- Match playback goal timing: stop front-loading goals into the early phases
--
-- Problem:
--   Club and international playback were assigning times by overall event rank
--   after sorting goals before assists/cards. That made goals cluster too early.
--
-- Fix:
--   Time goals against the number of goals only, spread across the full match,
--   with a small middle/late bias. Other events get their own independent spread.
--
-- Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.match_sim_build_playback(
  p_fixture_id bigint,
  p_duration_sec int DEFAULT 20
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_dur numeric := greatest(8, least(60, coalesce(p_duration_sec, 20)))::numeric;
  v_fixture record;
  v_events jsonb := '[]'::jsonb;
  v_row record;
  v_t numeric;
  v_minute int;
  v_hg int := 0;
  v_ag int := 0;
  v_i int := 0;
  v_n int;
  v_goal_n int := 0;
  v_other_n int := 0;
  v_goal_i int := 0;
  v_other_i int := 0;
  v_prog numeric;
BEGIN
  SELECT
    f.home_club_short_name,
    f.away_club_short_name,
    f.home_goals,
    f.away_goals
  INTO v_fixture
  FROM public.competition_fixtures f
  WHERE f.id = p_fixture_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('duration_sec', v_dur, 'events', '[]'::jsonb);
  END IF;

  v_events := v_events || jsonb_build_array(jsonb_build_object(
    't', 0,
    'type', 'kickoff',
    'side', null,
    'text', 'Kick-off',
    'minute', 1
  ));

  CREATE TEMP TABLE IF NOT EXISTS _ms_ev (
    ord serial,
    kind text,
    side text,
    player_id text,
    player_name text,
    goals int DEFAULT 0,
    assists int DEFAULT 0
  ) ON COMMIT DROP;
  DELETE FROM _ms_ev WHERE true;

  FOR v_row IN
    SELECT
      m.club_short_name AS side,
      m.player_id,
      coalesce(p."Name", m.player_id) AS player_name,
      coalesce(m.goals, 0) AS goals,
      coalesce(m.assists, 0) AS assists,
      coalesce(m.yellow_card, false) AS yellow_card,
      coalesce(m.red_card, false) AS red_card
    FROM public.competition_match_player_stats m
    LEFT JOIN public."Players" p ON p."Konami_ID"::text = m.player_id
    WHERE m.fixture_id = p_fixture_id
  LOOP
    IF v_row.goals > 0 THEN
      FOR v_i IN 1..v_row.goals LOOP
        INSERT INTO _ms_ev (kind, side, player_id, player_name, goals)
        VALUES ('goal', v_row.side, v_row.player_id, v_row.player_name, 1);
      END LOOP;
    END IF;
    IF v_row.assists > 0 THEN
      FOR v_i IN 1..v_row.assists LOOP
        INSERT INTO _ms_ev (kind, side, player_id, player_name, assists)
        VALUES ('assist', v_row.side, v_row.player_id, v_row.player_name, 1);
      END LOOP;
    END IF;
    IF v_row.yellow_card THEN
      INSERT INTO _ms_ev (kind, side, player_id, player_name)
      VALUES ('yellow', v_row.side, v_row.player_id, v_row.player_name);
    END IF;
    IF v_row.red_card THEN
      INSERT INTO _ms_ev (kind, side, player_id, player_name)
      VALUES ('red', v_row.side, v_row.player_id, v_row.player_name);
    END IF;
  END LOOP;

  BEGIN
    FOR v_row IN
      SELECT
        r.club_short_name AS side,
        i.player_id,
        coalesce(p."Name", i.player_id) AS player_name,
        coalesce(c.name, 'Injury') AS injury_name
      FROM public.competition_fixture_injury_roll r
      JOIN public.competition_player_injuries i ON i.id = r.injury_id
      LEFT JOIN public.competition_injury_catalogue c ON c.id = i.catalogue_id
      LEFT JOIN public."Players" p ON p."Konami_ID"::text = i.player_id
      WHERE r.fixture_id = p_fixture_id
        AND r.did_injure
    LOOP
      INSERT INTO _ms_ev (kind, side, player_id, player_name)
      VALUES ('injury', v_row.side, v_row.player_id, v_row.player_name || ' - ' || v_row.injury_name);
    END LOOP;
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;

  SELECT count(*)::int INTO v_n FROM _ms_ev;
  SELECT count(*)::int INTO v_goal_n FROM _ms_ev WHERE kind = 'goal';
  v_other_n := greatest(v_n - v_goal_n, 0);
  v_i := 0;

  IF v_n = 0 THEN
    v_events := v_events || jsonb_build_array(
      jsonb_build_object('t', round(v_dur * 0.25, 2), 'type', 'momentum', 'side', 'home', 'pressure', 0.62, 'text', 'Home pressing'),
      jsonb_build_object('t', round(v_dur * 0.55, 2), 'type', 'momentum', 'side', 'away', 'pressure', 0.58, 'text', 'Away on the break'),
      jsonb_build_object('t', round(v_dur * 0.78, 2), 'type', 'momentum', 'side', 'home', 'pressure', 0.55, 'text', 'End-to-end')
    );
  ELSE
    FOR v_row IN
      SELECT * FROM _ms_ev ORDER BY
        CASE kind WHEN 'goal' THEN 1 WHEN 'assist' THEN 2 WHEN 'yellow' THEN 3 WHEN 'red' THEN 4 ELSE 5 END,
        random()
    LOOP
      v_i := v_i + 1;

      IF v_row.kind = 'goal' THEN
        v_goal_i := v_goal_i + 1;
        v_prog := power(v_goal_i::numeric / (v_goal_n + 1)::numeric, 0.92);
        v_t := round((0.06 + (0.88 * v_prog) + ((random() - 0.5) * 0.05)) * v_dur, 2);
      ELSE
        v_other_i := v_other_i + 1;
        v_prog := v_other_i::numeric / greatest(v_other_n + 1, 1)::numeric;
        v_t := round((0.10 + (0.80 * v_prog) + ((random() - 0.5) * 0.16)) * v_dur, 2);
      END IF;

      v_t := least(v_dur - 0.4, greatest(0.5, v_t));
      v_minute := greatest(1, least(90, round((v_t / v_dur) * 90)::int));

      IF v_row.kind = 'goal' THEN
        IF v_row.side = v_fixture.home_club_short_name THEN
          v_hg := v_hg + 1;
        ELSE
          v_ag := v_ag + 1;
        END IF;
        v_events := v_events || jsonb_build_array(jsonb_build_object(
          't', v_t,
          'type', 'goal',
          'side', CASE WHEN v_row.side = v_fixture.home_club_short_name THEN 'home' ELSE 'away' END,
          'player', v_row.player_name,
          'player_id', v_row.player_id,
          'minute', v_minute,
          'score_home', v_hg,
          'score_away', v_ag,
          'text', format('%s'' GOAL — %s', v_minute, v_row.player_name),
          'pressure', 0.82
        ));
        v_events := v_events || jsonb_build_array(jsonb_build_object(
          't', least(v_dur - 0.2, v_t + 0.15),
          'type', 'momentum',
          'side', CASE WHEN v_row.side = v_fixture.home_club_short_name THEN 'home' ELSE 'away' END,
          'pressure', 0.78,
          'text', 'Momentum'
        ));
      ELSIF v_row.kind = 'assist' THEN
        v_events := v_events || jsonb_build_array(jsonb_build_object(
          't', v_t,
          'type', 'assist',
          'side', CASE WHEN v_row.side = v_fixture.home_club_short_name THEN 'home' ELSE 'away' END,
          'player', v_row.player_name,
          'minute', v_minute,
          'text', format('%s'' Assist — %s', v_minute, v_row.player_name)
        ));
      ELSIF v_row.kind = 'yellow' THEN
        v_events := v_events || jsonb_build_array(jsonb_build_object(
          't', v_t,
          'type', 'yellow',
          'side', CASE WHEN v_row.side = v_fixture.home_club_short_name THEN 'home' ELSE 'away' END,
          'player', v_row.player_name,
          'minute', v_minute,
          'text', format('%s'' Yellow — %s', v_minute, v_row.player_name)
        ));
      ELSIF v_row.kind = 'red' THEN
        v_events := v_events || jsonb_build_array(jsonb_build_object(
          't', v_t,
          'type', 'red',
          'side', CASE WHEN v_row.side = v_fixture.home_club_short_name THEN 'home' ELSE 'away' END,
          'player', v_row.player_name,
          'minute', v_minute,
          'text', format('%s'' RED — %s', v_minute, v_row.player_name),
          'pressure', 0.7
        ));
      ELSIF v_row.kind = 'injury' THEN
        v_events := v_events || jsonb_build_array(jsonb_build_object(
          't', v_t,
          'type', 'injury',
          'side', CASE WHEN v_row.side = v_fixture.home_club_short_name THEN 'home' ELSE 'away' END,
          'player', v_row.player_name,
          'minute', v_minute,
          'text', format('%s'' Injury — %s', v_minute, v_row.player_name)
        ));
      END IF;
    END LOOP;

    v_events := v_events || jsonb_build_array(
      jsonb_build_object('t', round(v_dur * 0.18, 2), 'type', 'momentum', 'side', 'home', 'pressure', 0.55 + random()*0.2, 'text', 'Home attack'),
      jsonb_build_object('t', round(v_dur * 0.42, 2), 'type', 'momentum', 'side', 'away', 'pressure', 0.55 + random()*0.2, 'text', 'Away attack'),
      jsonb_build_object('t', round(v_dur * 0.68, 2), 'type', 'momentum', 'side', CASE WHEN random() < 0.5 THEN 'home' ELSE 'away' END, 'pressure', 0.5 + random()*0.25, 'text', 'Pressure')
    );
  END IF;

  v_events := v_events || jsonb_build_array(jsonb_build_object(
    't', v_dur,
    'type', 'fulltime',
    'side', null,
    'score_home', coalesce(v_fixture.home_goals, v_hg),
    'score_away', coalesce(v_fixture.away_goals, v_ag),
    'text', format('Full time %s–%s', coalesce(v_fixture.home_goals, v_hg), coalesce(v_fixture.away_goals, v_ag)),
    'minute', 90
  ));

  SELECT coalesce(jsonb_agg(e.obj ORDER BY (e.obj->>'t')::numeric, e.ord), '[]'::jsonb)
  INTO v_events
  FROM (
    SELECT value AS obj, ordinality AS ord
    FROM jsonb_array_elements(v_events) WITH ORDINALITY
  ) e;

  RETURN jsonb_build_object(
    'duration_sec', v_dur,
    'events', v_events
  );
END;
$function$;

DROP FUNCTION IF EXISTS public.match_sim_build_intl_playback(text, text, int, int, int);

CREATE OR REPLACE FUNCTION public.match_sim_build_intl_playback(
  p_home_name text,
  p_away_name text,
  p_home_goals int,
  p_away_goals int,
  p_duration_sec int DEFAULT 20,
  p_home_stats jsonb DEFAULT '[]'::jsonb,
  p_away_stats jsonb DEFAULT '[]'::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SET search_path = public
AS $function$
DECLARE
  v_dur numeric := greatest(8, least(60, coalesce(p_duration_sec, 20)))::numeric;
  v_events jsonb := '[]'::jsonb;
  v_hg int := 0;
  v_ag int := 0;
  v_n int := 0;
  v_goal_n int := 0;
  v_other_n int := 0;
  v_goal_i int := 0;
  v_other_i int := 0;
  v_t numeric;
  v_minute int;
  v_prog numeric;
  r record;
BEGIN
  CREATE TEMP TABLE IF NOT EXISTS _intl_pb_ev (
    ord serial,
    kind text,
    side text,
    player_id text,
    player_name text,
    goals int DEFAULT 0,
    assists int DEFAULT 0
  ) ON COMMIT DROP;
  DELETE FROM _intl_pb_ev WHERE true;

  FOR r IN
    SELECT
      coalesce(nullif(btrim(e->>'player_id'), ''), '') AS player_id,
      coalesce(
        nullif(btrim(e->>'name'), ''),
        nullif(btrim(p."Name"), ''),
        nullif(btrim(e->>'player_id'), ''),
        'Unknown'
      ) AS player_name,
      greatest(coalesce(nullif(e->>'goals', '')::int, 0), 0) AS goals,
      greatest(coalesce(nullif(e->>'assists', '')::int, 0), 0) AS assists
    FROM jsonb_array_elements(coalesce(p_home_stats, '[]'::jsonb)) e
    LEFT JOIN public."Players" p ON p."Konami_ID"::text = e->>'player_id'
  LOOP
    IF r.player_id = '' THEN CONTINUE; END IF;
    IF r.goals > 0 THEN
      FOR v_n IN 1..r.goals LOOP
        INSERT INTO _intl_pb_ev (kind, side, player_id, player_name, goals)
        VALUES ('goal', 'home', r.player_id, r.player_name, 1);
      END LOOP;
    END IF;
    IF r.assists > 0 THEN
      FOR v_n IN 1..r.assists LOOP
        INSERT INTO _intl_pb_ev (kind, side, player_id, player_name, assists)
        VALUES ('assist', 'home', r.player_id, r.player_name, 1);
      END LOOP;
    END IF;
  END LOOP;

  FOR r IN
    SELECT
      coalesce(nullif(btrim(e->>'player_id'), ''), '') AS player_id,
      coalesce(
        nullif(btrim(e->>'name'), ''),
        nullif(btrim(p."Name"), ''),
        nullif(btrim(e->>'player_id'), ''),
        'Unknown'
      ) AS player_name,
      greatest(coalesce(nullif(e->>'goals', '')::int, 0), 0) AS goals,
      greatest(coalesce(nullif(e->>'assists', '')::int, 0), 0) AS assists
    FROM jsonb_array_elements(coalesce(p_away_stats, '[]'::jsonb)) e
    LEFT JOIN public."Players" p ON p."Konami_ID"::text = e->>'player_id'
  LOOP
    IF r.player_id = '' THEN CONTINUE; END IF;
    IF r.goals > 0 THEN
      FOR v_n IN 1..r.goals LOOP
        INSERT INTO _intl_pb_ev (kind, side, player_id, player_name, goals)
        VALUES ('goal', 'away', r.player_id, r.player_name, 1);
      END LOOP;
    END IF;
    IF r.assists > 0 THEN
      FOR v_n IN 1..r.assists LOOP
        INSERT INTO _intl_pb_ev (kind, side, player_id, player_name, assists)
        VALUES ('assist', 'away', r.player_id, r.player_name, 1);
      END LOOP;
    END IF;
  END LOOP;

  SELECT count(*) FILTER (WHERE kind = 'goal' AND side = 'home')::int INTO v_n FROM _intl_pb_ev;
  FOR v_goal_i IN 1..greatest(coalesce(p_home_goals, 0) - coalesce(v_n, 0), 0) LOOP
    INSERT INTO _intl_pb_ev (kind, side, player_id, player_name, goals)
    VALUES ('goal', 'home', NULL, coalesce(p_home_name, 'Home'), 1);
  END LOOP;
  SELECT count(*) FILTER (WHERE kind = 'goal' AND side = 'away')::int INTO v_n FROM _intl_pb_ev;
  FOR v_goal_i IN 1..greatest(coalesce(p_away_goals, 0) - coalesce(v_n, 0), 0) LOOP
    INSERT INTO _intl_pb_ev (kind, side, player_id, player_name, goals)
    VALUES ('goal', 'away', NULL, coalesce(p_away_name, 'Away'), 1);
  END LOOP;

  v_events := v_events || jsonb_build_array(jsonb_build_object(
    't', 0, 'type', 'kickoff', 'side', null, 'text', 'Kick-off', 'minute', 1
  ));

  SELECT count(*)::int INTO v_n FROM _intl_pb_ev;
  SELECT count(*)::int INTO v_goal_n FROM _intl_pb_ev WHERE kind = 'goal';
  v_other_n := greatest(v_n - v_goal_n, 0);
  v_goal_i := 0;
  v_other_i := 0;

  FOR r IN
    SELECT * FROM _intl_pb_ev
    ORDER BY
      CASE kind WHEN 'goal' THEN 1 WHEN 'assist' THEN 2 ELSE 3 END,
      random()
  LOOP
    IF r.kind = 'goal' THEN
      v_goal_i := v_goal_i + 1;
      v_prog := power(v_goal_i::numeric / (v_goal_n + 1)::numeric, 0.92);
      v_t := round((0.06 + (0.88 * v_prog) + ((random() - 0.5) * 0.05)) * v_dur, 2);
    ELSE
      v_other_i := v_other_i + 1;
      v_prog := v_other_i::numeric / greatest(v_other_n + 1, 1)::numeric;
      v_t := round((0.10 + (0.80 * v_prog) + ((random() - 0.5) * 0.16)) * v_dur, 2);
    END IF;

    v_t := least(v_dur - 0.4, greatest(0.5, v_t));
    v_minute := greatest(1, least(90, round((v_t / v_dur) * 90)::int));

    IF r.kind = 'goal' THEN
      IF r.side = 'home' THEN v_hg := v_hg + 1; ELSE v_ag := v_ag + 1; END IF;
      v_events := v_events || jsonb_build_array(jsonb_build_object(
        't', v_t,
        'type', 'goal',
        'side', r.side,
        'player', r.player_name,
        'player_id', r.player_id,
        'minute', v_minute,
        'score_home', v_hg,
        'score_away', v_ag,
        'text', format('%s'' GOAL — %s', v_minute, r.player_name),
        'pressure', 0.82
      ));
    ELSIF r.kind = 'assist' THEN
      v_events := v_events || jsonb_build_array(jsonb_build_object(
        't', v_t,
        'type', 'assist',
        'side', r.side,
        'player', r.player_name,
        'player_id', r.player_id,
        'minute', v_minute,
        'text', format('%s'' Assist — %s', v_minute, r.player_name)
      ));
    END IF;
  END LOOP;

  v_events := v_events || jsonb_build_array(jsonb_build_object(
    't', v_dur,
    'type', 'fulltime',
    'side', null,
    'text', format('FT %s–%s', coalesce(p_home_goals, 0), coalesce(p_away_goals, 0)),
    'minute', 90,
    'score_home', coalesce(p_home_goals, 0),
    'score_away', coalesce(p_away_goals, 0)
  ));

  SELECT coalesce(jsonb_agg(e.obj ORDER BY (e.obj->>'t')::numeric, e.ord), '[]'::jsonb)
  INTO v_events
  FROM (
    SELECT value AS obj, ordinality AS ord
    FROM jsonb_array_elements(v_events) WITH ORDINALITY
  ) e;

  RETURN jsonb_build_object(
    'duration_sec', v_dur,
    'events', v_events,
    'home_name', p_home_name,
    'away_name', p_away_name
  );
END;
$function$;

NOTIFY pgrst, 'reload schema';
