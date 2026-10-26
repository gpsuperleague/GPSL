-- =============================================================================
-- Injured → Match Fitness L5, ease back to L2 as recovery ticks
--
-- On new injury: set fitness to Injury Risk (5).
-- As out/recovery matches are served: scale level from 5 → 2 by remaining/total.
-- When fully recovered: Match Ready (2) — same as fitness_return_level default.
-- While injured (out or light-training), match ticks do not climb/drop fitness;
-- only the injury countdown moves the meter.
--
-- Requires: match_fitness_injury_weights_20261026.sql
-- Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.competition_match_fitness_level_during_injury(
  p_remaining int,
  p_initial int
)
RETURNS int
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE
    WHEN coalesce(p_remaining, 0) <= 0 THEN 2
    WHEN coalesce(p_initial, 0) <= 0 THEN 2
    ELSE greatest(
      2,
      least(
        5,
        2 + round(3.0 * p_remaining::numeric / p_initial::numeric)::int
      )
    )
  END;
$$;

COMMENT ON FUNCTION public.competition_match_fitness_level_during_injury(int, int) IS
  'Map injury remaining/initial absences onto fitness levels 5→2.';

CREATE OR REPLACE FUNCTION public.competition_match_fitness_sync_from_injury(
  p_injury_id bigint
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_inj public.competition_player_injuries%rowtype;
  v_s public.competition_injury_settings := public.competition_injury_settings_row();
  v_initial int;
  v_remaining int;
  v_level int;
  v_streak int;
  v_return int;
BEGIN
  SELECT * INTO v_inj FROM public.competition_player_injuries WHERE id = p_injury_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_found');
  END IF;

  v_return := greatest(1, least(5, coalesce(v_s.fitness_return_level, 2)));
  v_initial := greatest(
    coalesce(v_inj.matches_out, 0) + coalesce(v_inj.recovery_matches, 0),
    0
  );
  v_remaining := greatest(
    coalesce(v_inj.matches_out_remaining, 0) + coalesce(v_inj.recovery_remaining, 0),
    0
  );

  IF v_inj.status IS DISTINCT FROM 'active' OR v_remaining <= 0 THEN
    v_level := v_return;
  ELSE
    v_level := public.competition_match_fitness_level_during_injury(v_remaining, v_initial);
    -- Never below return level while still injured
    v_level := greatest(v_return, least(5, v_level));
  END IF;

  v_streak := public.competition_match_fitness_streak_for_level(
    v_level, coalesce(v_s.fitness_matches_to_max, 4)
  );

  PERFORM public.competition_match_fitness_ensure(
    coalesce(v_inj.season_id, v_inj.incurred_season_id),
    v_inj.player_id,
    v_inj.club_short_name,
    v_level,
    v_streak
  );

  RETURN jsonb_build_object(
    'ok', true,
    'injury_id', p_injury_id,
    'player_id', v_inj.player_id,
    'level', v_level,
    'remaining', v_remaining,
    'initial', v_initial
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.competition_match_fitness_sync_from_injury(bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.competition_match_fitness_sync_from_injury(bigint)
  TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Issue injury → L5
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.competition_injury_issue(
  p_season_id bigint,
  p_club text,
  p_player_id text,
  p_catalogue_id bigint,
  p_source_fixture_id bigint
)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_cat public.competition_injury_catalogue%rowtype;
  v_id bigint;
  v_state public.competition_club_injury_season;
  v_out int;
  v_rec int;
  v_s public.competition_injury_settings;
  v_streak int;
BEGIN
  SELECT * INTO v_cat FROM public.competition_injury_catalogue WHERE id = p_catalogue_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Injury catalogue row not found'; END IF;

  v_state := public.competition_injury_ensure_club_season(p_season_id, p_club);

  v_out := greatest(coalesce(v_cat.matches_out, 0), 0);
  v_rec := greatest(coalesce(v_cat.recovery_matches, 0), 0);
  IF to_regprocedure('public.medical_club_has_doctor(text)') IS NOT NULL
     AND public.medical_club_has_doctor(p_club) THEN
    v_out := greatest(v_out - 1, 0);
  END IF;

  INSERT INTO public.competition_player_injuries (
    season_id, incurred_season_id, player_id, club_short_name,
    label, status, catalogue_id, severity,
    matches_out, recovery_matches,
    matches_out_remaining, recovery_remaining,
    source_fixture_id
  )
  VALUES (
    p_season_id, p_season_id, p_player_id, p_club,
    v_cat.name, 'active', v_cat.id, v_cat.severity,
    v_out, v_rec,
    v_out, v_rec,
    p_source_fixture_id
  )
  RETURNING id INTO v_id;

  UPDATE public.competition_club_injury_season
  SET count_total = count_total + 1,
      count_major = count_major + CASE WHEN v_cat.severity = 'Major' THEN 1 ELSE 0 END,
      count_moderate = count_moderate + CASE WHEN v_cat.severity = 'Moderate' THEN 1 ELSE 0 END,
      count_minor = count_minor + CASE WHEN v_cat.severity = 'Minor' THEN 1 ELSE 0 END
  WHERE season_id = p_season_id AND club_short_name = p_club;

  -- Fresh injury → Injury Risk (L5)
  IF to_regprocedure('public.competition_match_fitness_ensure(bigint,text,text,int,int)') IS NOT NULL THEN
    v_s := public.competition_injury_settings_row();
    v_streak := public.competition_match_fitness_streak_for_level(
      5, coalesce(v_s.fitness_matches_to_max, 4)
    );
    PERFORM public.competition_match_fitness_ensure(
      p_season_id, p_player_id, p_club, 5, v_streak
    );
  END IF;

  PERFORM public.competition_injury_assign_fixtures(v_id);
  RETURN v_id;
END;
$function$;

-- ---------------------------------------------------------------------------
-- Serve: after each tick, sync fitness; recover → return level
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

  IF v_fixture.id IS NOT NULL
     AND to_regprocedure('public.competition_match_fitness_tick_club(bigint,text)') IS NOT NULL THEN
    PERFORM public.competition_match_fitness_tick_club(
      p_fixture_id, v_fixture.home_club_short_name
    );
    PERFORM public.competition_match_fitness_tick_club(
      p_fixture_id, v_fixture.away_club_short_name
    );
  END IF;

  PERFORM public.competition_injury_roll_for_fixture(p_fixture_id);
END;
$function$;

-- Freeze fitness climb/drop for any active injury (out or light training)
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
  v_appeared text[];
  v_pid text;
  v_streak int;
  v_level int;
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

  SELECT coalesce(array_agg(m.player_id), ARRAY[]::text[])
  INTO v_appeared
  FROM public.competition_match_player_stats m
  WHERE m.fixture_id = p_fixture_id
    AND upper(btrim(m.club_short_name)) = v_club
    AND m.appeared = true;

  FOR v_pid IN
    SELECT DISTINCT x.pid
    FROM (
      SELECT p."Konami_ID"::text AS pid
      FROM public."Players" p
      WHERE upper(btrim(coalesce(p."Contracted_Team", ''))) = v_club
      UNION
      SELECT unnest(v_appeared)
    ) x
    WHERE nullif(btrim(x.pid), '') IS NOT NULL
  LOOP
    -- Any active injury: fitness driven by recovery scale, not match ticks
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

    IF v_pid = ANY (v_appeared) THEN
      v_streak := v_streak + 1;
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
    'frozen_injured', v_n_skip
  );
END;
$function$;

-- Backfill: sync active injuries onto the 5→2 scale now
DO $backfill$
DECLARE
  r record;
  n int := 0;
BEGIN
  IF to_regprocedure('public.competition_match_fitness_sync_from_injury(bigint)') IS NULL THEN
    RETURN;
  END IF;
  FOR r IN
    SELECT i.id
    FROM public.competition_player_injuries i
    WHERE i.status = 'active'
      AND (
        coalesce(i.matches_out_remaining, 0) > 0
        OR coalesce(i.recovery_remaining, 0) > 0
      )
  LOOP
    PERFORM public.competition_match_fitness_sync_from_injury(r.id);
    n := n + 1;
  END LOOP;
  RAISE NOTICE 'Synced match fitness for % active injuries', n;
END;
$backfill$;

SELECT
  to_regprocedure('public.competition_match_fitness_sync_from_injury(bigint)') IS NOT NULL AS sync_ok,
  public.competition_match_fitness_level_during_injury(10, 10) AS start_level,
  public.competition_match_fitness_level_during_injury(5, 10) AS mid_level,
  public.competition_match_fitness_level_during_injury(1, 10) AS late_level,
  public.competition_match_fitness_level_during_injury(0, 10) AS done_level;
