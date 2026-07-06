-- =============================================================================
-- Match scheduling — slot alignment (early month unlock + normal Friday weeks)
--
-- Problem: propose-time slots use UK :00/:30 boundaries. After admin pull-forward
-- or "end month + open next", unlock_at = now() (e.g. Tue 14:23:17). The old
-- slot finder stepped +30m from that timestamp and never hit a valid boundary.
--
-- Fix:
--   • Align slot search to the next valid UK half-hour (no-op when already
--     Friday 19:00 or any :00/:30 kick-off).
--   • Pull-forward opens the next month on the current UK half-hour floor so the
--     month is LIVE immediately (align up left a gap until the next :00/:30).
--
-- Compatible with:
--   • Test seasons — early month end / calendar pull-forward
--   • Production — Friday 19:00 UK anchor via competition_admin_set_season_calendar
--
-- Run after: match_scheduling_catch_up.sql, competition_admin_end_gpsl_month.sql
-- =============================================================================

CREATE OR REPLACE FUNCTION public.match_schedule_align_kickoff_up(p_at timestamptz)
RETURNS timestamptz
LANGUAGE plpgsql
IMMUTABLE
AS $function$
DECLARE
  v_local timestamp;
  v_remainder int;
  v_on_boundary timestamptz;
BEGIN
  IF p_at IS NULL THEN
    RETURN NULL;
  END IF;

  -- UK wall-clock, whole minutes only (strip seconds/microseconds before rounding)
  v_local := date_trunc('minute', p_at AT TIME ZONE 'Europe/London');
  v_on_boundary := v_local AT TIME ZONE 'Europe/London';
  v_remainder := (
    EXTRACT(HOUR FROM v_local)::int * 60 + EXTRACT(MINUTE FROM v_local)::int
  ) % 30;

  IF v_remainder = 0 AND p_at = v_on_boundary THEN
    RETURN v_on_boundary;
  END IF;

  IF v_remainder = 0 THEN
    v_local := v_local + interval '30 minutes';
  ELSE
    v_local := v_local + ((30 - v_remainder) * interval '1 minute');
  END IF;

  RETURN v_local AT TIME ZONE 'Europe/London';
END;
$function$;

/** Floor to UK :00/:30 — use when opening the next GPSL month immediately. */
CREATE OR REPLACE FUNCTION public.match_schedule_align_kickoff_down(p_at timestamptz)
RETURNS timestamptz
LANGUAGE plpgsql
IMMUTABLE
AS $function$
DECLARE
  v_local timestamp;
  v_remainder int;
BEGIN
  IF p_at IS NULL THEN
    RETURN NULL;
  END IF;

  v_local := date_trunc('minute', p_at AT TIME ZONE 'Europe/London');
  v_remainder := (
    EXTRACT(HOUR FROM v_local)::int * 60 + EXTRACT(MINUTE FROM v_local)::int
  ) % 30;

  IF v_remainder > 0 THEN
    v_local := v_local - (v_remainder * interval '1 minute');
  END IF;

  RETURN v_local AT TIME ZONE 'Europe/London';
END;
$function$;

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

  IF v_unlock IS NULL OR v_lock IS NULL THEN
    RETURN;
  END IF;

  v_cursor := public.match_schedule_align_kickoff_up(greatest(v_unlock, v_now));

  WHILE v_cursor IS NOT NULL
    AND v_cursor + interval '30 minutes' <= v_lock
  LOOP
    IF v_cursor > v_now
       AND public.match_schedule_kickoff_is_slot(v_cursor)
       AND public.match_schedule_club_available_at(v_fixture.season_id, v_fixture.home_club_short_name, v_cursor)
       AND public.match_schedule_club_available_at(v_fixture.season_id, v_fixture.away_club_short_name, v_cursor)
    THEN
      kickoff_at := v_cursor;
      RETURN NEXT;
    END IF;
    v_cursor := v_cursor + interval '30 minutes';
  END LOOP;
END;
$function$;

CREATE OR REPLACE FUNCTION public.competition_admin_pull_forward_calendar_months(
  p_season_id bigint,
  p_after_gpsl_month text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_current record;
  v_next record;
  v_shift interval;
  v_count int := 0;
  v_next_unlock timestamptz;
  v_next_lock timestamptz;
  v_target_unlock timestamptz;
BEGIN
  SELECT *
  INTO v_current
  FROM public.competition_season_calendar c
  WHERE c.season_id = p_season_id
    AND c.gpsl_month = p_after_gpsl_month;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'month_not_on_calendar');
  END IF;

  SELECT *
  INTO v_next
  FROM public.competition_season_calendar c
  WHERE c.season_id = p_season_id
    AND c.sort_order = v_current.sort_order + 1;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_next_month');
  END IF;

  IF v_next.unlock_at <= now() THEN
    RETURN jsonb_build_object(
      'ok', false,
      'reason', 'next_month_already_open',
      'next_gpsl_month', v_next.gpsl_month
    );
  END IF;

  v_target_unlock := public.match_schedule_align_kickoff_down(now());
  IF v_target_unlock IS NULL THEN
    v_target_unlock := now();
  END IF;

  v_shift := v_target_unlock - v_next.unlock_at;

  UPDATE public.competition_season_calendar m
  SET
    unlock_at = m.unlock_at + v_shift,
    lock_at = m.lock_at + v_shift
  WHERE m.season_id = p_season_id
    AND m.sort_order >= v_next.sort_order;

  GET DIAGNOSTICS v_count = ROW_COUNT;

  SELECT unlock_at, lock_at
  INTO v_next_unlock, v_next_lock
  FROM public.competition_season_calendar c
  WHERE c.season_id = p_season_id
    AND c.gpsl_month = v_next.gpsl_month;

  RETURN jsonb_build_object(
    'ok', true,
    'shift', v_shift,
    'months_shifted', v_count,
    'next_gpsl_month', v_next.gpsl_month,
    'next_gpsl_month_label', public.competition_gpsl_month_label(v_next.gpsl_month),
    'next_unlock_at', v_next_unlock,
    'next_lock_at', v_next_lock
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.match_schedule_fixture_slots_diagnose(p_fixture_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_fixture public.competition_fixtures;
  v_unlock timestamptz;
  v_lock timestamptz;
  v_prop record;
  v_home_slots int;
  v_away_slots int;
  v_aligned timestamptz;
  v_intersection int;
BEGIN
  SELECT * INTO v_fixture FROM public.competition_fixtures WHERE id = p_fixture_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'fixture_not_found');
  END IF;

  SELECT w.unlock_at, w.lock_at, w.gpsl_month, w.is_catch_up
  INTO v_prop
  FROM public.match_schedule_proposal_kickoff_window(p_fixture_id) w;

  v_unlock := v_prop.unlock_at;
  v_lock := v_prop.lock_at;
  v_aligned := public.match_schedule_align_kickoff_up(greatest(coalesce(v_unlock, now()), now()));

  SELECT count(*)::int INTO v_home_slots
  FROM public.club_owner_availability_slot s
  WHERE s.season_id = v_fixture.season_id
    AND s.club_short_name = v_fixture.home_club_short_name;

  SELECT count(*)::int INTO v_away_slots
  FROM public.club_owner_availability_slot s
  WHERE s.season_id = v_fixture.season_id
    AND s.club_short_name = v_fixture.away_club_short_name;

  SELECT count(*)::int INTO v_intersection
  FROM public.match_schedule_intersection_slots(p_fixture_id) i;

  RETURN jsonb_build_object(
    'ok', true,
    'fixture_id', p_fixture_id,
    'home', v_fixture.home_club_short_name,
    'away', v_fixture.away_club_short_name,
    'gpsl_month', v_fixture.gpsl_month,
    'proposal_unlock_at', v_unlock,
    'proposal_lock_at', v_lock,
    'proposal_gpsl_month', v_prop.gpsl_month,
    'is_catch_up', coalesce(v_prop.is_catch_up, false),
    'unlock_on_slot_boundary', coalesce(public.match_schedule_kickoff_is_slot(v_unlock), false),
    'aligned_first_slot', v_aligned,
    'aligned_is_valid_slot', coalesce(public.match_schedule_kickoff_is_slot(v_aligned), false),
    'home_availability_slots', v_home_slots,
    'away_availability_slots', v_away_slots,
    'intersection_slot_count', v_intersection
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.match_schedule_align_kickoff_up(timestamptz) TO authenticated;
GRANT EXECUTE ON FUNCTION public.match_schedule_align_kickoff_down(timestamptz) TO authenticated;
GRANT EXECUTE ON FUNCTION public.match_schedule_fixture_slots_diagnose(bigint) TO authenticated;

NOTIFY pgrst, 'reload schema';
