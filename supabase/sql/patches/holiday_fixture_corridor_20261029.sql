-- =============================================================================
-- Holiday-impacted fixtures: arrange/play corridor
--
-- Only fixtures whose GPSL month is hit by a qualifying holiday (4+ day overlap
-- for either club) get this treatment. Other months stay on normal rules.
--
-- Corridor:
--   before play month → unlock = earliest calendar unlock at/before play month
--   in play month / catch-up → unlock = active GPSL month unlock
--   lock = lock of (play month + play-grace), capped at season end
--     league → +2; cup → +1; May cup → +0
--
-- Safe re-run. Depends on holiday_early_play_preseason / holiday_early_min_overlap_4d
-- and match_scheduling_rules play-grace helpers.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.match_schedule_fixture_is_holiday_impacted(
  p_fixture_id bigint
)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_fixture public.competition_fixtures;
  v_unlock timestamptz;
  v_lock timestamptz;
  v_min int := public.club_holiday_early_min_overlap_days();
BEGIN
  SELECT * INTO v_fixture
  FROM public.competition_fixtures f
  WHERE f.id = p_fixture_id;

  IF NOT FOUND THEN
    RETURN false;
  END IF;

  IF coalesce(v_fixture.competition_type, 'league') NOT IN ('league', 'cup') THEN
    RETURN false;
  END IF;

  IF v_fixture.status <> 'scheduled' THEN
    RETURN false;
  END IF;

  SELECT m.unlock_at, m.lock_at
  INTO v_unlock, v_lock
  FROM public.competition_season_calendar m
  WHERE m.season_id = v_fixture.season_id
    AND lower(btrim(m.gpsl_month)) = lower(btrim(v_fixture.gpsl_month));

  IF v_unlock IS NULL OR v_lock IS NULL THEN
    RETURN false;
  END IF;

  RETURN EXISTS (
    SELECT 1
    FROM public.club_owner_holidays h
    WHERE h.season_id = v_fixture.season_id
      AND h.club_short_name IN (
            v_fixture.home_club_short_name,
            v_fixture.away_club_short_name
          )
      AND public.club_holiday_overlap_inclusive_days(
            h.starts_at, h.ends_at, v_unlock, v_lock
          ) >= v_min
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.match_schedule_fixture_is_holiday_impacted(bigint)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.match_schedule_fixture_is_holiday_impacted(bigint)
  TO authenticated, service_role;

COMMENT ON FUNCTION public.match_schedule_fixture_is_holiday_impacted(bigint) IS
  'Fixture GPSL month is holiday-hit (4+ day overlap) for home or away — early/+grace corridor applies.';

CREATE OR REPLACE FUNCTION public.match_schedule_holiday_corridor_window(
  p_fixture_id bigint
)
RETURNS TABLE (
  unlock_at timestamptz,
  lock_at timestamptz,
  gpsl_month text,
  is_catch_up boolean,
  is_holiday_early boolean
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_fixture public.competition_fixtures;
  v_play_sort int;
  v_grace int;
  v_end_sort int;
  v_max_sort int;
  v_unlock timestamptz;
  v_lock timestamptz;
  v_end_month text;
  v_active text;
  v_active_sort int;
  v_early boolean := false;
  v_catch_up boolean := false;
BEGIN
  SELECT * INTO v_fixture
  FROM public.competition_fixtures f
  WHERE f.id = p_fixture_id;

  IF NOT FOUND THEN
    RETURN;
  END IF;

  IF NOT public.match_schedule_fixture_is_holiday_impacted(p_fixture_id) THEN
    RETURN;
  END IF;

  v_play_sort := public.competition_gpsl_month_sort(v_fixture.gpsl_month);
  IF v_play_sort IS NULL THEN
    RETURN;
  END IF;

  v_grace := public.match_schedule_play_grace_months(
    v_fixture.competition_type,
    v_fixture.gpsl_month
  );

  SELECT max(public.competition_gpsl_month_sort(cal.gpsl_month))
  INTO v_max_sort
  FROM public.competition_season_calendar cal
  WHERE cal.season_id = v_fixture.season_id;

  v_end_sort := least(v_play_sort + coalesce(v_grace, 0), coalesce(v_max_sort, v_play_sort));

  SELECT cal.lock_at, cal.gpsl_month
  INTO v_lock, v_end_month
  FROM public.competition_season_calendar cal
  WHERE cal.season_id = v_fixture.season_id
    AND public.competition_gpsl_month_sort(cal.gpsl_month) = v_end_sort
  ORDER BY cal.sort_order DESC
  LIMIT 1;

  IF v_lock IS NULL THEN
    RETURN;
  END IF;

  IF now() >= v_lock THEN
    RETURN;
  END IF;

  v_active := public.competition_active_gpsl_month(v_fixture.season_id, now());
  v_active_sort := public.competition_gpsl_month_sort(v_active);

  IF public.match_schedule_fixture_play_month_closed(p_fixture_id) THEN
    v_catch_up := true;
  ELSIF v_active_sort IS NOT NULL AND v_active_sort < v_play_sort THEN
    v_early := true;
  END IF;

  -- Before play month: allow KO from earliest open month through corridor end.
  -- In play month / catch-up: only from the active month forward (no past KOs).
  IF v_active_sort IS NOT NULL AND v_active_sort >= v_play_sort THEN
    SELECT cal.unlock_at
    INTO v_unlock
    FROM public.competition_season_calendar cal
    WHERE cal.season_id = v_fixture.season_id
      AND lower(btrim(cal.gpsl_month)) = lower(btrim(v_active))
    LIMIT 1;
  ELSE
    SELECT min(cal.unlock_at)
    INTO v_unlock
    FROM public.competition_season_calendar cal
    WHERE cal.season_id = v_fixture.season_id
      AND public.competition_gpsl_month_sort(cal.gpsl_month) <= v_play_sort
      AND cal.unlock_at IS NOT NULL;
  END IF;

  IF v_unlock IS NULL THEN
    RETURN;
  END IF;

  unlock_at := v_unlock;
  lock_at := v_lock;
  gpsl_month := coalesce(v_end_month, v_fixture.gpsl_month);
  is_catch_up := v_catch_up;
  is_holiday_early := v_early;
  RETURN NEXT;
END;
$function$;

REVOKE ALL ON FUNCTION public.match_schedule_holiday_corridor_window(bigint)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.match_schedule_holiday_corridor_window(bigint)
  TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.match_schedule_proposal_kickoff_window(
  p_fixture_id bigint
)
RETURNS TABLE (
  unlock_at timestamptz,
  lock_at timestamptz,
  gpsl_month text,
  is_catch_up boolean,
  is_holiday_early boolean
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_fixture public.competition_fixtures;
  v_active text;
  v_row record;
BEGIN
  SELECT * INTO v_fixture
  FROM public.competition_fixtures f
  WHERE f.id = p_fixture_id;

  IF NOT FOUND THEN
    RETURN;
  END IF;

  -- Holiday-impacted: early → play month → +grace corridor (only those fixtures)
  IF to_regprocedure('public.match_schedule_holiday_corridor_window(bigint)') IS NOT NULL THEN
    SELECT c.unlock_at, c.lock_at, c.gpsl_month, c.is_catch_up, c.is_holiday_early
    INTO v_row
    FROM public.match_schedule_holiday_corridor_window(p_fixture_id) c
    LIMIT 1;

    IF FOUND AND v_row.unlock_at IS NOT NULL THEN
      unlock_at := v_row.unlock_at;
      lock_at := v_row.lock_at;
      gpsl_month := v_row.gpsl_month;
      is_catch_up := coalesce(v_row.is_catch_up, false);
      is_holiday_early := coalesce(v_row.is_holiday_early, false);
      RETURN NEXT;
      RETURN;
    END IF;
  END IF;

  -- Normal catch-up (non-holiday): schedule inside the active GPSL month
  IF public.match_schedule_fixture_is_catch_up(p_fixture_id) THEN
    v_active := public.competition_active_gpsl_month(v_fixture.season_id, now());
    IF v_active IS NULL THEN
      RETURN;
    END IF;

    RETURN QUERY
    SELECT cal.unlock_at, cal.lock_at, cal.gpsl_month, true, false
    FROM public.competition_season_calendar cal
    WHERE cal.season_id = v_fixture.season_id
      AND lower(btrim(cal.gpsl_month)) = lower(btrim(v_active));
    RETURN;
  END IF;

  -- Legacy holiday-early (active month only) if corridor helper missing / no hit
  IF to_regprocedure('public.match_schedule_fixture_is_holiday_early(bigint)') IS NOT NULL
     AND public.match_schedule_fixture_is_holiday_early(p_fixture_id)
  THEN
    v_active := public.competition_active_gpsl_month(v_fixture.season_id, now());
    IF v_active IS NULL THEN
      RETURN;
    END IF;

    RETURN QUERY
    SELECT cal.unlock_at, cal.lock_at, cal.gpsl_month, false, true
    FROM public.competition_season_calendar cal
    WHERE cal.season_id = v_fixture.season_id
      AND lower(btrim(cal.gpsl_month)) = lower(btrim(v_active));
    RETURN;
  END IF;

  RETURN QUERY
  SELECT w.unlock_at, w.lock_at, w.gpsl_month, false, false
  FROM public.match_schedule_fixture_month_window(p_fixture_id) w;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.match_schedule_proposal_kickoff_window(bigint)
  TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';

SELECT
  (to_regprocedure('public.match_schedule_fixture_is_holiday_impacted(bigint)') IS NOT NULL)
    AS impacted_fn,
  (to_regprocedure('public.match_schedule_holiday_corridor_window(bigint)') IS NOT NULL)
    AS corridor_fn,
  (position('holiday_corridor_window' IN pg_get_functiondef(
    'public.match_schedule_proposal_kickoff_window(bigint)'::regprocedure
  )) > 0) AS proposal_uses_corridor;
