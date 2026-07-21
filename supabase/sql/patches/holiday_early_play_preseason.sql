-- =============================================================================
-- Holiday early play: schedule + play Aug–Sep (etc.) fixtures during an earlier
-- active GPSL month (e.g. June/July pre-season weeks), when a holiday booking
-- overlaps the fixture’s GPSL month window.
--
-- Also:
--   • Squad minimum (24) required for both clubs on the holiday-early path
--   • Holiday booking allowed while season is preseason or active
--
-- Safe re-run. Depends on: club_owner_holidays.sql, match_scheduling_catch_up.sql,
-- squad_minimum_august.sql, match_scheduling_month_lock_fines_and_replay.sql
-- =============================================================================

-- Either club’s holiday unlocks the fixture for early arrange/play
CREATE OR REPLACE FUNCTION public.match_schedule_fixture_is_holiday_early(p_fixture_id bigint)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_fixture public.competition_fixtures;
  v_active text;
BEGIN
  SELECT * INTO v_fixture
  FROM public.competition_fixtures f
  WHERE f.id = p_fixture_id;

  IF NOT FOUND THEN
    RETURN false;
  END IF;

  IF v_fixture.status <> 'scheduled' THEN
    RETURN false;
  END IF;

  -- Catch-up already moves scheduling into the active month
  IF public.match_schedule_fixture_is_catch_up(p_fixture_id) THEN
    RETURN false;
  END IF;

  v_active := public.competition_active_gpsl_month(v_fixture.season_id, now());
  IF v_active IS NULL THEN
    RETURN false;
  END IF;

  -- Already in the fixture’s play month → normal path
  IF lower(btrim(v_active)) = lower(btrim(v_fixture.gpsl_month)) THEN
    RETURN false;
  END IF;

  RETURN public.club_holiday_allows_fixture_early(
           p_fixture_id, v_fixture.home_club_short_name
         )
      OR public.club_holiday_allows_fixture_early(
           p_fixture_id, v_fixture.away_club_short_name
         );
END;
$function$;

CREATE OR REPLACE FUNCTION public.match_schedule_assert_holiday_early_squad_ready(
  p_fixture_id bigint
)
RETURNS void
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_fixture public.competition_fixtures;
  v_home_shortfall int;
  v_away_shortfall int;
  v_min int := public.squad_minimum_size();
BEGIN
  IF NOT public.match_schedule_fixture_is_holiday_early(p_fixture_id) THEN
    RETURN;
  END IF;

  SELECT * INTO v_fixture
  FROM public.competition_fixtures f
  WHERE f.id = p_fixture_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Fixture not found';
  END IF;

  v_home_shortfall := public.club_squad_minimum_shortfall(v_fixture.home_club_short_name);
  v_away_shortfall := public.club_squad_minimum_shortfall(v_fixture.away_club_short_name);

  IF v_home_shortfall > 0 THEN
    RAISE EXCEPTION
      'Holiday early play requires a full squad (min %). % is short by %.',
      v_min,
      v_fixture.home_club_short_name,
      v_home_shortfall;
  END IF;

  IF v_away_shortfall > 0 THEN
    RAISE EXCEPTION
      'Holiday early play requires a full squad (min %). % is short by %.',
      v_min,
      v_fixture.away_club_short_name,
      v_away_shortfall;
  END IF;
END;
$function$;

-- Fixture ids involving my club that are currently holiday-early (for Match Day UI)
CREATE OR REPLACE FUNCTION public.match_schedule_my_holiday_early_fixture_ids()
RETURNS bigint[]
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT coalesce(array_agg(f.id ORDER BY f.id), ARRAY[]::bigint[])
  FROM public.competition_fixtures f
  JOIN public.competition_seasons s ON s.id = f.season_id
  WHERE s.is_current = true
    AND s.status IN ('active', 'preseason')
    AND f.status = 'scheduled'
    AND public.my_club_shortname() IN (f.home_club_short_name, f.away_club_short_name)
    AND public.match_schedule_fixture_is_holiday_early(f.id);
$$;

-- Kick-off window: catch-up OR holiday-early → current active GPSL month
DROP FUNCTION IF EXISTS public.match_schedule_proposal_kickoff_window(bigint);

CREATE OR REPLACE FUNCTION public.match_schedule_proposal_kickoff_window(p_fixture_id bigint)
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
BEGIN
  SELECT * INTO v_fixture
  FROM public.competition_fixtures f
  WHERE f.id = p_fixture_id;

  IF NOT FOUND THEN
    RETURN;
  END IF;

  IF public.match_schedule_fixture_is_catch_up(p_fixture_id) THEN
    v_active := public.competition_active_gpsl_month(v_fixture.season_id, now());
    IF v_active IS NULL THEN
      RETURN;
    END IF;

    RETURN QUERY
    SELECT cal.unlock_at, cal.lock_at, cal.gpsl_month, true, false
    FROM public.competition_season_calendar cal
    WHERE cal.season_id = v_fixture.season_id
      AND cal.gpsl_month = v_active;
    RETURN;
  END IF;

  IF public.match_schedule_fixture_is_holiday_early(p_fixture_id) THEN
    v_active := public.competition_active_gpsl_month(v_fixture.season_id, now());
    IF v_active IS NULL THEN
      RETURN;
    END IF;

    RETURN QUERY
    SELECT cal.unlock_at, cal.lock_at, cal.gpsl_month, false, true
    FROM public.competition_season_calendar cal
    WHERE cal.season_id = v_fixture.season_id
      AND cal.gpsl_month = v_active;
    RETURN;
  END IF;

  RETURN QUERY
  SELECT w.unlock_at, w.lock_at, w.gpsl_month, false, false
  FROM public.match_schedule_fixture_month_window(p_fixture_id) w;
END;
$function$;

-- Intersection slots must follow the proposal window (holiday / catch-up aware)
CREATE OR REPLACE FUNCTION public.match_schedule_intersection_slots(p_fixture_id bigint)
RETURNS TABLE (kickoff_at timestamptz)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_fixture public.competition_fixtures;
  v_unlock timestamptz;
  v_lock timestamptz;
  v_cursor timestamptz;
  v_now timestamptz := now();
BEGIN
  SELECT * INTO v_fixture FROM public.competition_fixtures WHERE id = p_fixture_id;
  IF NOT FOUND THEN
    RETURN;
  END IF;

  SELECT w.unlock_at, w.lock_at
  INTO v_unlock, v_lock
  FROM public.match_schedule_proposal_kickoff_window(p_fixture_id) w;

  IF v_unlock IS NULL THEN
    RETURN;
  END IF;

  v_cursor := v_unlock;
  WHILE v_cursor + interval '30 minutes' <= v_lock LOOP
    IF v_cursor > v_now
       AND public.match_schedule_club_available_at(
             v_fixture.season_id, v_fixture.home_club_short_name, v_cursor
           )
       AND public.match_schedule_club_available_at(
             v_fixture.season_id, v_fixture.away_club_short_name, v_cursor
           )
    THEN
      kickoff_at := v_cursor;
      RETURN NEXT;
    END IF;
    v_cursor := v_cursor + interval '30 minutes';
  END LOOP;
END;
$function$;

CREATE OR REPLACE FUNCTION public.match_schedule_assert_kickoff_valid(
  p_fixture_id bigint,
  p_kickoff timestamptz
)
RETURNS public.competition_fixtures
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_fixture public.competition_fixtures;
  v_unlock timestamptz;
  v_lock timestamptz;
  v_window_month text;
  v_is_catch_up boolean;
  v_is_holiday_early boolean;
BEGIN
  SELECT * INTO v_fixture
  FROM public.competition_fixtures f
  WHERE f.id = p_fixture_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Fixture not found';
  END IF;

  IF v_fixture.status <> 'scheduled' THEN
    RAISE EXCEPTION 'Fixture is not open for scheduling';
  END IF;

  IF NOT public.match_schedule_kickoff_is_slot(p_kickoff) THEN
    RAISE EXCEPTION 'Kick-off must be on a 30-minute boundary (UK time)';
  END IF;

  IF p_kickoff <= now() THEN
    RAISE EXCEPTION 'That kick-off time has already passed';
  END IF;

  PERFORM public.match_schedule_assert_holiday_early_squad_ready(p_fixture_id);

  SELECT w.unlock_at, w.lock_at, w.gpsl_month, w.is_catch_up, w.is_holiday_early
  INTO v_unlock, v_lock, v_window_month, v_is_catch_up, v_is_holiday_early
  FROM public.match_schedule_proposal_kickoff_window(p_fixture_id) w;

  IF v_unlock IS NULL THEN
    IF public.match_schedule_fixture_is_catch_up(p_fixture_id) THEN
      RAISE EXCEPTION 'Catch-up scheduling opens when the current GPSL month is active';
    END IF;
    IF public.match_schedule_fixture_is_holiday_early(p_fixture_id) THEN
      RAISE EXCEPTION 'Holiday early play opens when the current GPSL month is active';
    END IF;
    RAISE EXCEPTION 'No GPSL month window for this fixture';
  END IF;

  IF p_kickoff < v_unlock OR p_kickoff + interval '30 minutes' > v_lock THEN
    IF coalesce(v_is_catch_up, false) THEN
      RAISE EXCEPTION 'Catch-up kick-off must fall within GPSL % (% – % UK)',
        public.competition_gpsl_month_label(v_window_month),
        public.match_schedule_format_kickoff_uk(v_unlock),
        public.match_schedule_format_kickoff_uk(v_lock);
    END IF;
    IF coalesce(v_is_holiday_early, false) THEN
      RAISE EXCEPTION 'Holiday early kick-off must fall within GPSL % (% – % UK)',
        public.competition_gpsl_month_label(v_window_month),
        public.match_schedule_format_kickoff_uk(v_unlock),
        public.match_schedule_format_kickoff_uk(v_lock);
    END IF;
    RAISE EXCEPTION 'Kick-off must fall within the GPSL month window (% – % UK)',
      public.match_schedule_format_kickoff_uk(v_unlock),
      public.match_schedule_format_kickoff_uk(v_lock);
  END IF;

  IF NOT public.match_schedule_club_available_at(
       v_fixture.season_id, v_fixture.home_club_short_name, p_kickoff
     ) THEN
    RAISE EXCEPTION 'Home club is not available at that time';
  END IF;

  IF NOT public.match_schedule_club_available_at(
       v_fixture.season_id, v_fixture.away_club_short_name, p_kickoff
     ) THEN
    RAISE EXCEPTION 'Away club is not available at that time';
  END IF;

  RETURN v_fixture;
END;
$function$;

CREATE OR REPLACE FUNCTION public.match_schedule_play_now_kickoff(p_fixture_id bigint)
RETURNS timestamptz
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_fixture public.competition_fixtures;
  v_schedule public.competition_fixture_schedule;
  v_unlock timestamptz;
  v_lock timestamptz;
  v_slot timestamptz;
  v_checkin interval;
BEGIN
  SELECT * INTO v_fixture FROM public.competition_fixtures WHERE id = p_fixture_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Fixture not found';
  END IF;

  SELECT * INTO v_schedule FROM public.competition_fixture_schedule WHERE fixture_id = p_fixture_id;
  IF NOT FOUND OR v_schedule.status <> 'agreed' OR v_schedule.agreed_kickoff_at IS NULL THEN
    RAISE EXCEPTION 'Fixture does not have an agreed kick-off';
  END IF;

  IF now() >= v_schedule.agreed_kickoff_at THEN
    RAISE EXCEPTION 'Play now is only available before the agreed kick-off';
  END IF;

  PERFORM public.match_schedule_assert_holiday_early_squad_ready(p_fixture_id);

  v_checkin := (public.match_schedule_checkin_minutes() || ' minutes')::interval;
  v_slot := public.match_schedule_current_uk_slot();

  IF now() >= v_slot + v_checkin THEN
    v_slot := v_slot + interval '30 minutes';
  END IF;

  IF v_slot >= v_schedule.agreed_kickoff_at THEN
    RAISE EXCEPTION 'No earlier play slot is available before the agreed kick-off';
  END IF;

  IF NOT public.match_schedule_kickoff_is_slot(v_slot) THEN
    RAISE EXCEPTION 'Invalid play-now slot';
  END IF;

  SELECT w.unlock_at, w.lock_at
  INTO v_unlock, v_lock
  FROM public.match_schedule_proposal_kickoff_window(p_fixture_id) w;

  IF v_unlock IS NULL THEN
    RAISE EXCEPTION 'No GPSL month window for this fixture';
  END IF;

  IF v_slot < v_unlock OR v_slot + interval '30 minutes' > v_lock THEN
    RAISE EXCEPTION 'Play-now slot must fall within the GPSL month window';
  END IF;

  RETURN v_slot;
END;
$function$;

-- Result calendar guard: either club’s holiday + squad ready
CREATE OR REPLACE FUNCTION public.competition_assert_fixture_month_unlocked(
  p_fixture_id bigint,
  p_club_short_name text DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_fixture public.competition_fixtures;
  v_active text;
  v_unlock timestamptz;
  v_lock timestamptz;
  v_club text;
BEGIN
  IF public.is_gpsl_admin() THEN
    RETURN;
  END IF;

  v_club := nullif(btrim(coalesce(p_club_short_name, '')), '');

  IF public.match_schedule_fixture_is_holiday_early(p_fixture_id) THEN
    PERFORM public.match_schedule_assert_holiday_early_squad_ready(p_fixture_id);
    RETURN;
  END IF;

  -- Legacy: submitting club’s own holiday while already in/near month (edge)
  IF v_club IS NOT NULL AND public.club_holiday_allows_fixture_early(p_fixture_id, v_club) THEN
    RETURN;
  END IF;

  SELECT f.* INTO v_fixture
  FROM public.competition_fixtures f
  WHERE f.id = p_fixture_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Fixture not found';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.competition_season_calendar_config c
    WHERE c.season_id = v_fixture.season_id
  ) THEN
    RETURN;
  END IF;

  v_active := public.competition_active_gpsl_month(v_fixture.season_id, now());

  IF v_active IS NOT NULL AND v_active = v_fixture.gpsl_month THEN
    RETURN;
  END IF;

  IF public.match_schedule_fixture_is_catch_up(p_fixture_id) AND v_active IS NOT NULL THEN
    RETURN;
  END IF;

  SELECT unlock_at, lock_at
  INTO v_unlock, v_lock
  FROM public.competition_season_calendar m
  WHERE m.season_id = v_fixture.season_id
    AND m.gpsl_month = v_fixture.gpsl_month;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'No calendar window for GPSL %', public.competition_gpsl_month_label(v_fixture.gpsl_month);
  END IF;

  IF now() < v_unlock THEN
    RAISE EXCEPTION '% matches unlock at % UK (Fri 19:00 week)',
      public.competition_gpsl_month_label(v_fixture.gpsl_month),
      to_char(v_unlock AT TIME ZONE 'Europe/London', 'Dy DD Mon YYYY HH24:MI');
  END IF;

  RAISE EXCEPTION '% matches locked since % UK',
    public.competition_gpsl_month_label(v_fixture.gpsl_month),
    to_char(v_lock AT TIME ZONE 'Europe/London', 'Dy DD Mon YYYY HH24:MI');
END;
$function$;

-- Book holidays in preseason (June booking before season flips to active)
CREATE OR REPLACE FUNCTION public.club_holiday_book(
  p_start_date date,
  p_end_date date
)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text;
  v_season_id bigint;
  v_starts timestamptz;
  v_ends timestamptz;
  v_days integer;
  v_used integer;
  v_max integer := public.club_holiday_max_days_per_season();
  v_id bigint;
BEGIN
  v_club := public.my_club_shortname();
  IF v_club IS NULL OR v_club = '' THEN
    RAISE EXCEPTION 'No club linked to this account';
  END IF;

  IF p_start_date IS NULL OR p_end_date IS NULL THEN
    RAISE EXCEPTION 'Start and end dates are required';
  END IF;

  IF p_end_date < p_start_date THEN
    RAISE EXCEPTION 'End date must be on or after start date';
  END IF;

  SELECT s.id INTO v_season_id
  FROM public.competition_seasons s
  WHERE s.is_current = true
    AND s.status IN ('active', 'preseason')
  LIMIT 1;

  IF v_season_id IS NULL THEN
    RAISE EXCEPTION 'No current competition season';
  END IF;

  v_starts := (p_start_date::timestamp AT TIME ZONE 'Europe/London');
  v_ends := ((p_end_date + 1)::timestamp AT TIME ZONE 'Europe/London');
  v_days := public.club_holiday_inclusive_days(v_starts, v_ends);

  IF v_days > v_max THEN
    RAISE EXCEPTION 'A single booking cannot exceed % days', v_max;
  END IF;

  v_used := public.club_holiday_days_used(v_season_id, v_club);
  IF v_used + v_days > v_max THEN
    RAISE EXCEPTION 'Only % days of holiday per season (% used, % requested)',
      v_max, v_used, v_days;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.competition_season_calendar cal
    WHERE cal.season_id = v_season_id
      AND cal.unlock_at < v_ends
      AND cal.lock_at > v_starts
      AND now() >= cal.unlock_at
  ) THEN
    RAISE EXCEPTION 'Cannot book holiday for a GPSL month that has already started (Fri 19:00 UK)';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.club_owner_holidays h
    WHERE h.season_id = v_season_id
      AND h.club_short_name = v_club
      AND h.starts_at < v_ends
      AND h.ends_at > v_starts
  ) THEN
    RAISE EXCEPTION 'Holiday overlaps an existing booking for this season';
  END IF;

  IF v_ends <= now() THEN
    RAISE EXCEPTION 'Holiday must end in the future';
  END IF;

  INSERT INTO public.club_owner_holidays (
    season_id,
    club_short_name,
    owner_id,
    starts_at,
    ends_at,
    day_count
  )
  VALUES (
    v_season_id,
    v_club,
    auth.uid(),
    v_starts,
    v_ends,
    v_days::smallint
  )
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$function$;

CREATE OR REPLACE VIEW public.club_owner_holidays_public
WITH (security_invoker = false)
AS
SELECT
  h.id,
  h.season_id,
  h.club_short_name,
  h.starts_at,
  h.ends_at,
  h.day_count,
  h.created_at,
  public.club_holiday_days_used(h.season_id, h.club_short_name) AS season_days_used,
  public.club_holiday_max_days_per_season() AS season_days_allowance,
  (
    public.club_holiday_max_days_per_season()
    - public.club_holiday_days_used(h.season_id, h.club_short_name)
  ) AS season_days_remaining,
  (now() >= h.starts_at AND now() < h.ends_at) AS is_active,
  (now() < h.starts_at) AS is_upcoming,
  (now() >= h.ends_at) AS is_ended
FROM public.club_owner_holidays h
JOIN public.competition_seasons s ON s.id = h.season_id
WHERE s.is_current = true
  AND s.status IN ('active', 'preseason')
  AND h.club_short_name = public.my_club_shortname();

-- Fixture context: expose holiday-early proposal window
CREATE OR REPLACE FUNCTION public.match_schedule_fixture_context(p_fixture_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text;
  v_fixture public.competition_fixtures;
  v_schedule public.competition_fixture_schedule;
  v_schedule_found boolean := false;
  v_pending public.competition_fixture_schedule_proposal;
  v_override public.competition_fixture_mutual_override;
  v_role text;
  v_home text;
  v_away text;
  v_unlock timestamptz;
  v_lock timestamptz;
  v_prop_unlock timestamptz;
  v_prop_lock timestamptz;
  v_prop_month text;
  v_prop_catch_up boolean := false;
  v_prop_holiday_early boolean := false;
  v_is_catch_up boolean := false;
  v_is_holiday_early boolean := false;
  v_slots jsonb;
  v_status text;
  v_agreed timestamptz;
  v_home_count smallint;
  v_away_count smallint;
  v_discord_hint boolean;
  v_pending_id bigint;
  v_mutual_used boolean := false;
  v_kickoff timestamptz;
  v_home_in boolean := false;
  v_away_in boolean := false;
  v_my_in boolean := false;
  v_emergency_used integer;
  v_reschedule_used boolean;
  v_play_now_kickoff timestamptz;
  v_can_play_now boolean := false;
  v_can_mutual_new_time boolean := false;
  v_my_override_confirmed boolean := false;
  v_can_confirm_override boolean := false;
  v_can_cancel_override boolean := false;
  v_can_catch_up_reset boolean := false;
  v_can_replay_reset boolean := false;
BEGIN
  PERFORM public.match_schedule_mutual_override_expire();
  v_club := public.my_club_shortname();
  SELECT * INTO v_fixture FROM public.competition_fixtures WHERE id = p_fixture_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Fixture not found'; END IF;
  IF NOT public.is_gpsl_admin()
     AND v_club NOT IN (v_fixture.home_club_short_name, v_fixture.away_club_short_name)
  THEN RAISE EXCEPTION 'You are not in this fixture'; END IF;
  PERFORM public.fixture_try_checkin_forfeit(p_fixture_id);
  SELECT * INTO v_fixture FROM public.competition_fixtures WHERE id = p_fixture_id;
  v_is_catch_up := public.match_schedule_fixture_is_catch_up(p_fixture_id);
  v_is_holiday_early := public.match_schedule_fixture_is_holiday_early(p_fixture_id);
  v_home := v_fixture.home_club_short_name;
  v_away := v_fixture.away_club_short_name;
  IF v_club = v_home THEN v_role := 'home';
  ELSIF v_club = v_away THEN v_role := 'away';
  ELSE v_role := 'admin'; END IF;
  SELECT * INTO v_schedule FROM public.competition_fixture_schedule WHERE fixture_id = p_fixture_id;
  v_schedule_found := FOUND;
  IF v_schedule_found THEN
    v_status := v_schedule.status;
    v_agreed := v_schedule.agreed_kickoff_at;
    v_home_count := v_schedule.home_proposal_count;
    v_away_count := v_schedule.away_proposal_count;
    v_discord_hint := v_schedule.discord_hint_shown;
    v_pending_id := v_schedule.pending_proposal_id;
    v_mutual_used := COALESCE(v_schedule.mutual_override_used, false);
  ELSE
    v_status := 'unscheduled'; v_agreed := NULL;
    v_home_count := 0; v_away_count := 0; v_discord_hint := false;
    v_pending_id := NULL; v_mutual_used := false;
  END IF;
  IF v_pending_id IS NOT NULL THEN
    SELECT * INTO v_pending FROM public.competition_fixture_schedule_proposal WHERE id = v_pending_id;
  END IF;
  SELECT * INTO v_override FROM public.competition_fixture_mutual_override
  WHERE fixture_id = p_fixture_id AND status = 'pending' ORDER BY created_at DESC LIMIT 1;
  SELECT w.unlock_at, w.lock_at INTO v_unlock, v_lock FROM public.match_schedule_fixture_month_window(p_fixture_id) w;
  SELECT w.unlock_at, w.lock_at, w.gpsl_month, w.is_catch_up, w.is_holiday_early
  INTO v_prop_unlock, v_prop_lock, v_prop_month, v_prop_catch_up, v_prop_holiday_early
  FROM public.match_schedule_proposal_kickoff_window(p_fixture_id) w;
  SELECT COALESCE(jsonb_agg(jsonb_build_object('iso_dow', s.iso_dow, 'hour', s.slot_minute / 60, 'minute', s.slot_minute % 60) ORDER BY s.iso_dow, s.slot_minute), '[]'::jsonb)
  INTO v_slots FROM public.club_owner_availability_slot s
  WHERE s.season_id = v_fixture.season_id AND s.club_short_name = v_club;
  v_kickoff := v_agreed;
  IF v_kickoff IS NOT NULL THEN
    SELECT EXISTS (SELECT 1 FROM public.competition_fixture_checkin c WHERE c.fixture_id = p_fixture_id AND c.club_short_name = v_home) INTO v_home_in;
    SELECT EXISTS (SELECT 1 FROM public.competition_fixture_checkin c WHERE c.fixture_id = p_fixture_id AND c.club_short_name = v_away) INTO v_away_in;
    IF v_club IS NOT NULL THEN
      SELECT EXISTS (SELECT 1 FROM public.competition_fixture_checkin c WHERE c.fixture_id = p_fixture_id AND c.club_short_name = v_club) INTO v_my_in;
    END IF;
  END IF;
  v_emergency_used := public.match_schedule_emergency_drops_used(v_fixture.season_id, v_club);
  v_reschedule_used := public.match_schedule_reschedule_used_this_month(v_fixture.season_id, v_club, v_fixture.gpsl_month);
  IF v_is_catch_up AND v_fixture.status = 'scheduled' THEN
    v_can_catch_up_reset := v_status IN ('agreed', 'negotiating')
      AND (v_kickoff IS NULL OR v_kickoff < now() OR NOT public.match_schedule_kickoff_in_proposal_window(p_fixture_id, v_kickoff))
      AND v_override.id IS NULL;
  END IF;
  IF NOT v_is_catch_up
     AND v_fixture.status = 'scheduled'
     AND public.match_schedule_fixture_play_month_open(p_fixture_id)
     AND v_status = 'agreed'
     AND v_kickoff IS NOT NULL
     AND v_kickoff < now()
     AND v_override.id IS NULL
  THEN
    v_can_replay_reset := true;
  END IF;
  IF v_fixture.status = 'scheduled' AND v_status = 'agreed' AND v_agreed IS NOT NULL AND NOT v_mutual_used AND v_override.id IS NULL THEN
    BEGIN
      v_play_now_kickoff := public.match_schedule_play_now_kickoff(p_fixture_id);
      v_can_play_now := true;
    EXCEPTION WHEN OTHERS THEN
      v_can_play_now := false; v_play_now_kickoff := NULL;
    END;
    v_can_mutual_new_time := now() < v_agreed;
  END IF;
  IF v_override.id IS NOT NULL AND v_club IS NOT NULL THEN
    IF v_club = v_home THEN v_my_override_confirmed := v_override.home_confirmed_at IS NOT NULL;
    ELSE v_my_override_confirmed := v_override.away_confirmed_at IS NOT NULL; END IF;
    v_can_confirm_override := NOT v_my_override_confirmed AND v_override.requested_by_club <> v_club;
    v_can_cancel_override := v_my_override_confirmed OR v_override.requested_by_club = v_club;
  END IF;
  RETURN jsonb_build_object(
    'fixture', jsonb_build_object('id', v_fixture.id, 'gpsl_month', v_fixture.gpsl_month, 'division', v_fixture.division, 'cup_code', v_fixture.cup_code, 'home_club_short_name', v_home, 'away_club_short_name', v_away, 'status', v_fixture.status, 'competition_type', v_fixture.competition_type, 'is_forfeit', v_fixture.is_forfeit, 'is_catch_up', v_is_catch_up, 'is_holiday_early', v_is_holiday_early),
    'schedule', jsonb_build_object('status', v_status, 'agreed_kickoff_at', v_agreed, 'home_proposal_count', v_home_count, 'away_proposal_count', v_away_count, 'discord_hint_shown', v_discord_hint, 'mutual_override_used', v_mutual_used, 'response_due_at', CASE WHEN v_schedule_found THEN v_schedule.response_due_at ELSE NULL END, 'response_required_club_short_name', CASE WHEN v_schedule_found THEN v_schedule.response_required_club_short_name ELSE NULL END, 'response_miss_count', CASE WHEN v_schedule_found THEN coalesce(v_schedule.response_miss_count, 0) ELSE 0 END),
    'pending_proposal', CASE WHEN v_pending.id IS NULL THEN NULL ELSE jsonb_build_object('id', v_pending.id, 'proposed_by_club_short_name', v_pending.proposed_by_club_short_name, 'kickoff_at', v_pending.kickoff_at) END,
    'mutual_override', CASE WHEN v_override.id IS NULL THEN NULL ELSE jsonb_build_object('id', v_override.id, 'kind', v_override.kind, 'proposed_kickoff_at', v_override.proposed_kickoff_at, 'requested_by_club_short_name', v_override.requested_by_club, 'expires_at', v_override.expires_at, 'my_confirmed', v_my_override_confirmed, 'can_confirm', v_can_confirm_override, 'can_cancel', v_can_cancel_override) END,
    'my_role', v_role, 'is_catch_up', v_is_catch_up, 'is_holiday_early', v_is_holiday_early,
    'month_window', jsonb_build_object('unlock_at', v_unlock, 'lock_at', v_lock),
    'proposal_window', jsonb_build_object('unlock_at', v_prop_unlock, 'lock_at', v_prop_lock, 'gpsl_month', v_prop_month, 'is_catch_up', coalesce(v_prop_catch_up, false), 'is_holiday_early', coalesce(v_prop_holiday_early, false)),
    'my_timezone', public.match_schedule_club_timezone(v_club),
    'home_timezone', public.match_schedule_club_timezone(v_home),
    'away_timezone', public.match_schedule_club_timezone(v_away),
    'my_weekly_slots', v_slots,
    'intersection_slots', (SELECT COALESCE(jsonb_agg(i.kickoff_at ORDER BY i.kickoff_at), '[]'::jsonb) FROM public.match_schedule_intersection_slots(p_fixture_id) i),
    'can_propose_first', (v_role = 'home' AND v_status = 'unscheduled' AND v_fixture.status = 'scheduled'),
    'can_respond', (v_pending.id IS NOT NULL AND v_pending.proposed_by_club_short_name <> v_club AND v_status = 'negotiating'),
    'response_deadline', public.match_schedule_response_deadline_json(p_fixture_id, v_club),
    'mutual_override_options', jsonb_build_object('can_request_play_now', v_can_play_now, 'play_now_kickoff_at', v_play_now_kickoff, 'can_request_new_time', v_can_mutual_new_time),
    'checkin', jsonb_build_object('home_checked_in', v_home_in, 'away_checked_in', v_away_in, 'my_checked_in', v_my_in, 'window_opens_at', v_kickoff, 'window_closes_at', CASE WHEN v_kickoff IS NULL THEN NULL ELSE v_kickoff + (public.match_schedule_checkin_minutes() || ' minutes')::interval END, 'play_block_ends_at', CASE WHEN v_kickoff IS NULL THEN NULL ELSE v_kickoff + (public.match_schedule_block_minutes() || ' minutes')::interval END, 'can_check_in', (v_fixture.status = 'scheduled' AND v_kickoff IS NOT NULL AND now() >= v_kickoff AND now() < v_kickoff + (public.match_schedule_checkin_minutes() || ' minutes')::interval AND NOT v_my_in), 'can_play', (v_fixture.status = 'scheduled' AND v_kickoff IS NOT NULL AND v_home_in AND v_away_in AND now() >= v_kickoff AND now() < v_kickoff + (public.match_schedule_block_minutes() || ' minutes')::interval)),
    'allowances', jsonb_build_object('emergency_drops_used', v_emergency_used, 'emergency_drops_remaining', greatest(0, 2 - v_emergency_used), 'reschedule_used_this_month', v_reschedule_used, 'can_voluntary_drop', (v_fixture.status = 'scheduled' AND v_kickoff IS NOT NULL AND now() <= v_kickoff - interval '24 hours' AND NOT v_reschedule_used AND v_override.id IS NULL AND NOT v_is_catch_up), 'can_emergency_drop', (v_fixture.status = 'scheduled' AND v_kickoff IS NOT NULL AND now() < v_kickoff AND now() > v_kickoff - interval '24 hours' AND v_override.id IS NULL AND NOT v_is_catch_up), 'can_catch_up_reset', v_can_catch_up_reset, 'can_replay_reset', v_can_replay_reset)
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.match_schedule_fixture_is_holiday_early(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.match_schedule_assert_holiday_early_squad_ready(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.match_schedule_my_holiday_early_fixture_ids() TO authenticated;
GRANT EXECUTE ON FUNCTION public.match_schedule_proposal_kickoff_window(bigint) TO authenticated;
GRANT SELECT ON public.club_owner_holidays_public TO authenticated;

NOTIFY pgrst, 'reload schema';
