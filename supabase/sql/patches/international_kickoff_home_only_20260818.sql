-- International kick-off: HOME nation proposes only; away Accepts (no counter).
-- Run after international_kickoff_withdraw_20260818.sql (or after availability + notifications).
-- Safe re-run.

-- ---------------------------------------------------------------------------
-- Context flags: home can propose; away can only accept (or withdraw legacy self-proposal)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.international_match_schedule_fixture_context(
  p_fixture_id bigint
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_fix public.international_fixtures;
  v_nation text := public.international_my_nation_code();
  v_home_club text;
  v_away_club text;
  v_my_club text;
  v_role text;
  v_sched public.international_fixture_schedule;
  v_sched_found boolean := false;
  v_pending public.international_fixture_schedule_proposal;
  v_status text := 'unscheduled';
  v_agreed timestamptz;
  v_home_count smallint := 0;
  v_away_count smallint := 0;
  v_pending_id bigint;
  v_unlock timestamptz;
  v_lock timestamptz;
  v_month text;
  v_my_slots jsonb := '[]'::jsonb;
  v_recent jsonb := '[]'::jsonb;
  v_can_propose boolean := false;
  v_can_respond boolean := false;
  v_can_withdraw boolean := false;
  v_staff boolean := false;
  v_home_name text;
  v_away_name text;
  v_my_tz text := 'Europe/London';
  v_home_tz text := 'Europe/London';
  v_away_tz text := 'Europe/London';
  v_is_home boolean := false;
BEGIN
  SELECT f.* INTO v_fix
  FROM public.international_fixtures f
  WHERE f.id = p_fixture_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'International fixture not found';
  END IF;

  v_staff := public.is_gpsl_admin();
  IF NOT v_staff AND to_regprocedure('public.is_gpsl_admin_or_mod()') IS NOT NULL THEN
    v_staff := public.is_gpsl_admin_or_mod();
  END IF;

  IF NOT v_staff
     AND (v_nation IS NULL OR v_nation NOT IN (v_fix.home_nation, v_fix.away_nation))
  THEN
    RAISE EXCEPTION 'You are not in this international fixture';
  END IF;

  v_home_club := public.international_club_for_nation(v_fix.home_nation);
  v_away_club := public.international_club_for_nation(v_fix.away_nation);
  v_my_club := CASE
    WHEN v_nation = v_fix.home_nation THEN v_home_club
    WHEN v_nation = v_fix.away_nation THEN v_away_club
    ELSE NULL
  END;

  IF v_nation = v_fix.home_nation THEN
    v_role := 'home';
    v_is_home := true;
  ELSIF v_nation = v_fix.away_nation THEN
    v_role := 'away';
  ELSE
    v_role := 'admin';
    v_is_home := true; -- staff acts as home for proposing
  END IF;

  SELECT * INTO v_sched
  FROM public.international_fixture_schedule
  WHERE fixture_id = p_fixture_id;
  v_sched_found := FOUND;

  IF v_sched_found THEN
    v_status := v_sched.status;
    v_agreed := v_sched.agreed_kickoff_at;
    v_home_count := coalesce(v_sched.home_proposal_count, 0);
    v_away_count := coalesce(v_sched.away_proposal_count, 0);
    v_pending_id := v_sched.pending_proposal_id;
  END IF;

  IF v_pending_id IS NOT NULL THEN
    SELECT * INTO v_pending
    FROM public.international_fixture_schedule_proposal
    WHERE id = v_pending_id;
  END IF;

  SELECT coalesce(
    jsonb_agg(
      jsonb_build_object(
        'id', p.id,
        'proposed_by_nation', p.proposed_by_nation,
        'kickoff_at', p.kickoff_at,
        'status', p.status,
        'created_at', p.created_at
      )
      ORDER BY p.created_at DESC, p.id DESC
    ),
    '[]'::jsonb
  )
  INTO v_recent
  FROM (
    SELECT *
    FROM public.international_fixture_schedule_proposal p
    WHERE p.fixture_id = p_fixture_id
    ORDER BY p.created_at DESC, p.id DESC
    LIMIT 6
  ) p;

  SELECT w.unlock_at, w.lock_at, w.gpsl_month
  INTO v_unlock, v_lock, v_month
  FROM public.international_match_schedule_proposal_window(p_fixture_id) w;

  -- Slots only for home (proposers). Away Accepts without picking slots.
  IF v_my_club IS NOT NULL
     AND NOT v_fix.played
     AND v_status <> 'agreed'
     AND (v_is_home OR v_staff)
  THEN
    SELECT coalesce(jsonb_agg(to_jsonb(s.kickoff_at) ORDER BY s.kickoff_at), '[]'::jsonb)
    INTO v_my_slots
    FROM public.international_match_schedule_club_window_slots(p_fixture_id, v_my_club) s;
  END IF;

  IF NOT v_fix.played AND v_status <> 'agreed' AND v_my_club IS NOT NULL THEN
    IF v_is_home OR v_staff THEN
      IF v_status = 'unscheduled' THEN
        v_can_propose := true;
      ELSIF v_status = 'negotiating' AND v_pending.id IS NOT NULL THEN
        -- Home may replace own pending or clear a legacy away pending
        v_can_propose := true;
        IF v_pending.proposed_by_nation IS DISTINCT FROM v_nation THEN
          v_can_respond := true;
        END IF;
        IF v_pending.proposed_by_nation = v_nation OR v_staff THEN
          v_can_withdraw := true;
        END IF;
      END IF;
    ELSE
      -- Away: Accept only (never propose / counter)
      IF v_status = 'negotiating' AND v_pending.id IS NOT NULL THEN
        IF v_pending.proposed_by_nation IS DISTINCT FROM v_nation THEN
          v_can_respond := true;
        ELSE
          -- Legacy: away previously counter-proposed — allow withdraw
          v_can_withdraw := true;
        END IF;
      END IF;
    END IF;
  END IF;

  IF NOT v_fix.played
     AND v_status = 'unscheduled'
     AND v_nation = v_fix.home_nation
     AND v_my_club IS NOT NULL
     AND v_away_club IS NULL
  THEN
    v_can_propose := true;
  END IF;

  SELECT hn.name, an.name
  INTO v_home_name, v_away_name
  FROM public.international_nations hn
  CROSS JOIN public.international_nations an
  WHERE hn.code = v_fix.home_nation
    AND an.code = v_fix.away_nation;

  IF v_my_club IS NOT NULL THEN
    v_my_tz := public.match_schedule_club_timezone(v_my_club);
  END IF;
  IF v_home_club IS NOT NULL THEN
    v_home_tz := public.match_schedule_club_timezone(v_home_club);
  END IF;
  IF v_away_club IS NOT NULL THEN
    v_away_tz := public.match_schedule_club_timezone(v_away_club);
  END IF;

  RETURN jsonb_build_object(
    'fixture', jsonb_build_object(
      'id', v_fix.id,
      'gpsl_month', v_fix.gpsl_month,
      'phase', v_fix.phase,
      'home_nation', v_fix.home_nation,
      'away_nation', v_fix.away_nation,
      'home_nation_name', coalesce(v_home_name, v_fix.home_nation),
      'away_nation_name', coalesce(v_away_name, v_fix.away_nation),
      'home_club_short_name', v_home_club,
      'away_club_short_name', v_away_club,
      'status', CASE WHEN v_fix.played THEN 'played' ELSE 'scheduled' END,
      'played', v_fix.played,
      'season_id', v_fix.season_id
    ),
    'schedule', jsonb_build_object(
      'status', v_status,
      'agreed_kickoff_at', v_agreed,
      'home_proposal_count', v_home_count,
      'away_proposal_count', v_away_count
    ),
    'pending_proposal', CASE
      WHEN v_pending.id IS NULL THEN NULL
      ELSE jsonb_build_object(
        'id', v_pending.id,
        'proposed_by_nation', v_pending.proposed_by_nation,
        'kickoff_at', v_pending.kickoff_at
      )
    END,
    'recent_proposals', v_recent,
    'my_role', v_role,
    'my_nation', v_nation,
    'my_club_short_name', v_my_club,
    'my_timezone', v_my_tz,
    'home_timezone', v_home_tz,
    'away_timezone', v_away_tz,
    'proposal_window', jsonb_build_object(
      'unlock_at', v_unlock,
      'lock_at', v_lock,
      'gpsl_month', v_month
    ),
    'my_window_slots', v_my_slots,
    'can_propose_first', v_can_propose AND v_status = 'unscheduled',
    'can_propose', v_can_propose,
    'can_respond', v_can_respond,
    'can_withdraw', v_can_withdraw,
    'home_vacant', v_home_club IS NULL,
    'away_vacant', v_away_club IS NULL
  );
END;
$function$;

-- ---------------------------------------------------------------------------
-- Propose: HOME (or staff) only — away must Accept
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.international_propose_kickoff(
  p_fixture_id bigint,
  p_kickoff_at timestamptz
)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_nation text := public.international_my_nation_code();
  v_fix public.international_fixtures;
  v_sched public.international_fixture_schedule;
  v_prop_id bigint;
  v_my_club text;
  v_opp text;
  v_opp_club text;
  v_unlock timestamptz;
  v_lock timestamptz;
  v_is_counter boolean := false;
  v_staff boolean := false;
  v_phase text;
  v_matchup text;
  v_ko_label text;
  v_href text;
BEGIN
  IF v_nation IS NULL THEN RAISE EXCEPTION 'No national team'; END IF;
  IF p_kickoff_at IS NULL THEN RAISE EXCEPTION 'Kickoff required'; END IF;

  SELECT * INTO v_fix FROM public.international_fixtures WHERE id = p_fixture_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Fixture not found'; END IF;
  IF v_nation NOT IN (v_fix.home_nation, v_fix.away_nation) THEN
    RAISE EXCEPTION 'Not your fixture';
  END IF;
  IF v_fix.played THEN RAISE EXCEPTION 'Already played'; END IF;

  v_staff := public.is_gpsl_admin();
  IF NOT v_staff AND to_regprocedure('public.is_gpsl_admin_or_mod()') IS NOT NULL THEN
    v_staff := public.is_gpsl_admin_or_mod();
  END IF;

  IF v_nation <> v_fix.home_nation AND NOT v_staff THEN
    RAISE EXCEPTION 'Only the home nation can propose kick-off times. Away Accepts only.';
  END IF;

  v_my_club := public.international_club_for_nation(v_nation);
  IF v_my_club IS NULL AND NOT v_staff THEN
    RAISE EXCEPTION 'Your nation has no owner club - cannot propose kick-off';
  END IF;

  IF NOT public.match_schedule_kickoff_is_slot(p_kickoff_at) THEN
    RAISE EXCEPTION 'Kick-off must be on a 30-minute UK clock (e.g. 19:00, 19:30)';
  END IF;

  IF p_kickoff_at <= now() THEN
    RAISE EXCEPTION 'Kick-off must be in the future';
  END IF;

  SELECT w.unlock_at, w.lock_at
  INTO v_unlock, v_lock
  FROM public.international_match_schedule_proposal_window(p_fixture_id) w;

  IF v_unlock IS NULL OR v_lock IS NULL THEN
    RAISE EXCEPTION 'No calendar window for this international GPSL month yet';
  END IF;

  IF p_kickoff_at < v_unlock OR p_kickoff_at + interval '30 minutes' > v_lock THEN
    RAISE EXCEPTION 'Kick-off must fall inside the GPSL month window for this fixture';
  END IF;

  IF v_my_club IS NOT NULL
     AND NOT public.match_schedule_club_available_at(
           v_fix.season_id, v_my_club, p_kickoff_at
         )
  THEN
    RAISE EXCEPTION 'You are not available at that time - set weekly availability on Owner Details first';
  END IF;

  IF v_my_club IS NOT NULL
     AND public.match_schedule_club_busy_at(
           v_my_club, p_kickoff_at, NULL, v_fix.season_id
         )
  THEN
    RAISE EXCEPTION 'You already have a club match overlapping that kick-off';
  END IF;

  INSERT INTO public.international_fixture_schedule (fixture_id, status)
  VALUES (p_fixture_id, 'unscheduled')
  ON CONFLICT (fixture_id) DO NOTHING;

  SELECT * INTO v_sched
  FROM public.international_fixture_schedule
  WHERE fixture_id = p_fixture_id
  FOR UPDATE;

  IF v_sched.status = 'agreed' THEN
    RAISE EXCEPTION 'Kick-off is already agreed for this fixture';
  END IF;

  v_is_counter := v_sched.status <> 'unscheduled';

  -- Home may propose when unscheduled, or replace any pending (own time change / legacy away)
  IF v_sched.status = 'negotiating' AND v_sched.pending_proposal_id IS NULL THEN
    RAISE EXCEPTION 'No pending proposal to replace';
  END IF;

  UPDATE public.international_fixture_schedule_proposal
  SET status = 'superseded'
  WHERE fixture_id = p_fixture_id AND status = 'pending';

  INSERT INTO public.international_fixture_schedule_proposal (
    fixture_id, proposed_by_nation, kickoff_at, status
  )
  VALUES (p_fixture_id, v_nation, p_kickoff_at, 'pending')
  RETURNING id INTO v_prop_id;

  v_opp := CASE
    WHEN v_nation = v_fix.home_nation THEN v_fix.away_nation
    ELSE v_fix.home_nation
  END;
  v_opp_club := public.international_club_for_nation(v_opp);
  v_phase := public.international_fixture_phase_label(v_fix.phase);
  v_matchup := public.international_fixture_matchup_label(p_fixture_id);
  v_ko_label := to_char(p_kickoff_at AT TIME ZONE 'Europe/London', 'Dy DD Mon HH24:MI') || ' UK';
  v_href := 'international_matchday.html?fixture=' || p_fixture_id::text;

  IF v_opp_club IS NULL THEN
    UPDATE public.international_fixture_schedule_proposal
    SET status = 'accepted'
    WHERE id = v_prop_id;

    UPDATE public.international_fixture_schedule
    SET status = 'agreed',
        agreed_kickoff_at = p_kickoff_at,
        pending_proposal_id = NULL,
        home_proposal_count = home_proposal_count
          + CASE WHEN v_nation = v_fix.home_nation THEN 1 ELSE 0 END,
        away_proposal_count = away_proposal_count
          + CASE WHEN v_nation = v_fix.away_nation THEN 1 ELSE 0 END,
        updated_at = now()
    WHERE fixture_id = p_fixture_id;

    IF v_my_club IS NOT NULL THEN
      PERFORM public.owner_inbox_send(
        'intl_kickoff_accepted',
        format('%s kick-off agreed (vacant opponent)', v_phase),
        format(E'%s\nKick-off: %s\nOpponent nation is vacant - time auto-agreed.', v_matchup, v_ko_label),
        v_my_club, NULL, NULL, NULL, NULL, NULL,
        v_href,
        'intl_ko_auto:' || v_prop_id::text,
        v_fix.gpsl_month, v_fix.season_id
      );
    END IF;

    RETURN v_prop_id;
  END IF;

  UPDATE public.international_fixture_schedule
  SET status = 'negotiating',
      pending_proposal_id = v_prop_id,
      home_proposal_count = home_proposal_count
        + CASE WHEN v_nation = v_fix.home_nation THEN 1 ELSE 0 END,
      away_proposal_count = away_proposal_count
        + CASE WHEN v_nation = v_fix.away_nation THEN 1 ELSE 0 END,
      updated_at = now()
  WHERE fixture_id = p_fixture_id;

  PERFORM public.owner_inbox_send(
    CASE WHEN NOT v_is_counter THEN 'intl_kickoff_proposal' ELSE 'intl_kickoff_counter' END,
    CASE
      WHEN NOT v_is_counter THEN format('%s kick-off proposed', v_phase)
      ELSE format('%s kick-off updated', v_phase)
    END,
    format(
      E'%s\nProposed kick-off: %s\nOpen International Matchday to Accept (home proposes only).',
      v_matchup, v_ko_label
    ),
    v_opp_club, NULL, NULL, NULL, NULL, NULL,
    v_href,
    'intl_ko:' || v_prop_id::text,
    v_fix.gpsl_month, v_fix.season_id
  );

  IF v_my_club IS NOT NULL THEN
    PERFORM public.owner_inbox_send(
      CASE WHEN NOT v_is_counter THEN 'intl_kickoff_proposal_sent' ELSE 'intl_kickoff_counter_sent' END,
      CASE
        WHEN NOT v_is_counter THEN format('%s kick-off proposal sent', v_phase)
        ELSE format('%s kick-off update sent', v_phase)
      END,
      format(E'%s\nYou proposed: %s\nWaiting for away to Accept.', v_matchup, v_ko_label),
      v_my_club, NULL, NULL, NULL, NULL, NULL,
      v_href,
      'intl_ko_sent:' || v_prop_id::text,
      v_fix.gpsl_month, v_fix.season_id
    );
  END IF;

  RETURN v_prop_id;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.international_match_schedule_fixture_context(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.international_propose_kickoff(bigint, timestamptz) TO authenticated;
