-- =============================================================================
-- Cup finals at Wembley Stadium
--
-- • Finals stamped with venue_name / venue_capacity (default Wembley, 90,000)
-- • Gate: Wembley capacity × fill, still 50/50 to both clubs
-- • TV: finals always selected; pool split 50/50 (neutral venue)
--
-- Run once. Safe re-run.
-- =============================================================================

ALTER TABLE public.global_settings
  ADD COLUMN IF NOT EXISTS cup_final_venue_name text NOT NULL DEFAULT 'Wembley Stadium',
  ADD COLUMN IF NOT EXISTS cup_final_venue_capacity integer NOT NULL DEFAULT 90000;

COMMENT ON COLUMN public.global_settings.cup_final_venue_name IS
  'Neutral stadium name for all cup finals (default Wembley Stadium).';
COMMENT ON COLUMN public.global_settings.cup_final_venue_capacity IS
  'Neutral stadium capacity used for cup-final gate revenue (default 90000).';

ALTER TABLE public.competition_fixtures
  ADD COLUMN IF NOT EXISTS venue_name text,
  ADD COLUMN IF NOT EXISTS venue_capacity integer;

COMMENT ON COLUMN public.competition_fixtures.venue_name IS
  'Optional override venue (e.g. Wembley Stadium for cup finals).';
COMMENT ON COLUMN public.competition_fixtures.venue_capacity IS
  'Optional override capacity used for gate settlement when set.';

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.competition_fixture_is_cup_final(
  p_fixture public.competition_fixtures
)
RETURNS boolean
LANGUAGE sql
STABLE
SET search_path = public
AS $$
  SELECT coalesce(p_fixture.competition_type, '') = 'cup'
    AND p_fixture.cup_code IS NOT NULL
    AND p_fixture.cup_round IS NOT NULL
    AND (
      EXISTS (
        SELECT 1
        FROM public.competition_cup_round_schedule s
        WHERE s.cup_code = p_fixture.cup_code
          AND s.round_no = p_fixture.cup_round::smallint
          AND s.stage = 'final'
      )
      OR p_fixture.cup_round = (
        SELECT max(n.round_no)
        FROM public.competition_cup_bracket_nodes n
        WHERE n.season_id = p_fixture.season_id
          AND n.cup_code = p_fixture.cup_code
      )
      OR p_fixture.cup_round = (
        SELECT max(s.round_no)
        FROM public.competition_cup_round_schedule s
        WHERE s.cup_code = p_fixture.cup_code
      )
      OR lower(coalesce(
        (
          SELECT s.round_label
          FROM public.competition_cup_round_schedule s
          WHERE s.cup_code = p_fixture.cup_code
            AND s.round_no = p_fixture.cup_round::smallint
          ORDER BY s.cup_leg DESC
          LIMIT 1
        ),
        ''
      )) LIKE '%final%'
    );
$$;

CREATE OR REPLACE FUNCTION public.competition_apply_cup_final_venue(p_fixture_id bigint)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_fixture public.competition_fixtures;
  v_name text;
  v_cap int;
BEGIN
  IF p_fixture_id IS NULL THEN
    RETURN;
  END IF;

  SELECT * INTO v_fixture
  FROM public.competition_fixtures
  WHERE id = p_fixture_id;

  IF NOT FOUND OR NOT public.competition_fixture_is_cup_final(v_fixture) THEN
    RETURN;
  END IF;

  SELECT
    coalesce(nullif(btrim(gs.cup_final_venue_name), ''), 'Wembley Stadium'),
    greatest(coalesce(gs.cup_final_venue_capacity, 90000), 1)
  INTO v_name, v_cap
  FROM public.global_settings gs
  WHERE gs.id = 1;

  v_name := coalesce(v_name, 'Wembley Stadium');
  v_cap := coalesce(v_cap, 90000);

  UPDATE public.competition_fixtures
  SET venue_name = v_name,
      venue_capacity = v_cap
  WHERE id = p_fixture_id
    AND (
      venue_name IS DISTINCT FROM v_name
      OR venue_capacity IS DISTINCT FROM v_cap
    );
END;
$function$;

-- ---------------------------------------------------------------------------
-- Create cup fixtures: stamp Wembley on finals
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.competition_create_cup_fixture_for_node(p_node_id bigint)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_node public.competition_cup_bracket_nodes;
  v_sched public.competition_cup_round_schedule;
  v_fixture_id bigint;
  v_cond jsonb;
BEGIN
  SELECT * INTO v_node FROM public.competition_cup_bracket_nodes WHERE id = p_node_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Bracket node not found';
  END IF;

  IF v_node.home_club_short_name IS NULL OR v_node.away_club_short_name IS NULL THEN
    RETURN NULL;
  END IF;

  IF v_node.fixture_id IS NOT NULL THEN
    PERFORM public.competition_apply_cup_final_venue(v_node.fixture_id);
    RETURN v_node.fixture_id;
  END IF;

  SELECT * INTO v_sched
  FROM public.competition_cup_round_schedule s
  WHERE s.cup_code = v_node.cup_code
    AND s.round_no = v_node.round_no
    AND s.cup_leg = coalesce(v_node.cup_leg, 1);

  IF NOT FOUND THEN
    RAISE EXCEPTION 'No cup schedule for % round % leg %',
      v_node.cup_code, v_node.round_no, v_node.cup_leg;
  END IF;

  v_cond := public.competition_roll_home_match_conditions(
    v_node.home_club_short_name,
    v_sched.gpsl_month
  );

  INSERT INTO public.competition_fixtures (
    season_id,
    division,
    competition_type,
    matchday,
    gpsl_month,
    week_in_month,
    home_club_short_name,
    away_club_short_name,
    weather,
    pitch_condition,
    kit_season,
    cup_code,
    cup_round,
    cup_match,
    cup_leg
  )
  VALUES (
    v_node.season_id,
    'cup',
    'cup',
    v_node.round_no,
    v_sched.gpsl_month,
    1,
    v_node.home_club_short_name,
    v_node.away_club_short_name,
    v_cond ->> 'weather',
    v_cond ->> 'pitch_condition',
    v_cond ->> 'kit_season',
    v_node.cup_code,
    v_node.round_no,
    v_node.match_no,
    coalesce(v_node.cup_leg, 1)
  )
  RETURNING id INTO v_fixture_id;

  UPDATE public.competition_cup_bracket_nodes
  SET fixture_id = v_fixture_id
  WHERE id = p_node_id;

  PERFORM public.competition_apply_cup_final_venue(v_fixture_id);

  RETURN v_fixture_id;
END;
$function$;

-- ---------------------------------------------------------------------------
-- Gate: finals use Wembley capacity, still 50/50
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.competition_settle_fixture_gates(p_fixture_id bigint)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_fixture public.competition_fixtures;
  v_capacity int;
  v_pos int;
  v_hist numeric;
  v_breakdown jsonb;
  v_total numeric;
  v_home_share numeric;
  v_away_share numeric;
  v_desc text;
  v_home_club text;
  v_away_club text;
  v_division text;
  v_gate_pct numeric;
  v_is_final boolean := false;
  v_venue text;
BEGIN
  IF p_fixture_id IS NULL THEN
    RETURN;
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.competition_finance_ledger
    WHERE fixture_id = p_fixture_id
      AND entry_type IN ('gate_league_home', 'gate_cup_share')
  ) THEN
    RETURN;
  END IF;

  SELECT * INTO v_fixture
  FROM public.competition_fixtures
  WHERE id = p_fixture_id
    AND status = 'played'
    AND home_goals IS NOT NULL
    AND away_goals IS NOT NULL;

  IF NOT FOUND THEN
    RETURN;
  END IF;

  v_home_club := v_fixture.home_club_short_name;
  v_away_club := v_fixture.away_club_short_name;
  v_is_final := public.competition_fixture_is_cup_final(v_fixture);

  IF v_is_final THEN
    PERFORM public.competition_apply_cup_final_venue(p_fixture_id);
    SELECT * INTO v_fixture
    FROM public.competition_fixtures
    WHERE id = p_fixture_id;
  END IF;

  IF v_fixture.competition_type = 'cup' THEN
    SELECT ccs.division INTO v_division
    FROM public.competition_club_seasons ccs
    WHERE ccs.season_id = v_fixture.season_id
      AND ccs.club_short_name = v_home_club;
  ELSE
    v_division := v_fixture.division;
  END IF;

  v_division := coalesce(v_division, 'superleague');

  IF v_is_final THEN
    v_capacity := coalesce(
      nullif(v_fixture.venue_capacity, 0),
      (SELECT gs.cup_final_venue_capacity FROM public.global_settings gs WHERE gs.id = 1),
      90000
    );
    v_venue := coalesce(
      nullif(btrim(v_fixture.venue_name), ''),
      (SELECT gs.cup_final_venue_name FROM public.global_settings gs WHERE gs.id = 1),
      'Wembley Stadium'
    );
  ELSE
    SELECT coalesce(c."Capacity", 0)::int INTO v_capacity
    FROM public."Clubs" c
    WHERE c."ShortName" = v_home_club;
    v_venue := NULL;
  END IF;

  v_pos := public.competition_club_table_position(
    v_fixture.season_id,
    v_division,
    v_home_club
  );
  v_hist := public.competition_club_history_avg_position(v_home_club, 5);
  v_breakdown := public.competition_compute_gate_total(
    v_capacity,
    v_pos,
    v_hist,
    v_home_club,
    v_fixture.season_id,
    v_division
  );

  IF v_is_final THEN
    v_breakdown := v_breakdown || jsonb_build_object(
      'venue_name', v_venue,
      'neutral_final', true,
      'capacity', v_capacity
    );
  END IF;

  v_total := (v_breakdown ->> 'total_gate')::numeric;

  IF v_total IS NULL OR v_total <= 0 THEN
    RETURN;
  END IF;

  v_gate_pct := coalesce(
    (v_breakdown ->> 'gate_fill_pct')::numeric,
    round((v_breakdown ->> 'attendance_rate')::numeric * 100, 1)
  );

  IF v_fixture.competition_type = 'league' THEN
    v_desc := format(
      'Gate MD%s — %s vs %s (home 100%%) · gate fill %s%%',
      v_fixture.matchday,
      v_home_club,
      v_away_club,
      v_gate_pct
    );

    PERFORM public.competition_credit_club_balance(v_home_club, v_total);

    INSERT INTO public.competition_finance_ledger (
      season_id, fixture_id, club_short_name, entry_type, amount, description, metadata
    )
    VALUES (
      v_fixture.season_id,
      p_fixture_id,
      v_home_club,
      'gate_league_home',
      v_total,
      v_desc,
      v_breakdown
    );
  ELSIF v_fixture.competition_type = 'cup' THEN
    v_home_share := round(v_total / 2.0, 2);
    v_away_share := v_total - v_home_share;

    IF v_is_final THEN
      v_desc := format(
        '%s Final — %s vs %s at %s (50/50 gate · cap %s · fill %s%%)',
        upper(v_fixture.cup_code),
        v_home_club,
        v_away_club,
        v_venue,
        v_capacity,
        v_gate_pct
      );
    ELSE
      v_desc := format(
        '%s R%s — %s vs %s (50/50 gate)',
        upper(v_fixture.cup_code),
        v_fixture.cup_round,
        v_home_club,
        v_away_club
      );
    END IF;

    PERFORM public.competition_credit_club_balance(v_home_club, v_home_share);
    PERFORM public.competition_credit_club_balance(v_away_club, v_away_share);

    INSERT INTO public.competition_finance_ledger (
      season_id, fixture_id, club_short_name, entry_type, amount, description, metadata
    )
    VALUES
      (
        v_fixture.season_id,
        p_fixture_id,
        v_home_club,
        'gate_cup_share',
        v_home_share,
        v_desc || ' (home)',
        v_breakdown
      ),
      (
        v_fixture.season_id,
        p_fixture_id,
        v_away_club,
        'gate_cup_share',
        v_away_share,
        v_desc || ' (away)',
        v_breakdown
      );
  END IF;
END;
$function$;

-- ---------------------------------------------------------------------------
-- TV: guarantee finals + 50/50 split
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.competition_tv_ensure_cup_final_selected(p_fixture_id bigint)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_fixture public.competition_fixtures;
  v_div text;
BEGIN
  IF p_fixture_id IS NULL THEN
    RETURN false;
  END IF;

  SELECT * INTO v_fixture
  FROM public.competition_fixtures
  WHERE id = p_fixture_id;

  IF NOT FOUND OR NOT public.competition_fixture_is_cup_final(v_fixture) THEN
    RETURN false;
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.competition_tv_fixture_selection s
    WHERE s.fixture_id = p_fixture_id
  ) THEN
    RETURN true;
  END IF;

  v_div := public.competition_tv_fixture_effective_division(v_fixture);

  INSERT INTO public.competition_tv_fixture_selection (
    season_id, fixture_id, division, gpsl_month, tv_score, reasons
  )
  VALUES (
    v_fixture.season_id,
    p_fixture_id,
    coalesce(v_div, 'superleague'),
    v_fixture.gpsl_month,
    9999,
    jsonb_build_array('cup_final_guaranteed')
  )
  ON CONFLICT ON CONSTRAINT competition_tv_fixture_selection_unique DO NOTHING;

  RETURN true;
END;
$function$;

CREATE OR REPLACE FUNCTION public.competition_tv_select_division_month(
  p_season_id bigint,
  p_division text,
  p_gpsl_month text,
  p_replace boolean DEFAULT false
)
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_s public.global_settings;
  v_before_md int;
  v_pick int;
  v_selected int := 0;
  v_fixture record;
  v_scored record;
  v_home_count int;
  v_away_count int;
  v_home_dry int;
  v_away_dry int;
  v_breakdown jsonb;
  v_running_home int;
  v_running_away int;
  v_full_fixture public.competition_fixtures;
  v_finals int := 0;
BEGIN
  IF p_season_id IS NULL OR p_division IS NULL OR p_gpsl_month IS NULL THEN
    RETURN 0;
  END IF;

  v_s := public.tv_revenue_settings();
  v_pick := greatest(v_s.tv_matches_per_month, 0);

  IF NOT p_replace AND EXISTS (
    SELECT 1 FROM public.competition_tv_fixture_selection
    WHERE season_id = p_season_id
      AND division = p_division
      AND gpsl_month = p_gpsl_month
  ) THEN
    RETURN 0;
  END IF;

  IF p_replace THEN
    DELETE FROM public.competition_tv_fixture_selection
    WHERE season_id = p_season_id
      AND division = p_division
      AND gpsl_month = p_gpsl_month;
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.competition_fixtures f
    WHERE f.season_id = p_season_id
      AND f.gpsl_month = p_gpsl_month
      AND f.status <> 'cancelled'
      AND (
        (f.competition_type = 'league' AND f.division = p_division)
        OR (
          f.competition_type = 'cup'
          AND public.competition_tv_fixture_effective_division(f) = p_division
        )
      )
  ) THEN
    RETURN 0;
  END IF;

  -- Cup finals always get TV (neutral venue — both clubs share the pool)
  FOR v_full_fixture IN
    SELECT f.*
    FROM public.competition_fixtures f
    WHERE f.season_id = p_season_id
      AND f.gpsl_month = p_gpsl_month
      AND f.status <> 'cancelled'
      AND f.competition_type = 'cup'
      AND public.competition_tv_fixture_effective_division(f) = p_division
      AND public.competition_fixture_is_cup_final(f)
  LOOP
    IF public.competition_tv_ensure_cup_final_selected(v_full_fixture.id) THEN
      v_finals := v_finals + 1;
    END IF;
  END LOOP;

  v_before_md := public.competition_tv_division_as_of_matchday(p_season_id, p_division, p_gpsl_month);

  CREATE TEMP TABLE IF NOT EXISTS tv_month_candidates (
    fixture_id bigint PRIMARY KEY,
    home_club text NOT NULL,
    away_club text NOT NULL,
    tv_score numeric NOT NULL,
    reasons jsonb NOT NULL,
    home_tv_count int NOT NULL,
    away_tv_count int NOT NULL
  ) ON COMMIT DROP;

  TRUNCATE tv_month_candidates;

  FOR v_fixture IN
    SELECT f.id, f.home_club_short_name, f.away_club_short_name
    FROM public.competition_fixtures f
    WHERE f.season_id = p_season_id
      AND f.gpsl_month = p_gpsl_month
      AND f.status <> 'cancelled'
      AND (
        (f.competition_type = 'league' AND f.division = p_division)
        OR (
          f.competition_type = 'cup'
          AND public.competition_tv_fixture_effective_division(f) = p_division
        )
      )
  LOOP
    v_home_count := public.competition_tv_club_count_before_month(
      p_season_id, p_division, v_fixture.home_club_short_name, p_gpsl_month
    );
    v_away_count := public.competition_tv_club_count_before_month(
      p_season_id, p_division, v_fixture.away_club_short_name, p_gpsl_month
    );
    v_home_dry := public.competition_tv_months_since_last(
      p_season_id, p_division, v_fixture.home_club_short_name, p_gpsl_month
    );
    v_away_dry := public.competition_tv_months_since_last(
      p_season_id, p_division, v_fixture.away_club_short_name, p_gpsl_month
    );

    v_breakdown := public.competition_tv_score_fixture(
      v_fixture.id,
      v_before_md,
      v_home_count,
      v_away_count,
      v_home_dry,
      v_away_dry
    );

    IF coalesce((v_breakdown ->> 'score')::numeric, 0) <= 0 THEN
      CONTINUE;
    END IF;

    INSERT INTO tv_month_candidates (
      fixture_id, home_club, away_club, tv_score, reasons, home_tv_count, away_tv_count
    )
    VALUES (
      v_fixture.id,
      v_fixture.home_club_short_name,
      v_fixture.away_club_short_name,
      (v_breakdown ->> 'score')::numeric,
      coalesce(v_breakdown -> 'reasons', '[]'::jsonb),
      v_home_count,
      v_away_count
    );
  END LOOP;

  FOR v_scored IN
    SELECT *
    FROM tv_month_candidates
    ORDER BY tv_score DESC, fixture_id ASC
  LOOP
    EXIT WHEN v_selected >= v_pick;

    IF EXISTS (
      SELECT 1
      FROM public.competition_tv_fixture_selection s
      WHERE s.season_id = p_season_id
        AND s.fixture_id = v_scored.fixture_id
    ) THEN
      CONTINUE;
    END IF;

    v_running_home := v_scored.home_tv_count + (
      SELECT count(*)::int
      FROM public.competition_tv_fixture_selection s
      JOIN public.competition_fixtures f ON f.id = s.fixture_id
      WHERE s.season_id = p_season_id
        AND s.division = p_division
        AND s.gpsl_month = p_gpsl_month
        AND (f.home_club_short_name = v_scored.home_club OR f.away_club_short_name = v_scored.home_club)
    );
    v_running_away := v_scored.away_tv_count + (
      SELECT count(*)::int
      FROM public.competition_tv_fixture_selection s
      JOIN public.competition_fixtures f ON f.id = s.fixture_id
      WHERE s.season_id = p_season_id
        AND s.division = p_division
        AND s.gpsl_month = p_gpsl_month
        AND (f.home_club_short_name = v_scored.away_club OR f.away_club_short_name = v_scored.away_club)
    );

    IF v_running_home >= v_s.tv_club_max_season AND v_running_away >= v_s.tv_club_max_season THEN
      CONTINUE;
    END IF;

    INSERT INTO public.competition_tv_fixture_selection (
      season_id, fixture_id, division, gpsl_month, tv_score, reasons
    )
    VALUES (
      p_season_id,
      v_scored.fixture_id,
      p_division,
      p_gpsl_month,
      v_scored.tv_score,
      v_scored.reasons
    )
    ON CONFLICT ON CONSTRAINT competition_tv_fixture_selection_unique DO NOTHING;

    IF FOUND THEN
      v_selected := v_selected + 1;
    END IF;
  END LOOP;

  RETURN v_selected + v_finals;
END;
$function$;

CREATE OR REPLACE FUNCTION public.competition_tv_settle_fixture(p_fixture_id bigint)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_fixture public.competition_fixtures;
  v_pool numeric;
  v_home_amount numeric;
  v_away_amount numeric;
  v_desc text;
  v_label text;
  v_meta jsonb;
  v_is_final boolean := false;
  v_home_pct int;
  v_away_pct int;
BEGIN
  IF p_fixture_id IS NULL THEN
    RETURN;
  END IF;

  SELECT * INTO v_fixture
  FROM public.competition_fixtures
  WHERE id = p_fixture_id
    AND competition_type IN ('league', 'cup')
    AND status = 'played'
    AND home_goals IS NOT NULL
    AND away_goals IS NOT NULL;

  IF NOT FOUND THEN
    RETURN;
  END IF;

  v_is_final := public.competition_fixture_is_cup_final(v_fixture);
  IF v_is_final THEN
    PERFORM public.competition_tv_ensure_cup_final_selected(p_fixture_id);
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.competition_tv_fixture_selection WHERE fixture_id = p_fixture_id
  ) THEN
    RETURN;
  END IF;

  v_pool := (SELECT tv_per_match_amount FROM public.global_settings WHERE id = 1);

  IF v_pool IS NULL OR v_pool <= 0 THEN
    RETURN;
  END IF;

  IF v_is_final THEN
    v_home_amount := round(v_pool / 2.0, 2);
    v_away_amount := v_pool - v_home_amount;
    v_home_pct := 50;
    v_away_pct := 50;
  ELSE
    v_home_amount := public.competition_tv_home_share(v_pool);
    v_away_amount := public.competition_tv_away_share(v_pool);
    v_home_pct := 80;
    v_away_pct := 20;
  END IF;

  v_label := public.competition_tv_fixture_settle_label(v_fixture);

  IF NOT EXISTS (
    SELECT 1 FROM public.competition_finance_ledger
    WHERE fixture_id = p_fixture_id
      AND club_short_name = v_fixture.home_club_short_name
      AND entry_type = 'tv_revenue'
  ) THEN
    v_desc := format(
      'TV revenue (home %s%%) %s — %s vs %s',
      v_home_pct,
      v_label,
      v_fixture.home_club_short_name,
      v_fixture.away_club_short_name
    );
    v_meta := jsonb_build_object(
      'gpsl_month', v_fixture.gpsl_month,
      'role', 'home',
      'tv_share_pct', v_home_pct,
      'tv_match_pool', v_pool,
      'competition_type', v_fixture.competition_type,
      'cup_code', v_fixture.cup_code,
      'neutral_final', v_is_final
    );
    IF to_regprocedure('public.post_club_ledger(text,text,numeric,text,jsonb,bigint,bigint,boolean,boolean)') IS NOT NULL THEN
      PERFORM public.post_club_ledger(
        v_fixture.home_club_short_name,
        'tv_revenue',
        v_home_amount,
        v_desc,
        v_meta,
        v_fixture.season_id,
        p_fixture_id,
        true,
        true
      );
    ELSE
      PERFORM public.competition_credit_club_balance(v_fixture.home_club_short_name, v_home_amount);
      INSERT INTO public.competition_finance_ledger (
        season_id, fixture_id, club_short_name, entry_type, amount, description, metadata
      )
      VALUES (
        v_fixture.season_id,
        p_fixture_id,
        v_fixture.home_club_short_name,
        'tv_revenue',
        v_home_amount,
        v_desc,
        v_meta
      );
    END IF;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.competition_finance_ledger
    WHERE fixture_id = p_fixture_id
      AND club_short_name = v_fixture.away_club_short_name
      AND entry_type = 'tv_revenue'
  ) THEN
    v_desc := format(
      'TV revenue (away %s%%) %s — %s vs %s',
      v_away_pct,
      v_label,
      v_fixture.home_club_short_name,
      v_fixture.away_club_short_name
    );
    v_meta := jsonb_build_object(
      'gpsl_month', v_fixture.gpsl_month,
      'role', 'away',
      'tv_share_pct', v_away_pct,
      'tv_match_pool', v_pool,
      'competition_type', v_fixture.competition_type,
      'cup_code', v_fixture.cup_code,
      'neutral_final', v_is_final
    );
    IF to_regprocedure('public.post_club_ledger(text,text,numeric,text,jsonb,bigint,bigint,boolean,boolean)') IS NOT NULL THEN
      PERFORM public.post_club_ledger(
        v_fixture.away_club_short_name,
        'tv_revenue',
        v_away_amount,
        v_desc,
        v_meta,
        v_fixture.season_id,
        p_fixture_id,
        true,
        true
      );
    ELSE
      PERFORM public.competition_credit_club_balance(v_fixture.away_club_short_name, v_away_amount);
      INSERT INTO public.competition_finance_ledger (
        season_id, fixture_id, club_short_name, entry_type, amount, description, metadata
      )
      VALUES (
        v_fixture.season_id,
        p_fixture_id,
        v_fixture.away_club_short_name,
        'tv_revenue',
        v_away_amount,
        v_desc,
        v_meta
      );
    END IF;
  END IF;
END;
$function$;

-- ---------------------------------------------------------------------------
-- Public fixtures view: expose venue (+ keep scheduling columns)
-- ---------------------------------------------------------------------------

DROP VIEW IF EXISTS public.competition_fixtures_public;

CREATE VIEW public.competition_fixtures_public
WITH (security_invoker = false)
AS
SELECT
  f.id,
  f.season_id,
  f.division,
  f.competition_type,
  f.cup_code,
  f.cup_round,
  f.cup_match,
  f.cup_leg,
  f.matchday,
  f.gpsl_month,
  f.week_in_month,
  f.home_club_short_name,
  hc."Club" AS home_club_name,
  f.away_club_short_name,
  ac."Club" AS away_club_name,
  f.weather,
  f.pitch_condition,
  f.kit_season,
  public.competition_club_continent(f.home_club_short_name) AS home_continent,
  f.venue_name,
  f.venue_capacity,
  f.home_goals,
  f.away_goals,
  f.status,
  f.is_forfeit,
  public.match_schedule_fixture_is_catch_up(f.id) AS is_catch_up,
  sub.submission_id,
  sub.submission_status,
  sub.submitted_by_club,
  sub.proposed_home_goals,
  sub.proposed_away_goals,
  sub.proposed_et_home_goals,
  sub.proposed_et_away_goals,
  sub.proposed_pen_winner_club,
  COALESCE(sch.status, 'unscheduled') AS schedule_status,
  sch.agreed_kickoff_at,
  sch.pending_proposal_id AS schedule_pending_proposal_id,
  sch.home_proposal_count AS schedule_home_proposal_count,
  sch.away_proposal_count AS schedule_away_proposal_count,
  COALESCE(sch.discord_hint_shown, false) AS schedule_discord_hint,
  sch.response_due_at AS schedule_response_due_at,
  sch.response_required_club_short_name AS schedule_response_required_club,
  chk.home_checked_in,
  chk.away_checked_in
FROM public.competition_fixtures f
JOIN public.competition_seasons s ON s.id = f.season_id
JOIN public."Clubs" hc ON hc."ShortName" = f.home_club_short_name
JOIN public."Clubs" ac ON ac."ShortName" = f.away_club_short_name
LEFT JOIN public.competition_fixture_schedule sch ON sch.fixture_id = f.id
LEFT JOIN LATERAL (
  SELECT
    EXISTS (
      SELECT 1 FROM public.competition_fixture_checkin c
      WHERE c.fixture_id = f.id AND c.club_short_name = f.home_club_short_name
    ) AS home_checked_in,
    EXISTS (
      SELECT 1 FROM public.competition_fixture_checkin c
      WHERE c.fixture_id = f.id AND c.club_short_name = f.away_club_short_name
    ) AS away_checked_in
) chk ON true
LEFT JOIN LATERAL (
  SELECT
    rs.id AS submission_id,
    rs.status AS submission_status,
    rs.submitted_by_club,
    rs.home_goals AS proposed_home_goals,
    rs.away_goals AS proposed_away_goals,
    rs.et_home_goals AS proposed_et_home_goals,
    rs.et_away_goals AS proposed_et_away_goals,
    rs.pen_winner_club_short_name AS proposed_pen_winner_club
  FROM public.competition_result_submissions rs
  WHERE rs.fixture_id = f.id
    AND rs.status = 'pending'
    AND (
      public.is_gpsl_admin()
      OR public.my_club_shortname() = f.home_club_short_name
      OR public.my_club_shortname() = f.away_club_short_name
    )
  LIMIT 1
) sub ON true
WHERE s.status = 'active' AND s.is_current = true;

GRANT SELECT ON public.competition_fixtures_public TO authenticated;
GRANT SELECT ON public.competition_fixtures_public TO anon;

-- ---------------------------------------------------------------------------
-- Club fixtures RPC: venue + cup attendance from gate_cup_share
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.club_fixtures_my_club()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := public.my_club_shortname();
BEGIN
  IF v_club IS NULL OR btrim(v_club) = '' THEN
    RETURN '[]'::jsonb;
  END IF;

  RETURN coalesce(
    (
      SELECT jsonb_agg(row_to_json(t)::jsonb ORDER BY t.gpsl_month_sort, t.matchday, t.id)
      FROM (
        SELECT
          f.id,
          f.season_id,
          f.division,
          f.competition_type,
          f.cup_code,
          f.cup_round,
          f.cup_match,
          f.matchday,
          f.gpsl_month,
          f.week_in_month,
          public.competition_gpsl_month_sort(f.gpsl_month) AS gpsl_month_sort,
          f.home_club_short_name,
          hc."Club" AS home_club_name,
          f.away_club_short_name,
          ac."Club" AS away_club_name,
          f.weather,
          f.pitch_condition,
          f.kit_season,
          public.competition_club_continent(f.home_club_short_name) AS home_continent,
          f.venue_name,
          f.venue_capacity,
          f.home_goals,
          f.away_goals,
          f.status,
          f.is_forfeit,
          (f.home_club_short_name = v_club) AS is_home,
          coalesce(sch.status, 'unscheduled') AS schedule_status,
          sch.agreed_kickoff_at,
          CASE
            WHEN f.competition_type = 'league' AND f.status = 'played' THEN
              public.competition_club_table_position_as_of(
                f.season_id,
                f.division,
                v_club,
                f.matchday + 1
              )
            ELSE NULL
          END AS league_position,
          CASE
            WHEN f.status = 'played' THEN (
              SELECT round(
                (l.metadata ->> 'capacity')::numeric
                * (l.metadata ->> 'attendance_rate')::numeric
              )::int
              FROM public.competition_finance_ledger l
              WHERE l.fixture_id = f.id
                AND l.entry_type IN ('gate_league_home', 'gate_cup_share')
              LIMIT 1
            )
            ELSE NULL
          END AS attendance,
          CASE
            WHEN f.status = 'played' THEN (
              SELECT coalesce(
                jsonb_agg(
                  jsonb_build_object(
                    'player_id', m.player_id,
                    'player_name', p."Name",
                    'goals', m.goals,
                    'assists', m.assists,
                    'is_player_of_match', m.is_player_of_match,
                    'yellow_card', coalesce(m.yellow_card, false),
                    'red_card', coalesce(m.red_card, false)
                  )
                  ORDER BY
                    m.is_player_of_match DESC,
                    m.goals DESC,
                    m.assists DESC,
                    m.red_card DESC,
                    m.yellow_card DESC,
                    p."Name"
                ),
                '[]'::jsonb
              )
              FROM public.competition_match_player_stats m
              JOIN public."Players" p ON p."Konami_ID"::text = m.player_id
              WHERE m.fixture_id = f.id
                AND m.club_short_name = v_club
                AND (
                  m.goals > 0
                  OR m.assists > 0
                  OR m.is_player_of_match
                  OR coalesce(m.yellow_card, false)
                  OR coalesce(m.red_card, false)
                )
            )
            ELSE '[]'::jsonb
          END AS match_contributions,
          CASE
            WHEN f.status = 'played'
             AND to_regclass('public.competition_player_injuries') IS NOT NULL THEN (
              SELECT coalesce(
                jsonb_agg(
                  jsonb_build_object(
                    'player_id', i.player_id,
                    'player_name', p."Name",
                    'label', coalesce(nullif(btrim(i.label), ''), cat.name, 'Injury'),
                    'severity', coalesce(i.severity, cat.severity)
                  )
                  ORDER BY p."Name"
                ),
                '[]'::jsonb
              )
              FROM public.competition_player_injuries i
              LEFT JOIN public."Players" p ON p."Konami_ID"::text = i.player_id::text
              LEFT JOIN public.competition_injury_catalogue cat ON cat.id = i.catalogue_id
              WHERE i.source_fixture_id = f.id
                AND i.club_short_name = v_club
            )
            ELSE '[]'::jsonb
          END AS match_injuries
        FROM public.competition_fixtures f
        JOIN public.competition_seasons s ON s.id = f.season_id
        JOIN public."Clubs" hc ON hc."ShortName" = f.home_club_short_name
        JOIN public."Clubs" ac ON ac."ShortName" = f.away_club_short_name
        LEFT JOIN public.competition_fixture_schedule sch ON sch.fixture_id = f.id
        WHERE s.is_current = true
          AND (
            f.home_club_short_name = v_club
            OR f.away_club_short_name = v_club
          )
      ) t
    ),
    '[]'::jsonb
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.club_fixtures_my_club() TO authenticated;
GRANT EXECUTE ON FUNCTION public.competition_fixture_is_cup_final(public.competition_fixtures) TO authenticated;
GRANT EXECUTE ON FUNCTION public.competition_apply_cup_final_venue(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.competition_tv_ensure_cup_final_selected(bigint) TO authenticated;

-- Backfill existing cup finals (also available as competition_admin_backfill_cup_final_venues)
DO $$
DECLARE
  r record;
  v_name text;
  v_cap int;
BEGIN
  SELECT
    coalesce(nullif(btrim(gs.cup_final_venue_name), ''), 'Wembley Stadium'),
    greatest(coalesce(gs.cup_final_venue_capacity, 90000), 1)
  INTO v_name, v_cap
  FROM public.global_settings gs
  WHERE gs.id = 1;

  v_name := coalesce(v_name, 'Wembley Stadium');
  v_cap := coalesce(v_cap, 90000);

  FOR r IN
    SELECT f.id
    FROM public.competition_fixtures f
    WHERE f.competition_type = 'cup'
      AND public.competition_fixture_is_cup_final(f)
  LOOP
    UPDATE public.competition_fixtures
    SET venue_name = v_name,
        venue_capacity = v_cap
    WHERE id = r.id;
  END LOOP;

  UPDATE public.competition_fixtures f
  SET venue_name = v_name,
      venue_capacity = v_cap
  WHERE f.competition_type = 'cup'
    AND f.cup_round = (
      SELECT max(n.round_no)
      FROM public.competition_cup_bracket_nodes n
      WHERE n.season_id = f.season_id
        AND n.cup_code = f.cup_code
    );
END $$;

NOTIFY pgrst, 'reload schema';
