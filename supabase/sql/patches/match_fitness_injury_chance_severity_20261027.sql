-- =============================================================================
-- Match fitness → injury chance boost + severity bias + retuned victim weights
--
-- 1) Club hit chance: modest boost from L4/L5 players who appeared (cap +25%).
-- 2) Victim pick: sharper fitness weights (L1 low → L5 high).
-- 3) Severity after victim known:
--    L1–2 → mostly Minor (Moderate/Major still possible)
--    L3   → more Moderate; Major less likely but possible
--    L4–5 → more Moderate + Major (serious more likely at L4/L5)
-- 4) Injury catalogue durations unchanged.
--
-- Requires: match_fitness_injury_weights_20261026.sql
-- Safe re-run.
-- =============================================================================

-- Sharper default victim weights (admin can still override)
UPDATE public.competition_injury_settings
SET
  fitness_weight_l1 = 0.250,
  fitness_weight_l2 = 0.550,
  fitness_weight_l3 = 1.000,
  fitness_weight_l4 = 1.750,
  fitness_weight_l5 = 2.750,
  updated_at = now()
WHERE id = 1;

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
    WHEN 1 THEN coalesce(v_s.fitness_weight_l1, 0.250)
    WHEN 2 THEN coalesce(v_s.fitness_weight_l2, 0.550)
    WHEN 3 THEN coalesce(v_s.fitness_weight_l3, 1.000)
    WHEN 4 THEN coalesce(v_s.fitness_weight_l4, 1.750)
    ELSE coalesce(v_s.fitness_weight_l5, 2.750)
  END;
END;
$function$;

-- Modest chance multiplier from appeared players at L4/L5 (max +25%)
CREATE OR REPLACE FUNCTION public.competition_injury_fitness_chance_mult(
  p_fixture_id bigint,
  p_club text,
  p_season_id bigint
)
RETURNS numeric
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := upper(btrim(coalesce(p_club, '')));
  v_n4 int := 0;
  v_n5 int := 0;
  v_mult numeric;
BEGIN
  IF v_club = '' OR p_fixture_id IS NULL THEN
    RETURN 1.0;
  END IF;

  SELECT
    count(*) FILTER (WHERE coalesce(f.fitness_level, 1) = 4),
    count(*) FILTER (WHERE coalesce(f.fitness_level, 1) >= 5)
  INTO v_n4, v_n5
  FROM public.competition_match_player_stats m
  LEFT JOIN public.competition_player_match_fitness f
    ON f.season_id = p_season_id
   AND f.player_id = m.player_id
  WHERE m.fixture_id = p_fixture_id
    AND upper(btrim(m.club_short_name)) = v_club
    AND m.appeared = true;

  -- +4% per L4, +8% per L5, capped at 1.25
  v_mult := 1.0
    + 0.04 * coalesce(v_n4, 0)
    + 0.08 * coalesce(v_n5, 0);

  RETURN least(1.25, greatest(1.0, v_mult));
END;
$function$;

COMMENT ON FUNCTION public.competition_injury_fitness_chance_mult(bigint, text, bigint) IS
  'Injury hit chance multiplier from L4/L5 players who appeared (cap +25%).';

-- Severity pick biased by victim fitness level; still respects season caps
CREATE OR REPLACE FUNCTION public.competition_injury_pick_severity_for_fitness(
  p_state public.competition_club_injury_season,
  p_settings public.competition_injury_settings,
  p_fitness_level int DEFAULT 1
)
RETURNS text
LANGUAGE plpgsql
STABLE
SET search_path = public
AS $function$
DECLARE
  v_lvl int := greatest(1, least(5, coalesce(p_fitness_level, 1)));
  v_w_min numeric := 0;
  v_w_mod numeric := 0;
  v_w_maj numeric := 0;
  v_m_min numeric := 1;
  v_m_mod numeric := 1;
  v_m_maj numeric := 1;
  v_total numeric;
  v_roll numeric;
BEGIN
  IF p_state.count_total >= p_settings.max_total THEN
    RETURN NULL;
  END IF;

  -- Relative severity tilt by match fitness (catalogue durations unchanged)
  IF v_lvl <= 2 THEN
    -- Mostly low injuries; medium/serious possible but less likely
    v_m_min := 1.45;
    v_m_mod := 0.55;
    v_m_maj := 0.35;
  ELSIF v_lvl = 3 THEN
    -- More medium; serious less likely than baseline but not impossible
    v_m_min := 0.85;
    v_m_mod := 1.45;
    v_m_maj := 0.70;
  ELSIF v_lvl = 4 THEN
    -- Serious more likely
    v_m_min := 0.55;
    v_m_mod := 1.15;
    v_m_maj := 2.20;
  ELSE
    -- L5: more medium + high
    v_m_min := 0.40;
    v_m_mod := 1.35;
    v_m_maj := 2.80;
  END IF;

  IF p_state.count_minor < p_settings.max_minor THEN
    v_w_min := coalesce(p_settings.weight_minor, 70) * v_m_min;
  END IF;
  IF p_state.count_moderate < p_settings.max_moderate THEN
    v_w_mod := coalesce(p_settings.weight_moderate, 25) * v_m_mod;
  END IF;
  IF p_state.count_major < p_settings.max_major THEN
    v_w_maj := coalesce(p_settings.weight_major, 5) * v_m_maj;
  END IF;

  v_total := v_w_min + v_w_mod + v_w_maj;
  IF v_total <= 0 THEN
    RETURN NULL;
  END IF;

  v_roll := random() * v_total;
  IF v_roll < v_w_min THEN
    RETURN 'Minor';
  ELSIF v_roll < v_w_min + v_w_mod THEN
    RETURN 'Moderate';
  END IF;
  RETURN 'Major';
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_injury_pick_severity_for_fitness(
  public.competition_club_injury_season,
  public.competition_injury_settings,
  int
) TO authenticated;

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
  v_fit_mult numeric := 1.0;
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

  -- Within reason: L4/L5 apps nudge club hit chance up (max +25%)
  v_fit_mult := public.competition_injury_fitness_chance_mult(
    p_fixture_id, p_club, v_fixture.season_id
  );
  v_chance := least(1.0, greatest(0.0, v_chance * v_fit_mult));

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
      'fitness_chance_mult', round(v_fit_mult, 4),
      'remaining_cap', v_remaining_cap,
      'remaining_fixtures', v_remaining_fix
    );
  END IF;

  v_fit_gk := public.competition_injury_fit_gk_count(p_club);

  -- 1) Pick victim by fitness weight first
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

  v_fit_level := coalesce(v_fit_level, 1);

  -- 2) Severity biased by that player's fitness (caps still apply)
  v_severity := public.competition_injury_pick_severity_for_fitness(
    v_state, v_settings, v_fit_level
  );
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
    'fitness_chance_mult', round(v_fit_mult, 4),
    'injury', v_cat.name,
    'severity', v_cat.severity,
    'chance', round(v_chance, 4),
    'remaining_cap', v_remaining_cap - 1,
    'cooldown_matches', v_cooldown
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_injury_roll_for_club(bigint, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.competition_injury_fitness_chance_mult(bigint, text, bigint)
  TO authenticated;
