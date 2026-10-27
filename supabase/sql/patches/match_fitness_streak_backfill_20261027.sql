-- =============================================================================
-- Backfill match-fitness consecutive streaks from played league/cup stats
--
-- Why squad shows 0/4: consecutive_appearances only advances when a fixture is
-- fitness-ticked after confirm. Older matches were never rebuilt into the table.
--
-- Rebuilds current-season non-injured rows:
--   start = +1.0 · subbed on = +0.5 · miss = L1 reset / L2+ drop one level
--   forfeits ignored · preseason ignored
--
-- Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.admin_match_fitness_rebuild_streaks(
  p_season_id bigint DEFAULT NULL,
  p_club text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season bigint := p_season_id;
  v_club_filter text := upper(nullif(btrim(coalesce(p_club, '')), ''));
  v_to_max int := 4;
  v_fx record;
  v_club text;
  v_pid text;
  v_streak numeric;
  v_level int;
  v_credit numeric;
  v_started boolean;
  v_subbed boolean;
  v_players int := 0;
  v_fixtures int := 0;
BEGIN
  IF NOT public.is_gpsl_admin()
     AND current_user NOT IN ('postgres', 'supabase_admin', 'service_role') THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF v_season IS NULL THEN
    SELECT id INTO v_season
    FROM public.competition_seasons
    WHERE is_current = true
    ORDER BY id DESC
    LIMIT 1;
  END IF;
  IF v_season IS NULL THEN
    RAISE EXCEPTION 'No current season';
  END IF;

  BEGIN
    v_to_max := greatest(
      coalesce((public.competition_injury_settings_row()).fitness_matches_to_max, 4),
      1
    );
  EXCEPTION WHEN OTHERS THEN
    v_to_max := 4;
  END;

  -- Reset non-injured fitness rows for the rebuild scope
  UPDATE public.competition_player_match_fitness f
  SET consecutive_appearances = 0,
      fitness_level = 1,
      updated_at = now()
  WHERE f.season_id = v_season
    AND (v_club_filter IS NULL OR upper(btrim(f.club_short_name)) = v_club_filter)
    AND NOT EXISTS (
      SELECT 1
      FROM public.competition_player_injuries i
      WHERE i.player_id = f.player_id
        AND i.status = 'active'
        AND (
          coalesce(i.matches_out_remaining, 0) > 0
          OR coalesce(i.recovery_remaining, 0) > 0
        )
    );

  -- Clear tick dedupe so future confirms still work; rebuild writes rows directly
  DELETE FROM public.competition_fixture_match_fitness_tick t
  USING public.competition_fixtures fx
  WHERE t.fixture_id = fx.id
    AND fx.season_id = v_season
    AND (v_club_filter IS NULL OR upper(btrim(t.club_short_name)) = v_club_filter);

  FOR v_fx IN
    SELECT
      fx.id,
      fx.home_club_short_name,
      fx.away_club_short_name,
      fx.gpsl_month,
      fx.matchday,
      fx.competition_type
    FROM public.competition_fixtures fx
    WHERE fx.season_id = v_season
      AND fx.status = 'played'
      AND coalesce(fx.competition_type, 'league') IN ('league', 'cup')
      AND coalesce(fx.is_forfeit, false) = false
      AND (
        v_club_filter IS NULL
        OR upper(btrim(fx.home_club_short_name)) = v_club_filter
        OR upper(btrim(fx.away_club_short_name)) = v_club_filter
      )
      AND (
        to_regprocedure('public.competition_injury_is_preseason_month(text)') IS NULL
        OR NOT public.competition_injury_is_preseason_month(fx.gpsl_month)
      )
    ORDER BY
      public.competition_gpsl_month_sort(fx.gpsl_month) NULLS LAST,
      coalesce(fx.matchday, 0),
      fx.id
  LOOP
    v_fixtures := v_fixtures + 1;

    FOREACH v_club IN ARRAY ARRAY[
      upper(btrim(v_fx.home_club_short_name)),
      upper(btrim(v_fx.away_club_short_name))
    ]
    LOOP
      IF v_club IS NULL OR v_club = '' THEN
        CONTINUE;
      END IF;
      IF v_club_filter IS NOT NULL AND v_club <> v_club_filter THEN
        CONTINUE;
      END IF;

      FOR v_pid IN
        SELECT DISTINCT x.pid
        FROM (
          SELECT p."Konami_ID"::text AS pid
          FROM public."Players" p
          WHERE upper(btrim(coalesce(p."Contracted_Team", ''))) = v_club
          UNION
          SELECT m.player_id
          FROM public.competition_match_player_stats m
          WHERE m.fixture_id = v_fx.id
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
          CONTINUE;
        END IF;

        SELECT f.consecutive_appearances, f.fitness_level
        INTO v_streak, v_level
        FROM public.competition_player_match_fitness f
        WHERE f.season_id = v_season AND f.player_id = v_pid;

        v_streak := coalesce(v_streak, 0);
        v_level := coalesce(v_level, 1);

        SELECT
          coalesce(bool_or(m.started), false),
          coalesce(bool_or(m.subbed_on AND NOT coalesce(m.started, false)), false)
        INTO v_started, v_subbed
        FROM public.competition_match_player_stats m
        WHERE m.fixture_id = v_fx.id
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
        ELSE
          v_level := greatest(1, v_level - 1);
          v_streak := public.competition_match_fitness_streak_for_level(v_level, v_to_max);
        END IF;

        PERFORM public.competition_match_fitness_ensure(
          v_season, v_pid, v_club, v_level, v_streak
        );
        v_players := v_players + 1;
      END LOOP;

      -- Mark fixture/club as ticked so live confirms don't double-apply
      INSERT INTO public.competition_fixture_match_fitness_tick (fixture_id, club_short_name)
      VALUES (v_fx.id, v_club)
      ON CONFLICT DO NOTHING;
    END LOOP;
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true,
    'season_id', v_season,
    'club', v_club_filter,
    'fixtures_processed', v_fixtures,
    'player_updates', v_players,
    'matches_to_max', v_to_max
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.admin_match_fitness_rebuild_streaks(bigint, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_match_fitness_rebuild_streaks(bigint, text) TO authenticated;

-- Run for whole current season (or pass a club: 'JUB')
SELECT public.admin_match_fitness_rebuild_streaks(NULL, NULL) AS rebuild;

-- Spot-check (change club if needed)
SELECT
  f.club_short_name,
  f.player_id,
  f.fitness_level,
  f.consecutive_appearances
FROM public.competition_player_match_fitness f
WHERE f.season_id = (
  SELECT id FROM public.competition_seasons WHERE is_current = true ORDER BY id DESC LIMIT 1
)
  AND f.consecutive_appearances > 0
ORDER BY f.consecutive_appearances DESC, f.club_short_name, f.player_id
LIMIT 40;

NOTIFY pgrst, 'reload schema';
