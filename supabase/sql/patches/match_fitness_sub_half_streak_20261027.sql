-- =============================================================================
-- Match fitness: subbed-on = 0.5 toward consecutive streak (starts = 1.0)
--
-- Unchanged:
--   • Level 1–5 still climbs every fitness_matches_to_max (default 4) streak units
--   • Miss (no start, no sub): level >1 drops one level; level 1 resets streak to 0
--
-- New:
--   • Start  → +1.0 consecutive
--   • Sub on → +0.5 consecutive (not a full unit)
--   • Forfeit fixtures do not tick fitness / consecutive at all
--
-- consecutive_appearances becomes numeric(8,1). Safe re-run.
-- =============================================================================

ALTER TABLE public.competition_player_match_fitness
  ALTER COLUMN consecutive_appearances TYPE numeric(8, 1)
  USING consecutive_appearances::numeric(8, 1);

ALTER TABLE public.competition_player_match_fitness
  DROP CONSTRAINT IF EXISTS competition_player_match_fitness_consecutive_appearances_check;

ALTER TABLE public.competition_player_match_fitness
  ADD CONSTRAINT competition_player_match_fitness_consecutive_appearances_check
  CHECK (consecutive_appearances >= 0);

CREATE OR REPLACE FUNCTION public.competition_match_fitness_level_from_streak(
  p_streak numeric,
  p_to_max int DEFAULT 4
)
RETURNS int
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE
    WHEN coalesce(p_streak, 0) <= 0 THEN 1
    ELSE least(
      5,
      1 + floor(
        coalesce(p_streak, 0) / greatest(coalesce(p_to_max, 4), 1)
      )::int
    )
  END;
$$;

COMMENT ON FUNCTION public.competition_match_fitness_level_from_streak(numeric, int) IS
  'Fitness level 1–5 from consecutive streak units (starts 1.0, subs 0.5); p_to_max units per level up.';

-- Keep int overload for older callers (casts through numeric)
CREATE OR REPLACE FUNCTION public.competition_match_fitness_level_from_streak(
  p_streak int,
  p_to_max int DEFAULT 4
)
RETURNS int
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT public.competition_match_fitness_level_from_streak(p_streak::numeric, p_to_max);
$$;

DROP FUNCTION IF EXISTS public.competition_match_fitness_streak_for_level(integer, integer);
DROP FUNCTION IF EXISTS public.competition_match_fitness_streak_for_level(int, int);

CREATE OR REPLACE FUNCTION public.competition_match_fitness_streak_for_level(
  p_level int,
  p_to_max int DEFAULT 4
)
RETURNS numeric
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE
    WHEN coalesce(p_level, 1) <= 1 THEN 0::numeric
    ELSE (
      (least(5, greatest(coalesce(p_level, 1), 1)) - 1)
      * greatest(coalesce(p_to_max, 4), 1)
    )::numeric
  END;
$$;

COMMENT ON FUNCTION public.competition_match_fitness_streak_for_level(int, int) IS
  'Minimum consecutive streak units that map to the given fitness level.';

DROP FUNCTION IF EXISTS public.competition_match_fitness_ensure(bigint, text, text, int, int);

CREATE OR REPLACE FUNCTION public.competition_match_fitness_ensure(
  p_season_id bigint,
  p_player_id text,
  p_club text,
  p_level int DEFAULT 1,
  p_streak numeric DEFAULT 0
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  INSERT INTO public.competition_player_match_fitness AS f (
    season_id, player_id, club_short_name,
    consecutive_appearances, fitness_level, updated_at
  ) VALUES (
    p_season_id,
    p_player_id,
    upper(btrim(p_club)),
    round(greatest(coalesce(p_streak, 0), 0)::numeric, 1),
    greatest(1, least(5, coalesce(p_level, 1))),
    now()
  )
  ON CONFLICT (season_id, player_id) DO UPDATE
  SET club_short_name = excluded.club_short_name,
      consecutive_appearances = excluded.consecutive_appearances,
      fitness_level = excluded.fitness_level,
      updated_at = now();
END;
$function$;

CREATE OR REPLACE FUNCTION public.competition_match_fitness_set_return_level(
  p_season_id bigint,
  p_player_id text,
  p_club text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_s public.competition_injury_settings := public.competition_injury_settings_row();
  v_lvl int := greatest(1, least(5, coalesce(v_s.fitness_return_level, 2)));
  v_streak numeric;
BEGIN
  v_streak := public.competition_match_fitness_streak_for_level(
    v_lvl, coalesce(v_s.fitness_matches_to_max, 4)
  );
  PERFORM public.competition_match_fitness_ensure(
    p_season_id, p_player_id, p_club, v_lvl, v_streak
  );
END;
$function$;

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
BEGIN
  IF v_club = '' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_club');
  END IF;

  SELECT * INTO v_fixture FROM public.competition_fixtures WHERE id = p_fixture_id;
  IF NOT FOUND OR v_fixture.status <> 'played' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_played');
  END IF;

  -- Forfeits must not affect consecutive / level
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
    -- Active injury: fitness driven by recovery scale, not match ticks
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

    SELECT f.consecutive_appearances, f.fitness_level
    INTO v_streak, v_level
    FROM public.competition_player_match_fitness f
    WHERE f.season_id = v_fixture.season_id AND f.player_id = v_pid;

    v_streak := coalesce(v_streak, 0);
    v_level := coalesce(v_level, 1);

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
      -- Miss: L1 → streak 0; L2+ → drop one level
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
    'frozen_injured', v_n_skip
  );
END;
$function$;

COMMENT ON COLUMN public.competition_player_match_fitness.consecutive_appearances IS
  'Consecutive streak units toward next fitness level: start = 1.0, subbed on = 0.5.';

COMMENT ON COLUMN public.competition_injury_settings.fitness_matches_to_max IS
  'Consecutive streak units needed to climb one fitness level (start=1, sub=0.5). Default 4.';

GRANT EXECUTE ON FUNCTION public.competition_match_fitness_ensure(bigint, text, text, int, numeric)
  TO authenticated;
GRANT EXECUTE ON FUNCTION public.competition_match_fitness_tick_club(bigint, text)
  TO service_role;

-- Expose matches_to_max for squad UI consecutive progress (3.5/4)
CREATE OR REPLACE FUNCTION public.club_match_fitness_map(p_club text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := upper(nullif(btrim(coalesce(p_club, public.my_club_shortname())), ''));
  v_season bigint;
  v_to_max int := 4;
BEGIN
  IF v_club IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_club', 'by_player', '{}'::jsonb);
  END IF;

  BEGIN
    v_to_max := greatest(
      coalesce((public.competition_injury_settings_row()).fitness_matches_to_max, 4),
      1
    );
  EXCEPTION WHEN OTHERS THEN
    v_to_max := 4;
  END;

  SELECT id INTO v_season
  FROM public.competition_seasons
  WHERE is_current = true
  ORDER BY id DESC
  LIMIT 1;

  IF v_season IS NULL THEN
    RETURN jsonb_build_object(
      'ok', true,
      'club', v_club,
      'matches_to_max', v_to_max,
      'by_player', '{}'::jsonb
    );
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'club', v_club,
    'season_id', v_season,
    'matches_to_max', v_to_max,
    'by_player', coalesce((
      SELECT jsonb_object_agg(
        f.player_id,
        jsonb_build_object(
          'level', f.fitness_level,
          'label', public.competition_match_fitness_label(f.fitness_level),
          'consecutive', f.consecutive_appearances
        )
      )
      FROM public.competition_player_match_fitness f
      WHERE f.season_id = v_season
        AND upper(btrim(f.club_short_name)) = v_club
    ), '{}'::jsonb)
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.club_match_fitness_map(text) TO authenticated;

NOTIFY pgrst, 'reload schema';
