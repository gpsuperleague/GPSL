-- =============================================================================
-- Club season expectation: position-based bands (2026-10-05)
-- =============================================================================
-- Replaces the points-ratio band with "places below expected finish":
--   0 or better → on_target · 1–2 → slight · 3–5 → bad · 6+ → abysmal
--   (thresholds in global_settings: club_expect_slight_places / club_expect_bad_places)
--
-- Super League relegation:
--   • Expected 1st–15th: relegated by any route → at least 'bad';
--     finishing 18th+ when expected top 10 → 'abysmal'.
--   • Expected 16th–20th ("Avoid relegation"): judged on survival —
--       stays up (≤15th, or survives the playoffs) → on_target
--       relegated via playoffs (lost 16v17 or SL playoff final) → slight
--       relegated 18th–20th at/above expected place → slight
--       relegated 1–2 places below expected → bad, 3+ → abysmal
--     16th/17th before the playoffs are played → slight (provisional).
-- Championship: promoted (top 2 or playoff winner) → on_target; else place gap.
--
-- Cups no longer affect the band. Cup targets still rescue a slight miss;
-- a Super8 cup target falls back to the Plate (same stage) when the club
-- is not in this season's Super8.
--
-- The same band drives stadium fill, board fine, forced listing, cup rescue
-- and manager-deal club checks. Run once in Supabase SQL Editor. Safe re-run.
-- =============================================================================

ALTER TABLE public.global_settings
  ADD COLUMN IF NOT EXISTS club_expect_slight_places smallint NOT NULL DEFAULT 2,
  ADD COLUMN IF NOT EXISTS club_expect_bad_places smallint NOT NULL DEFAULT 5;

-- ---------------------------------------------------------------------------
-- Band from positions
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.club_league_expectation_band(
  p_club_short_name text,
  p_season_id bigint,
  p_expected_pos int,
  p_actual_pos int,
  p_division text
)
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_slight int;
  v_bad int;
  v_exp int := greatest(1, least(20, coalesce(p_expected_pos, 10)));
  v_act int := greatest(1, coalesce(p_actual_pos, 10));
  v_gap int;
  v_band text;
  v_moves_exist boolean := false;
  v_relegated boolean := false;
  v_promoted boolean := false;
  v_playoff_pending boolean := false;
BEGIN
  SELECT coalesce(g.club_expect_slight_places, 2), coalesce(g.club_expect_bad_places, 5)
  INTO v_slight, v_bad
  FROM public.global_settings g
  WHERE g.id = 1;
  v_slight := coalesce(v_slight, 2);
  v_bad := greatest(coalesce(v_bad, 5), v_slight);

  v_gap := v_act - v_exp;
  v_band := CASE
    WHEN v_gap <= 0 THEN 'on_target'
    WHEN v_gap <= v_slight THEN 'slight'
    WHEN v_gap <= v_bad THEN 'bad'
    ELSE 'abysmal'
  END;

  IF p_season_id IS NOT NULL AND to_regclass('public.competition_season_movements') IS NOT NULL THEN
    SELECT EXISTS (
      SELECT 1 FROM public.competition_season_movements m WHERE m.season_id = p_season_id
    ) INTO v_moves_exist;

    SELECT
      coalesce(bool_or(m.from_division = 'superleague' AND m.to_division <> 'superleague'), false),
      coalesce(bool_or(m.to_division = 'superleague' AND m.from_division <> 'superleague'), false)
    INTO v_relegated, v_promoted
    FROM public.competition_season_movements m
    WHERE m.season_id = p_season_id
      AND m.club_short_name = p_club_short_name;
  END IF;

  IF coalesce(p_division, '') = 'superleague' THEN
    v_relegated := coalesce(v_relegated, false) OR v_act >= 18;
    v_playoff_pending := v_act IN (16, 17) AND NOT v_moves_exist;

    IF v_exp >= 16 THEN
      IF NOT v_relegated THEN
        RETURN CASE WHEN v_playoff_pending THEN 'slight' ELSE 'on_target' END;
      END IF;
      IF v_act <= 17 OR v_gap <= 0 THEN
        RETURN 'slight';
      END IF;
      RETURN CASE WHEN v_gap <= 2 THEN 'bad' ELSE 'abysmal' END;
    END IF;

    IF v_relegated AND v_band IN ('on_target', 'slight') THEN
      v_band := 'bad';
    END IF;
    IF v_act >= 18 AND v_exp <= 10 THEN
      v_band := 'abysmal';
    END IF;
    RETURN v_band;
  END IF;

  IF coalesce(p_division, '') IN ('championship_a', 'championship_b') THEN
    IF v_act <= 2 OR coalesce(v_promoted, false) THEN
      RETURN 'on_target';
    END IF;
  END IF;

  RETURN v_band;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.club_league_expectation_band(text, bigint, int, int, text) TO authenticated;

-- ---------------------------------------------------------------------------
-- Swap the band line inside competition_stadium_season_metrics
-- ---------------------------------------------------------------------------
DO $inject_band$
DECLARE
  v_def text;
  v_old text := 'v_band := public.competition_stadium_performance_band(v_gap, v_expected_pts, v_cfg);';
  v_new text := 'v_band := public.club_league_expectation_band(p_club_short_name, v_season_id, v_expected_pos, v_actual_pos, coalesce(v_standing_division, v_division));';
BEGIN
  SELECT pg_get_functiondef('public.competition_stadium_season_metrics(text,bigint,text)'::regprocedure)
  INTO v_def;
  IF position(v_new IN v_def) > 0 THEN
    RAISE NOTICE 'competition_stadium_season_metrics already uses position bands';
  ELSIF position(v_old IN v_def) = 0 THEN
    RAISE EXCEPTION 'competition_stadium_season_metrics: band line not found — position bands not applied';
  ELSE
    EXECUTE replace(v_def, v_old, v_new);
  END IF;
END;
$inject_band$;

-- ---------------------------------------------------------------------------
-- Cup targets: Super8 → Plate fallback when not in this season's Super8
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.club_cup_target_status(
  p_club_short_name text,
  p_season_id bigint
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_division text;
  v_tier text;
  v_targets jsonb := '[]'::jsonb;
  v_any_met boolean := false;
  v_any_applicable boolean := false;
  v_t record;
  v_met boolean;
  v_cup text;
  v_label text;
BEGIN
  SELECT ccs.division INTO v_division
  FROM public.competition_club_seasons ccs
  WHERE ccs.season_id = p_season_id AND ccs.club_short_name = p_club_short_name;

  BEGIN
    v_tier := public.competition_club_tier(p_club_short_name);
  EXCEPTION WHEN OTHERS THEN
    v_tier := NULL;
  END;

  IF v_division IS NOT NULL THEN
    FOR v_t IN
      SELECT * FROM public.club_prestige_cup_targets t
      WHERE (t.division IS NULL OR t.division = v_division)
        AND (t.tier IS NULL OR t.tier = v_tier)
      ORDER BY t.sort_order, t.id
    LOOP
      v_cup := v_t.cup_code;
      v_label := coalesce(nullif(btrim(v_t.label), ''),
                          public.competition_cup_target_label(v_t.cup_code, v_t.cup_stage));
      v_met := public.competition_cup_target_met(p_season_id, p_club_short_name, v_cup, v_t.cup_stage);

      IF v_met IS NULL AND v_t.cup_code = 'super8' THEN
        v_met := public.competition_cup_target_met(p_season_id, p_club_short_name, 'plate', v_t.cup_stage);
        IF v_met IS NOT NULL THEN
          v_cup := 'plate';
          v_label := public.competition_cup_target_label('plate', v_t.cup_stage) || ' (not in Super8)';
        END IF;
      END IF;

      IF v_met IS NOT NULL THEN
        v_any_applicable := true;
      END IF;
      IF v_met IS TRUE THEN
        v_any_met := true;
      END IF;
      v_targets := v_targets || jsonb_build_array(jsonb_build_object(
        'cup_code', v_cup,
        'cup_stage', v_t.cup_stage,
        'label', v_label,
        'applicable', v_met IS NOT NULL,
        'met', v_met
      ));
    END LOOP;
  END IF;

  RETURN jsonb_build_object(
    'club', p_club_short_name,
    'season_id', p_season_id,
    'division', v_division,
    'tier', v_tier,
    'targets', v_targets,
    'applicable', v_any_applicable,
    'met', v_any_met
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.club_cup_target_status(text, bigint) TO authenticated;

-- ---------------------------------------------------------------------------
-- Expectation labels: 16th+ is a relegation-playoff / drop place
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.competition_club_expectation_label(p_position smallint)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE
    WHEN p_position IS NULL THEN NULL
    WHEN p_position <= 1 THEN 'Win the league'
    WHEN p_position <= 2 THEN 'Finish top 2'
    WHEN p_position <= 4 THEN 'Finish top 4'
    WHEN p_position <= 6 THEN 'Finish top 6'
    WHEN p_position <= 10 THEN 'Finish top 10'
    WHEN p_position <= 14 THEN 'Mid-table finish'
    WHEN p_position <= 15 THEN 'Lower mid-table'
    ELSE 'Avoid relegation'
  END;
$$;

GRANT EXECUTE ON FUNCTION public.competition_club_expectation_label(smallint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.competition_club_expectation_label(smallint) TO anon;

-- ---------------------------------------------------------------------------
-- Admin: tune thresholds
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_set_club_expectation_places(
  p_slight_places int,
  p_bad_places int
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;
  IF p_slight_places IS NULL OR p_bad_places IS NULL
     OR p_slight_places < 0 OR p_bad_places < p_slight_places OR p_bad_places > 19 THEN
    RAISE EXCEPTION 'Need 0 ≤ slight ≤ bad ≤ 19';
  END IF;
  UPDATE public.global_settings
  SET club_expect_slight_places = p_slight_places,
      club_expect_bad_places = p_bad_places,
      updated_at = now()
  WHERE id = 1;
  RETURN jsonb_build_object('ok', true, 'slight', p_slight_places, 'bad', p_bad_places);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.admin_set_club_expectation_places(int, int) TO authenticated;

NOTIFY pgrst, 'reload schema';
