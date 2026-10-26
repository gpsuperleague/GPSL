-- =============================================================================
-- Match fitness levels (per player) → weight injury victim pick
--
-- Levels 1–5 (Fully Fit → Injury Risk). Climb with consecutive league/cup
-- appearances; 1 match rested (club played, player did not appear) drops one
-- level. Matches-to-max-level default 4 (adjustable). Returning from injury
-- starts at level 2.
--
-- Club hit chance unchanged (secret injury_risk + medical). Only who gets
-- injured among appearers is weighted.
--
-- Also: max_total already admin-adjustable; expose fitness settings alongside.
-- Safe re-run.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Settings
-- ---------------------------------------------------------------------------
ALTER TABLE public.competition_injury_settings
  ADD COLUMN IF NOT EXISTS fitness_matches_to_max int NOT NULL DEFAULT 4,
  ADD COLUMN IF NOT EXISTS fitness_weight_l1 numeric(6,3) NOT NULL DEFAULT 0.500,
  ADD COLUMN IF NOT EXISTS fitness_weight_l2 numeric(6,3) NOT NULL DEFAULT 0.750,
  ADD COLUMN IF NOT EXISTS fitness_weight_l3 numeric(6,3) NOT NULL DEFAULT 1.000,
  ADD COLUMN IF NOT EXISTS fitness_weight_l4 numeric(6,3) NOT NULL DEFAULT 1.400,
  ADD COLUMN IF NOT EXISTS fitness_weight_l5 numeric(6,3) NOT NULL DEFAULT 1.850,
  ADD COLUMN IF NOT EXISTS fitness_return_level int NOT NULL DEFAULT 2;

UPDATE public.competition_injury_settings
SET fitness_matches_to_max = coalesce(fitness_matches_to_max, 4),
    fitness_weight_l1 = coalesce(fitness_weight_l1, 0.500),
    fitness_weight_l2 = coalesce(fitness_weight_l2, 0.750),
    fitness_weight_l3 = coalesce(fitness_weight_l3, 1.000),
    fitness_weight_l4 = coalesce(fitness_weight_l4, 1.400),
    fitness_weight_l5 = coalesce(fitness_weight_l5, 1.850),
    fitness_return_level = coalesce(fitness_return_level, 2)
WHERE id = 1;

COMMENT ON COLUMN public.competition_injury_settings.fitness_matches_to_max IS
  'Consecutive league/cup appearances to reach fitness level 5 (Injury Risk). Default 4.';
COMMENT ON COLUMN public.competition_injury_settings.max_total IS
  'Max injuries per club per season (all severities). Admin adjustable.';

-- ---------------------------------------------------------------------------
-- Per-player season fitness
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.competition_player_match_fitness (
  season_id bigint NOT NULL REFERENCES public.competition_seasons (id) ON DELETE CASCADE,
  player_id text NOT NULL,
  club_short_name text NOT NULL,
  consecutive_appearances int NOT NULL DEFAULT 0 CHECK (consecutive_appearances >= 0),
  fitness_level smallint NOT NULL DEFAULT 1 CHECK (fitness_level BETWEEN 1 AND 5),
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (season_id, player_id)
);

CREATE INDEX IF NOT EXISTS competition_player_match_fitness_club_idx
  ON public.competition_player_match_fitness (season_id, club_short_name);

ALTER TABLE public.competition_player_match_fitness ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS competition_player_match_fitness_select ON public.competition_player_match_fitness;
CREATE POLICY competition_player_match_fitness_select
  ON public.competition_player_match_fitness
  FOR SELECT TO authenticated
  USING (true);

GRANT SELECT ON public.competition_player_match_fitness TO authenticated;

CREATE TABLE IF NOT EXISTS public.competition_fixture_match_fitness_tick (
  fixture_id bigint NOT NULL,
  club_short_name text NOT NULL,
  ticked_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (fixture_id, club_short_name)
);

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.competition_match_fitness_level_from_streak(
  p_streak int,
  p_to_max int DEFAULT 4
)
RETURNS int
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE
    WHEN coalesce(p_streak, 0) <= 0 THEN 1
    ELSE least(
      5,
      1 + ceil(
        p_streak::numeric * 4 / greatest(coalesce(p_to_max, 4), 1)
      )::int
    )
  END;
$$;

CREATE OR REPLACE FUNCTION public.competition_match_fitness_streak_for_level(
  p_level int,
  p_to_max int DEFAULT 4
)
RETURNS int
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE
    WHEN coalesce(p_level, 1) <= 1 THEN 0
    WHEN p_level >= 5 THEN greatest(coalesce(p_to_max, 4), 1)
    ELSE greatest(
      1,
      ceil(
        (p_level - 1)::numeric * greatest(coalesce(p_to_max, 4), 1) / 4.0
      )::int
    )
  END;
$$;

CREATE OR REPLACE FUNCTION public.competition_match_fitness_label(p_level int)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE greatest(1, least(5, coalesce(p_level, 1)))
    WHEN 1 THEN 'Fully Fit'
    WHEN 2 THEN 'Match Ready'
    WHEN 3 THEN 'Managing Load'
    WHEN 4 THEN 'Fitness Concern'
    ELSE 'Injury Risk'
  END;
$$;

CREATE OR REPLACE FUNCTION public.competition_match_fitness_weight(
  p_level int,
  p_settings public.competition_injury_settings DEFAULT NULL
)
RETURNS numeric
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_s public.competition_injury_settings;
  v_lvl int := greatest(1, least(5, coalesce(p_level, 1)));
BEGIN
  v_s := coalesce(p_settings, public.competition_injury_settings_row());
  RETURN CASE v_lvl
    WHEN 1 THEN coalesce(v_s.fitness_weight_l1, 0.5)
    WHEN 2 THEN coalesce(v_s.fitness_weight_l2, 0.75)
    WHEN 3 THEN coalesce(v_s.fitness_weight_l3, 1.0)
    WHEN 4 THEN coalesce(v_s.fitness_weight_l4, 1.4)
    ELSE coalesce(v_s.fitness_weight_l5, 1.85)
  END;
END;
$function$;

CREATE OR REPLACE FUNCTION public.competition_match_fitness_ensure(
  p_season_id bigint,
  p_player_id text,
  p_club text,
  p_level int DEFAULT 1,
  p_streak int DEFAULT 0
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  INSERT INTO public.competition_player_match_fitness AS f (
    season_id, player_id, club_short_name,
    consecutive_appearances, fitness_level, updated_at
  ) VALUES (
    p_season_id,
    p_player_id,
    upper(btrim(p_club)),
    greatest(coalesce(p_streak, 0), 0),
    greatest(1, least(5, coalesce(p_level, 1))),
    now()
  )
  ON CONFLICT (season_id, player_id) DO UPDATE
  SET club_short_name = excluded.club_short_name,
      consecutive_appearances = excluded.consecutive_appearances,
      fitness_level = excluded.fitness_level,
      updated_at = now();
END;
$function$;

CREATE OR REPLACE FUNCTION public.competition_match_fitness_set_return_level(
  p_season_id bigint,
  p_player_id text,
  p_club text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_s public.competition_injury_settings := public.competition_injury_settings_row();
  v_lvl int := greatest(1, least(5, coalesce(v_s.fitness_return_level, 2)));
  v_streak int;
BEGIN
  v_streak := public.competition_match_fitness_streak_for_level(
    v_lvl, coalesce(v_s.fitness_matches_to_max, 4)
  );
  PERFORM public.competition_match_fitness_ensure(
    p_season_id, p_player_id, p_club, v_lvl, v_streak
  );
END;
$function$;

-- ---------------------------------------------------------------------------
-- Tick after a played league/cup fixture
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.competition_match_fitness_tick_club(
  p_fixture_id bigint,
  p_club text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_fixture public.competition_fixtures%rowtype;
  v_club text := upper(btrim(coalesce(p_club, '')));
  v_s public.competition_injury_settings;
  v_to_max int;
  v_appeared text[];
  v_pid text;
  v_streak int;
  v_level int;
  v_n_up int := 0;
  v_n_down int := 0;
  v_n_skip int := 0;
  v_inserted int := 0;
BEGIN
  IF v_club = '' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_club');
  END IF;

  SELECT * INTO v_fixture FROM public.competition_fixtures WHERE id = p_fixture_id;
  IF NOT FOUND OR v_fixture.status <> 'played' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_played');
  END IF;

  IF coalesce(v_fixture.competition_type, 'league') NOT IN ('league', 'cup') THEN
    RETURN jsonb_build_object('ok', true, 'skipped', true, 'reason', 'not_league_cup');
  END IF;

  IF to_regprocedure('public.competition_injury_is_preseason_month(text)') IS NOT NULL
     AND public.competition_injury_is_preseason_month(v_fixture.gpsl_month) THEN
    RETURN jsonb_build_object('ok', true, 'skipped', true, 'reason', 'preseason');
  END IF;

  INSERT INTO public.competition_fixture_match_fitness_tick (fixture_id, club_short_name)
  VALUES (p_fixture_id, v_club)
  ON CONFLICT DO NOTHING;
  GET DIAGNOSTICS v_inserted = ROW_COUNT;
  IF v_inserted = 0 THEN
    RETURN jsonb_build_object('ok', true, 'deduped', true);
  END IF;

  v_s := public.competition_injury_settings_row();
  v_to_max := greatest(coalesce(v_s.fitness_matches_to_max, 4), 1);

  SELECT coalesce(array_agg(m.player_id), ARRAY[]::text[])
  INTO v_appeared
  FROM public.competition_match_player_stats m
  WHERE m.fixture_id = p_fixture_id
    AND upper(btrim(m.club_short_name)) = v_club
    AND m.appeared = true;

  FOR v_pid IN
    SELECT DISTINCT x.pid
    FROM (
      SELECT p."Konami_ID"::text AS pid
      FROM public."Players" p
      WHERE upper(btrim(coalesce(p."Contracted_Team", ''))) = v_club
      UNION
      SELECT unnest(v_appeared)
    ) x
    WHERE nullif(btrim(x.pid), '') IS NOT NULL
  LOOP
    IF EXISTS (
      SELECT 1
      FROM public.competition_player_injuries i
      WHERE i.player_id = v_pid
        AND i.status = 'active'
        AND coalesce(i.matches_out_remaining, 0) > 0
    ) THEN
      v_n_skip := v_n_skip + 1;
      CONTINUE;
    END IF;

    SELECT f.consecutive_appearances, f.fitness_level
    INTO v_streak, v_level
    FROM public.competition_player_match_fitness f
    WHERE f.season_id = v_fixture.season_id AND f.player_id = v_pid;

    v_streak := coalesce(v_streak, 0);
    v_level := coalesce(v_level, 1);

    IF v_pid = ANY (v_appeared) THEN
      v_streak := v_streak + 1;
      v_level := public.competition_match_fitness_level_from_streak(v_streak, v_to_max);
      v_n_up := v_n_up + 1;
    ELSE
      v_level := greatest(1, v_level - 1);
      v_streak := public.competition_match_fitness_streak_for_level(v_level, v_to_max);
      v_n_down := v_n_down + 1;
    END IF;

    PERFORM public.competition_match_fitness_ensure(
      v_fixture.season_id, v_pid, v_club, v_level, v_streak
    );
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true,
    'club', v_club,
    'climbed', v_n_up,
    'dropped', v_n_down,
    'frozen_out', v_n_skip
  );
END;
$function$;

-- ---------------------------------------------------------------------------
-- Serve injuries: recover → return fitness → tick fitness → roll
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.competition_serve_injuries_for_fixture(
  p_fixture_id bigint
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_row record;
  v_fixture public.competition_fixtures%rowtype;
  v_rec record;
BEGIN
  SELECT * INTO v_fixture FROM public.competition_fixtures WHERE id = p_fixture_id;

  FOR v_row IN
    SELECT iff.id, iff.injury_id, iff.phase
    FROM public.competition_player_injury_fixtures iff
    WHERE iff.fixture_id = p_fixture_id
      AND iff.served = false
  LOOP
    UPDATE public.competition_player_injury_fixtures
    SET served = true
    WHERE id = v_row.id;

    IF v_row.phase = 'out' THEN
      UPDATE public.competition_player_injuries
      SET matches_out_remaining = greatest(coalesce(matches_out_remaining, 1) - 1, 0)
      WHERE id = v_row.injury_id;
    ELSE
      UPDATE public.competition_player_injuries
      SET recovery_remaining = greatest(coalesce(recovery_remaining, 1) - 1, 0)
      WHERE id = v_row.injury_id;
    END IF;
  END LOOP;

  FOR v_rec IN
    SELECT i.id, i.player_id, i.club_short_name, i.season_id
    FROM public.competition_player_injuries i
    WHERE i.status = 'active'
      AND coalesce(i.matches_out_remaining, 0) <= 0
      AND coalesce(i.recovery_remaining, 0) <= 0
      AND EXISTS (
        SELECT 1 FROM public.competition_player_injury_fixtures iff
        WHERE iff.injury_id = i.id
      )
      AND NOT EXISTS (
        SELECT 1 FROM public.competition_player_injury_fixtures iff
        WHERE iff.injury_id = i.id AND iff.served = false
      )
  LOOP
    UPDATE public.competition_player_injuries
    SET status = 'recovered',
        recovered_at = coalesce(recovered_at, now())
    WHERE id = v_rec.id
      AND status = 'active';

    IF FOUND THEN
      PERFORM public.competition_match_fitness_set_return_level(
        coalesce(v_rec.season_id, v_fixture.season_id),
        v_rec.player_id,
        v_rec.club_short_name
      );
    END IF;
  END LOOP;

  IF v_fixture.id IS NOT NULL THEN
    PERFORM public.competition_match_fitness_tick_club(
      p_fixture_id, v_fixture.home_club_short_name
    );
    PERFORM public.competition_match_fitness_tick_club(
      p_fixture_id, v_fixture.away_club_short_name
    );
  END IF;

  PERFORM public.competition_injury_roll_for_fixture(p_fixture_id);
END;
$function$;

-- ---------------------------------------------------------------------------
-- Injury roll: weight victim by fitness level
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.competition_injury_roll_for_club(
  p_fixture_id bigint,
  p_club text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_fixture public.competition_fixtures%rowtype;
  v_settings public.competition_injury_settings;
  v_state public.competition_club_injury_season;
  v_chance numeric;
  v_paced numeric;
  v_remaining_cap int;
  v_remaining_fix int;
  v_severity text;
  v_cat public.competition_injury_catalogue%rowtype;
  v_player_id text;
  v_injury_id bigint;
  v_fit_gk int;
  v_cooldown int;
  v_fit_level int;
BEGIN
  SELECT * INTO v_fixture FROM public.competition_fixtures WHERE id = p_fixture_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'fixture_not_found');
  END IF;

  IF v_fixture.status <> 'played' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'fixture_not_played');
  END IF;

  IF public.competition_injury_is_preseason_month(v_fixture.gpsl_month) THEN
    INSERT INTO public.competition_fixture_injury_roll (fixture_id, club_short_name, did_injure)
    VALUES (p_fixture_id, p_club, false)
    ON CONFLICT DO NOTHING;
    RETURN jsonb_build_object('ok', true, 'did_injure', false, 'reason', 'preseason_month');
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.competition_match_player_stats m
    WHERE m.fixture_id = p_fixture_id
      AND m.club_short_name = p_club
      AND m.appeared = true
  ) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_stats_yet');
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.competition_fixture_injury_roll r
    WHERE r.fixture_id = p_fixture_id AND r.club_short_name = p_club
  ) THEN
    RETURN jsonb_build_object('ok', true, 'did_injure', false, 'reason', 'already_rolled');
  END IF;

  v_settings := public.competition_injury_settings_row();
  v_state := public.competition_injury_ensure_club_season(v_fixture.season_id, p_club);
  v_cooldown := greatest(0, coalesce(v_settings.cooldown_matches, 5));

  IF v_state.count_total >= v_settings.max_total THEN
    INSERT INTO public.competition_fixture_injury_roll (fixture_id, club_short_name, did_injure)
    VALUES (p_fixture_id, p_club, false);
    RETURN jsonb_build_object('ok', true, 'did_injure', false, 'reason', 'cap_total');
  END IF;

  IF v_state.count_total > 0
     AND coalesce(v_state.matches_since_injury, 999) < v_cooldown THEN
    UPDATE public.competition_club_injury_season
    SET matches_since_injury = coalesce(matches_since_injury, 0) + 1
    WHERE season_id = v_fixture.season_id
      AND club_short_name = p_club;

    INSERT INTO public.competition_fixture_injury_roll (fixture_id, club_short_name, did_injure)
    VALUES (p_fixture_id, p_club, false);

    RETURN jsonb_build_object(
      'ok', true,
      'did_injure', false,
      'reason', 'cooldown',
      'matches_since_injury', coalesce(v_state.matches_since_injury, 0) + 1,
      'cooldown_matches', v_cooldown
    );
  END IF;

  v_remaining_cap := greatest(0, v_settings.max_total - coalesce(v_state.count_total, 0));
  v_remaining_fix := public.competition_injury_remaining_fixtures(
    v_fixture.season_id, p_club
  );
  v_remaining_fix := greatest(1, v_remaining_fix + 1);

  IF coalesce(v_settings.pace_enabled, true) THEN
    v_paced := v_remaining_cap::numeric / v_remaining_fix::numeric;
    v_chance := least(
      coalesce(v_settings.pace_chance_cap, 0.12),
      greatest(coalesce(v_settings.pace_chance_floor, 0.03), v_paced)
    ) * coalesce(v_state.injury_risk, 1.0);
  ELSE
    v_chance := least(
      1.0,
      greatest(0.0, coalesce(v_settings.base_match_chance, 0.09) * coalesce(v_state.injury_risk, 1.0))
    );
  END IF;

  IF to_regprocedure('public.medical_injury_chance_reduction(text)') IS NOT NULL THEN
    v_chance := least(
      1.0,
      greatest(0.0, v_chance - coalesce(public.medical_injury_chance_reduction(p_club), 0))
    );
  END IF;

  IF random() >= v_chance THEN
    UPDATE public.competition_club_injury_season
    SET matches_since_injury = coalesce(matches_since_injury, 0) + 1
    WHERE season_id = v_fixture.season_id
      AND club_short_name = p_club;

    INSERT INTO public.competition_fixture_injury_roll (fixture_id, club_short_name, did_injure)
    VALUES (p_fixture_id, p_club, false);

    RETURN jsonb_build_object(
      'ok', true,
      'did_injure', false,
      'reason', 'no_hit',
      'chance', round(v_chance, 4),
      'remaining_cap', v_remaining_cap,
      'remaining_fixtures', v_remaining_fix
    );
  END IF;

  v_severity := public.competition_injury_pick_severity(v_state, v_settings);
  IF v_severity IS NULL THEN
    INSERT INTO public.competition_fixture_injury_roll (fixture_id, club_short_name, did_injure)
    VALUES (p_fixture_id, p_club, false);
    RETURN jsonb_build_object('ok', true, 'did_injure', false, 'reason', 'no_severity_left');
  END IF;

  SELECT * INTO v_cat
  FROM public.competition_injury_catalogue c
  WHERE c.active AND c.severity = v_severity
  ORDER BY random()
  LIMIT 1;

  IF NOT FOUND THEN
    INSERT INTO public.competition_fixture_injury_roll (fixture_id, club_short_name, did_injure)
    VALUES (p_fixture_id, p_club, false);
    RETURN jsonb_build_object('ok', true, 'did_injure', false, 'reason', 'empty_catalogue');
  END IF;

  v_fit_gk := public.competition_injury_fit_gk_count(p_club);

  -- Weighted pick by match fitness (higher level → more likely)
  SELECT x.player_id, x.fitness_level
  INTO v_player_id, v_fit_level
  FROM (
    SELECT
      m.player_id,
      coalesce(f.fitness_level, 1) AS fitness_level,
      public.competition_match_fitness_weight(
        coalesce(f.fitness_level, 1), v_settings
      ) AS w
    FROM public.competition_match_player_stats m
    JOIN public."Players" p ON p."Konami_ID"::text = m.player_id
    LEFT JOIN public.competition_player_match_fitness f
      ON f.season_id = v_fixture.season_id
     AND f.player_id = m.player_id
    WHERE m.fixture_id = p_fixture_id
      AND m.club_short_name = p_club
      AND m.appeared = true
      AND NOT public.competition_injury_player_is_out(m.player_id)
      AND NOT (
        upper(coalesce(p."Position", '')) = 'GK'
        AND v_fit_gk <= 1
      )
  ) x
  ORDER BY -ln(greatest(random(), 1e-12)) / greatest(x.w, 0.01)
  LIMIT 1;

  IF v_player_id IS NULL THEN
    INSERT INTO public.competition_fixture_injury_roll (fixture_id, club_short_name, did_injure)
    VALUES (p_fixture_id, p_club, false);
    RETURN jsonb_build_object('ok', true, 'did_injure', false, 'reason', 'no_eligible_player');
  END IF;

  v_injury_id := public.competition_injury_issue(
    v_fixture.season_id, p_club, v_player_id, v_cat.id, p_fixture_id
  );

  UPDATE public.competition_club_injury_season
  SET matches_since_injury = 0
  WHERE season_id = v_fixture.season_id
    AND club_short_name = p_club;

  INSERT INTO public.competition_fixture_injury_roll (
    fixture_id, club_short_name, did_injure, injury_id
  ) VALUES (p_fixture_id, p_club, true, v_injury_id);

  RETURN jsonb_build_object(
    'ok', true,
    'did_injure', true,
    'injury_id', v_injury_id,
    'player_id', v_player_id,
    'fitness_level', v_fit_level,
    'injury', v_cat.name,
    'severity', v_cat.severity,
    'chance', round(v_chance, 4),
    'remaining_cap', v_remaining_cap - 1,
    'cooldown_matches', v_cooldown
  );
END;
$function$;

-- ---------------------------------------------------------------------------
-- Admin settings save/get (include fitness + max_total)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_injury_settings_save(p_settings jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF NOT public.is_gpsl_admin()
     AND current_user NOT IN ('postgres', 'supabase_admin', 'service_role') THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  UPDATE public.competition_injury_settings
  SET max_major = coalesce((p_settings ->> 'max_major')::int, max_major),
      max_moderate = coalesce((p_settings ->> 'max_moderate')::int, max_moderate),
      max_minor = coalesce((p_settings ->> 'max_minor')::int, max_minor),
      max_total = coalesce((p_settings ->> 'max_total')::int, max_total),
      base_match_chance = coalesce((p_settings ->> 'base_match_chance')::numeric, base_match_chance),
      weight_minor = coalesce((p_settings ->> 'weight_minor')::numeric, weight_minor),
      weight_moderate = coalesce((p_settings ->> 'weight_moderate')::numeric, weight_moderate),
      weight_major = coalesce((p_settings ->> 'weight_major')::numeric, weight_major),
      preseason_months = coalesce(
        ARRAY(SELECT jsonb_array_elements_text(p_settings -> 'preseason_months')),
        preseason_months
      ),
      preseason_matches_per_month = coalesce(
        (p_settings ->> 'preseason_matches_per_month')::int,
        preseason_matches_per_month
      ),
      risk_min = coalesce((p_settings ->> 'risk_min')::numeric, risk_min),
      risk_max = coalesce((p_settings ->> 'risk_max')::numeric, risk_max),
      cooldown_matches = coalesce((p_settings ->> 'cooldown_matches')::int, cooldown_matches),
      pace_enabled = coalesce((p_settings ->> 'pace_enabled')::boolean, pace_enabled),
      pace_chance_floor = coalesce((p_settings ->> 'pace_chance_floor')::numeric, pace_chance_floor),
      pace_chance_cap = coalesce((p_settings ->> 'pace_chance_cap')::numeric, pace_chance_cap),
      fitness_matches_to_max = coalesce(
        (p_settings ->> 'fitness_matches_to_max')::int, fitness_matches_to_max
      ),
      fitness_weight_l1 = coalesce((p_settings ->> 'fitness_weight_l1')::numeric, fitness_weight_l1),
      fitness_weight_l2 = coalesce((p_settings ->> 'fitness_weight_l2')::numeric, fitness_weight_l2),
      fitness_weight_l3 = coalesce((p_settings ->> 'fitness_weight_l3')::numeric, fitness_weight_l3),
      fitness_weight_l4 = coalesce((p_settings ->> 'fitness_weight_l4')::numeric, fitness_weight_l4),
      fitness_weight_l5 = coalesce((p_settings ->> 'fitness_weight_l5')::numeric, fitness_weight_l5),
      fitness_return_level = coalesce(
        (p_settings ->> 'fitness_return_level')::int, fitness_return_level
      ),
      updated_at = now()
  WHERE id = 1;

  RETURN public.admin_injury_settings_get();
END;
$function$;

-- ---------------------------------------------------------------------------
-- Squad / public read helper
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.club_match_fitness_map(p_club text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := upper(nullif(btrim(coalesce(p_club, public.my_club_shortname())), ''));
  v_season bigint;
BEGIN
  IF v_club IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_club', 'by_player', '{}'::jsonb);
  END IF;

  SELECT id INTO v_season
  FROM public.competition_seasons
  WHERE is_current = true
  ORDER BY id DESC
  LIMIT 1;

  IF v_season IS NULL THEN
    RETURN jsonb_build_object('ok', true, 'club', v_club, 'by_player', '{}'::jsonb);
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'club', v_club,
    'season_id', v_season,
    'by_player', coalesce((
      SELECT jsonb_object_agg(
        f.player_id,
        jsonb_build_object(
          'level', f.fitness_level,
          'label', public.competition_match_fitness_label(f.fitness_level),
          'consecutive', f.consecutive_appearances
        )
      )
      FROM public.competition_player_match_fitness f
      WHERE f.season_id = v_season
        AND upper(btrim(f.club_short_name)) = v_club
    ), '{}'::jsonb)
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.club_match_fitness_map(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.club_match_fitness_map(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.competition_match_fitness_tick_club(bigint, text) TO service_role;
GRANT EXECUTE ON FUNCTION public.competition_injury_roll_for_club(bigint, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_injury_settings_save(jsonb) TO authenticated;

SELECT
  to_regprocedure('public.competition_match_fitness_tick_club(bigint,text)') IS NOT NULL AS tick_ok,
  to_regprocedure('public.club_match_fitness_map(text)') IS NOT NULL AS map_ok,
  (
    SELECT fitness_matches_to_max FROM public.competition_injury_settings WHERE id = 1
  ) AS matches_to_max;
