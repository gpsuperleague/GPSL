-- =============================================================================
-- Hotfix: match_schedule_fixture_context must not INSERT (was STABLE + ensure_row).
-- Run once if you already deployed match_scheduling_phase1.sql.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.match_schedule_fixture_context(p_fixture_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text;
  v_fixture public.competition_fixtures;
  v_schedule public.competition_fixture_schedule;
  v_schedule_found boolean := false;
  v_pending public.competition_fixture_schedule_proposal;
  v_role text;
  v_home text;
  v_away text;
  v_unlock timestamptz;
  v_lock timestamptz;
  v_slots jsonb;
  v_status text;
  v_agreed timestamptz;
  v_home_count smallint;
  v_away_count smallint;
  v_discord_hint boolean;
  v_pending_id bigint;
BEGIN
  v_club := public.my_club_shortname();

  SELECT * INTO v_fixture FROM public.competition_fixtures WHERE id = p_fixture_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Fixture not found';
  END IF;

  IF NOT public.is_gpsl_admin()
     AND v_club NOT IN (v_fixture.home_club_short_name, v_fixture.away_club_short_name)
  THEN
    RAISE EXCEPTION 'You are not in this fixture';
  END IF;

  v_home := v_fixture.home_club_short_name;
  v_away := v_fixture.away_club_short_name;

  IF v_club = v_home THEN
    v_role := 'home';
  ELSIF v_club = v_away THEN
    v_role := 'away';
  ELSE
    v_role := 'admin';
  END IF;

  SELECT * INTO v_schedule
  FROM public.competition_fixture_schedule
  WHERE fixture_id = p_fixture_id;

  v_schedule_found := FOUND;

  IF v_schedule_found THEN
    v_status := v_schedule.status;
    v_agreed := v_schedule.agreed_kickoff_at;
    v_home_count := v_schedule.home_proposal_count;
    v_away_count := v_schedule.away_proposal_count;
    v_discord_hint := v_schedule.discord_hint_shown;
    v_pending_id := v_schedule.pending_proposal_id;
  ELSE
    v_status := 'unscheduled';
    v_agreed := NULL;
    v_home_count := 0;
    v_away_count := 0;
    v_discord_hint := false;
    v_pending_id := NULL;
  END IF;

  IF v_pending_id IS NOT NULL THEN
    SELECT * INTO v_pending
    FROM public.competition_fixture_schedule_proposal
    WHERE id = v_pending_id;
  END IF;

  SELECT w.unlock_at, w.lock_at INTO v_unlock, v_lock
  FROM public.match_schedule_fixture_month_window(p_fixture_id) w;

  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'iso_dow', s.iso_dow,
      'hour', s.slot_minute / 60,
      'minute', s.slot_minute % 60
    )
    ORDER BY s.iso_dow, s.slot_minute
  ), '[]'::jsonb)
  INTO v_slots
  FROM public.club_owner_availability_slot s
  WHERE s.season_id = v_fixture.season_id
    AND s.club_short_name = v_club;

  RETURN jsonb_build_object(
    'fixture', jsonb_build_object(
      'id', v_fixture.id,
      'gpsl_month', v_fixture.gpsl_month,
      'home_club_short_name', v_home,
      'away_club_short_name', v_away,
      'status', v_fixture.status,
      'competition_type', v_fixture.competition_type
    ),
    'schedule', jsonb_build_object(
      'status', v_status,
      'agreed_kickoff_at', v_agreed,
      'home_proposal_count', v_home_count,
      'away_proposal_count', v_away_count,
      'discord_hint_shown', v_discord_hint
    ),
    'pending_proposal', CASE WHEN v_pending.id IS NULL THEN NULL ELSE jsonb_build_object(
      'id', v_pending.id,
      'proposed_by_club_short_name', v_pending.proposed_by_club_short_name,
      'kickoff_at', v_pending.kickoff_at
    ) END,
    'my_role', v_role,
    'month_window', jsonb_build_object('unlock_at', v_unlock, 'lock_at', v_lock),
    'my_timezone', public.match_schedule_club_timezone(v_club),
    'home_timezone', public.match_schedule_club_timezone(v_home),
    'away_timezone', public.match_schedule_club_timezone(v_away),
    'my_weekly_slots', v_slots,
    'intersection_slots', (
      SELECT COALESCE(jsonb_agg(i.kickoff_at ORDER BY i.kickoff_at), '[]'::jsonb)
      FROM public.match_schedule_intersection_slots(p_fixture_id) i
    ),
    'can_propose_first', (v_role = 'home' AND v_status = 'unscheduled'),
    'can_respond', (
      v_pending.id IS NOT NULL
      AND v_pending.proposed_by_club_short_name <> v_club
      AND v_status = 'negotiating'
    )
  );
END;
$function$;

NOTIFY pgrst, 'reload schema';
