-- =============================================================================
-- Backfill match-fitness consecutive streaks (v3)
--
-- Why you still saw 16.0 / 12.0:
--   competition_match_fitness_streak_for_level(5)=16 and (4)=12.
--   Injured players are mapped onto that scale and v1/v2 SKIPPED them, so
--   those rows never changed.
--
-- v3:
--   1) Reset ALL fitness rows (including injured)
--   2) Rebuild from August+ league/cup appearance stats (start=1, sub=0.5)
--   3) Re-apply injury fitness scale for active injuries
--   4) Spot-check separates healthy vs injured
--
-- Safe re-run. Run entire file in SQL Editor.
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
  v_aug int := public.competition_gpsl_month_sort('august');
  v_club text;
  v_fx record;
  v_pid text;
  v_streak numeric;
  v_level int;
  v_credit numeric;
  v_started boolean;
  v_subbed boolean;
  v_appeared boolean;
  v_clubs int := 0;
  v_fixtures int := 0;
  v_updates int := 0;
  v_inj_synced int := 0;
  v_inj record;
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

  -- Reset EVERYONE in scope (injured re-synced at the end)
  UPDATE public.competition_player_match_fitness f
  SET consecutive_appearances = 0,
      fitness_level = 1,
      updated_at = now()
  WHERE f.season_id = v_season
    AND (v_club_filter IS NULL OR upper(btrim(f.club_short_name)) = v_club_filter);

  DELETE FROM public.competition_fixture_match_fitness_tick t
  USING public.competition_fixtures fx
  WHERE t.fixture_id = fx.id
    AND fx.season_id = v_season
    AND (v_club_filter IS NULL OR upper(btrim(t.club_short_name)) = v_club_filter);

  FOR v_club IN
    SELECT DISTINCT upper(btrim(c."ShortName")) AS club
    FROM public."Clubs" c
    WHERE coalesce(c.is_archived, false) = false
      AND c.owner_id IS NOT NULL
      AND (v_club_filter IS NULL OR upper(btrim(c."ShortName")) = v_club_filter)
    ORDER BY 1
  LOOP
    v_clubs := v_clubs + 1;

    FOR v_fx IN
      SELECT fx.id, fx.gpsl_month, fx.matchday
      FROM public.competition_fixtures fx
      WHERE fx.season_id = v_season
        AND fx.status = 'played'
        AND coalesce(fx.competition_type, 'league') IN ('league', 'cup')
        AND coalesce(fx.is_forfeit, false) = false
        AND (
          upper(btrim(fx.home_club_short_name)) = v_club
          OR upper(btrim(fx.away_club_short_name)) = v_club
        )
        AND lower(btrim(coalesce(fx.gpsl_month, ''))) NOT IN ('june', 'july', 'playoffs')
        AND coalesce(public.competition_gpsl_month_sort(fx.gpsl_month), 0) >= coalesce(v_aug, 0)
        AND (
          to_regprocedure('public.competition_injury_is_preseason_month(text)') IS NULL
          OR NOT public.competition_injury_is_preseason_month(fx.gpsl_month)
        )
        AND EXISTS (
          SELECT 1
          FROM public.competition_match_player_stats m
          WHERE m.fixture_id = fx.id
            AND upper(btrim(m.club_short_name)) = v_club
            AND m.appeared = true
        )
      ORDER BY
        public.competition_gpsl_month_sort(fx.gpsl_month) NULLS LAST,
        coalesce(fx.matchday, 0),
        fx.id
    LOOP
      v_fixtures := v_fixtures + 1;

      FOR v_pid IN
        SELECT DISTINCT x.pid
        FROM (
          SELECT f.player_id AS pid
          FROM public.competition_player_match_fitness f
          WHERE f.season_id = v_season
            AND upper(btrim(f.club_short_name)) = v_club
            AND f.consecutive_appearances > 0
          UNION
          SELECT m.player_id
          FROM public.competition_match_player_stats m
          WHERE m.fixture_id = v_fx.id
            AND upper(btrim(m.club_short_name)) = v_club
            AND m.appeared = true
        ) x
        WHERE nullif(btrim(x.pid), '') IS NOT NULL
      LOOP
        -- Appearance rebuild ignores injury freeze; injury scale reapplied below
        v_streak := 0;
        v_level := 1;
        v_appeared := false;
        v_started := false;
        v_subbed := false;
        v_credit := 0;

        SELECT f.consecutive_appearances, f.fitness_level
        INTO v_streak, v_level
        FROM public.competition_player_match_fitness f
        WHERE f.season_id = v_season AND f.player_id = v_pid;

        IF NOT FOUND THEN
          v_streak := 0;
          v_level := 1;
        ELSE
          v_streak := coalesce(v_streak, 0);
          v_level := coalesce(v_level, 1);
        END IF;

        SELECT
          coalesce(bool_or(m.appeared), false),
          coalesce(bool_or(m.started), false),
          coalesce(bool_or(m.subbed_on AND NOT coalesce(m.started, false)), false)
        INTO v_appeared, v_started, v_subbed
        FROM public.competition_match_player_stats m
        WHERE m.fixture_id = v_fx.id
          AND upper(btrim(m.club_short_name)) = v_club
          AND m.player_id = v_pid;

        v_appeared := coalesce(v_appeared, false);
        v_started := coalesce(v_started, false);
        v_subbed := coalesce(v_subbed, false);

        IF v_appeared AND v_started THEN
          v_credit := 1.0;
        ELSIF v_appeared AND v_subbed THEN
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
        v_updates := v_updates + 1;
      END LOOP;

      INSERT INTO public.competition_fixture_match_fitness_tick (fixture_id, club_short_name)
      VALUES (v_fx.id, v_club)
      ON CONFLICT DO NOTHING;
    END LOOP;
  END LOOP;

  -- Put injured players back on the injury fitness meter (L5↔16 units, etc.)
  IF to_regprocedure('public.competition_match_fitness_sync_from_injury(bigint)') IS NOT NULL THEN
    FOR v_inj IN
      SELECT i.id
      FROM public.competition_player_injuries i
      WHERE i.status = 'active'
        AND (
          coalesce(i.matches_out_remaining, 0) > 0
          OR coalesce(i.recovery_remaining, 0) > 0
        )
        AND (
          v_club_filter IS NULL
          OR upper(btrim(i.club_short_name)) = v_club_filter
        )
    LOOP
      PERFORM public.competition_match_fitness_sync_from_injury(v_inj.id);
      v_inj_synced := v_inj_synced + 1;
    END LOOP;
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'version', 3,
    'season_id', v_season,
    'club', v_club_filter,
    'clubs', v_clubs,
    'club_fixtures_processed', v_fixtures,
    'player_updates', v_updates,
    'injuries_resynced', v_inj_synced,
    'matches_to_max', v_to_max
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.admin_match_fitness_rebuild_streaks(bigint, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_match_fitness_rebuild_streaks(bigint, text) TO authenticated;

-- 1) Rebuild
SELECT public.admin_match_fitness_rebuild_streaks(NULL, NULL) AS rebuild;

-- 2) Healthy players only — consecutive should be ~0–4 (August games)
SELECT
  f.club_short_name,
  f.player_id,
  f.fitness_level,
  f.consecutive_appearances
FROM public.competition_player_match_fitness f
WHERE f.season_id = (
  SELECT id FROM public.competition_seasons WHERE is_current = true ORDER BY id DESC LIMIT 1
)
  AND NOT EXISTS (
    SELECT 1
    FROM public.competition_player_injuries i
    WHERE i.player_id = f.player_id
      AND i.status = 'active'
      AND (
        coalesce(i.matches_out_remaining, 0) > 0
        OR coalesce(i.recovery_remaining, 0) > 0
      )
  )
ORDER BY f.consecutive_appearances DESC, f.club_short_name
LIMIT 40;

-- 3) Injured players — 12 / 16 here is the injury meter mapping, NOT 12–16 matches
SELECT
  f.club_short_name,
  f.player_id,
  f.fitness_level,
  f.consecutive_appearances,
  i.label AS injury,
  i.matches_out_remaining,
  i.recovery_remaining
FROM public.competition_player_match_fitness f
JOIN public.competition_player_injuries i
  ON i.player_id = f.player_id
 AND i.status = 'active'
 AND (
   coalesce(i.matches_out_remaining, 0) > 0
   OR coalesce(i.recovery_remaining, 0) > 0
 )
WHERE f.season_id = (
  SELECT id FROM public.competition_seasons WHERE is_current = true ORDER BY id DESC LIMIT 1
)
ORDER BY f.consecutive_appearances DESC
LIMIT 40;

NOTIFY pgrst, 'reload schema';
