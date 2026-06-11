-- Manager expectancy scaling — reference chart only (NOT in-game player stat changes).
--
-- The +1 / +2 / +3 columns describe how strongly a manager proficiency "lifts" players in
-- each rating band in eFootball terms. GPSL does not amend GPDB player stats from this.
-- We use the chart only to score how much a manager should lift a club's squad on paper,
-- then derive pre-season requisites and season expectations (position / contract renewal).
--
-- Run after managers_system.sql. Safe to re-run.

-- ---------------------------------------------------------------------------
-- Table (rename columns if old tier*_min/max league-points labels exist)
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.manager_proficiency_expectancy (
  proficiency smallint PRIMARY KEY CHECK (proficiency >= 1 AND proficiency <= 99),
  boost1_min smallint NOT NULL CHECK (boost1_min >= 0),
  boost1_max smallint NOT NULL CHECK (boost1_max >= boost1_min),
  boost2_min smallint CHECK (boost2_min IS NULL OR boost2_min >= 0),
  boost2_max smallint CHECK (boost2_max IS NULL OR boost2_max >= boost2_min),
  boost3_min smallint CHECK (boost3_min IS NULL OR boost3_min >= 0),
  boost3_max smallint CHECK (boost3_max IS NULL OR boost3_max >= boost3_min),
  updated_at timestamptz NOT NULL DEFAULT now()
);

DO $rename_boost_cols$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'manager_proficiency_expectancy'
      AND column_name = 'tier1_min'
  ) THEN
    ALTER TABLE public.manager_proficiency_expectancy RENAME COLUMN tier1_min TO boost1_min;
    ALTER TABLE public.manager_proficiency_expectancy RENAME COLUMN tier1_max TO boost1_max;
    ALTER TABLE public.manager_proficiency_expectancy RENAME COLUMN tier2_min TO boost2_min;
    ALTER TABLE public.manager_proficiency_expectancy RENAME COLUMN tier2_max TO boost2_max;
    ALTER TABLE public.manager_proficiency_expectancy RENAME COLUMN tier3_min TO boost3_min;
    ALTER TABLE public.manager_proficiency_expectancy RENAME COLUMN tier3_max TO boost3_max;
  END IF;
END;
$rename_boost_cols$;

COMMENT ON TABLE public.manager_proficiency_expectancy IS
  'Reference chart: player rating bands per +1/+2/+3 impact tier. Expectancy scaling only — no GPDB stat writes.';

COMMENT ON COLUMN public.manager_proficiency_expectancy.boost1_min IS 'Min player Rating in +1 reference impact band (expectancy scaling, not a stat change).';
COMMENT ON COLUMN public.manager_proficiency_expectancy.boost2_min IS 'Min player Rating in +2 reference impact band.';
COMMENT ON COLUMN public.manager_proficiency_expectancy.boost3_min IS 'Min player Rating in +3 reference impact band.';

-- ---------------------------------------------------------------------------
-- Chart helpers
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.manager_proficiency_clamp(p_rating smallint)
RETURNS smallint
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT LEAST(89, GREATEST(77, coalesce(p_rating, 77)::int))::smallint;
$$;

CREATE OR REPLACE FUNCTION public.manager_expectancy_for(p_rating smallint)
RETURNS public.manager_proficiency_expectancy
LANGUAGE sql
STABLE
AS $$
  SELECT e.*
  FROM public.manager_proficiency_expectancy e
  WHERE e.proficiency = public.manager_proficiency_clamp(p_rating);
$$;

CREATE OR REPLACE FUNCTION public.manager_player_in_boost_band(
  p_player_rating smallint,
  p_min smallint,
  p_max smallint
)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT p_player_rating IS NOT NULL
    AND p_min IS NOT NULL
    AND p_max IS NOT NULL
    AND p_player_rating >= p_min
    AND p_player_rating <= p_max;
$$;

-- Reference impact weight (+0 if outside all bands). Never modifies Players.
CREATE OR REPLACE FUNCTION public.manager_player_stat_boost(
  p_manager_rating smallint,
  p_player_rating smallint
)
RETURNS smallint
LANGUAGE plpgsql
STABLE
AS $function$
DECLARE
  e public.manager_proficiency_expectancy;
BEGIN
  IF p_player_rating IS NULL THEN
    RETURN 0;
  END IF;

  e := public.manager_expectancy_for(p_manager_rating);
  IF e.proficiency IS NULL THEN
    RETURN 0;
  END IF;

  IF public.manager_player_in_boost_band(p_player_rating, e.boost3_min, e.boost3_max) THEN
    RETURN 3;
  END IF;
  IF public.manager_player_in_boost_band(p_player_rating, e.boost2_min, e.boost2_max) THEN
    RETURN 2;
  END IF;
  IF public.manager_player_in_boost_band(p_player_rating, e.boost1_min, e.boost1_max) THEN
    RETURN 1;
  END IF;

  RETURN 0;
END;
$function$;

CREATE OR REPLACE FUNCTION public.manager_boost_band_label(
  p_boost smallint,
  p_min smallint,
  p_max smallint
)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE
    WHEN p_min IS NULL OR p_max IS NULL THEN NULL
    ELSE format('+%s (players %s–%s)', p_boost, p_min, p_max)
  END;
$$;

-- Top-N contracted players — reference-only squad strength for expectancy scaling
CREATE OR REPLACE FUNCTION public.manager_club_squad_boost_stats(
  p_club_short_name text,
  p_manager_rating smallint,
  p_squad_size smallint DEFAULT 18
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_raw numeric;
  v_boosted numeric;
  v_count int;
  v_b1 int := 0;
  v_b2 int := 0;
  v_b3 int := 0;
BEGIN
  IF p_club_short_name IS NULL OR btrim(p_club_short_name) = '' THEN
    RETURN NULL;
  END IF;

  SELECT
    round(avg(s.rating)::numeric, 2),
    round(avg(s.rating + s.boost)::numeric, 2),
    count(*)::int,
    count(*) FILTER (WHERE s.boost = 1),
    count(*) FILTER (WHERE s.boost = 2),
    count(*) FILTER (WHERE s.boost = 3)
  INTO v_raw, v_boosted, v_count, v_b1, v_b2, v_b3
  FROM (
    SELECT
      p."Rating"::int AS rating,
      public.manager_player_stat_boost(p_manager_rating, p."Rating"::smallint) AS boost
    FROM public."Players" p
    WHERE p."Contracted_Team" = p_club_short_name
      AND p."Rating" IS NOT NULL
    ORDER BY p."Rating" DESC
    LIMIT greatest(coalesce(p_squad_size, 18), 1)
  ) s;

  IF v_count IS NULL OR v_count = 0 THEN
    RETURN jsonb_build_object(
      'squad_size', 0,
      'raw_avg', NULL,
      'boosted_avg', NULL,
      'boost_delta', NULL
    );
  END IF;

  RETURN jsonb_build_object(
    'squad_size', v_count,
    'raw_avg', v_raw,
    'boosted_avg', v_boosted,
    'boost_delta', round(v_boosted - v_raw, 2),
    'players_plus1', v_b1,
    'players_plus2', v_b2,
    'players_plus3', v_b3
  );
END;
$function$;

-- Position lift from manager impact on this squad (shared by stadium + contracts)
CREATE OR REPLACE FUNCTION public.manager_club_squad_position_lift(
  p_club_short_name text,
  p_manager_rating smallint DEFAULT NULL
)
RETURNS numeric
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_rating smallint;
  v_stats jsonb;
  v_delta numeric;
  v_lift numeric;
BEGIN
  IF p_manager_rating IS NULL THEN
    SELECT m.rating INTO v_rating
    FROM public."Managers" m
    WHERE m.contracted_club = p_club_short_name
    LIMIT 1;
  ELSE
    v_rating := p_manager_rating;
  END IF;

  IF v_rating IS NULL THEN
    RETURN 0;
  END IF;

  v_stats := public.manager_club_squad_boost_stats(p_club_short_name, v_rating);
  v_delta := (v_stats ->> 'boost_delta')::numeric;

  IF v_delta IS NULL THEN
    RETURN 0;
  END IF;

  -- Each +1 effective squad point ≈ 1 league place (capped)
  v_lift := round(v_delta);
  RETURN greatest(0, least(v_lift, 6));
END;
$function$;

CREATE OR REPLACE FUNCTION public.manager_club_season_expectation(
  p_club_short_name text,
  p_manager_rating smallint DEFAULT NULL,
  p_division text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_rating smallint;
  v_division text;
  v_club_count smallint;
  v_prestige_rank smallint;
  v_tier text;
  v_baseline smallint;
  v_lift numeric;
  v_expected smallint;
  v_stats jsonb;
  v_e public.manager_proficiency_expectancy;
  v_expected_pts numeric;
BEGIN
  IF p_manager_rating IS NULL THEN
    SELECT m.rating INTO v_rating
    FROM public."Managers" m
    WHERE m.contracted_club = p_club_short_name
    LIMIT 1;
  ELSE
    v_rating := p_manager_rating;
  END IF;

  IF v_rating IS NULL THEN
    RETURN NULL;
  END IF;

  v_stats := public.manager_club_squad_boost_stats(p_club_short_name, v_rating);
  v_e := public.manager_expectancy_for(v_rating);

  SELECT count(*)::smallint INTO v_club_count FROM public."Clubs";

  SELECT p.prestige_rank INTO v_prestige_rank
  FROM public.competition_club_prestige_public p
  WHERE p.club_short_name = p_club_short_name;

  v_prestige_rank := coalesce(v_prestige_rank, v_club_count);
  v_tier := public.competition_club_tier(p_club_short_name);

  v_baseline := public.competition_club_baseline_expected_position(v_prestige_rank, v_club_count);
  v_lift := public.manager_club_squad_position_lift(p_club_short_name, v_rating);

  v_expected := v_baseline;
  IF v_tier IN ('medium', 'low') AND v_lift > 0 THEN
    v_expected := greatest(1::smallint, (v_baseline - v_lift)::smallint);
  ELSIF v_tier = 'big' AND v_lift > 0 THEN
    -- Big clubs: manager+squad can raise the bar slightly, never lower prestige floor
    v_expected := greatest(1::smallint, least(v_baseline, (v_baseline - least(v_lift, 2))::smallint));
  END IF;

  IF p_division IS NULL THEN
    SELECT ccs.division INTO v_division
    FROM public.competition_club_seasons ccs
    JOIN public.competition_seasons s ON s.id = ccs.season_id AND s.is_current = true
    WHERE ccs.club_short_name = p_club_short_name
    LIMIT 1;
  ELSE
    v_division := p_division;
  END IF;

  v_expected_pts := public.competition_club_league_points(
    coalesce(v_division, 'superleague'),
    v_expected
  );

  RETURN jsonb_build_object(
    'manager_rating', v_rating,
    'proficiency_clamped', public.manager_proficiency_clamp(v_rating),
    'squad_size', (v_stats ->> 'squad_size')::int,
    'raw_avg', (v_stats ->> 'raw_avg')::numeric,
    'boosted_avg', (v_stats ->> 'boosted_avg')::numeric,
    'boost_delta', (v_stats ->> 'boost_delta')::numeric,
    'players_plus1', (v_stats ->> 'players_plus1')::int,
    'players_plus2', (v_stats ->> 'players_plus2')::int,
    'players_plus3', (v_stats ->> 'players_plus3')::int,
    'boost1_label', public.manager_boost_band_label(1, v_e.boost1_min, v_e.boost1_max),
    'boost2_label', public.manager_boost_band_label(2, v_e.boost2_min, v_e.boost2_max),
    'boost3_label', public.manager_boost_band_label(3, v_e.boost3_min, v_e.boost3_max),
    'baseline_position', v_baseline,
    'expected_position', v_expected,
    'expected_league_pts', v_expected_pts,
    'club_tier', v_tier
  );
END;
$function$;

-- Season performance vs squad-derived expectation: 0=below, 1=met (+1), 2=beat (+2), 3=exceeded (+3)
CREATE OR REPLACE FUNCTION public.manager_season_tier_achieved(
  p_expected_position smallint,
  p_actual_position smallint
)
RETURNS smallint
LANGUAGE plpgsql
IMMUTABLE
AS $function$
DECLARE
  v_gap smallint;
BEGIN
  IF p_expected_position IS NULL OR p_actual_position IS NULL THEN
    RETURN NULL;
  END IF;

  v_gap := p_expected_position - p_actual_position;

  IF v_gap >= 4 THEN
    RETURN 3;
  ELSIF v_gap >= 2 THEN
    RETURN 2;
  ELSIF v_gap >= 0 THEN
    RETURN 1;
  END IF;

  RETURN 0;
END;
$function$;

CREATE OR REPLACE FUNCTION public.manager_contract_renewed(
  p_expected_position smallint,
  p_actual_position smallint
)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT public.manager_season_tier_achieved(p_expected_position, p_actual_position) >= 1;
$$;

-- Restore position-based target check (legacy table unused for renew; kept for compat)
CREATE OR REPLACE FUNCTION public.manager_target_met(
  p_target public.manager_rating_targets,
  p_actual_position smallint,
  p_division text
)
RETURNS boolean
LANGUAGE plpgsql
IMMUTABLE
AS $function$
BEGIN
  IF p_target IS NULL OR p_actual_position IS NULL THEN
    RETURN NULL;
  END IF;

  IF p_target.target_kind = 'max_position' THEN
    RETURN p_actual_position <= p_target.target_value;
  END IF;

  IF p_target.target_kind = 'promotion' THEN
    RETURN p_actual_position <= 2;
  END IF;

  IF p_target.target_kind = 'avoid_relegation' THEN
    IF p_division = 'superleague' THEN
      RETURN p_actual_position <= 18;
    END IF;
    RETURN p_actual_position <= 18;
  END IF;

  RETURN NULL;
END;
$function$;

CREATE OR REPLACE FUNCTION public.manager_process_season_end()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season public.competition_seasons;
  v_mgr public."Managers"%rowtype;
  v_division text;
  v_pos smallint;
  v_expect jsonb;
  v_expected_pos smallint;
  v_tier smallint;
  v_results jsonb := '[]'::jsonb;
  v_row jsonb;
BEGIN
  SELECT * INTO v_season
  FROM public.competition_seasons
  WHERE is_current = true
  ORDER BY id DESC
  LIMIT 1;

  FOR v_mgr IN
    SELECT * FROM public."Managers"
    WHERE contracted_club IS NOT NULL
      AND contract_seasons_remaining > 0
  LOOP
    SELECT cs.division, cs.season_position
    INTO v_division, v_pos
    FROM public.manager_club_season_position(v_season.id, v_mgr.contracted_club) cs;

    v_expect := public.manager_club_season_expectation(
      v_mgr.contracted_club,
      v_mgr.rating,
      v_division
    );
    v_expected_pos := (v_expect ->> 'expected_position')::smallint;
    v_tier := public.manager_season_tier_achieved(v_expected_pos, v_pos);

    IF v_tier >= 1 THEN
      UPDATE public."Managers"
      SET contract_seasons_remaining = 2,
          weekly_wage = public.manager_weekly_wage_for(market_value),
          updated_at = now()
      WHERE id = v_mgr.id;

      v_row := jsonb_build_object(
        'manager_id', v_mgr.id,
        'club', v_mgr.contracted_club,
        'action', 'renewed',
        'position', v_pos,
        'expected_position', v_expected_pos,
        'tier', v_tier
      );
    ELSIF v_tier = 0 THEN
      PERFORM public.manager_release_from_club(
        v_mgr.id,
        v_mgr.contracted_club,
        v_mgr.market_value::numeric,
        'transfer_sale'
      );

      v_row := jsonb_build_object(
        'manager_id', v_mgr.id,
        'club', v_mgr.contracted_club,
        'action', 'released',
        'position', v_pos,
        'expected_position', v_expected_pos,
        'tier', v_tier,
        'payout', v_mgr.market_value
      );
    ELSE
      UPDATE public."Managers"
      SET contract_seasons_remaining = greatest(contract_seasons_remaining - 1, 0),
          updated_at = now()
      WHERE id = v_mgr.id;

      IF (SELECT contract_seasons_remaining FROM public."Managers" WHERE id = v_mgr.id) = 0 THEN
        PERFORM public.manager_release_from_club(v_mgr.id, NULL, NULL, 'transfer_sale');
        v_row := jsonb_build_object('manager_id', v_mgr.id, 'club', v_mgr.contracted_club, 'action', 'contract_expired');
      ELSE
        v_row := jsonb_build_object('manager_id', v_mgr.id, 'club', v_mgr.contracted_club, 'action', 'season_tick');
      END IF;
    END IF;

    IF v_row IS NOT NULL THEN
      v_results := v_results || jsonb_build_array(v_row);
    END IF;
  END LOOP;

  RETURN jsonb_build_object('ok', true, 'season_id', v_season.id, 'results', v_results);
END;
$function$;

-- ---------------------------------------------------------------------------
-- Public status view
-- ---------------------------------------------------------------------------

DROP VIEW IF EXISTS public.manager_club_status_public;

CREATE VIEW public.manager_club_status_public
WITH (security_invoker = true)
AS
SELECT
  c."ShortName" AS club_short_name,
  m.id AS manager_id,
  m.name AS manager_name,
  m.rating AS manager_rating,
  m.market_value,
  m.contract_seasons_remaining,
  m.weekly_wage,
  c.manager_sacks_remaining,
  coalesce(pos.division, ccs.division) AS division,
  pos.season_position,
  (exp.d ->> 'raw_avg')::numeric AS squad_raw_avg,
  (exp.d ->> 'boosted_avg')::numeric AS squad_boosted_avg,
  (exp.d ->> 'boost_delta')::numeric AS squad_boost_delta,
  (exp.d ->> 'baseline_position')::smallint AS baseline_position,
  (exp.d ->> 'expected_position')::smallint AS expected_position,
  (exp.d ->> 'expected_league_pts')::numeric AS expected_league_pts,
  exp.d ->> 'boost1_label' AS boost1_label,
  exp.d ->> 'boost2_label' AS boost2_label,
  exp.d ->> 'boost3_label' AS boost3_label,
  public.manager_season_tier_achieved(
    (exp.d ->> 'expected_position')::smallint,
    pos.season_position
  ) AS expectancy_tier,
  public.manager_contract_renewed(
    (exp.d ->> 'expected_position')::smallint,
    pos.season_position
  ) AS target_met
FROM public."Clubs" c
LEFT JOIN public."Managers" m ON m.id = c.manager_id
LEFT JOIN public.competition_seasons s ON s.is_current = true
LEFT JOIN public.competition_club_seasons ccs
  ON ccs.club_short_name = c."ShortName" AND ccs.season_id = s.id
LEFT JOIN LATERAL public.manager_club_season_position(s.id, c."ShortName") pos ON s.id IS NOT NULL
LEFT JOIN LATERAL (
  SELECT public.manager_club_season_expectation(
    c."ShortName",
    m.rating,
    coalesce(pos.division, ccs.division)
  ) AS d
) exp ON m.id IS NOT NULL;

GRANT SELECT ON public.manager_club_status_public TO authenticated;

-- ---------------------------------------------------------------------------
-- Admin upsert (accepts boost*_min/max or legacy tier*_min/max keys)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.admin_upsert_manager_proficiency_expectancy(p_payload jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  INSERT INTO public.manager_proficiency_expectancy (
    proficiency,
    boost1_min, boost1_max,
    boost2_min, boost2_max,
    boost3_min, boost3_max
  )
  VALUES (
    (p_payload ->> 'proficiency')::smallint,
    coalesce((p_payload ->> 'boost1_min')::smallint, (p_payload ->> 'tier1_min')::smallint),
    coalesce((p_payload ->> 'boost1_max')::smallint, (p_payload ->> 'tier1_max')::smallint),
    nullif(coalesce(p_payload ->> 'boost2_min', p_payload ->> 'tier2_min'), '')::smallint,
    nullif(coalesce(p_payload ->> 'boost2_max', p_payload ->> 'tier2_max'), '')::smallint,
    nullif(coalesce(p_payload ->> 'boost3_min', p_payload ->> 'tier3_min'), '')::smallint,
    nullif(coalesce(p_payload ->> 'boost3_max', p_payload ->> 'tier3_max'), '')::smallint
  )
  ON CONFLICT (proficiency) DO UPDATE SET
    boost1_min = excluded.boost1_min,
    boost1_max = excluded.boost1_max,
    boost2_min = excluded.boost2_min,
    boost2_max = excluded.boost2_max,
    boost3_min = excluded.boost3_min,
    boost3_max = excluded.boost3_max,
    updated_at = now();

  RETURN jsonb_build_object('ok', true);
END;
$function$;

-- Seed chart (GP proficiency 77–89). Values = player rating bands per boost tier.
INSERT INTO public.manager_proficiency_expectancy (
  proficiency, boost1_min, boost1_max, boost2_min, boost2_max, boost3_min, boost3_max
)
VALUES
  (77, 48, 94, 95, 97, NULL, NULL),
  (78, 44, 87, 88, 97, NULL, NULL),
  (79, 40, 76, 77, 97, NULL, NULL),
  (80, 40, 76, 77, 97, NULL, NULL),
  (81, 40, 69, 70, 97, NULL, NULL),
  (82, 40, 69, 70, 97, NULL, NULL),
  (83, 40, 66, 67, 97, NULL, NULL),
  (84, 40, 61, 62, 92, 93, 96),
  (85, 40, 61, 62, 92, 93, 96),
  (86, 40, 58, 58, 89, 90, 96),
  (87, 40, 58, 59, 87, 88, 96),
  (88, 40, 56, 57, 84, 85, 96),
  (89, 40, 55, 56, 83, 84, 96)
ON CONFLICT (proficiency) DO UPDATE SET
  boost1_min = excluded.boost1_min,
  boost1_max = excluded.boost1_max,
  boost2_min = excluded.boost2_min,
  boost2_max = excluded.boost2_max,
  boost3_min = excluded.boost3_min,
  boost3_max = excluded.boost3_max,
  updated_at = now();

ALTER TABLE public.manager_proficiency_expectancy ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS manager_proficiency_expectancy_select ON public.manager_proficiency_expectancy;
CREATE POLICY manager_proficiency_expectancy_select ON public.manager_proficiency_expectancy
  FOR SELECT TO authenticated USING (true);

DROP POLICY IF EXISTS manager_proficiency_expectancy_admin ON public.manager_proficiency_expectancy;
CREATE POLICY manager_proficiency_expectancy_admin ON public.manager_proficiency_expectancy
  FOR ALL TO authenticated
  USING (public.is_gpsl_admin())
  WITH CHECK (public.is_gpsl_admin());

GRANT SELECT ON public.manager_proficiency_expectancy TO authenticated;
GRANT EXECUTE ON FUNCTION public.manager_expectancy_for(smallint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.manager_player_stat_boost(smallint, smallint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.manager_club_squad_boost_stats(text, smallint, smallint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.manager_club_squad_position_lift(text, smallint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.manager_club_season_expectation(text, smallint, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.manager_season_tier_achieved(smallint, smallint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_upsert_manager_proficiency_expectancy(jsonb) TO authenticated;

-- ---------------------------------------------------------------------------
-- Season expectations inbox
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.owner_inbox_notify_season_expectations(p_club_short_name text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_mgr public."Managers"%rowtype;
  v_division text;
  v_expect jsonb;
  v_fill numeric;
  v_target_fill numeric;
  v_body text;
  v_bands text;
BEGIN
  SELECT * INTO v_mgr
  FROM public."Managers" m
  WHERE m.contracted_club = p_club_short_name
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN;
  END IF;

  SELECT ccs.division INTO v_division
  FROM public.competition_club_seasons ccs
  JOIN public.competition_seasons s ON s.id = ccs.season_id AND s.is_current = true
  WHERE ccs.club_short_name = p_club_short_name
  LIMIT 1;

  v_expect := public.manager_club_season_expectation(p_club_short_name, v_mgr.rating, v_division);

  SELECT c.stadium_display_fill_pct, c.stadium_fill_target_pct
  INTO v_fill, v_target_fill
  FROM public."Clubs" c
  WHERE c."ShortName" = p_club_short_name;

  v_bands := concat_ws(
    ' · ',
    v_expect ->> 'boost1_label',
    v_expect ->> 'boost2_label',
    v_expect ->> 'boost3_label'
  );

  v_body := concat_ws(
    E'\n',
    format('Manager: %s (proficiency %s, %s season(s) remaining)', v_mgr.name, v_mgr.rating, v_mgr.contract_seasons_remaining),
    format(
      'Expectancy scaling (reference only — GPDB stats unchanged): top-%s squad avg %s, reference effective %s (+%s chart weight). Bands: %s.',
      coalesce(v_expect ->> 'squad_size', '?'),
      coalesce(v_expect ->> 'raw_avg', '?'),
      coalesce(v_expect ->> 'boosted_avg', '?'),
      coalesce(v_expect ->> 'boost_delta', '0'),
      coalesce(nullif(v_bands, ''), 'see Admin → Manager squad boost chart')
    ),
    format(
      'Season expectation: finish around league position %s (%s pts) to renew. Beat it by 2+ places for +2, 4+ for +3.',
      coalesce(v_expect ->> 'expected_position', '?'),
      coalesce(v_expect ->> 'expected_league_pts', '?')
    ),
    format('Stadium: maintain strong attendance — current fill %s%%, season target %s%%.',
      coalesce(round(v_fill)::text, '?'), coalesce(round(v_target_fill)::text, '100')),
    E'See Club Details for live progress.'
  );

  PERFORM public.owner_inbox_send(
    'season_expectations',
    'Season expectations',
    v_body,
    p_club_short_name,
    NULL,
    NULL, NULL, NULL, NULL,
    'club_details.html',
    'season_expectations:' || p_club_short_name || ':' || v_mgr.id::text,
    NULL, NULL
  );
END;
$function$;

-- ---------------------------------------------------------------------------
-- Stadium: squad-boost lift (requires stadium_attendance_v2.sql)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.competition_stadium_season_metrics(
  p_club_short_name text,
  p_season_id bigint DEFAULT NULL,
  p_division text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_cfg public.global_settings;
  v_season_id bigint;
  v_division text;
  v_capacity int;
  v_tier text;
  v_prestige_rank smallint;
  v_club_count smallint;
  v_baseline_pos smallint;
  v_expected_pos smallint;
  v_actual_pos smallint;
  v_manager_rating smallint;
  v_lift numeric;
  v_league_expected numeric;
  v_league_actual numeric;
  v_cup_expected numeric;
  v_cup_actual numeric;
  v_expected_pts numeric;
  v_actual_pts numeric;
  v_gap numeric;
  v_band text;
  v_penalty numeric;
  v_prestige_base numeric;
  v_season_target numeric;
  v_rank_row record;
  v_standing_division text;
BEGIN
  SELECT * INTO v_cfg FROM public.global_settings WHERE id = 1;

  IF p_season_id IS NULL THEN
    SELECT id INTO v_season_id
    FROM public.competition_seasons
    WHERE is_current = true AND status = 'active'
    LIMIT 1;
  ELSE
    v_season_id := p_season_id;
  END IF;

  IF v_season_id IS NULL THEN
    RETURN jsonb_build_object('error', 'No active season');
  END IF;

  IF p_division IS NULL THEN
    SELECT ccs.division INTO v_division
    FROM public.competition_club_seasons ccs
    WHERE ccs.season_id = v_season_id
      AND ccs.club_short_name = p_club_short_name
    LIMIT 1;
  ELSE
    v_division := p_division;
  END IF;

  SELECT coalesce(c."Capacity", 0)::int, c.manager_rating
  INTO v_capacity, v_manager_rating
  FROM public."Clubs" c
  WHERE c."ShortName" = p_club_short_name;

  v_tier := public.competition_club_tier(p_club_short_name);

  SELECT count(*)::smallint INTO v_club_count FROM public."Clubs";

  SELECT p.prestige_rank, p.rolling_points, p.composite_score, p.seasons_count
  INTO v_rank_row
  FROM public.competition_club_prestige_public p
  WHERE p.club_short_name = p_club_short_name;

  v_prestige_rank := coalesce(v_rank_row.prestige_rank, v_club_count);
  v_prestige_base := public.competition_stadium_prestige_base_fill(p_club_short_name);

  v_baseline_pos := public.competition_club_baseline_expected_position(
    v_prestige_rank,
    v_club_count
  );
  v_expected_pos := v_baseline_pos;

  v_lift := public.manager_club_squad_position_lift(p_club_short_name, v_manager_rating);

  IF v_tier IN ('medium', 'low') AND v_lift > 0 THEN
    v_expected_pos := greatest(1::smallint, (v_baseline_pos - v_lift)::smallint);
  ELSIF v_tier = 'big' AND v_lift > 0 THEN
    v_expected_pos := greatest(1::smallint, least(v_baseline_pos, (v_baseline_pos - least(v_lift, 2))::smallint));
  END IF;

  SELECT cs.division, cs.final_position
  INTO v_standing_division, v_actual_pos
  FROM public.competition_club_season_standing(v_season_id, p_club_short_name) cs;

  v_actual_pos := coalesce(v_actual_pos, 10);

  v_league_expected := public.competition_club_league_points(
    coalesce(v_division, v_standing_division, 'superleague'),
    v_expected_pos
  );

  v_cup_expected := public.competition_club_expected_cup_points(
    coalesce(v_division, v_standing_division, 'superleague'),
    v_expected_pos
  );

  SELECT
    (live ->> 'league_points')::numeric,
    (live ->> 'cup_points')::numeric
  INTO v_league_actual, v_cup_actual
  FROM public.competition_club_live_season_points(v_season_id, p_club_short_name) live;

  v_league_actual := coalesce(v_league_actual, 0);
  v_cup_actual := coalesce(v_cup_actual, 0);

  v_expected_pts :=
    v_league_expected * v_cfg.stadium_league_expect_weight
    + v_cup_expected * v_cfg.stadium_cup_expect_weight;

  v_actual_pts :=
    v_league_actual * v_cfg.stadium_league_perf_weight
    + v_cup_actual * v_cfg.stadium_cup_perf_weight;

  v_gap := v_actual_pts - v_expected_pts;
  v_band := public.competition_stadium_performance_band(v_gap, v_expected_pts, v_cfg);
  v_penalty := public.competition_stadium_performance_penalty(v_band, v_cfg);

  v_season_target := v_prestige_base;

  IF v_band = 'on_target' THEN
    v_season_target := least(
      v_cfg.stadium_max_display_fill_pct,
      v_prestige_base + v_cfg.stadium_season_gain_on_target_pct
    );
  ELSE
    v_season_target := greatest(
      v_cfg.stadium_min_fill_pct,
      v_prestige_base - v_penalty
    );
  END IF;

  RETURN jsonb_build_object(
    'club_short_name', p_club_short_name,
    'season_id', v_season_id,
    'division', coalesce(v_division, v_standing_division),
    'capacity', v_capacity,
    'club_tier', v_tier,
    'prestige_rank', v_prestige_rank,
    'rolling_points', coalesce(v_rank_row.rolling_points, 0),
    'seasons_in_roll', coalesce(v_rank_row.seasons_count, 0),
    'composite_score', coalesce(v_rank_row.composite_score, 0),
    'manager_rating', v_manager_rating,
    'manager_squad_lift', v_lift,
    'baseline_expected_position', v_baseline_pos,
    'expected_position', v_expected_pos,
    'actual_position', v_actual_pos,
    'league_expected_points', round(v_league_expected, 2),
    'league_actual_points', round(v_league_actual, 2),
    'cup_expected_points', round(v_cup_expected, 2),
    'cup_actual_points', round(v_cup_actual, 2),
    'expected_points', round(v_expected_pts, 2),
    'actual_points', round(v_actual_pts, 2),
    'performance_gap', round(v_gap, 2),
    'performance_band', v_band,
    'performance_penalty_pct', v_penalty,
    'prestige_base_fill_pct', v_prestige_base,
    'season_target_fill_pct', round(v_season_target, 2),
    'min_fill_pct', v_cfg.stadium_min_fill_pct,
    'target_fill_pct', v_cfg.stadium_target_fill_pct,
    'max_display_fill_pct', v_cfg.stadium_max_display_fill_pct,
    'monthly_drift_pct', v_cfg.stadium_monthly_drift_pct
  );
END;
$function$;
