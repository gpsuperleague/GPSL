-- =============================================================================
-- Vacant clubs (Clubs.owner_id IS NULL): walkovers + void matches
--
-- Settled automatically when each GPSL month locks (end of the week):
--   League
--     • Owned v vacant  → 3–0 to the owned club (forfeit, no fine)
--     • Vacant v vacant → VOID: counts as played (+1 MP) for both,
--                         no W/D/L, no goals, no points; form shows "-"
--   Cup
--     • Owned v vacant  → 3–0 to the owned club (advances)
--     • Vacant v vacant → 3–0 to a random side (same side both legs)
--
-- Vacancy is judged at the moment the month locks, so a club taken over
-- mid-week plays its fixtures normally. Fixtures involving a vacant club
-- can't be simulated / submitted by anyone (they wait for the walkover).
--
-- Runs from pg_cron every 5 minutes (cheap no-op when nothing is due).
-- Admin can run it now:  SELECT public.admin_vacant_walkovers_run_now();
--
-- Run once in Supabase SQL Editor. Safe re-run.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1) Void flag
-- ---------------------------------------------------------------------------
ALTER TABLE public.competition_fixtures
  ADD COLUMN IF NOT EXISTS is_void boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN public.competition_fixtures.is_void IS
  'Vacant v vacant league match: status played, no score, +1 MP each, no points.';

-- ---------------------------------------------------------------------------
-- 2) Helpers
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.competition_club_is_vacant(p_club text)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT coalesce(
    (SELECT c.owner_id IS NULL FROM public."Clubs" c WHERE c."ShortName" = btrim(p_club) LIMIT 1),
    false
  );
$$;

GRANT EXECUTE ON FUNCTION public.competition_club_is_vacant(text) TO authenticated;

CREATE OR REPLACE FUNCTION public.competition_fixture_involves_vacant_club(p_fixture_id bigint)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT coalesce((
    SELECT f.competition_type IN ('league', 'cup')
       AND (
         public.competition_club_is_vacant(f.home_club_short_name)
         OR public.competition_club_is_vacant(f.away_club_short_name)
       )
    FROM public.competition_fixtures f
    WHERE f.id = p_fixture_id
  ), false);
$$;

GRANT EXECUTE ON FUNCTION public.competition_fixture_involves_vacant_club(bigint) TO authenticated;

-- ---------------------------------------------------------------------------
-- 3) Apply one vacant-club result
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.competition_apply_vacant_fixture_result(p_fixture_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_f public.competition_fixtures;
  v_home_vacant boolean;
  v_away_vacant boolean;
  v_loser text;
  v_winner text;
  v_low text;
  v_high text;
  v_title text;
  v_body text;
BEGIN
  SELECT * INTO v_f
  FROM public.competition_fixtures
  WHERE id = p_fixture_id
  FOR UPDATE;

  IF NOT FOUND OR v_f.status IS DISTINCT FROM 'scheduled'
     OR v_f.competition_type NOT IN ('league', 'cup') THEN
    RETURN jsonb_build_object('ok', false, 'fixture_id', p_fixture_id, 'reason', 'not_applicable');
  END IF;

  v_home_vacant := public.competition_club_is_vacant(v_f.home_club_short_name);
  v_away_vacant := public.competition_club_is_vacant(v_f.away_club_short_name);

  IF NOT v_home_vacant AND NOT v_away_vacant THEN
    RETURN jsonb_build_object('ok', false, 'fixture_id', p_fixture_id, 'reason', 'both_owned');
  END IF;

  UPDATE public.competition_result_submissions
  SET status = 'rejected',
      reject_reason = 'Superseded by vacant-club walkover',
      responded_at = now()
  WHERE fixture_id = p_fixture_id
    AND status = 'pending';

  -- League vacant v vacant → void
  IF v_home_vacant AND v_away_vacant AND v_f.competition_type = 'league' THEN
    UPDATE public.competition_fixtures
    SET status = 'played',
        is_void = true,
        home_goals = NULL,
        away_goals = NULL
    WHERE id = p_fixture_id;

    PERFORM public.competition_try_pay_league_division_prizes(v_f.season_id, v_f.division);

    RETURN jsonb_build_object('ok', true, 'fixture_id', p_fixture_id, 'result', 'void');
  END IF;

  IF v_home_vacant AND v_away_vacant THEN
    -- Cup vacant v vacant: deterministic "random" loser so both legs agree
    v_low := least(v_f.home_club_short_name, v_f.away_club_short_name);
    v_high := greatest(v_f.home_club_short_name, v_f.away_club_short_name);
    v_loser := CASE
      WHEN substr(md5(concat_ws(':', v_f.season_id, v_f.cup_code, v_low, v_high)), 1, 1) < '8'
      THEN v_low ELSE v_high
    END;
  ELSIF v_home_vacant THEN
    v_loser := v_f.home_club_short_name;
  ELSE
    v_loser := v_f.away_club_short_name;
  END IF;

  v_winner := CASE
    WHEN v_loser = v_f.home_club_short_name THEN v_f.away_club_short_name
    ELSE v_f.home_club_short_name
  END;

  UPDATE public.competition_fixtures
  SET home_goals = CASE WHEN v_winner = v_f.home_club_short_name THEN 3 ELSE 0 END,
      away_goals = CASE WHEN v_winner = v_f.away_club_short_name THEN 3 ELSE 0 END,
      status = 'played',
      is_forfeit = true,
      forfeit_loser_club = v_loser
  WHERE id = p_fixture_id;

  IF v_f.competition_type = 'cup' THEN
    PERFORM public.competition_cup_on_fixture_played(p_fixture_id);
  ELSE
    PERFORM public.competition_try_pay_league_division_prizes(v_f.season_id, v_f.division);
  END IF;

  -- Tell the owned winner (vacant clubs have no inbox)
  IF NOT public.competition_club_is_vacant(v_winner) THEN
    BEGIN
      v_title := public.competition_fixture_inbox_title(p_fixture_id, 'Walkover win');
      v_body := public.competition_fixture_inbox_body(
        p_fixture_id,
        format('%s has no owner, so you win 3–0 by walkover.', public.club_display_name(v_loser))
      );
      PERFORM public.owner_inbox_send(
        'match_forfeit_applied', v_title, v_body,
        v_winner, NULL, p_fixture_id,
        NULL, NULL, NULL,
        'fixture_schedule.html?fixture=' || p_fixture_id::text,
        'vacant_walkover:' || p_fixture_id::text,
        v_f.gpsl_month, v_f.season_id, NULL
      );
    EXCEPTION WHEN OTHERS THEN
      NULL;
    END;
  END IF;

  RETURN jsonb_build_object(
    'ok', true, 'fixture_id', p_fixture_id, 'result', 'walkover',
    'winner', v_winner, 'loser', v_loser
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.competition_apply_vacant_fixture_result(bigint) FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 4) Month-lock processor (one job row per locked GPSL month)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.competition_process_vacant_walkovers(p_season_id bigint DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season_id bigint := p_season_id;
  v_cal record;
  v_fx record;
  v_job_key text;
  v_month_sort smallint;
  v_res jsonb;
  v_month_results jsonb;
  v_walkovers int;
  v_voids int;
  v_out jsonb := '[]'::jsonb;
BEGIN
  IF v_season_id IS NULL THEN
    SELECT id INTO v_season_id
    FROM public.competition_seasons
    WHERE is_current = true AND status = 'active'
    ORDER BY id DESC
    LIMIT 1;
  END IF;

  IF v_season_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_active_season');
  END IF;

  FOR v_cal IN
    SELECT c.gpsl_month
    FROM public.competition_season_calendar c
    WHERE c.season_id = v_season_id
      AND c.lock_at IS NOT NULL
      AND c.lock_at <= now()
    ORDER BY public.competition_gpsl_month_sort(c.gpsl_month)
  LOOP
    v_job_key := 'vacant_walkovers:' || v_cal.gpsl_month;

    IF EXISTS (
      SELECT 1 FROM public.competition_season_calendar_jobs j
      WHERE j.season_id = v_season_id AND j.job_key = v_job_key
    ) THEN
      CONTINUE;
    END IF;

    v_month_sort := public.competition_gpsl_month_sort(v_cal.gpsl_month);
    v_month_results := '[]'::jsonb;
    v_walkovers := 0;
    v_voids := 0;

    FOR v_fx IN
      SELECT f.id
      FROM public.competition_fixtures f
      WHERE f.season_id = v_season_id
        AND f.status = 'scheduled'
        AND f.competition_type IN ('league', 'cup')
        AND f.gpsl_month IS NOT NULL
        AND public.competition_gpsl_month_sort(f.gpsl_month) <= v_month_sort
        AND (
          public.competition_club_is_vacant(f.home_club_short_name)
          OR public.competition_club_is_vacant(f.away_club_short_name)
        )
      ORDER BY public.competition_gpsl_month_sort(f.gpsl_month), f.matchday NULLS LAST, f.id
    LOOP
      v_res := public.competition_apply_vacant_fixture_result(v_fx.id);
      IF coalesce((v_res->>'ok')::boolean, false) THEN
        IF v_res->>'result' = 'void' THEN
          v_voids := v_voids + 1;
        ELSE
          v_walkovers := v_walkovers + 1;
        END IF;
        v_month_results := v_month_results || jsonb_build_array(v_res);
      END IF;
    END LOOP;

    INSERT INTO public.competition_season_calendar_jobs (season_id, job_key, gpsl_month, result)
    VALUES (
      v_season_id, v_job_key, v_cal.gpsl_month,
      jsonb_build_object('ok', true, 'walkovers', v_walkovers, 'voids', v_voids, 'fixtures', v_month_results)
    )
    ON CONFLICT (season_id, job_key) DO UPDATE
      SET result = excluded.result, gpsl_month = excluded.gpsl_month, ran_at = now();

    v_out := v_out || jsonb_build_array(jsonb_build_object(
      'gpsl_month', v_cal.gpsl_month, 'walkovers', v_walkovers, 'voids', v_voids
    ));
  END LOOP;

  RETURN jsonb_build_object('ok', true, 'season_id', v_season_id, 'processed', v_out);
END;
$function$;

REVOKE ALL ON FUNCTION public.competition_process_vacant_walkovers(bigint) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.competition_process_vacant_walkovers(bigint) TO service_role;

CREATE OR REPLACE FUNCTION public.admin_vacant_walkovers_run_now()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;
  RETURN public.competition_process_vacant_walkovers(NULL);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.admin_vacant_walkovers_run_now() TO authenticated;

-- ---------------------------------------------------------------------------
-- 5) Nobody can play / simulate / submit a fixture with a vacant club
--    (injected at the top of competition_assert_fixture_month_unlocked,
--    which Simulate, Instant result and result submit all call)
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_oid oid;
  v_def text;
  v_new text;
BEGIN
  FOR v_oid IN
    SELECT p.oid
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname = 'competition_assert_fixture_month_unlocked'
      AND p.prokind = 'f'
  LOOP
    v_def := pg_get_functiondef(v_oid);
    IF position('competition_fixture_involves_vacant_club' IN v_def) > 0 THEN
      CONTINUE;
    END IF;
    v_new := regexp_replace(
      v_def,
      E'\\nBEGIN\\n',
      E'\nBEGIN\n'
      || E'  IF public.competition_fixture_involves_vacant_club(p_fixture_id) THEN\n'
      || E'    RAISE EXCEPTION ''This fixture involves a club with no owner. It is settled automatically when the GPSL month ends (3–0 walkover, or void if both clubs have no owner).'';\n'
      || E'  END IF;\n'
    );
    IF v_new IS DISTINCT FROM v_def THEN
      EXECUTE v_new;
      RAISE NOTICE 'Vacant-club guard added to %', v_oid::regprocedure;
    ELSE
      RAISE WARNING 'Could not inject vacant-club guard into %', v_oid::regprocedure;
    END IF;
  END LOOP;
END $$;

-- ---------------------------------------------------------------------------
-- 6) Void fixtures count in tables (MP only)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.competition_fixture_counts_in_tables(p_fixture_id bigint)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_fixture public.competition_fixtures;
  v_active text;
  v_fixture_sort smallint;
  v_active_sort smallint;
BEGIN
  SELECT * INTO v_fixture
  FROM public.competition_fixtures f
  WHERE f.id = p_fixture_id;

  IF NOT FOUND THEN
    RETURN false;
  END IF;

  IF v_fixture.status IS DISTINCT FROM 'played' THEN
    RETURN false;
  END IF;

  IF NOT coalesce(v_fixture.is_void, false)
     AND (v_fixture.home_goals IS NULL OR v_fixture.away_goals IS NULL) THEN
    RETURN false;
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.competition_season_calendar_config c
    WHERE c.season_id = v_fixture.season_id
  ) THEN
    RETURN true;
  END IF;

  v_active := public.competition_active_gpsl_month(v_fixture.season_id, now());

  IF v_active IS NULL THEN
    RETURN EXISTS (
      SELECT 1
      FROM public.competition_season_calendar m
      WHERE m.season_id = v_fixture.season_id
        AND lower(btrim(m.gpsl_month)) = lower(btrim(coalesce(v_fixture.gpsl_month, '')))
        AND now() >= m.unlock_at
    );
  END IF;

  v_fixture_sort := public.competition_gpsl_month_sort(v_fixture.gpsl_month);
  v_active_sort := public.competition_gpsl_month_sort(v_active);

  IF v_fixture_sort IS NULL OR v_active_sort IS NULL THEN
    RETURN true;
  END IF;

  RETURN v_fixture_sort <= v_active_sort;
END;
$function$;

-- ---------------------------------------------------------------------------
-- 7) Live standings: void = +1 MP, no W/D/L/goals/points, form "-"
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW public.competition_standings_public
WITH (security_invoker = false)
AS
WITH active_season AS (
  SELECT id
  FROM public.competition_seasons
  WHERE is_current = true AND status = 'active'
  LIMIT 1
),
registered AS (
  SELECT
    ccs.season_id,
    ccs.division,
    ccs.club_short_name,
    c."Club" AS club_name
  FROM public.competition_club_seasons ccs
  JOIN public."Clubs" c ON c."ShortName" = ccs.club_short_name
  JOIN active_season s ON s.id = ccs.season_id
  WHERE ccs.division IN ('superleague', 'championship_a', 'championship_b')
),
played AS (
  SELECT f.*
  FROM public.competition_fixtures f
  JOIN active_season s ON s.id = f.season_id
  WHERE f.competition_type = 'league'
    AND f.status = 'played'
    AND (f.is_void OR (f.home_goals IS NOT NULL AND f.away_goals IS NOT NULL))
    AND public.competition_fixture_counts_in_tables(f.id)
),
home_apps AS (
  SELECT
    season_id, division, home_club_short_name AS club_short_name, matchday,
    1 AS mp,
    CASE WHEN NOT is_void AND home_goals > away_goals THEN 1 ELSE 0 END AS w,
    CASE WHEN NOT is_void AND home_goals = away_goals THEN 1 ELSE 0 END AS d,
    CASE WHEN NOT is_void AND home_goals < away_goals THEN 1 ELSE 0 END AS l,
    coalesce(home_goals, 0) AS gf, coalesce(away_goals, 0) AS ga,
    CASE
      WHEN is_void THEN '-'
      WHEN home_goals > away_goals THEN 'W'
      WHEN home_goals = away_goals THEN 'D'
      ELSE 'L'
    END AS result_char
  FROM played
),
away_apps AS (
  SELECT
    season_id, division, away_club_short_name AS club_short_name, matchday,
    1 AS mp,
    CASE WHEN NOT is_void AND away_goals > home_goals THEN 1 ELSE 0 END AS w,
    CASE WHEN NOT is_void AND away_goals = home_goals THEN 1 ELSE 0 END AS d,
    CASE WHEN NOT is_void AND away_goals < home_goals THEN 1 ELSE 0 END AS l,
    coalesce(away_goals, 0) AS gf, coalesce(home_goals, 0) AS ga,
    CASE
      WHEN is_void THEN '-'
      WHEN away_goals > home_goals THEN 'W'
      WHEN away_goals = home_goals THEN 'D'
      ELSE 'L'
    END AS result_char
  FROM played
),
all_apps AS (
  SELECT * FROM home_apps UNION ALL SELECT * FROM away_apps
),
totals AS (
  SELECT
    season_id, division, club_short_name,
    sum(mp)::int AS mp, sum(w)::int AS w, sum(d)::int AS d, sum(l)::int AS l,
    sum(gf)::int AS gf, sum(ga)::int AS ga, sum(gf) - sum(ga) AS gd,
    sum(w) * 3 + sum(d) AS pts
  FROM all_apps
  GROUP BY season_id, division, club_short_name
),
point_adj AS (
  SELECT a.season_id, a.club_short_name, sum(a.points_delta)::int AS adj_pts
  FROM public.competition_league_points_adjustments a
  JOIN active_season s ON s.id = a.season_id
  GROUP BY a.season_id, a.club_short_name
),
form_strings AS (
  SELECT
    r.season_id, r.division, r.club_short_name,
    (
      SELECT string_agg(x.result_char, '' ORDER BY x.matchday)
      FROM (
        SELECT a2.result_char, a2.matchday
        FROM all_apps a2
        WHERE a2.season_id = r.season_id
          AND a2.division = r.division
          AND a2.club_short_name = r.club_short_name
        ORDER BY a2.matchday DESC
        LIMIT 10
      ) x
    ) AS form_last10
  FROM registered r
),
combined AS (
  SELECT
    r.season_id, r.division, r.club_short_name, r.club_name,
    coalesce(t.mp, 0) AS mp, coalesce(t.w, 0) AS w, coalesce(t.d, 0) AS d,
    coalesce(t.l, 0) AS l, coalesce(t.gf, 0) AS gf, coalesce(t.ga, 0) AS ga,
    coalesce(t.gd, 0) AS gd,
    coalesce(t.pts, 0) + coalesce(pa.adj_pts, 0) AS pts,
    coalesce(f.form_last10, '') AS form_last10
  FROM registered r
  LEFT JOIN totals t
    ON t.season_id = r.season_id AND t.division = r.division AND t.club_short_name = r.club_short_name
  LEFT JOIN point_adj pa
    ON pa.season_id = r.season_id AND pa.club_short_name = r.club_short_name
  LEFT JOIN form_strings f
    ON f.season_id = r.season_id AND f.division = r.division AND f.club_short_name = r.club_short_name
)
SELECT
  season_id, division, club_short_name, club_name,
  row_number() OVER (
    PARTITION BY season_id, division
    ORDER BY pts DESC, gd DESC, gf DESC, club_name ASC
  )::int AS table_position,
  mp, w, d, l, gf, ga, gd, pts, form_last10
FROM combined;

GRANT SELECT ON public.competition_standings_public TO authenticated;
GRANT SELECT ON public.competition_standings_public TO anon;

-- ---------------------------------------------------------------------------
-- 8) Any-season standings (seeding / movements): same void rule
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.competition_league_standings_for_season(
  p_season_id bigint
)
RETURNS TABLE (
  season_id bigint,
  division text,
  club_short_name text,
  club_name text,
  table_position int,
  mp int,
  w int,
  d int,
  l int,
  gf int,
  ga int,
  gd int,
  pts int
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF p_season_id IS NULL THEN
    RETURN;
  END IF;

  IF (
    SELECT count(*)::int
    FROM public.competition_club_season_archive a
    WHERE a.season_id = p_season_id
      AND a.division IN ('superleague', 'championship_a', 'championship_b')
  ) >= 60 THEN
    RETURN QUERY
    SELECT
      a.season_id,
      a.division,
      a.club_short_name,
      coalesce(c."Club", a.club_short_name) AS club_name,
      a.final_position::int AS table_position,
      coalesce(a.mp, 0)::int,
      coalesce(a.won, 0)::int,
      coalesce(a.drawn, 0)::int,
      coalesce(a.lost, 0)::int,
      coalesce(a.gf, 0)::int,
      coalesce(a.ga, 0)::int,
      coalesce(a.gd, 0)::int,
      coalesce(a.pts, 0)::int
    FROM public.competition_club_season_archive a
    LEFT JOIN public."Clubs" c ON c."ShortName" = a.club_short_name
    WHERE a.season_id = p_season_id
      AND a.division IN ('superleague', 'championship_a', 'championship_b')
    ORDER BY a.division, a.final_position;
    RETURN;
  END IF;

  RETURN QUERY
  WITH registered AS (
    SELECT
      ccs.season_id,
      ccs.division,
      ccs.club_short_name,
      c."Club" AS club_name
    FROM public.competition_club_seasons ccs
    JOIN public."Clubs" c ON c."ShortName" = ccs.club_short_name
    WHERE ccs.season_id = p_season_id
      AND ccs.division IN ('superleague', 'championship_a', 'championship_b')
  ),
  played AS (
    SELECT f.*
    FROM public.competition_fixtures f
    WHERE f.season_id = p_season_id
      AND f.competition_type = 'league'
      AND f.status = 'played'
      AND (f.is_void OR (f.home_goals IS NOT NULL AND f.away_goals IS NOT NULL))
  ),
  home_apps AS (
    SELECT
      season_id, division, home_club_short_name AS club_short_name,
      1 AS mp,
      CASE WHEN NOT is_void AND home_goals > away_goals THEN 1 ELSE 0 END AS w,
      CASE WHEN NOT is_void AND home_goals = away_goals THEN 1 ELSE 0 END AS d,
      CASE WHEN NOT is_void AND home_goals < away_goals THEN 1 ELSE 0 END AS l,
      coalesce(home_goals, 0) AS gf, coalesce(away_goals, 0) AS ga
    FROM played
  ),
  away_apps AS (
    SELECT
      season_id, division, away_club_short_name AS club_short_name,
      1 AS mp,
      CASE WHEN NOT is_void AND away_goals > home_goals THEN 1 ELSE 0 END AS w,
      CASE WHEN NOT is_void AND away_goals = home_goals THEN 1 ELSE 0 END AS d,
      CASE WHEN NOT is_void AND away_goals < home_goals THEN 1 ELSE 0 END AS l,
      coalesce(away_goals, 0) AS gf, coalesce(home_goals, 0) AS ga
    FROM played
  ),
  all_apps AS (
    SELECT * FROM home_apps UNION ALL SELECT * FROM away_apps
  ),
  totals AS (
    SELECT
      a.season_id, a.division, a.club_short_name,
      sum(a.mp)::int AS mp, sum(a.w)::int AS w, sum(a.d)::int AS d, sum(a.l)::int AS l,
      sum(a.gf)::int AS gf, sum(a.ga)::int AS ga, (sum(a.gf) - sum(a.ga))::int AS gd,
      (sum(a.w) * 3 + sum(a.d))::int AS pts
    FROM all_apps a
    GROUP BY a.season_id, a.division, a.club_short_name
  ),
  point_adj AS (
    SELECT a.season_id, a.club_short_name, sum(a.points_delta)::int AS adj_pts
    FROM public.competition_league_points_adjustments a
    WHERE a.season_id = p_season_id
    GROUP BY a.season_id, a.club_short_name
  ),
  combined AS (
    SELECT
      r.season_id, r.division, r.club_short_name, r.club_name,
      coalesce(t.mp, 0) AS mp, coalesce(t.w, 0) AS w, coalesce(t.d, 0) AS d,
      coalesce(t.l, 0) AS l, coalesce(t.gf, 0) AS gf, coalesce(t.ga, 0) AS ga,
      coalesce(t.gd, 0) AS gd,
      coalesce(t.pts, 0) + coalesce(pa.adj_pts, 0) AS pts
    FROM registered r
    LEFT JOIN totals t
      ON t.season_id = r.season_id
     AND t.division = r.division
     AND t.club_short_name = r.club_short_name
    LEFT JOIN point_adj pa
      ON pa.season_id = r.season_id
     AND pa.club_short_name = r.club_short_name
  )
  SELECT
    c.season_id,
    c.division,
    c.club_short_name,
    c.club_name,
    row_number() OVER (
      PARTITION BY c.season_id, c.division
      ORDER BY c.pts DESC, c.gd DESC, c.gf DESC, c.club_name ASC
    )::int AS table_position,
    c.mp, c.w, c.d, c.l, c.gf, c.ga, c.gd, c.pts
  FROM combined c;
END;
$function$;

-- ---------------------------------------------------------------------------
-- 9) GPSL Sport secondary stories: skip walkovers and void matches
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  r record;
  v_def text;
  v_new text;
BEGIN
  FOR r IN
    SELECT p.oid
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.prokind = 'f'
      AND p.proname LIKE 'gpsl_sport%'
  LOOP
    v_def := pg_get_functiondef(r.oid);
    IF position('ORDER BY (coalesce(f.home_goals, 0) + coalesce(f.away_goals, 0))' IN v_def) = 0
       OR position('NOT coalesce(f.is_void, false)' IN v_def) > 0 THEN
      CONTINUE;
    END IF;
    v_new := regexp_replace(
      v_def,
      E'AND f\\.status = ''played''(\\s+)ORDER BY \\(coalesce\\(f\\.home_goals, 0\\) \\+ coalesce\\(f\\.away_goals, 0\\)\\)',
      E'AND f.status = ''played'' AND NOT coalesce(f.is_void, false) AND NOT coalesce(f.is_forfeit, false)\\1ORDER BY (coalesce(f.home_goals, 0) + coalesce(f.away_goals, 0))',
      'g'
    );
    IF v_new IS DISTINCT FROM v_def THEN
      EXECUTE v_new;
      RAISE NOTICE 'GPSL Sport stories skip walkovers/voids in %', r.oid::regprocedure;
    END IF;
  END LOOP;
END $$;

-- ---------------------------------------------------------------------------
-- 10) Cron: every 5 minutes (no-op unless a GPSL month has just locked)
-- ---------------------------------------------------------------------------
DO $cron$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'gpsl-vacant-walkovers') THEN
      PERFORM cron.unschedule('gpsl-vacant-walkovers');
    END IF;
    PERFORM cron.schedule(
      'gpsl-vacant-walkovers',
      '*/5 * * * *',
      $job$SELECT public.competition_process_vacant_walkovers(NULL);$job$
    );
  ELSE
    RAISE WARNING 'pg_cron not installed — run SELECT public.admin_vacant_walkovers_run_now(); after each GPSL month locks.';
  END IF;
END $cron$;

NOTIFY pgrst, 'reload schema';
