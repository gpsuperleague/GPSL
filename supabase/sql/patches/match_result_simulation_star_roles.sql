-- =============================================================================
-- Star impact by position group + must play in natural (profile) position
--   Goal boost   → LWF, RWF, SS, CF
--   Assist boost → LB, RB, CMF, AMF, LMF, RMF
--   Concede cut  → DMF, GK, CB
-- Star boosts only apply when profile Position matches the pitch slot.
-- Run after match_result_simulation_stars_playback.sql
-- =============================================================================

SET lock_timeout = '15s';
SET statement_timeout = '90s';

-- Canonical pitch/profile codes for exact in-position checks
CREATE OR REPLACE FUNCTION public.match_sim_canonical_pos(p_pos text)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE
AS $function$
DECLARE
  v text := upper(coalesce(nullif(btrim(p_pos), ''), ''));
BEGIN
  IF v = '' THEN
    RETURN NULL;
  END IF;

  -- Strip trailing digits from slots like CB1 / CB2
  v := regexp_replace(v, '[0-9]+$', '');

  IF v IN ('GK') THEN RETURN 'GK'; END IF;
  IF v IN ('CB', 'LCB', 'RCB', 'SW') THEN RETURN 'CB'; END IF;
  IF v IN ('DMF', 'CDM') THEN RETURN 'DMF'; END IF;
  IF v IN ('LB', 'LWB') THEN RETURN 'LB'; END IF;
  IF v IN ('RB', 'RWB') THEN RETURN 'RB'; END IF;
  IF v IN ('CMF', 'CM') THEN RETURN 'CMF'; END IF;
  IF v IN ('AMF', 'AM') THEN RETURN 'AMF'; END IF;
  IF v IN ('LMF', 'LM') THEN RETURN 'LMF'; END IF;
  IF v IN ('RMF', 'RM') THEN RETURN 'RMF'; END IF;
  IF v IN ('LWF') THEN RETURN 'LWF'; END IF;
  IF v IN ('RWF') THEN RETURN 'RWF'; END IF;
  IF v IN ('SS') THEN RETURN 'SS'; END IF;
  IF v IN ('CF', 'ST', 'FW') THEN RETURN 'CF'; END IF;

  RETURN NULL;
END;
$function$;

-- True when pitch slot and profile Position are the same canonical role
-- (e.g. CF on CF, CB on LCB/RCB/CB). Empty pitch_slot → treat as natural
-- (auto XI fallback places players by profile).
CREATE OR REPLACE FUNCTION public.match_sim_on_natural_position(
  p_pitch_slot text,
  p_profile_pos text
)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE
    WHEN nullif(btrim(coalesce(p_pitch_slot, '')), '') IS NULL THEN true
    ELSE public.match_sim_canonical_pos(p_pitch_slot)
         IS NOT DISTINCT FROM public.match_sim_canonical_pos(p_profile_pos)
         AND public.match_sim_canonical_pos(p_pitch_slot) IS NOT NULL
  END;
$$;

CREATE OR REPLACE FUNCTION public.match_sim_star_is_finisher(p_role text)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT coalesce(p_role, '') = 'fw';
$$;

CREATE OR REPLACE FUNCTION public.match_sim_star_is_creator(p_role text)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT coalesce(p_role, '') IN ('fb', 'mf');
$$;

CREATE OR REPLACE FUNCTION public.match_sim_star_is_stopper(p_role text)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT coalesce(p_role, '') IN ('gk', 'def', 'dmf');
$$;

CREATE OR REPLACE FUNCTION public.match_sim_side_star_powers(p_side jsonb)
RETURNS jsonb
LANGUAGE sql
STABLE
AS $$
  SELECT jsonb_build_object(
    'def', coalesce(sum(
      CASE WHEN public.match_sim_star_boost_active(
        (e->>'is_star')::boolean,
        coalesce((e->>'on_natural')::boolean, false),
        e->>'role',
        'stop'
      ) THEN public.match_sim_star_quality((e->>'rating')::numeric) ELSE 0 END
    ), 0),
    'create', coalesce(sum(
      CASE WHEN public.match_sim_star_boost_active(
        (e->>'is_star')::boolean,
        coalesce((e->>'on_natural')::boolean, false),
        e->>'role',
        'create'
      ) THEN public.match_sim_star_quality((e->>'rating')::numeric) ELSE 0 END
    ), 0),
    'fin', coalesce(sum(
      CASE WHEN public.match_sim_star_boost_active(
        (e->>'is_star')::boolean,
        coalesce((e->>'on_natural')::boolean, false),
        e->>'role',
        'fin'
      ) THEN public.match_sim_star_quality((e->>'rating')::numeric) ELSE 0 END
    ), 0),
    'total', coalesce(sum(
      CASE
        WHEN coalesce((e->>'is_star')::boolean, false)
             AND coalesce((e->>'on_natural')::boolean, false)
        THEN public.match_sim_star_quality((e->>'rating')::numeric)
        ELSE 0
      END
    ), 0),
    'count', coalesce(count(*) FILTER (
      WHERE coalesce((e->>'is_star')::boolean, false)
        AND coalesce((e->>'on_natural')::boolean, false)
    ), 0)
  )
  FROM jsonb_array_elements(coalesce(p_side, '[]'::jsonb)) e
  WHERE coalesce((e->>'started')::boolean, false);
$$;

CREATE OR REPLACE FUNCTION public.match_sim_star_goal_mult(
  p_is_star boolean,
  p_role text,
  p_rating numeric,
  p_on_natural boolean DEFAULT false
)
RETURNS numeric
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_s jsonb := public.match_sim_settings();
  v_boost numeric := coalesce((v_s->>'star_goal_boost_pct')::numeric, 12) / 100.0;
  v_q numeric;
BEGIN
  IF NOT public.match_sim_star_boost_active(p_is_star, p_on_natural, p_role, 'fin') THEN
    RETURN 1.0;
  END IF;
  v_q := public.match_sim_star_quality(p_rating);
  RETURN 1.0 + v_boost * (0.6 + 0.8 * v_q);
END;
$function$;

CREATE OR REPLACE FUNCTION public.match_sim_star_assist_mult(
  p_is_star boolean,
  p_role text,
  p_rating numeric,
  p_on_natural boolean DEFAULT false
)
RETURNS numeric
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_s jsonb := public.match_sim_settings();
  v_boost numeric := coalesce((v_s->>'star_assist_boost_pct')::numeric, 12) / 100.0;
  v_q numeric;
BEGIN
  IF NOT public.match_sim_star_boost_active(p_is_star, p_on_natural, p_role, 'create') THEN
    RETURN 1.0;
  END IF;
  v_q := public.match_sim_star_quality(p_rating);
  RETURN 1.0 + v_boost * (0.55 + 0.85 * v_q);
END;
$function$;

-- Load XI with profile position + on_natural flag
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
        -- Pitch role drives match play; profile used for natural-position check
        'role', public.match_sim_role_from_slot(sp.pitch_slot, NULL),
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

  v_n := jsonb_array_length(v_rows);

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
          'role', public.match_sim_role_from_slot(NULL, p."Position"),
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
    v_n := jsonb_array_length(v_rows);
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
            public.match_sim_role_from_slot(NULL, p."Position") AS role,
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
              'role', public.match_sim_role_from_slot(NULL, p."Position"),
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

-- Team xG: concede cut from natural stoppers; goal boost from natural finishers
CREATE OR REPLACE FUNCTION public.match_sim_sample_goals(
  p_outcome text,
  p_diff numeric,
  p_home_atk numeric,
  p_away_atk numeric,
  p_home_def numeric,
  p_away_def numeric,
  p_home_star_def numeric,
  p_away_star_def numeric,
  p_home_star_create numeric,
  p_away_star_create numeric,
  p_home_star_fin numeric,
  p_away_star_fin numeric
)
RETURNS int[]
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_s jsonb := public.match_sim_settings();
  v_cut numeric := coalesce((v_s->>'star_concede_cut_pct')::numeric, 10) / 100.0;
  v_boost numeric := coalesce((v_s->>'star_goal_boost_pct')::numeric, 12) / 100.0;
  v_home_xg numeric;
  v_away_xg numeric;
  v_hg int;
  v_ag int;
  v_blowout boolean := abs(coalesce(p_diff, 0)) >= 80;
  v_mod_h numeric := 1.0;
  v_mod_a numeric := 1.0;
  i int;
BEGIN
  v_mod_h := v_mod_h * power(greatest(0.70, 1.0 - v_cut), greatest(coalesce(p_away_star_def, 0), 0));
  v_mod_a := v_mod_a * power(greatest(0.70, 1.0 - v_cut), greatest(coalesce(p_home_star_def, 0), 0));
  v_mod_h := v_mod_h * power(1.0 + v_boost, greatest(coalesce(p_home_star_fin, 0), 0));
  v_mod_a := v_mod_a * power(1.0 + v_boost, greatest(coalesce(p_away_star_fin, 0), 0));
  PERFORM coalesce(p_home_star_create, 0) + coalesce(p_away_star_create, 0);

  v_home_xg := greatest(0.35, least(3.8, (p_home_atk / greatest(p_away_def, 1)) * 1.6)) * v_mod_h;
  v_away_xg := greatest(0.35, least(3.8, (p_away_atk / greatest(p_home_def, 1)) * 1.6)) * v_mod_a;

  IF p_outcome = 'home' THEN
    v_home_xg := greatest(v_home_xg, v_away_xg + 0.55);
    IF v_blowout THEN
      v_home_xg := greatest(v_home_xg, 2.4);
      v_away_xg := least(v_away_xg, 0.9);
    END IF;
  ELSIF p_outcome = 'away' THEN
    v_away_xg := greatest(v_away_xg, v_home_xg + 0.55);
    IF v_blowout THEN
      v_away_xg := greatest(v_away_xg, 2.4);
      v_home_xg := least(v_home_xg, 0.9);
    END IF;
  ELSE
    v_home_xg := (v_home_xg + v_away_xg) / 2.0;
    v_away_xg := v_home_xg;
    v_home_xg := least(v_home_xg, 2.2);
    v_away_xg := least(v_away_xg, 2.2);
  END IF;

  v_hg := 0;
  v_ag := 0;
  FOR i IN 1..6 LOOP
    IF random() < least(0.92, v_home_xg / 6.0) THEN v_hg := v_hg + 1; END IF;
    IF random() < least(0.92, v_away_xg / 6.0) THEN v_ag := v_ag + 1; END IF;
  END LOOP;

  IF p_outcome = 'home' AND v_hg <= v_ag THEN
    v_hg := v_ag + 1 + CASE WHEN v_blowout AND random() < 0.45 THEN 1 ELSE 0 END;
  ELSIF p_outcome = 'away' AND v_ag <= v_hg THEN
    v_ag := v_hg + 1 + CASE WHEN v_blowout AND random() < 0.45 THEN 1 ELSE 0 END;
  ELSIF p_outcome = 'draw' THEN
    v_hg := least(v_hg, 4);
    v_ag := v_hg;
  END IF;

  v_hg := least(v_hg, CASE WHEN v_blowout THEN 6 ELSE 5 END);
  v_ag := least(v_ag, CASE WHEN v_blowout THEN 6 ELSE 5 END);

  RETURN ARRAY[v_hg, v_ag];
END;
$function$;

CREATE OR REPLACE FUNCTION public.match_sim_build_club_stats(
  p_side jsonb,
  p_goals int,
  p_conceded int,
  p_won boolean,
  p_drew boolean,
  p_is_motm_side boolean
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SET search_path = public
AS $function$
DECLARE
  r record;
  v_goal_pool numeric := 0;
  v_assist_pool numeric := 0;
  v_goals_left int := greatest(p_goals, 0);
  v_assists_target int;
  v_assists_left int;
  v_pick text;
  v_roll numeric;
  v_acc numeric;
  v_base numeric;
  v_rating numeric;
  v_best_id text;
  v_best_r numeric := -1;
  v_out jsonb := '[]'::jsonb;
  v_goals_map jsonb := '{}'::jsonb;
  v_assists_map jsonb := '{}'::jsonb;
  v_ratings jsonb := '{}'::jsonb;
  v_id text;
  v_role text;
  v_pr numeric;
  v_started boolean;
BEGIN
  FOR r IN
    SELECT * FROM jsonb_to_recordset(p_side) AS x(
      player_id text, name text, rating numeric, role text,
      pitch_slot text, profile_pos text, on_natural boolean, started boolean, subbed_on boolean, is_star boolean
    )
  LOOP
    IF coalesce(r.started, false) THEN
      v_goal_pool := v_goal_pool
        + public.match_sim_goal_weight(r.role) * (r.rating / 70.0)
        * public.match_sim_star_goal_mult(r.is_star, r.role, r.rating, coalesce(r.on_natural, false));
      v_assist_pool := v_assist_pool
        + public.match_sim_assist_weight(r.role) * (r.rating / 70.0)
        * public.match_sim_star_assist_mult(r.is_star, r.role, r.rating, coalesce(r.on_natural, false));
    END IF;
    v_goals_map := v_goals_map || jsonb_build_object(r.player_id, 0);
    v_assists_map := v_assists_map || jsonb_build_object(r.player_id, 0);
  END LOOP;

  IF v_goal_pool <= 0 THEN
    v_goal_pool := 1;
  END IF;
  IF v_assist_pool <= 0 THEN
    v_assist_pool := 1;
  END IF;

  -- Distribute goals
  WHILE v_goals_left > 0 LOOP
    v_roll := random() * v_goal_pool;
    v_acc := 0;
    v_pick := NULL;
    FOR r IN
      SELECT * FROM jsonb_to_recordset(p_side) AS x(
        player_id text, name text, rating numeric, role text,
        pitch_slot text, profile_pos text, on_natural boolean, started boolean, subbed_on boolean, is_star boolean
      )
      WHERE coalesce(started, false)
    LOOP
      v_acc := v_acc + public.match_sim_goal_weight(r.role) * (r.rating / 70.0)
        * public.match_sim_star_goal_mult(r.is_star, r.role, r.rating, coalesce(r.on_natural, false));
      IF v_roll <= v_acc THEN
        v_pick := r.player_id;
        EXIT;
      END IF;
    END LOOP;
    IF v_pick IS NULL THEN
      SELECT e->>'player_id' INTO v_pick
      FROM jsonb_array_elements(p_side) e
      WHERE coalesce((e->>'started')::boolean, false)
      ORDER BY random()
      LIMIT 1;
    END IF;
    v_goals_map := jsonb_set(
      v_goals_map,
      ARRAY[v_pick],
      to_jsonb(coalesce((v_goals_map->>v_pick)::int, 0) + 1)
    );
    v_goals_left := v_goals_left - 1;
  END LOOP;

  -- Assists: typically a bit fewer than goals
  v_assists_target := CASE
    WHEN p_goals <= 0 THEN 0
    ELSE greatest(0, least(p_goals, floor(p_goals * (0.55 + random() * 0.35))::int))
  END;
  v_assists_left := v_assists_target;
  WHILE v_assists_left > 0 LOOP
    v_roll := random() * v_assist_pool;
    v_acc := 0;
    v_pick := NULL;
    FOR r IN
      SELECT * FROM jsonb_to_recordset(p_side) AS x(
        player_id text, name text, rating numeric, role text,
        pitch_slot text, profile_pos text, on_natural boolean, started boolean, subbed_on boolean, is_star boolean
      )
      WHERE coalesce(started, false)
    LOOP
      v_acc := v_acc + public.match_sim_assist_weight(r.role) * (r.rating / 70.0)
        * public.match_sim_star_assist_mult(r.is_star, r.role, r.rating, coalesce(r.on_natural, false));
      IF v_roll <= v_acc THEN
        v_pick := r.player_id;
        EXIT;
      END IF;
    END LOOP;
    IF v_pick IS NULL THEN
      SELECT e->>'player_id' INTO v_pick
      FROM jsonb_array_elements(p_side) e
      WHERE coalesce((e->>'started')::boolean, false)
      ORDER BY random()
      LIMIT 1;
    END IF;
    v_assists_map := jsonb_set(
      v_assists_map,
      ARRAY[v_pick],
      to_jsonb(coalesce((v_assists_map->>v_pick)::int, 0) + 1)
    );
    v_assists_left := v_assists_left - 1;
  END LOOP;

  -- Ratings: 6.0 base; winners slightly higher; contributions bump; clean sheet bump
  FOR r IN
    SELECT * FROM jsonb_to_recordset(p_side) AS x(
      player_id text, name text, rating numeric, role text,
      pitch_slot text, profile_pos text, on_natural boolean, started boolean, subbed_on boolean, is_star boolean
    )
  LOOP
    v_id := r.player_id;
    v_role := r.role;
    v_pr := coalesce(r.rating, 70);
    v_started := coalesce(r.started, false) OR coalesce(r.subbed_on, false);
    v_base := 6.0;

    IF p_won THEN
      v_base := v_base + 0.35 + (random() * 0.45);
    ELSIF p_drew THEN
      v_base := v_base + (random() * 0.35) - 0.05;
    ELSE
      v_base := v_base - 0.25 + (random() * 0.35);
    END IF;

    -- Ability relative to 75
    v_base := v_base + ((v_pr - 75) / 40.0) * 0.35;

    IF NOT coalesce(r.started, false) AND coalesce(r.subbed_on, false) THEN
      v_base := v_base - 0.15;
    END IF;

    v_base := v_base
      + coalesce((v_goals_map->>v_id)::int, 0) * 0.55
      + coalesce((v_assists_map->>v_id)::int, 0) * 0.35;

    IF p_conceded = 0 AND v_role IN ('gk', 'def', 'fb', 'dmf') AND coalesce(r.started, false) THEN
      v_base := v_base + 0.35 + random() * 0.25;
    END IF;

    IF p_conceded >= 3 AND v_role IN ('gk', 'def') AND coalesce(r.started, false) THEN
      v_base := v_base - 0.35;
    END IF;

    -- Rare highs; clamp
    IF random() < 0.012 AND p_won AND coalesce((v_goals_map->>v_id)::int, 0) >= 2 THEN
      v_base := greatest(v_base, 9.2);
    END IF;

    v_rating := round(greatest(4.5, least(9.7, v_base))::numeric, 1);
    v_ratings := v_ratings || jsonb_build_object(v_id, v_rating);

    IF v_started AND v_rating > v_best_r THEN
      v_best_r := v_rating;
      v_best_id := v_id;
    END IF;
  END LOOP;

  -- Prefer MOTM from winning side; if draw, either side eligible via caller flag
  IF NOT p_is_motm_side THEN
    v_best_id := NULL;
  END IF;

  FOR r IN
    SELECT * FROM jsonb_to_recordset(p_side) AS x(
      player_id text, name text, rating numeric, role text,
      pitch_slot text, profile_pos text, on_natural boolean, started boolean, subbed_on boolean, is_star boolean
    )
  LOOP
    v_out := v_out || jsonb_build_array(
      jsonb_build_object(
        'player_id', r.player_id,
        'started', coalesce(r.started, false),
        'subbed_on', coalesce(r.subbed_on, false) AND NOT coalesce(r.started, false),
        'goals', coalesce((v_goals_map->>r.player_id)::int, 0),
        'assists', coalesce((v_assists_map->>r.player_id)::int, 0),
        'rating', coalesce((v_ratings->>r.player_id)::numeric, 6.0),
        'potm', (v_best_id IS NOT NULL AND r.player_id = v_best_id),
        'yellow_card', false,
        'red_card', false
      )
    );
  END LOOP;

  RETURN v_out;
END;
$function$;

-- Drop old 3-arg mult signatures so only natural-aware versions remain
DROP FUNCTION IF EXISTS public.match_sim_star_goal_mult(boolean, text, numeric);
DROP FUNCTION IF EXISTS public.match_sim_star_assist_mult(boolean, text, numeric);

GRANT EXECUTE ON FUNCTION public.match_sim_canonical_pos(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.match_sim_on_natural_position(text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.match_sim_star_is_finisher(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.match_sim_star_is_creator(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.match_sim_star_is_stopper(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.match_sim_star_boost_active(boolean, boolean, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.match_sim_side_star_powers(jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.match_sim_star_goal_mult(boolean, text, numeric, boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.match_sim_star_assist_mult(boolean, text, numeric, boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.match_sim_load_club_side(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.match_sim_build_club_stats(jsonb, int, int, boolean, boolean, boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.match_sim_sample_goals(
  text, numeric, numeric, numeric, numeric, numeric,
  numeric, numeric, numeric, numeric, numeric, numeric
) TO authenticated;

NOTIFY pgrst, 'reload schema';