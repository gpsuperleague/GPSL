-- Injury pins: cups jump in front of league matches in the same GPSL month.
-- The one-time block counts matches already played since the injury.
-- Once the book is clear, fitness restarts at Match Ready and every later
-- league/cup match already ticked for the club is applied: a start or sub climbs,
-- a match he did not play is rest and drops one level. Those ticks were skipped
-- while the injury was still open, and the club tick is not run again.
-- Opening a match only moves absences that are still owed.
--
-- Order: GPSL month, then cup before league, then matchday, then id.
-- Safe re-run.

SET statement_timeout = '180s';

CREATE OR REPLACE FUNCTION public.competition_injury_assign_fixtures(
  p_injury_id bigint
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_inj public.competition_player_injuries%rowtype;
  v_season_id bigint;
  v_fx record;
  v_need_out int;
  v_need_rec int;
BEGIN
  SELECT * INTO v_inj FROM public.competition_player_injuries WHERE id = p_injury_id;
  IF NOT FOUND THEN RETURN; END IF;

  -- A pin left on a match that has already been played is served, not moved.
  FOR v_fx IN
    SELECT iff.id, iff.phase
    FROM public.competition_player_injury_fixtures iff
    JOIN public.competition_fixtures f ON f.id = iff.fixture_id
    WHERE iff.injury_id = p_injury_id
      AND iff.served = false
      AND lower(coalesce(f.status, '')) IN ('played', 'completed', 'forfeit')
      AND coalesce(f.is_void, false) = false
  LOOP
    UPDATE public.competition_player_injury_fixtures
    SET served = true
    WHERE id = v_fx.id;

    IF v_fx.phase = 'recovery' THEN
      UPDATE public.competition_player_injuries
      SET recovery_remaining = greatest(coalesce(recovery_remaining, 1) - 1, 0)
      WHERE id = p_injury_id;
    ELSE
      UPDATE public.competition_player_injuries
      SET matches_out_remaining = greatest(coalesce(matches_out_remaining, 1) - 1, 0)
      WHERE id = p_injury_id;
    END IF;
  END LOOP;

  SELECT * INTO v_inj FROM public.competition_player_injuries WHERE id = p_injury_id;

  UPDATE public.competition_player_injuries
  SET status = 'recovered',
      recovered_at = coalesce(recovered_at, now())
  WHERE id = p_injury_id
    AND status = 'active'
    AND coalesce(matches_out_remaining, 0) <= 0
    AND coalesce(recovery_remaining, 0) <= 0;

  SELECT * INTO v_inj FROM public.competition_player_injuries WHERE id = p_injury_id;
  IF v_inj.status IS DISTINCT FROM 'active' THEN
    DELETE FROM public.competition_player_injury_fixtures
    WHERE injury_id = p_injury_id AND served = false;
    IF to_regprocedure('public.competition_match_fitness_replay_after_injury(bigint)') IS NOT NULL THEN
      PERFORM public.competition_match_fitness_replay_after_injury(p_injury_id);
    ELSIF to_regprocedure('public.competition_match_fitness_sync_from_injury(bigint)') IS NOT NULL THEN
      PERFORM public.competition_match_fitness_sync_from_injury(p_injury_id);
    END IF;
    RETURN;
  END IF;

  v_need_out := greatest(coalesce(v_inj.matches_out_remaining, 0), 0);
  v_need_rec := greatest(coalesce(v_inj.recovery_remaining, 0), 0);

  DELETE FROM public.competition_player_injury_fixtures
  WHERE injury_id = p_injury_id AND served = false;

  SELECT s.id INTO v_season_id
  FROM public.competition_seasons s
  WHERE s.is_current = true
  ORDER BY s.id DESC
  LIMIT 1;

  IF v_season_id IS NULL THEN
    v_season_id := coalesce(v_inj.season_id, v_inj.incurred_season_id);
  END IF;

  FOR v_fx IN
    SELECT f.id
    FROM public.competition_fixtures f
    WHERE f.season_id = v_season_id
      AND f.status = 'scheduled'
      AND (f.home_club_short_name = v_inj.club_short_name
           OR f.away_club_short_name = v_inj.club_short_name)
      AND (v_inj.source_fixture_id IS NULL OR f.id IS DISTINCT FROM v_inj.source_fixture_id)
      AND NOT public.competition_injury_is_preseason_month(f.gpsl_month)
    ORDER BY
      coalesce(public.competition_gpsl_month_sort(f.gpsl_month), 99),
      CASE WHEN f.competition_type = 'cup' THEN 0 ELSE 1 END,
      coalesce(f.matchday, 9999),
      f.id
  LOOP
    EXIT WHEN v_need_out <= 0 AND v_need_rec <= 0;

    IF v_need_out > 0 THEN
      INSERT INTO public.competition_player_injury_fixtures (
        injury_id, fixture_id, phase, served
      ) VALUES (p_injury_id, v_fx.id, 'out', false)
      ON CONFLICT (injury_id, fixture_id) DO UPDATE
        SET phase = 'out', served = false;
      v_need_out := v_need_out - 1;
    ELSIF v_need_rec > 0 THEN
      INSERT INTO public.competition_player_injury_fixtures (
        injury_id, fixture_id, phase, served
      ) VALUES (p_injury_id, v_fx.id, 'recovery', false)
      ON CONFLICT (injury_id, fixture_id) DO UPDATE
        SET phase = 'recovery', served = false;
      v_need_rec := v_need_rec - 1;
    END IF;
  END LOOP;

  IF to_regprocedure('public.competition_match_fitness_sync_from_injury(bigint)') IS NOT NULL THEN
    PERFORM public.competition_match_fitness_sync_from_injury(p_injury_id);
  END IF;
END;
$function$;

-- One-time (and explicit) catch-up. Not used when a match page opens.
CREATE OR REPLACE FUNCTION public.competition_injury_catch_up_played(
  p_injury_id bigint
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_inj public.competition_player_injuries%rowtype;
  v_src public.competition_fixtures%rowtype;
  v_season_id bigint;
  v_fx record;
BEGIN
  SELECT * INTO v_inj FROM public.competition_player_injuries WHERE id = p_injury_id;
  IF NOT FOUND OR v_inj.source_fixture_id IS NULL THEN
    PERFORM public.competition_injury_assign_fixtures(p_injury_id);
    RETURN;
  END IF;

  SELECT * INTO v_src FROM public.competition_fixtures WHERE id = v_inj.source_fixture_id;
  IF NOT FOUND THEN
    PERFORM public.competition_injury_assign_fixtures(p_injury_id);
    RETURN;
  END IF;

  SELECT s.id INTO v_season_id
  FROM public.competition_seasons s
  WHERE s.is_current = true
  ORDER BY s.id DESC
  LIMIT 1;

  IF v_season_id IS NULL THEN
    v_season_id := coalesce(v_inj.season_id, v_inj.incurred_season_id);
  END IF;

  IF v_season_id IS NOT NULL THEN
    FOR v_fx IN
      SELECT f.id
      FROM public.competition_fixtures f
      WHERE f.season_id = v_season_id
        AND f.id IS DISTINCT FROM v_src.id
        AND lower(coalesce(f.status, '')) IN ('played', 'completed', 'forfeit')
        AND coalesce(f.is_void, false) = false
        AND (f.home_club_short_name = v_inj.club_short_name
             OR f.away_club_short_name = v_inj.club_short_name)
        AND NOT public.competition_injury_is_preseason_month(f.gpsl_month)
        AND (
          coalesce(public.competition_gpsl_month_sort(f.gpsl_month), 99),
          CASE WHEN f.competition_type = 'cup' THEN 0 ELSE 1 END,
          coalesce(f.matchday, 9999),
          f.id
        ) > (
          coalesce(public.competition_gpsl_month_sort(v_src.gpsl_month), 99),
          CASE WHEN v_src.competition_type = 'cup' THEN 0 ELSE 1 END,
          coalesce(v_src.matchday, 9999),
          v_src.id
        )
        AND NOT EXISTS (
          SELECT 1
          FROM public.competition_player_injury_fixtures iff
          WHERE iff.injury_id = p_injury_id
            AND iff.fixture_id = f.id
            AND iff.served = true
        )
      ORDER BY
        coalesce(public.competition_gpsl_month_sort(f.gpsl_month), 99),
        CASE WHEN f.competition_type = 'cup' THEN 0 ELSE 1 END,
        coalesce(f.matchday, 9999),
        f.id
    LOOP
      SELECT * INTO v_inj FROM public.competition_player_injuries WHERE id = p_injury_id;
      EXIT WHEN coalesce(v_inj.matches_out_remaining, 0) <= 0
        AND coalesce(v_inj.recovery_remaining, 0) <= 0;

      IF coalesce(v_inj.matches_out_remaining, 0) > 0 THEN
        INSERT INTO public.competition_player_injury_fixtures (
          injury_id, fixture_id, phase, served
        ) VALUES (p_injury_id, v_fx.id, 'out', true)
        ON CONFLICT (injury_id, fixture_id) DO UPDATE
          SET phase = 'out', served = true;
        UPDATE public.competition_player_injuries
        SET matches_out_remaining = greatest(coalesce(matches_out_remaining, 1) - 1, 0)
        WHERE id = p_injury_id;
      ELSE
        INSERT INTO public.competition_player_injury_fixtures (
          injury_id, fixture_id, phase, served
        ) VALUES (p_injury_id, v_fx.id, 'recovery', true)
        ON CONFLICT (injury_id, fixture_id) DO UPDATE
          SET phase = 'recovery', served = true;
        UPDATE public.competition_player_injuries
        SET recovery_remaining = greatest(coalesce(recovery_remaining, 1) - 1, 0)
        WHERE id = p_injury_id;
      END IF;
    END LOOP;
  END IF;

  PERFORM public.competition_injury_assign_fixtures(p_injury_id);
END;
$function$;

REVOKE ALL ON FUNCTION public.competition_injury_catch_up_played(bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.competition_injury_catch_up_played(bigint)
  TO service_role;

CREATE OR REPLACE FUNCTION public.trg_cup_fixture_resync_injuries()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF NEW.competition_type IS DISTINCT FROM 'cup' THEN
    RETURN NEW;
  END IF;

  IF to_regprocedure('public.competition_resync_pending_injuries(bigint, text)') IS NULL THEN
    RETURN NEW;
  END IF;

  PERFORM public.competition_resync_pending_injuries(NEW.season_id, NEW.home_club_short_name);
  PERFORM public.competition_resync_pending_injuries(NEW.season_id, NEW.away_club_short_name);
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS cup_fixture_resync_injuries ON public.competition_fixtures;
CREATE TRIGGER cup_fixture_resync_injuries
  AFTER INSERT ON public.competition_fixtures
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_cup_fixture_resync_injuries();

-- After the absence is over: Match Ready, then each later ticked match.
-- A start climbs (1), a sub climbs (0.5), a match he did not play drops one level.
-- Level 4 needs 12 consecutive start-units from Fully Fit, or 8 after Match Ready.
-- Rest cannot climb there. Safe to run again: it rebuilds from the return level.
CREATE OR REPLACE FUNCTION public.competition_match_fitness_replay_after_injury(
  p_injury_id bigint
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_inj public.competition_player_injuries%rowtype;
  v_end public.competition_fixtures%rowtype;
  v_fx record;
  v_s public.competition_injury_settings;
  v_to_max int := 4;
  v_return int := 2;
  v_level int;
  v_streak numeric;
  v_old int;
  v_credit numeric;
  v_started boolean;
  v_subbed boolean;
  v_rested int := 0;
  v_appeared numeric := 0;
  v_season_id bigint;
  v_end_id bigint;
BEGIN
  SELECT * INTO v_inj FROM public.competition_player_injuries WHERE id = p_injury_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_found');
  END IF;

  IF v_inj.status = 'active'
     AND (
       coalesce(v_inj.matches_out_remaining, 0) > 0
       OR coalesce(v_inj.recovery_remaining, 0) > 0
     ) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'still_out');
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.competition_player_injuries i
    WHERE i.player_id = v_inj.player_id
      AND i.id <> p_injury_id
      AND i.status = 'active'
      AND (
        coalesce(i.matches_out_remaining, 0) > 0
        OR coalesce(i.recovery_remaining, 0) > 0
      )
  ) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'still_out');
  END IF;

  BEGIN
    v_s := public.competition_injury_settings_row();
    v_to_max := greatest(coalesce(v_s.fitness_matches_to_max, 4), 1);
    v_return := greatest(1, least(5, coalesce(v_s.fitness_return_level, 2)));
  EXCEPTION WHEN OTHERS THEN
    v_to_max := 4;
    v_return := 2;
  END;

  v_season_id := coalesce(v_inj.season_id, v_inj.incurred_season_id);

  SELECT f.fitness_level INTO v_old
  FROM public.competition_player_match_fitness f
  WHERE f.player_id = v_inj.player_id
    AND f.season_id = v_season_id;

  -- Last match that counted toward the absence. Rest starts with the next one.
  SELECT f.* INTO v_end
  FROM public.competition_player_injury_fixtures iff
  JOIN public.competition_fixtures f ON f.id = iff.fixture_id
  WHERE iff.injury_id = p_injury_id
    AND iff.served = true
  ORDER BY
    coalesce(public.competition_gpsl_month_sort(f.gpsl_month), 99) DESC,
    CASE WHEN f.competition_type = 'cup' THEN 0 ELSE 1 END DESC,
    coalesce(f.matchday, 9999) DESC,
    f.id DESC
  LIMIT 1;

  IF NOT FOUND AND v_inj.source_fixture_id IS NOT NULL THEN
    SELECT * INTO v_end
    FROM public.competition_fixtures
    WHERE id = v_inj.source_fixture_id;
  END IF;

  IF FOUND THEN
    v_end_id := v_end.id;
  END IF;

  v_level := v_return;
  v_streak := public.competition_match_fitness_streak_for_level(v_level, v_to_max);

  IF v_end_id IS NOT NULL AND v_season_id IS NOT NULL THEN
    FOR v_fx IN
      SELECT f.id
      FROM public.competition_fixtures f
      WHERE f.season_id = v_season_id
        AND f.status = 'played'
        AND coalesce(f.is_forfeit, false) = false
        AND coalesce(f.competition_type, 'league') IN ('league', 'cup')
        AND NOT public.competition_injury_is_preseason_month(f.gpsl_month)
        AND (
          f.home_club_short_name = v_inj.club_short_name
          OR f.away_club_short_name = v_inj.club_short_name
        )
        AND (
          coalesce(public.competition_gpsl_month_sort(f.gpsl_month), 99),
          CASE WHEN f.competition_type = 'cup' THEN 0 ELSE 1 END,
          coalesce(f.matchday, 9999),
          f.id
        ) > (
          coalesce(public.competition_gpsl_month_sort(v_end.gpsl_month), 99),
          CASE WHEN v_end.competition_type = 'cup' THEN 0 ELSE 1 END,
          coalesce(v_end.matchday, 9999),
          v_end.id
        )
        AND EXISTS (
          SELECT 1
          FROM public.competition_fixture_match_fitness_tick t
          WHERE t.fixture_id = f.id
            AND upper(btrim(t.club_short_name)) = upper(btrim(v_inj.club_short_name))
        )
      ORDER BY
        coalesce(public.competition_gpsl_month_sort(f.gpsl_month), 99),
        CASE WHEN f.competition_type = 'cup' THEN 0 ELSE 1 END,
        coalesce(f.matchday, 9999),
        f.id
    LOOP
      SELECT
        coalesce(bool_or(m.started), false),
        coalesce(bool_or(m.subbed_on AND NOT coalesce(m.started, false)), false)
      INTO v_started, v_subbed
      FROM public.competition_match_player_stats m
      WHERE m.fixture_id = v_fx.id
        AND upper(btrim(m.club_short_name)) = upper(btrim(v_inj.club_short_name))
        AND m.player_id = v_inj.player_id
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
        v_appeared := v_appeared + v_credit;
      ELSE
        v_level := greatest(1, v_level - 1);
        v_streak := public.competition_match_fitness_streak_for_level(v_level, v_to_max);
        v_rested := v_rested + 1;
      END IF;
    END LOOP;
  END IF;

  IF v_season_id IS NOT NULL THEN
    PERFORM public.competition_match_fitness_ensure(
      v_season_id, v_inj.player_id, v_inj.club_short_name, v_level, v_streak
    );
  END IF;

  IF to_regclass('pg_temp._injury_rest_replay') IS NOT NULL THEN
    INSERT INTO pg_temp._injury_rest_replay (
      injury_id, old_level, new_level, rested, appeared, end_fixture_id
    ) VALUES (
      p_injury_id, v_old, v_level, v_rested, v_appeared, v_end_id
    )
    ON CONFLICT (injury_id) DO UPDATE
    SET new_level = excluded.new_level,
        rested = excluded.rested,
        appeared = excluded.appeared,
        end_fixture_id = excluded.end_fixture_id;
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'injury_id', p_injury_id,
    'player_id', v_inj.player_id,
    'old_level', v_old,
    'new_level', v_level,
    'rested', v_rested,
    'appeared', v_appeared
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.competition_match_fitness_replay_after_injury(bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.competition_match_fitness_replay_after_injury(bigint)
  TO service_role;

DROP TABLE IF EXISTS pg_temp._injury_rest_replay;
CREATE TEMP TABLE _injury_rest_replay (
  injury_id bigint PRIMARY KEY,
  old_level int,
  new_level int,
  rested int,
  appeared numeric,
  end_fixture_id bigint
);

DO $$
DECLARE
  r record;
  v_n int := 0;
BEGIN
  FOR r IN
    SELECT i.id
    FROM public.competition_player_injuries i
    WHERE i.status = 'active'
      AND (
        coalesce(i.matches_out_remaining, 0) > 0
        OR coalesce(i.recovery_remaining, 0) > 0
      )
  LOOP
    PERFORM public.competition_injury_catch_up_played(r.id);
    v_n := v_n + 1;
  END LOOP;
  RAISE NOTICE 'injury_cup_before_league: re-pinned % active injuries', v_n;
END $$;

-- Anyone already off the injury list: replay rest/appearances since the absence ended.
DO $$
DECLARE
  r record;
  v_season bigint;
BEGIN
  SELECT s.id INTO v_season
  FROM public.competition_seasons s
  WHERE s.is_current = true
  ORDER BY s.id DESC
  LIMIT 1;

  IF v_season IS NULL THEN
    RETURN;
  END IF;

  FOR r IN
    SELECT DISTINCT ON (i.player_id) i.id
    FROM public.competition_player_injuries i
    WHERE coalesce(i.season_id, i.incurred_season_id) = v_season
      AND NOT (
        i.status = 'active'
        AND (
          coalesce(i.matches_out_remaining, 0) > 0
          OR coalesce(i.recovery_remaining, 0) > 0
        )
      )
    ORDER BY i.player_id, coalesce(i.recovered_at, i.created_at) DESC, i.id DESC
  LOOP
    PERFORM public.competition_match_fitness_replay_after_injury(r.id);
  END LOOP;
END $$;

NOTIFY pgrst, 'reload schema';

-- Every injury still active, plus any just cleared by this run.
SELECT
  i.club_short_name,
  p."Name" AS player,
  i.label,
  i.status,
  i.matches_out AS out_at_start,
  i.matches_out_remaining AS out_left,
  rp.old_level AS fitness_before,
  mf.fitness_level,
  public.competition_match_fitness_label(mf.fitness_level) AS fitness,
  rp.rested AS rested_since,
  rp.appeared AS appeared_since,
  src.gpsl_month AS injured_month,
  src.matchday AS injured_matchday,
  src.competition_type AS injured_in,
  src.home_club_short_name || ' vs ' || src.away_club_short_name AS injured_match,
  endf.gpsl_month AS absence_ended_month,
  endf.matchday AS absence_ended_matchday,
  endf.home_club_short_name || ' vs ' || endf.away_club_short_name AS absence_ended,
  (
    SELECT count(*)
    FROM public.competition_player_injury_fixtures f
    WHERE f.injury_id = i.id AND f.served AND f.phase = 'out'
  ) AS matches_served,
  (
    SELECT string_agg(
      f.gpsl_month || ' ' || f.competition_type || ' MD' || coalesce(f.matchday::text, '?')
        || ' ' || f.home_club_short_name || ' vs ' || f.away_club_short_name
        || CASE WHEN iff.served THEN ' (served)' ELSE ' (still out)' END,
      ' | ' ORDER BY
        coalesce(public.competition_gpsl_month_sort(f.gpsl_month), 99),
        CASE WHEN f.competition_type = 'cup' THEN 0 ELSE 1 END,
        coalesce(f.matchday, 9999),
        f.id
    )
    FROM public.competition_player_injury_fixtures iff
    JOIN public.competition_fixtures f ON f.id = iff.fixture_id
    WHERE iff.injury_id = i.id
  ) AS pins
FROM public.competition_player_injuries i
LEFT JOIN public."Players" p ON p."Konami_ID"::text = i.player_id
LEFT JOIN public.competition_fixtures src ON src.id = i.source_fixture_id
LEFT JOIN public.competition_player_match_fitness mf
  ON mf.player_id = i.player_id
 AND mf.season_id = coalesce(i.season_id, i.incurred_season_id)
LEFT JOIN pg_temp._injury_rest_replay rp ON rp.injury_id = i.id
LEFT JOIN public.competition_fixtures endf ON endf.id = rp.end_fixture_id
WHERE i.status = 'active'
   OR i.recovered_at > now() - interval '10 minutes'
   OR (rp.injury_id IS NOT NULL AND rp.old_level IS DISTINCT FROM rp.new_level)
ORDER BY i.club_short_name, p."Name", i.created_at;
