-- =============================================================================
-- Injury spacing: cooldown + season pacing
--
-- Problem: flat ~15%/match front-loads injuries early, clubs hit max_total=4,
-- then the rest of the season is silent.
--
-- Fix:
--   1) Cooldown — after an injury, that club cannot hit again for N matches
--      (default 5).
--   2) Pace — chance ≈ remaining_cap / remaining_fixtures (clamped), so the
--      season quota is spent gradually instead of in a burst.
--   3) Slightly lower default base_match_chance (fallback when pace is off).
--
-- Run once in Supabase SQL Editor. Safe re-run.
-- =============================================================================

ALTER TABLE public.competition_injury_settings
  ADD COLUMN IF NOT EXISTS cooldown_matches int NOT NULL DEFAULT 5,
  ADD COLUMN IF NOT EXISTS pace_enabled boolean NOT NULL DEFAULT true,
  ADD COLUMN IF NOT EXISTS pace_chance_floor numeric(6,4) NOT NULL DEFAULT 0.0300,
  ADD COLUMN IF NOT EXISTS pace_chance_cap numeric(6,4) NOT NULL DEFAULT 0.1200;

ALTER TABLE public.competition_club_injury_season
  ADD COLUMN IF NOT EXISTS matches_since_injury int NOT NULL DEFAULT 999;

-- Soften default flat chance (used when pace_enabled = false)
UPDATE public.competition_injury_settings
SET base_match_chance = least(base_match_chance, 0.0900),
    cooldown_matches = coalesce(cooldown_matches, 5),
    pace_enabled = coalesce(pace_enabled, true),
    pace_chance_floor = coalesce(pace_chance_floor, 0.0300),
    pace_chance_cap = coalesce(pace_chance_cap, 0.1200),
    updated_at = now()
WHERE id = 1;

CREATE OR REPLACE FUNCTION public.competition_injury_remaining_fixtures(
  p_season_id bigint,
  p_club text
)
RETURNS int
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT count(*)::int
  FROM public.competition_fixtures f
  WHERE f.season_id = p_season_id
    AND f.status = 'scheduled'
    AND (
      f.home_club_short_name = p_club
      OR f.away_club_short_name = p_club
    )
    AND NOT public.competition_injury_is_preseason_month(f.gpsl_month);
$$;

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

  -- Cooldown after a prior injury this season
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
  -- Current fixture is already played; remaining_fixtures is future only.
  -- Add 1 so the last games still have a fair share.
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

  SELECT m.player_id INTO v_player_id
  FROM public.competition_match_player_stats m
  JOIN public."Players" p ON p."Konami_ID"::text = m.player_id
  WHERE m.fixture_id = p_fixture_id
    AND m.club_short_name = p_club
    AND m.appeared = true
    AND NOT public.competition_injury_player_is_out(m.player_id)
    AND NOT (
      upper(coalesce(p."Position", '')) = 'GK'
      AND v_fit_gk <= 1
    )
  ORDER BY random()
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
    'injury', v_cat.name,
    'severity', v_cat.severity,
    'chance', round(v_chance, 4),
    'remaining_cap', v_remaining_cap - 1,
    'cooldown_matches', v_cooldown
  );
END;
$function$;

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
      updated_at = now()
  WHERE id = 1;

  RETURN public.admin_injury_settings_get();
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_injury_remaining_fixtures(bigint, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.competition_injury_roll_for_club(bigint, text) TO authenticated;
