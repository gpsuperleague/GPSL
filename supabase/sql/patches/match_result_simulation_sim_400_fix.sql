-- =============================================================================
-- HOTFIX: simulate 400 — cast NULL::text in load_club_side + safer playback
-- Run after match_result_simulation_star_roles.sql
-- =============================================================================

SET lock_timeout = '15s';

-- Drop ambiguous older int-star sample_goals overload if still present
DO $$
BEGIN
  DROP FUNCTION IF EXISTS public.match_sim_sample_goals(
    text, numeric, numeric, numeric, numeric, numeric,
    int, int, int, int, int, int
  );
EXCEPTION WHEN OTHERS THEN
  NULL;
END $$;

CREATE OR REPLACE FUNCTION public.match_sim_load_club_side(p_club text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := btrim(p_club);
  v_rows jsonb;
  v_n int;
  v_max_subs int := 5;
BEGIN
  BEGIN
    v_max_subs := greatest(
      0,
      least(5, coalesce((public.match_sim_settings()->>'max_subs_on')::int, 5))
    );
  EXCEPTION WHEN OTHERS THEN
    v_max_subs := 5;
  END;

  SELECT coalesce(
    jsonb_agg(
      jsonb_build_object(
        'player_id', sp.player_id,
        'name', p."Name",
        'rating', public.match_sim_player_rating_num(p."Rating"::text, 70),
        'role', public.match_sim_role_from_slot(sp.pitch_slot, NULL::text),
        'pitch_slot', sp.pitch_slot,
        'profile_pos', p."Position",
        'on_natural', public.match_sim_on_natural_position(sp.pitch_slot, p."Position"),
        'started', true,
        'subbed_on', false,
        'is_star', public.match_sim_is_star(
          public.match_sim_player_rating_num(p."Rating"::text, 70)
        )
      )
      ORDER BY sp.sort_order NULLS LAST, sp.pitch_slot, p."Name"
    ),
    '[]'::jsonb
  )
  INTO v_rows
  FROM public.club_matchday_squad_player sp
  JOIN public."Players" p ON p."Konami_ID"::text = sp.player_id
  WHERE sp.club_short_name = v_club
    AND sp.slot_kind = 'pitch'
    AND p."Contracted_Team" = v_club;

  v_n := coalesce(jsonb_array_length(v_rows), 0);

  IF v_n < 11 THEN
    SELECT coalesce(
      jsonb_agg(x.obj ORDER BY x.ord),
      '[]'::jsonb
    )
    INTO v_rows
    FROM (
      SELECT
        jsonb_build_object(
          'player_id', p."Konami_ID"::text,
          'name', p."Name",
          'rating', public.match_sim_player_rating_num(p."Rating"::text, 70),
          'role', public.match_sim_role_from_slot(NULL::text, p."Position"),
          'pitch_slot', NULL,
          'profile_pos', p."Position",
          'on_natural', true,
          'started', true,
          'subbed_on', false,
          'is_star', public.match_sim_is_star(
            public.match_sim_player_rating_num(p."Rating"::text, 70)
          )
        ) AS obj,
        row_number() OVER (
          ORDER BY public.match_sim_player_rating_num(p."Rating"::text, 0) DESC, p."Name"
        ) AS ord
      FROM public."Players" p
      WHERE p."Contracted_Team" = v_club
      LIMIT 11
    ) x;
    v_n := coalesce(jsonb_array_length(v_rows), 0);
  END IF;

  IF v_n < 11 THEN
    RAISE EXCEPTION 'Club % needs at least 11 contracted players to simulate (have %)', v_club, v_n;
  END IF;

  IF v_max_subs <= 0 THEN
    RETURN v_rows;
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.club_matchday_squad_player sp
    WHERE sp.club_short_name = v_club AND sp.slot_kind = 'bench'
  ) THEN
    SELECT v_rows || coalesce(
      (
        SELECT jsonb_agg(
          jsonb_build_object(
            'player_id', b.player_id,
            'name', b.name,
            'rating', b.rating,
            'role', b.role,
            'pitch_slot', NULL,
            'profile_pos', b.profile_pos,
            'on_natural', true,
            'started', false,
            'subbed_on', true,
            'is_star', b.is_star
          )
          ORDER BY b.ord
        )
        FROM (
          SELECT
            sp.player_id,
            p."Name" AS name,
            public.match_sim_player_rating_num(p."Rating"::text, 70) AS rating,
            public.match_sim_role_from_slot(NULL::text, p."Position") AS role,
            p."Position" AS profile_pos,
            public.match_sim_is_star(
              public.match_sim_player_rating_num(p."Rating"::text, 70)
            ) AS is_star,
            row_number() OVER (
              ORDER BY sp.sort_order NULLS LAST, p."Name"
            ) AS ord
          FROM public.club_matchday_squad_player sp
          JOIN public."Players" p ON p."Konami_ID"::text = sp.player_id
          WHERE sp.club_short_name = v_club
            AND sp.slot_kind = 'bench'
            AND p."Contracted_Team" = v_club
        ) b
        WHERE b.ord <= v_max_subs
      ),
      '[]'::jsonb
    )
    INTO v_rows;
  ELSE
    SELECT v_rows || coalesce(
      (
        SELECT jsonb_agg(y.obj ORDER BY y.ord)
        FROM (
          SELECT
            jsonb_build_object(
              'player_id', p."Konami_ID"::text,
              'name', p."Name",
              'rating', public.match_sim_player_rating_num(p."Rating"::text, 70),
              'role', public.match_sim_role_from_slot(NULL::text, p."Position"),
              'pitch_slot', NULL,
              'profile_pos', p."Position",
              'on_natural', true,
              'started', false,
              'subbed_on', true,
              'is_star', public.match_sim_is_star(
                public.match_sim_player_rating_num(p."Rating"::text, 70)
              )
            ) AS obj,
            row_number() OVER (
              ORDER BY public.match_sim_player_rating_num(p."Rating"::text, 0) DESC, p."Name"
            ) AS ord
          FROM public."Players" p
          WHERE p."Contracted_Team" = v_club
            AND NOT EXISTS (
              SELECT 1
              FROM jsonb_array_elements(v_rows) e
              WHERE e->>'player_id' = p."Konami_ID"::text
            )
        ) y
        WHERE y.ord <= v_max_subs
      ),
      '[]'::jsonb
    )
    INTO v_rows;
  END IF;

  RETURN v_rows;
END;
$function$;

-- Playback without temp tables (avoids session/temp issues under PostgREST)
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
  v_home text;
  v_away text;
  v_final_hg int;
  v_final_ag int;
  v_events jsonb := '[]'::jsonb;
  v_raw jsonb := '[]'::jsonb;
  v_row record;
  v_el jsonb;
  v_t numeric;
  v_minute int;
  v_hg int := 0;
  v_ag int := 0;
  v_i int := 0;
  v_n int;
  v_side text;
  v_kind text;
  v_name text;
BEGIN
  SELECT
    f.home_club_short_name,
    f.away_club_short_name,
    f.home_goals,
    f.away_goals
  INTO v_home, v_away, v_final_hg, v_final_ag
  FROM public.competition_fixtures f
  WHERE f.id = p_fixture_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('duration_sec', v_dur, 'events', '[]'::jsonb);
  END IF;

  v_events := v_events || jsonb_build_array(jsonb_build_object(
    't', 0, 'type', 'kickoff', 'side', null, 'text', 'Kick-off', 'minute', 1
  ));

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
    FOR v_i IN 1..greatest(v_row.goals, 0) LOOP
      v_raw := v_raw || jsonb_build_array(jsonb_build_object(
        'kind', 'goal', 'side', v_row.side, 'player', v_row.player_name
      ));
    END LOOP;
    FOR v_i IN 1..greatest(v_row.assists, 0) LOOP
      v_raw := v_raw || jsonb_build_array(jsonb_build_object(
        'kind', 'assist', 'side', v_row.side, 'player', v_row.player_name
      ));
    END LOOP;
    IF v_row.yellow_card THEN
      v_raw := v_raw || jsonb_build_array(jsonb_build_object(
        'kind', 'yellow', 'side', v_row.side, 'player', v_row.player_name
      ));
    END IF;
    IF v_row.red_card THEN
      v_raw := v_raw || jsonb_build_array(jsonb_build_object(
        'kind', 'red', 'side', v_row.side, 'player', v_row.player_name
      ));
    END IF;
  END LOOP;

  BEGIN
    FOR v_row IN
      SELECT
        r.club_short_name AS side,
        coalesce(p."Name", i.player_id) AS player_name,
        coalesce(c.name, coalesce(i.label, 'Injury')) AS injury_name
      FROM public.competition_fixture_injury_roll r
      JOIN public.competition_player_injuries i ON i.id = r.injury_id
      LEFT JOIN public.competition_injury_catalogue c ON c.id = i.catalogue_id
      LEFT JOIN public."Players" p ON p."Konami_ID"::text = i.player_id
      WHERE r.fixture_id = p_fixture_id
        AND r.did_injure
    LOOP
      v_raw := v_raw || jsonb_build_array(jsonb_build_object(
        'kind', 'injury',
        'side', v_row.side,
        'player', v_row.player_name || ' - ' || v_row.injury_name
      ));
    END LOOP;
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;

  v_n := coalesce(jsonb_array_length(v_raw), 0);
  v_i := 0;
  v_hg := 0;
  v_ag := 0;

  IF v_n = 0 THEN
    v_events := v_events || jsonb_build_array(
      jsonb_build_object('t', round(v_dur * 0.25, 2), 'type', 'momentum', 'side', 'home', 'pressure', 0.62, 'text', 'Home pressing'),
      jsonb_build_object('t', round(v_dur * 0.55, 2), 'type', 'momentum', 'side', 'away', 'pressure', 0.58, 'text', 'Away on the break'),
      jsonb_build_object('t', round(v_dur * 0.78, 2), 'type', 'momentum', 'side', 'home', 'pressure', 0.55, 'text', 'End-to-end')
    );
  ELSE
    FOR v_el IN
      SELECT value
      FROM jsonb_array_elements(v_raw) WITH ORDINALITY AS t(value, ord)
      ORDER BY
        CASE value->>'kind'
          WHEN 'goal' THEN 1
          WHEN 'assist' THEN 2
          WHEN 'yellow' THEN 3
          WHEN 'red' THEN 4
          ELSE 5
        END,
        ord
    LOOP
      v_i := v_i + 1;
      v_kind := v_el->>'kind';
      v_side := v_el->>'side';
      v_name := v_el->>'player';
      v_t := round((0.08 + (0.84 * (v_i::numeric / (v_n + 1)::numeric))) * v_dur, 2);
      v_t := least(v_dur - 0.4, greatest(0.5, v_t));
      v_minute := greatest(1, least(90, round((v_t / v_dur) * 90)::int));

      IF v_kind = 'goal' THEN
        IF v_side = v_home THEN v_hg := v_hg + 1; ELSE v_ag := v_ag + 1; END IF;
        v_events := v_events || jsonb_build_array(jsonb_build_object(
          't', v_t,
          'type', 'goal',
          'side', CASE WHEN v_side = v_home THEN 'home' ELSE 'away' END,
          'player', v_name,
          'minute', v_minute,
          'score_home', v_hg,
          'score_away', v_ag,
          'text', format('%s'' GOAL — %s', v_minute, v_name),
          'pressure', 0.82
        ));
        v_events := v_events || jsonb_build_array(jsonb_build_object(
          't', least(v_dur - 0.2, v_t + 0.15),
          'type', 'momentum',
          'side', CASE WHEN v_side = v_home THEN 'home' ELSE 'away' END,
          'pressure', 0.78,
          'text', 'Momentum'
        ));
      ELSIF v_kind = 'assist' THEN
        v_events := v_events || jsonb_build_array(jsonb_build_object(
          't', v_t, 'type', 'assist',
          'side', CASE WHEN v_side = v_home THEN 'home' ELSE 'away' END,
          'player', v_name, 'minute', v_minute,
          'text', format('%s'' Assist — %s', v_minute, v_name)
        ));
      ELSIF v_kind = 'yellow' THEN
        v_events := v_events || jsonb_build_array(jsonb_build_object(
          't', v_t, 'type', 'yellow',
          'side', CASE WHEN v_side = v_home THEN 'home' ELSE 'away' END,
          'player', v_name, 'minute', v_minute,
          'text', format('%s'' Yellow — %s', v_minute, v_name)
        ));
      ELSIF v_kind = 'red' THEN
        v_events := v_events || jsonb_build_array(jsonb_build_object(
          't', v_t, 'type', 'red',
          'side', CASE WHEN v_side = v_home THEN 'home' ELSE 'away' END,
          'player', v_name, 'minute', v_minute,
          'text', format('%s'' RED — %s', v_minute, v_name),
          'pressure', 0.7
        ));
      ELSIF v_kind = 'injury' THEN
        v_events := v_events || jsonb_build_array(jsonb_build_object(
          't', v_t, 'type', 'injury',
          'side', CASE WHEN v_side = v_home THEN 'home' ELSE 'away' END,
          'player', v_name, 'minute', v_minute,
          'text', format('%s'' Injury — %s', v_minute, v_name)
        ));
      END IF;
    END LOOP;

    v_events := v_events || jsonb_build_array(
      jsonb_build_object('t', round(v_dur * 0.18, 2), 'type', 'momentum', 'side', 'home', 'pressure', 0.6, 'text', 'Home attack'),
      jsonb_build_object('t', round(v_dur * 0.42, 2), 'type', 'momentum', 'side', 'away', 'pressure', 0.6, 'text', 'Away attack'),
      jsonb_build_object('t', round(v_dur * 0.68, 2), 'type', 'momentum', 'side', 'home', 'pressure', 0.55, 'text', 'Pressure')
    );
  END IF;

  v_events := v_events || jsonb_build_array(jsonb_build_object(
    't', v_dur,
    'type', 'fulltime',
    'side', null,
    'score_home', coalesce(v_final_hg, v_hg),
    'score_away', coalesce(v_final_ag, v_ag),
    'text', format('Full time %s–%s', coalesce(v_final_hg, v_hg), coalesce(v_final_ag, v_ag)),
    'minute', 90
  ));

  SELECT coalesce(jsonb_agg(e.obj ORDER BY (e.obj->>'t')::numeric, e.ord), '[]'::jsonb)
  INTO v_events
  FROM (
    SELECT value AS obj, ordinality AS ord
    FROM jsonb_array_elements(v_events) WITH ORDINALITY
  ) e;

  RETURN jsonb_build_object('duration_sec', v_dur, 'events', v_events);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.match_sim_load_club_side(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.match_sim_build_playback(bigint, int) TO authenticated;

NOTIFY pgrst, 'reload schema';
