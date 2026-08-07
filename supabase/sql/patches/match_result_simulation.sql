-- =============================================================================
-- Match result simulation (test seasons) — toggleable, owner-triggered
--
-- Run in Supabase SQL Editor. Safe re-run.
--
-- Toggle: global_settings.match_result_simulation_enabled (admin RPC)
-- Owner:  competition_simulate_fixture_result(fixture_id)
--         → strength-based score + squad stats + MOTM, auto-finalises result
-- Lock:   fixture.result_sim_lock_* so only one owner can run a fixture
-- =============================================================================

ALTER TABLE public.global_settings
  ADD COLUMN IF NOT EXISTS match_result_simulation_enabled boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN public.global_settings.match_result_simulation_enabled IS
  'When true, club owners see Simulate on fixtures and may auto-finalise results. Off for live seasons.';

ALTER TABLE public.competition_fixtures
  ADD COLUMN IF NOT EXISTS result_sim_lock_club text,
  ADD COLUMN IF NOT EXISTS result_sim_lock_at timestamptz;

COMMENT ON COLUMN public.competition_fixtures.result_sim_lock_club IS
  'Club currently simulating this fixture (blocks opponent overwrite).';
COMMENT ON COLUMN public.competition_fixtures.result_sim_lock_at IS
  'When simulation lock was taken.';

-- ---------------------------------------------------------------------------
-- Admin toggle
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_set_match_result_simulation_enabled(p_enabled boolean)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  UPDATE public.global_settings
  SET match_result_simulation_enabled = coalesce(p_enabled, false),
      updated_at = now()
  WHERE id = 1;

  RETURN jsonb_build_object(
    'ok', true,
    'match_result_simulation_enabled', coalesce(p_enabled, false)
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.match_result_simulation_enabled()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT coalesce(
    (SELECT g.match_result_simulation_enabled FROM public.global_settings g WHERE g.id = 1),
    false
  );
$$;

CREATE OR REPLACE FUNCTION public.match_result_simulation_status()
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT jsonb_build_object(
    'enabled', public.match_result_simulation_enabled(),
    'is_admin', public.is_gpsl_admin()
  );
$$;

GRANT EXECUTE ON FUNCTION public.admin_set_match_result_simulation_enabled(boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.match_result_simulation_enabled() TO authenticated;
GRANT EXECUTE ON FUNCTION public.match_result_simulation_status() TO authenticated;

-- ---------------------------------------------------------------------------
-- Role helpers
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.match_sim_role_from_slot(
  p_pitch_slot text,
  p_player_position text DEFAULT NULL
)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE
AS $function$
DECLARE
  v_slot text := upper(coalesce(nullif(btrim(p_pitch_slot), ''), ''));
  v_pos text := upper(coalesce(nullif(btrim(p_player_position), ''), ''));
BEGIN
  IF v_slot IN ('GK') OR v_pos IN ('GK') THEN
    RETURN 'gk';
  END IF;
  IF v_slot IN ('LB', 'RB', 'LWB', 'RWB') OR v_pos IN ('LB', 'RB', 'LWB', 'RWB') THEN
    RETURN 'fb';
  END IF;
  IF v_slot LIKE 'CB%' OR v_slot IN ('LCB', 'RCB', 'SW')
     OR v_pos IN ('CB', 'LCB', 'RCB', 'SW') THEN
    RETURN 'def';
  END IF;
  IF v_slot IN ('DMF', 'CDM') OR v_pos IN ('DMF', 'CDM') THEN
    RETURN 'dmf';
  END IF;
  IF v_slot IN ('CF', 'SS', 'LWF', 'RWF', 'ST')
     OR v_pos IN ('CF', 'SS', 'LWF', 'RWF', 'ST', 'FW') THEN
    RETURN 'fw';
  END IF;
  IF v_slot IN ('CMF', 'AMF', 'LMF', 'RMF', 'CM', 'AM', 'LM', 'RM')
     OR v_pos IN ('CMF', 'AMF', 'LMF', 'RMF', 'CM', 'AM', 'LM', 'RM', 'MF') THEN
    RETURN 'mf';
  END IF;
  -- Fallback from generic position letter
  IF left(v_pos, 1) = 'G' THEN RETURN 'gk'; END IF;
  IF left(v_pos, 1) = 'D' THEN RETURN 'def'; END IF;
  IF left(v_pos, 1) = 'M' THEN RETURN 'mf'; END IF;
  IF left(v_pos, 1) IN ('F', 'S', 'W', 'C') THEN RETURN 'fw'; END IF;
  RETURN 'mf';
END;
$function$;

CREATE OR REPLACE FUNCTION public.match_sim_goal_weight(p_role text)
RETURNS numeric
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE coalesce(p_role, 'mf')
    WHEN 'gk' THEN 0.01
    WHEN 'def' THEN 0.10
    WHEN 'fb' THEN 0.12
    WHEN 'dmf' THEN 0.12
    WHEN 'mf' THEN 0.29
    WHEN 'fw' THEN 0.60
    ELSE 0.20
  END;
$$;

CREATE OR REPLACE FUNCTION public.match_sim_assist_weight(p_role text)
RETURNS numeric
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE coalesce(p_role, 'mf')
    WHEN 'gk' THEN 0.01
    WHEN 'def' THEN 0.10
    WHEN 'fb' THEN 0.22
    WHEN 'dmf' THEN 0.18
    WHEN 'mf' THEN 0.40  -- creative midfielders drive assists
    WHEN 'fw' THEN 0.28
    ELSE 0.20
  END;
$$;

CREATE OR REPLACE FUNCTION public.match_sim_is_star(p_rating numeric)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_min numeric;
BEGIN
  SELECT coalesce(g.star_tax_min_rating, 70)::numeric
  INTO v_min
  FROM public.global_settings g
  WHERE g.id = 1;
  RETURN coalesce(p_rating, 0) >= coalesce(v_min, 70);
EXCEPTION WHEN OTHERS THEN
  RETURN coalesce(p_rating, 0) >= 70;
END;
$function$;

-- Players."Rating" is text in GPDB — never coalesce(text, int).
CREATE OR REPLACE FUNCTION public.match_sim_player_rating_num(
  p_rating text,
  p_default numeric DEFAULT 70
)
RETURNS numeric
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT coalesce(
    nullif(
      regexp_replace(coalesce(btrim(p_rating), ''), '[^0-9.]', '', 'g'),
      ''
    )::numeric,
    p_default
  );
$$;

-- ---------------------------------------------------------------------------
-- Load XI (+ up to 5 bench) from matchday squad, else top contracted by Rating
-- ---------------------------------------------------------------------------
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
BEGIN
  SELECT coalesce(
    jsonb_agg(
      jsonb_build_object(
        'player_id', sp.player_id,
        'name', p."Name",
        'rating', public.match_sim_player_rating_num(p."Rating"::text, 70),
        'role', public.match_sim_role_from_slot(sp.pitch_slot, p."Position"),
        'pitch_slot', sp.pitch_slot,
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

  -- Bench: matchday bench first, else next highest ratings
  -- Matchday may list up to 12; only 5 may be marked Subbed on for result submit.
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
        WHERE b.ord <= 5
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
        WHERE y.ord <= 5
      ),
      '[]'::jsonb
    )
    INTO v_rows;
  END IF;

  RETURN v_rows;
END;
$function$;

CREATE OR REPLACE FUNCTION public.match_sim_side_strength(p_side jsonb)
RETURNS numeric
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT coalesce(sum((e->>'rating')::numeric), 0)
  FROM jsonb_array_elements(p_side) e
  WHERE coalesce((e->>'started')::boolean, false);
$$;

CREATE OR REPLACE FUNCTION public.match_sim_side_attack(p_side jsonb)
RETURNS numeric
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT coalesce(sum((e->>'rating')::numeric * public.match_sim_goal_weight(e->>'role')), 0)
  FROM jsonb_array_elements(p_side) e
  WHERE coalesce((e->>'started')::boolean, false);
$$;

CREATE OR REPLACE FUNCTION public.match_sim_side_defence(p_side jsonb)
RETURNS numeric
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT coalesce(
    sum(
      (e->>'rating')::numeric * CASE e->>'role'
        WHEN 'gk' THEN 1.4
        WHEN 'def' THEN 1.2
        WHEN 'fb' THEN 1.0
        WHEN 'dmf' THEN 1.1
        ELSE 0.35
      END
    ),
    0
  )
  FROM jsonb_array_elements(p_side) e
  WHERE coalesce((e->>'started')::boolean, false);
$$;

-- ---------------------------------------------------------------------------
-- Outcome + score
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.match_sim_pick_outcome(p_home_str numeric, p_away_str numeric)
RETURNS text
LANGUAGE plpgsql
VOLATILE
AS $function$
DECLARE
  v_diff numeric := coalesce(p_home_str, 0) - coalesce(p_away_str, 0);
  v_abs numeric := abs(v_diff);
  v_roll numeric := random();
  v_home_fav boolean := v_diff >= 0;
BEGIN
  IF v_abs >= 100 THEN
    RETURN CASE WHEN v_home_fav THEN 'home' ELSE 'away' END;
  END IF;

  IF v_abs >= 50 THEN
    -- stronger 60%, draw 20%, upset 20%
    IF v_roll < 0.60 THEN
      RETURN CASE WHEN v_home_fav THEN 'home' ELSE 'away' END;
    ELSIF v_roll < 0.80 THEN
      RETURN 'draw';
    ELSE
      RETURN CASE WHEN v_home_fav THEN 'away' ELSE 'home' END;
    END IF;
  END IF;

  -- 0–49: draw 60%, each side 20%
  IF v_roll < 0.20 THEN
    RETURN 'home';
  ELSIF v_roll < 0.40 THEN
    RETURN 'away';
  ELSE
    RETURN 'draw';
  END IF;
END;
$function$;

CREATE OR REPLACE FUNCTION public.match_sim_sample_goals(
  p_outcome text,
  p_diff numeric,
  p_home_atk numeric,
  p_away_atk numeric,
  p_home_def numeric,
  p_away_def numeric,
  p_home_star_def int,
  p_away_star_def int,
  p_home_star_create int,
  p_away_star_create int,
  p_home_star_fin int,
  p_away_star_fin int
)
RETURNS int[]  -- {home_goals, away_goals}
LANGUAGE plpgsql
VOLATILE
AS $function$
DECLARE
  v_home_xg numeric;
  v_away_xg numeric;
  v_hg int;
  v_ag int;
  v_blowout boolean := abs(coalesce(p_diff, 0)) >= 100;
  v_mod_h numeric := 1.0;
  v_mod_a numeric := 1.0;
  i int;
BEGIN
  -- Star factor (~10% each): defensive stars suppress opp xG; creators/finishers boost own
  v_mod_h := v_mod_h * power(0.90, greatest(p_away_star_def, 0));
  v_mod_a := v_mod_a * power(0.90, greatest(p_home_star_def, 0));
  v_mod_h := v_mod_h * power(1.10, greatest(p_home_star_create + p_home_star_fin, 0) * 0.5);
  v_mod_a := v_mod_a * power(1.10, greatest(p_away_star_create + p_away_star_fin, 0) * 0.5);

  -- Baseline xG from attack vs defence
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
    -- draws: pull toward each other
    v_home_xg := (v_home_xg + v_away_xg) / 2.0;
    v_away_xg := v_home_xg;
    v_home_xg := least(v_home_xg, 2.2);
    v_away_xg := least(v_away_xg, 2.2);
  END IF;

  -- Simple Poisson-ish sample via Bernoulli trials on half-xg buckets
  v_hg := 0;
  v_ag := 0;
  FOR i IN 1..6 LOOP
    IF random() < least(0.92, v_home_xg / 6.0) THEN v_hg := v_hg + 1; END IF;
    IF random() < least(0.92, v_away_xg / 6.0) THEN v_ag := v_ag + 1; END IF;
  END LOOP;

  -- Enforce outcome
  IF p_outcome = 'home' AND v_hg <= v_ag THEN
    v_hg := v_ag + 1 + CASE WHEN v_blowout AND random() < 0.45 THEN 1 ELSE 0 END;
  ELSIF p_outcome = 'away' AND v_ag <= v_hg THEN
    v_ag := v_hg + 1 + CASE WHEN v_blowout AND random() < 0.45 THEN 1 ELSE 0 END;
  ELSIF p_outcome = 'draw' THEN
    v_hg := least(v_hg, 4);
    v_ag := v_hg;
  END IF;

  -- Cap craziness
  v_hg := least(v_hg, CASE WHEN v_blowout THEN 6 ELSE 5 END);
  v_ag := least(v_ag, CASE WHEN v_blowout THEN 6 ELSE 5 END);

  RETURN ARRAY[v_hg, v_ag];
END;
$function$;

-- ---------------------------------------------------------------------------
-- Build player stats JSON for one club
-- ---------------------------------------------------------------------------
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
      pitch_slot text, started boolean, subbed_on boolean, is_star boolean
    )
  LOOP
    IF coalesce(r.started, false) THEN
      v_goal_pool := v_goal_pool
        + public.match_sim_goal_weight(r.role) * (r.rating / 70.0)
        * CASE WHEN r.is_star AND r.role = 'fw' THEN 1.15 ELSE 1.0 END;
      v_assist_pool := v_assist_pool
        + public.match_sim_assist_weight(r.role) * (r.rating / 70.0)
        * CASE WHEN r.is_star AND r.role IN ('mf', 'fb') THEN 1.12 ELSE 1.0 END;
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
        pitch_slot text, started boolean, subbed_on boolean, is_star boolean
      )
      WHERE coalesce(started, false)
    LOOP
      v_acc := v_acc + public.match_sim_goal_weight(r.role) * (r.rating / 70.0)
        * CASE WHEN r.is_star AND r.role = 'fw' THEN 1.15 ELSE 1.0 END;
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
        pitch_slot text, started boolean, subbed_on boolean, is_star boolean
      )
      WHERE coalesce(started, false)
    LOOP
      v_acc := v_acc + public.match_sim_assist_weight(r.role) * (r.rating / 70.0)
        * CASE WHEN r.is_star AND r.role IN ('mf', 'fb') THEN 1.12 ELSE 1.0 END;
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
      pitch_slot text, started boolean, subbed_on boolean, is_star boolean
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
      pitch_slot text, started boolean, subbed_on boolean, is_star boolean
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

-- ---------------------------------------------------------------------------
-- Main owner RPC
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.competition_simulate_fixture_result(p_fixture_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
SET statement_timeout = '15s'
AS $function$
DECLARE
  v_club text := public.my_club_shortname();
  v_fixture public.competition_fixtures;
  v_home jsonb;
  v_away jsonb;
  v_home_str numeric;
  v_away_str numeric;
  v_diff numeric;
  v_outcome text;
  v_score int[];
  v_hg int;
  v_ag int;
  v_home_stats jsonb;
  v_away_stats jsonb;
  v_home_won boolean;
  v_away_won boolean;
  v_draw boolean;
  v_motm_home boolean;
  v_home_star_def int;
  v_away_star_def int;
  v_home_star_create int;
  v_away_star_create int;
  v_home_star_fin int;
  v_away_star_fin int;
  v_home_name text;
  v_away_name text;
BEGIN
  IF NOT public.match_result_simulation_enabled() THEN
    RAISE EXCEPTION 'Match result simulation is disabled';
  END IF;

  IF v_club IS NULL OR v_club = '' THEN
    RAISE EXCEPTION 'No club linked to this account';
  END IF;

  SELECT * INTO v_fixture
  FROM public.competition_fixtures f
  WHERE f.id = p_fixture_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Fixture not found';
  END IF;

  IF v_club NOT IN (v_fixture.home_club_short_name, v_fixture.away_club_short_name) THEN
    RAISE EXCEPTION 'Your club is not in this fixture';
  END IF;

  IF v_fixture.status <> 'scheduled' THEN
    RAISE EXCEPTION 'Fixture is not open for simulation (status=%)', v_fixture.status;
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.competition_result_submissions s
    WHERE s.fixture_id = p_fixture_id AND s.status = 'pending'
  ) THEN
    RAISE EXCEPTION 'A result is already awaiting confirmation for this fixture';
  END IF;

  -- Lock: if another club holds a fresh lock, block
  IF v_fixture.result_sim_lock_club IS NOT NULL
     AND v_fixture.result_sim_lock_club IS DISTINCT FROM v_club
     AND v_fixture.result_sim_lock_at IS NOT NULL
     AND v_fixture.result_sim_lock_at > now() - interval '30 seconds' THEN
    RAISE EXCEPTION
      'Opponent is already simulating this fixture — wait a moment or refresh';
  END IF;

  UPDATE public.competition_fixtures
  SET result_sim_lock_club = v_club,
      result_sim_lock_at = now()
  WHERE id = p_fixture_id;

  v_home := public.match_sim_load_club_side(v_fixture.home_club_short_name);
  v_away := public.match_sim_load_club_side(v_fixture.away_club_short_name);

  v_home_str := public.match_sim_side_strength(v_home);
  v_away_str := public.match_sim_side_strength(v_away);
  v_diff := v_home_str - v_away_str;

  SELECT
    count(*) FILTER (
      WHERE coalesce((e->>'is_star')::boolean, false)
        AND (e->>'role') IN ('gk', 'def', 'dmf')
        AND coalesce((e->>'started')::boolean, false)
    ),
    count(*) FILTER (
      WHERE coalesce((e->>'is_star')::boolean, false)
        AND (e->>'role') IN ('fb', 'mf')
        AND coalesce((e->>'started')::boolean, false)
    ),
    count(*) FILTER (
      WHERE coalesce((e->>'is_star')::boolean, false)
        AND (e->>'role') = 'fw'
        AND coalesce((e->>'started')::boolean, false)
    )
  INTO v_home_star_def, v_home_star_create, v_home_star_fin
  FROM jsonb_array_elements(v_home) e;

  SELECT
    count(*) FILTER (
      WHERE coalesce((e->>'is_star')::boolean, false)
        AND (e->>'role') IN ('gk', 'def', 'dmf')
        AND coalesce((e->>'started')::boolean, false)
    ),
    count(*) FILTER (
      WHERE coalesce((e->>'is_star')::boolean, false)
        AND (e->>'role') IN ('fb', 'mf')
        AND coalesce((e->>'started')::boolean, false)
    ),
    count(*) FILTER (
      WHERE coalesce((e->>'is_star')::boolean, false)
        AND (e->>'role') = 'fw'
        AND coalesce((e->>'started')::boolean, false)
    )
  INTO v_away_star_def, v_away_star_create, v_away_star_fin
  FROM jsonb_array_elements(v_away) e;

  v_outcome := public.match_sim_pick_outcome(v_home_str, v_away_str);
  v_score := public.match_sim_sample_goals(
    v_outcome,
    v_diff,
    public.match_sim_side_attack(v_home),
    public.match_sim_side_attack(v_away),
    public.match_sim_side_defence(v_home),
    public.match_sim_side_defence(v_away),
    v_home_star_def,
    v_away_star_def,
    v_home_star_create,
    v_away_star_create,
    v_home_star_fin,
    v_away_star_fin
  );
  v_hg := v_score[1];
  v_ag := v_score[2];

  v_home_won := v_hg > v_ag;
  v_away_won := v_ag > v_hg;
  v_draw := v_hg = v_ag;
  v_motm_home := CASE
    WHEN v_home_won THEN true
    WHEN v_away_won THEN false
    ELSE random() < 0.5
  END;

  v_home_stats := public.match_sim_build_club_stats(
    v_home, v_hg, v_ag, v_home_won, v_draw, v_motm_home
  );
  v_away_stats := public.match_sim_build_club_stats(
    v_away, v_ag, v_hg, v_away_won, v_draw, NOT v_motm_home
  );

  -- Cancel any stale pending inbox
  UPDATE public.competition_result_submissions
  SET status = 'rejected',
      reject_reason = 'Superseded by match simulation',
      responded_at = now()
  WHERE fixture_id = p_fixture_id
    AND status = 'pending';

  UPDATE public.competition_inbox
  SET read_at = coalesce(read_at, now())
  WHERE fixture_id = p_fixture_id
    AND message_type = 'result_to_confirm';

  UPDATE public.competition_fixtures
  SET home_goals = v_hg::smallint,
      away_goals = v_ag::smallint,
      status = 'played',
      result_sim_lock_club = NULL,
      result_sim_lock_at = NULL
  WHERE id = p_fixture_id;

  PERFORM public.competition_apply_club_player_stats(
    v_fixture.id,
    v_fixture.season_id,
    v_fixture.home_club_short_name,
    v_home_stats,
    v_hg
  );
  PERFORM public.competition_apply_club_player_stats(
    v_fixture.id,
    v_fixture.season_id,
    v_fixture.away_club_short_name,
    v_away_stats,
    v_ag
  );

  BEGIN
    PERFORM public.competition_settle_fixture_gates(p_fixture_id);
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;

  IF v_fixture.competition_type = 'league' THEN
    BEGIN
      PERFORM public.competition_try_pay_league_division_prizes(
        v_fixture.season_id,
        v_fixture.division
      );
    EXCEPTION WHEN OTHERS THEN
      NULL;
    END;
  ELSIF v_fixture.competition_type = 'cup' THEN
    BEGIN
      PERFORM public.competition_cup_on_fixture_played(p_fixture_id);
    EXCEPTION WHEN OTHERS THEN
      NULL;
    END;
  END IF;

  SELECT "Club" INTO v_home_name FROM public."Clubs" WHERE "ShortName" = v_fixture.home_club_short_name;
  SELECT "Club" INTO v_away_name FROM public."Clubs" WHERE "ShortName" = v_fixture.away_club_short_name;

  -- Notify opponent
  PERFORM public.competition_inbox_notify(
    CASE
      WHEN v_club = v_fixture.home_club_short_name THEN v_fixture.away_club_short_name
      ELSE v_fixture.home_club_short_name
    END,
    'result_confirmed',
    p_fixture_id,
    NULL,
    format('Simulated result: %s vs %s', coalesce(v_home_name, 'Home'), coalesce(v_away_name, 'Away')),
    format(
      'Matchday %s — %s simulated the result %s–%s (XI strength %s vs %s).',
      v_fixture.matchday,
      v_club,
      v_hg,
      v_ag,
      round(v_home_str)::text,
      round(v_away_str)::text
    )
  );

  RETURN jsonb_build_object(
    'ok', true,
    'fixture_id', p_fixture_id,
    'home_club', v_fixture.home_club_short_name,
    'away_club', v_fixture.away_club_short_name,
    'home_goals', v_hg,
    'away_goals', v_ag,
    'outcome', v_outcome,
    'home_xi_strength', round(v_home_str, 1),
    'away_xi_strength', round(v_away_str, 1),
    'strength_diff', round(v_diff, 1),
    'simulated_by', v_club
  );
EXCEPTION
  WHEN OTHERS THEN
    UPDATE public.competition_fixtures
    SET result_sim_lock_club = NULL,
        result_sim_lock_at = NULL
    WHERE id = p_fixture_id
      AND result_sim_lock_club = v_club;
    RAISE;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_simulate_fixture_result(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.match_sim_load_club_side(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.match_sim_player_rating_num(text, numeric) TO authenticated;

NOTIFY pgrst, 'reload schema';
