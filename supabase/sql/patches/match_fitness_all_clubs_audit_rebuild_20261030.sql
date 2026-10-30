-- Match fitness: all-clubs audit + durable root-cause fix + full rebuild
-- =============================================================================
-- BAR showed Apps>0 / streak 0 because fitness ticks could lock with no stats.
-- This patch:
--   A) Pre-audit (mismatches / missing ticks)
--   B) Durable serve_injuries (injury serve + defer guard + fitness tick + roll)
--   C) Tick requires appeared stats before consuming dedupe row
--   D) Rebuild streaks for EVERY club (August+ league/cup)
--   E) Post-audit (should be clean)
-- Safe re-run. Admin / SQL editor.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- A) PRE-AUDIT
-- ---------------------------------------------------------------------------

-- A1: Played league/cup fixtures with club appearances but no fitness tick
WITH cur AS (
  SELECT id AS season_id
  FROM public.competition_seasons
  WHERE is_current = true
  ORDER BY id DESC
  LIMIT 1
),
sides AS (
  SELECT
    f.id AS fixture_id,
    f.gpsl_month,
    f.matchday,
    f.competition_type,
    upper(btrim(x.club)) AS club,
    (
      SELECT count(*) FROM public.competition_match_player_stats m
      WHERE m.fixture_id = f.id
        AND upper(btrim(m.club_short_name)) = upper(btrim(x.club))
        AND m.appeared
    ) AS appeared_n,
    EXISTS (
      SELECT 1 FROM public.competition_fixture_match_fitness_tick t
      WHERE t.fixture_id = f.id
        AND upper(btrim(t.club_short_name)) = upper(btrim(x.club))
    ) AS has_tick
  FROM public.competition_fixtures f
  JOIN cur ON cur.season_id = f.season_id
  CROSS JOIN LATERAL (
    VALUES (f.home_club_short_name), (f.away_club_short_name)
  ) AS x(club)
  WHERE f.status = 'played'
    AND coalesce(f.is_forfeit, false) = false
    AND coalesce(f.competition_type, 'league') IN ('league', 'cup')
    AND lower(btrim(coalesce(f.gpsl_month, ''))) NOT IN ('june', 'july', 'playoffs')
    AND (
      to_regprocedure('public.competition_injury_is_preseason_month(text)') IS NULL
      OR NOT public.competition_injury_is_preseason_month(f.gpsl_month)
    )
)
SELECT
  'pre_missing_ticks' AS section,
  club,
  count(*) AS fixtures_missing_tick
FROM sides
WHERE appeared_n > 0 AND NOT has_tick
GROUP BY club
ORDER BY fixtures_missing_tick DESC, club;

-- A2: Healthy players with starts but consecutive still 0 (the BAR-class bug)
WITH cur AS (
  SELECT id AS season_id
  FROM public.competition_seasons
  WHERE is_current = true
  ORDER BY id DESC
  LIMIT 1
),
apps AS (
  SELECT
    upper(btrim(m.club_short_name)) AS club,
    m.player_id,
    count(*) FILTER (WHERE m.appeared AND m.started) AS starts,
    count(*) FILTER (
      WHERE m.appeared AND m.subbed_on AND NOT coalesce(m.started, false)
    ) AS subs
  FROM public.competition_match_player_stats m
  JOIN public.competition_fixtures f ON f.id = m.fixture_id
  JOIN cur ON cur.season_id = f.season_id
  WHERE f.status = 'played'
    AND coalesce(f.is_forfeit, false) = false
    AND coalesce(f.competition_type, 'league') IN ('league', 'cup')
    AND lower(btrim(coalesce(f.gpsl_month, ''))) NOT IN ('june', 'july', 'playoffs')
  GROUP BY 1, 2
)
SELECT
  'pre_zero_streak_with_apps' AS section,
  a.club,
  count(*) AS players,
  sum(a.starts) AS total_starts
FROM apps a
JOIN cur ON true
LEFT JOIN public.competition_player_match_fitness f
  ON f.season_id = cur.season_id AND f.player_id = a.player_id
WHERE (a.starts + a.subs) >= 2
  AND coalesce(f.consecutive_appearances, 0) = 0
  AND NOT EXISTS (
    SELECT 1 FROM public.competition_player_injuries i
    WHERE i.player_id = a.player_id
      AND i.status = 'active'
      AND (
        coalesce(i.matches_out_remaining, 0) > 0
        OR coalesce(i.recovery_remaining, 0) > 0
      )
  )
GROUP BY a.club
ORDER BY players DESC, a.club;

-- A3: Wire health
SELECT
  'pre_wire_health' AS section,
  to_regprocedure('public.competition_match_fitness_tick_club(bigint,text)') IS NOT NULL AS tick_fn,
  to_regprocedure('public.admin_match_fitness_rebuild_streaks(bigint,text)') IS NOT NULL AS rebuild_fn,
  position(
    'competition_match_fitness_tick_club' IN pg_get_functiondef(
      'public.competition_serve_injuries_for_fixture(bigint)'::regprocedure
    )
  ) > 0 AS serve_calls_tick,
  position(
    'gpsl.defer_injury_fitness' IN pg_get_functiondef(
      'public.competition_serve_injuries_for_fixture(bigint)'::regprocedure
    )
  ) > 0 AS serve_has_defer,
  position(
    'no_appeared_stats' IN pg_get_functiondef(
      'public.competition_match_fitness_tick_club(bigint,text)'::regprocedure
    )
  ) > 0 AS tick_requires_stats;

-- ---------------------------------------------------------------------------
-- B) Durable serve_injuries (do not depend on soft-wire surviving)
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

    IF to_regprocedure('public.competition_match_fitness_sync_from_injury(bigint)') IS NOT NULL THEN
      PERFORM public.competition_match_fitness_sync_from_injury(v_row.injury_id);
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

    IF FOUND
       AND to_regprocedure(
         'public.competition_match_fitness_set_return_level(bigint,text,text)'
       ) IS NOT NULL THEN
      PERFORM public.competition_match_fitness_set_return_level(
        coalesce(v_rec.season_id, v_fixture.season_id),
        v_rec.player_id,
        v_rec.club_short_name
      );
    END IF;
  END LOOP;

  -- Confirm path sets this on during hard work; soft-tail turns it off and
  -- calls again so fitness/roll still run after stats are committed.
  IF current_setting('gpsl.defer_injury_fitness', true) = 'on' THEN
    RETURN;
  END IF;

  IF v_fixture.id IS NOT NULL
     AND to_regprocedure('public.competition_match_fitness_tick_club(bigint,text)') IS NOT NULL THEN
    PERFORM public.competition_match_fitness_tick_club(
      p_fixture_id, v_fixture.home_club_short_name
    );
    PERFORM public.competition_match_fitness_tick_club(
      p_fixture_id, v_fixture.away_club_short_name
    );
  END IF;

  IF to_regprocedure('public.competition_injury_roll_for_fixture(bigint)') IS NOT NULL THEN
    PERFORM public.competition_injury_roll_for_fixture(p_fixture_id);
  END IF;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_serve_injuries_for_fixture(bigint)
  TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- C) Tick must not lock without appearance stats
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
  v_pid text;
  v_streak numeric;
  v_level int;
  v_credit numeric;
  v_started boolean;
  v_subbed boolean;
  v_n_up int := 0;
  v_n_down int := 0;
  v_n_skip int := 0;
  v_inserted int := 0;
  v_appeared_n int := 0;
BEGIN
  IF v_club = '' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_club');
  END IF;

  SELECT * INTO v_fixture FROM public.competition_fixtures WHERE id = p_fixture_id;
  IF NOT FOUND OR v_fixture.status <> 'played' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_played');
  END IF;

  IF coalesce(v_fixture.is_forfeit, false) THEN
    RETURN jsonb_build_object('ok', true, 'skipped', true, 'reason', 'forfeit');
  END IF;

  IF coalesce(v_fixture.competition_type, 'league') NOT IN ('league', 'cup') THEN
    RETURN jsonb_build_object('ok', true, 'skipped', true, 'reason', 'not_league_cup');
  END IF;

  IF to_regprocedure('public.competition_injury_is_preseason_month(text)') IS NOT NULL
     AND public.competition_injury_is_preseason_month(v_fixture.gpsl_month) THEN
    RETURN jsonb_build_object('ok', true, 'skipped', true, 'reason', 'preseason');
  END IF;

  SELECT count(*)::int INTO v_appeared_n
  FROM public.competition_match_player_stats m
  WHERE m.fixture_id = p_fixture_id
    AND upper(btrim(m.club_short_name)) = v_club
    AND m.appeared = true;

  IF coalesce(v_appeared_n, 0) = 0 THEN
    RETURN jsonb_build_object(
      'ok', true,
      'skipped', true,
      'reason', 'no_appeared_stats',
      'club', v_club
    );
  END IF;

  INSERT INTO public.competition_fixture_match_fitness_tick (fixture_id, club_short_name)
  VALUES (p_fixture_id, v_club)
  ON CONFLICT DO NOTHING;
  GET DIAGNOSTICS v_inserted = ROW_COUNT;
  IF v_inserted = 0 THEN
    RETURN jsonb_build_object('ok', true, 'deduped', true);
  END IF;

  BEGIN
    v_s := public.competition_injury_settings_row();
    v_to_max := greatest(coalesce(v_s.fitness_matches_to_max, 4), 1);
  EXCEPTION WHEN OTHERS THEN
    v_to_max := 4;
  END;

  FOR v_pid IN
    SELECT DISTINCT x.pid
    FROM (
      SELECT p."Konami_ID"::text AS pid
      FROM public."Players" p
      WHERE upper(btrim(coalesce(p."Contracted_Team", ''))) = v_club
      UNION
      SELECT m.player_id
      FROM public.competition_match_player_stats m
      WHERE m.fixture_id = p_fixture_id
        AND upper(btrim(m.club_short_name)) = v_club
        AND m.appeared = true
    ) x
    WHERE nullif(btrim(x.pid), '') IS NOT NULL
  LOOP
    IF EXISTS (
      SELECT 1
      FROM public.competition_player_injuries i
      WHERE i.player_id = v_pid
        AND i.status = 'active'
        AND (
          coalesce(i.matches_out_remaining, 0) > 0
          OR coalesce(i.recovery_remaining, 0) > 0
        )
    ) THEN
      v_n_skip := v_n_skip + 1;
      CONTINUE;
    END IF;

    v_streak := 0;
    v_level := 1;
    v_started := false;
    v_subbed := false;
    v_credit := 0;

    SELECT f.consecutive_appearances, f.fitness_level
    INTO v_streak, v_level
    FROM public.competition_player_match_fitness f
    WHERE f.season_id = v_fixture.season_id AND f.player_id = v_pid;

    IF NOT FOUND THEN
      v_streak := 0;
      v_level := 1;
    ELSE
      v_streak := coalesce(v_streak, 0);
      v_level := coalesce(v_level, 1);
    END IF;

    SELECT
      coalesce(bool_or(m.started), false),
      coalesce(bool_or(m.subbed_on AND NOT coalesce(m.started, false)), false)
    INTO v_started, v_subbed
    FROM public.competition_match_player_stats m
    WHERE m.fixture_id = p_fixture_id
      AND upper(btrim(m.club_short_name)) = v_club
      AND m.player_id = v_pid
      AND m.appeared = true;

    v_started := coalesce(v_started, false);
    v_subbed := coalesce(v_subbed, false);

    IF v_started THEN
      v_credit := 1.0;
    ELSIF v_subbed THEN
      v_credit := 0.5;
    ELSE
      v_credit := 0;
    END IF;

    IF v_credit > 0 THEN
      v_streak := round((v_streak + v_credit)::numeric, 1);
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
    'frozen_injured', v_n_skip,
    'appeared_rows', v_appeared_n
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_match_fitness_tick_club(bigint, text)
  TO service_role;

-- ---------------------------------------------------------------------------
-- D) Full rebuild (all clubs)
-- ---------------------------------------------------------------------------
DO $need$
BEGIN
  IF to_regprocedure('public.admin_match_fitness_rebuild_streaks(bigint, text)') IS NULL THEN
    RAISE EXCEPTION
      'admin_match_fitness_rebuild_streaks missing — run match_fitness_streak_backfill_20261027.sql first';
  END IF;
END;
$need$;

SELECT public.admin_match_fitness_rebuild_streaks(NULL, NULL) AS all_clubs_rebuild;

-- ---------------------------------------------------------------------------
-- E) POST-AUDIT
-- ---------------------------------------------------------------------------

WITH cur AS (
  SELECT id AS season_id
  FROM public.competition_seasons
  WHERE is_current = true
  ORDER BY id DESC
  LIMIT 1
),
sides AS (
  SELECT
    f.id AS fixture_id,
    upper(btrim(x.club)) AS club,
    (
      SELECT count(*) FROM public.competition_match_player_stats m
      WHERE m.fixture_id = f.id
        AND upper(btrim(m.club_short_name)) = upper(btrim(x.club))
        AND m.appeared
    ) AS appeared_n,
    EXISTS (
      SELECT 1 FROM public.competition_fixture_match_fitness_tick t
      WHERE t.fixture_id = f.id
        AND upper(btrim(t.club_short_name)) = upper(btrim(x.club))
    ) AS has_tick
  FROM public.competition_fixtures f
  JOIN cur ON cur.season_id = f.season_id
  CROSS JOIN LATERAL (
    VALUES (f.home_club_short_name), (f.away_club_short_name)
  ) AS x(club)
  WHERE f.status = 'played'
    AND coalesce(f.is_forfeit, false) = false
    AND coalesce(f.competition_type, 'league') IN ('league', 'cup')
    AND lower(btrim(coalesce(f.gpsl_month, ''))) NOT IN ('june', 'july', 'playoffs')
    AND (
      to_regprocedure('public.competition_injury_is_preseason_month(text)') IS NULL
      OR NOT public.competition_injury_is_preseason_month(f.gpsl_month)
    )
)
SELECT
  'post_missing_ticks' AS section,
  club,
  count(*) AS fixtures_missing_tick
FROM sides
WHERE appeared_n > 0 AND NOT has_tick
GROUP BY club
ORDER BY fixtures_missing_tick DESC, club;

WITH cur AS (
  SELECT id AS season_id
  FROM public.competition_seasons
  WHERE is_current = true
  ORDER BY id DESC
  LIMIT 1
),
apps AS (
  SELECT
    upper(btrim(m.club_short_name)) AS club,
    m.player_id,
    count(*) FILTER (WHERE m.appeared AND m.started) AS starts,
    count(*) FILTER (
      WHERE m.appeared AND m.subbed_on AND NOT coalesce(m.started, false)
    ) AS subs
  FROM public.competition_match_player_stats m
  JOIN public.competition_fixtures f ON f.id = m.fixture_id
  JOIN cur ON cur.season_id = f.season_id
  WHERE f.status = 'played'
    AND coalesce(f.is_forfeit, false) = false
    AND coalesce(f.competition_type, 'league') IN ('league', 'cup')
    AND lower(btrim(coalesce(f.gpsl_month, ''))) NOT IN ('june', 'july', 'playoffs')
  GROUP BY 1, 2
)
SELECT
  'post_zero_streak_with_apps' AS section,
  a.club,
  count(*) AS players,
  sum(a.starts) AS total_starts
FROM apps a
JOIN cur ON true
LEFT JOIN public.competition_player_match_fitness f
  ON f.season_id = cur.season_id AND f.player_id = a.player_id
WHERE (a.starts + a.subs) >= 2
  AND coalesce(f.consecutive_appearances, 0) = 0
  AND NOT EXISTS (
    SELECT 1 FROM public.competition_player_injuries i
    WHERE i.player_id = a.player_id
      AND i.status = 'active'
      AND (
        coalesce(i.matches_out_remaining, 0) > 0
        OR coalesce(i.recovery_remaining, 0) > 0
      )
  )
GROUP BY a.club
ORDER BY players DESC, a.club;

-- Club summary after rebuild (healthy only)
WITH cur AS (
  SELECT id AS season_id
  FROM public.competition_seasons
  WHERE is_current = true
  ORDER BY id DESC
  LIMIT 1
)
SELECT
  'post_club_summary' AS section,
  f.club_short_name AS club,
  count(*) AS fitness_rows,
  count(*) FILTER (WHERE f.consecutive_appearances > 0) AS with_streak,
  count(*) FILTER (WHERE f.consecutive_appearances = 0) AS zero_streak,
  round(avg(f.consecutive_appearances)::numeric, 2) AS avg_streak,
  max(f.consecutive_appearances) AS max_streak
FROM public.competition_player_match_fitness f
JOIN cur ON cur.season_id = f.season_id
WHERE NOT EXISTS (
  SELECT 1 FROM public.competition_player_injuries i
  WHERE i.player_id = f.player_id
    AND i.status = 'active'
    AND (
      coalesce(i.matches_out_remaining, 0) > 0
      OR coalesce(i.recovery_remaining, 0) > 0
    )
)
GROUP BY f.club_short_name
ORDER BY with_streak DESC, club;

SELECT
  'post_wire_health' AS section,
  position(
    'competition_match_fitness_tick_club' IN pg_get_functiondef(
      'public.competition_serve_injuries_for_fixture(bigint)'::regprocedure
    )
  ) > 0 AS serve_calls_tick,
  position(
    'gpsl.defer_injury_fitness' IN pg_get_functiondef(
      'public.competition_serve_injuries_for_fixture(bigint)'::regprocedure
    )
  ) > 0 AS serve_has_defer,
  position(
    'no_appeared_stats' IN pg_get_functiondef(
      'public.competition_match_fitness_tick_club(bigint,text)'::regprocedure
    )
  ) > 0 AS tick_requires_stats;

NOTIFY pgrst, 'reload schema';
