-- Match fitness: don't lock a fixture tick with no player stats + rebuild BAR
-- =============================================================================
-- Symptom: squad shows season Apps = 3 but Match Fitness streak "0/4".
--
-- "n/4" is consecutive fitness units toward the next risk band (start=1,
-- sub=0.5), NOT season appearances. It reads competition_player_match_fitness
-- .consecutive_appearances. If that column is 0, UI shows 0/4.
--
-- Root cause: competition_match_fitness_tick_club inserts the dedupe tick
-- *before* checking stats. If confirm/soft-tail ran with no appeared rows yet
-- (or a race), the whole squad is treated as "miss" → streak stays 0, and
-- later stats never re-tick (deduped).
--
-- Fix:
--   1) Require ≥1 appeared row for the club before consuming the tick
--   2) Rebuild BAR streaks from played league/cup stats (August+)
-- Safe re-run.
-- =============================================================================

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

  -- Do NOT consume the tick until this club has appearance rows — otherwise a
  -- premature tick zeros the whole squad and later stats never re-apply.
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

  v_s := public.competition_injury_settings_row();
  v_to_max := greatest(coalesce(v_s.fitness_matches_to_max, 4), 1);

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

-- Clear bad BAR ticks (so rebuild can re-apply) and rebuild streaks
DO $fix$
BEGIN
  IF to_regprocedure('public.admin_match_fitness_rebuild_streaks(bigint, text)') IS NULL THEN
    RAISE NOTICE 'admin_match_fitness_rebuild_streaks missing — run match_fitness_streak_backfill_20261027.sql';
    RETURN;
  END IF;
END;
$fix$;

SELECT public.admin_match_fitness_rebuild_streaks(NULL, 'BAR') AS bar_fitness_rebuild;

-- Spot-check: GK / high-app BAR players should now show consecutive ≈ starts
WITH cur AS (
  SELECT id AS season_id
  FROM public.competition_seasons
  WHERE is_current = true
  ORDER BY id DESC
  LIMIT 1
),
apps AS (
  SELECT
    m.player_id,
    count(*) FILTER (WHERE m.appeared AND m.started) AS starts,
    count(*) FILTER (
      WHERE m.appeared AND m.subbed_on AND NOT coalesce(m.started, false)
    ) AS subs
  FROM public.competition_match_player_stats m
  JOIN public.competition_fixtures fx ON fx.id = m.fixture_id
  JOIN cur ON cur.season_id = fx.season_id
  WHERE upper(btrim(m.club_short_name)) = 'BAR'
    AND fx.status = 'played'
    AND coalesce(fx.competition_type, 'league') IN ('league', 'cup')
    AND lower(btrim(coalesce(fx.gpsl_month, ''))) NOT IN ('june', 'july', 'playoffs')
  GROUP BY m.player_id
)
SELECT
  p."Name",
  p."Position",
  a.starts,
  a.subs,
  f.consecutive_appearances,
  f.fitness_level
FROM apps a
JOIN cur ON true
LEFT JOIN public.competition_player_match_fitness f
  ON f.season_id = cur.season_id AND f.player_id = a.player_id
LEFT JOIN public."Players" p ON p."Konami_ID"::text = a.player_id
ORDER BY a.starts DESC, a.subs DESC, p."Name"
LIMIT 25;

NOTIFY pgrst, 'reload schema';
