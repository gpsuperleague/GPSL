-- International kick-off: withdraw own pending proposal + proposal history in context.
-- Lets away/home undo an accidental counter-propose so the opponent can propose again.

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
  ELSIF v_nation = v_fix.away_nation THEN
    v_role := 'away';
  ELSE
    v_role := 'admin';
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

  IF v_my_club IS NOT NULL AND NOT v_fix.played AND v_status <> 'agreed' THEN
    SELECT coalesce(jsonb_agg(to_jsonb(s.kickoff_at) ORDER BY s.kickoff_at), '[]'::jsonb)
    INTO v_my_slots
    FROM public.international_match_schedule_club_window_slots(p_fixture_id, v_my_club) s;
  END IF;

  IF NOT v_fix.played AND v_status <> 'agreed' AND v_my_club IS NOT NULL THEN
    IF v_status = 'unscheduled' THEN
      v_can_propose := (v_nation = v_fix.home_nation) OR v_staff;
    ELSIF v_status = 'negotiating' AND v_pending.id IS NOT NULL THEN
      v_can_propose := v_pending.proposed_by_nation IS DISTINCT FROM v_nation;
      v_can_respond := v_pending.proposed_by_nation IS DISTINCT FROM v_nation;
      v_can_withdraw := v_pending.proposed_by_nation = v_nation OR v_staff;
    END IF;
  END IF;

  -- Vacant opponent: home can still propose (auto-agree on propose)
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

CREATE OR REPLACE FUNCTION public.international_withdraw_kickoff_proposal(
  p_fixture_id bigint
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_nation text := public.international_my_nation_code();
  v_fix public.international_fixtures;
  v_sched public.international_fixture_schedule;
  v_prop public.international_fixture_schedule_proposal;
  v_staff boolean := false;
  v_opp text;
  v_opp_club text;
  v_my_club text;
  v_href text;
BEGIN
  IF v_nation IS NULL THEN
    RAISE EXCEPTION 'No national team';
  END IF;

  SELECT * INTO v_fix
  FROM public.international_fixtures
  WHERE id = p_fixture_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Fixture not found';
  END IF;

  v_staff := public.is_gpsl_admin();
  IF NOT v_staff AND to_regprocedure('public.is_gpsl_admin_or_mod()') IS NOT NULL THEN
    v_staff := public.is_gpsl_admin_or_mod();
  END IF;

  IF NOT v_staff AND v_nation NOT IN (v_fix.home_nation, v_fix.away_nation) THEN
    RAISE EXCEPTION 'Not your fixture';
  END IF;
  IF v_fix.played THEN
    RAISE EXCEPTION 'Already played';
  END IF;

  SELECT * INTO v_sched
  FROM public.international_fixture_schedule
  WHERE fixture_id = p_fixture_id
  FOR UPDATE;

  IF NOT FOUND OR v_sched.status <> 'negotiating' OR v_sched.pending_proposal_id IS NULL THEN
    RAISE EXCEPTION 'No pending kick-off proposal to withdraw';
  END IF;

  SELECT * INTO v_prop
  FROM public.international_fixture_schedule_proposal
  WHERE id = v_sched.pending_proposal_id
  FOR UPDATE;

  IF NOT FOUND OR v_prop.status <> 'pending' THEN
    RAISE EXCEPTION 'No pending kick-off proposal to withdraw';
  END IF;

  IF v_prop.proposed_by_nation IS DISTINCT FROM v_nation AND NOT v_staff THEN
    RAISE EXCEPTION 'Only the proposer can withdraw this kick-off proposal';
  END IF;

  UPDATE public.international_fixture_schedule_proposal
  SET status = 'withdrawn'
  WHERE id = v_prop.id;

  UPDATE public.international_fixture_schedule
  SET status = 'unscheduled',
      pending_proposal_id = NULL,
      updated_at = now()
  WHERE fixture_id = p_fixture_id;

  v_opp := CASE
    WHEN v_prop.proposed_by_nation = v_fix.home_nation THEN v_fix.away_nation
    ELSE v_fix.home_nation
  END;
  v_opp_club := public.international_club_for_nation(v_opp);
  v_my_club := public.international_club_for_nation(v_prop.proposed_by_nation);
  v_href := 'international_matchday.html?fixture=' || p_fixture_id::text;

  IF v_opp_club IS NOT NULL THEN
    BEGIN
      PERFORM public.owner_inbox_send(
        'intl_kickoff_withdrawn',
        'International kick-off proposal withdrawn',
        format(
          'The pending kick-off for %s vs %s was withdrawn. Home can propose again.',
          v_fix.home_nation,
          v_fix.away_nation
        ),
        v_opp_club, NULL, NULL, NULL, NULL, NULL,
        v_href,
        'intl_ko_wd:' || v_prop.id::text,
        v_fix.gpsl_month,
        v_fix.season_id
      );
    EXCEPTION WHEN OTHERS THEN
      NULL; -- inbox optional / type not yet allowed
    END;
  END IF;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.international_match_schedule_fixture_context(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.international_withdraw_kickoff_proposal(bigint) TO authenticated;

-- Allow withdrawn inbox type (extends intl notification CHECK)
ALTER TABLE public.competition_inbox
  DROP CONSTRAINT IF EXISTS competition_inbox_message_type_check;

ALTER TABLE public.competition_inbox
  ADD CONSTRAINT competition_inbox_message_type_check
  CHECK (
    message_type IN (
      'welcome_gpsl',
      'result_submitted',
      'result_to_confirm',
      'result_rejected',
      'result_confirmed',
      'transfer_signed',
      'transfer_sold',
      'transfer_upcoming',
      'underperformance_transfer',
      'draft_scheduled',
      'special_auction_scheduled',
      'fine_applied',
      'loan_drawdown',
      'loan_repayment',
      'loan_interest',
      'points_deduction',
      'nation_pick_turn',
      'nation_selection_open',
      'season_expectations',
      'season_overview',
      'player_awards',
      'monthly_fixtures',
      'match_time_proposed',
      'match_time_countered',
      'match_time_proposal_sent',
      'match_time_counter_sent',
      'match_time_accepted',
      'match_rescheduled',
      'match_emergency_drop',
      'match_forfeit_applied',
      'match_checkin_open',
      'match_mutual_override_requested',
      'match_mutual_override_applied',
      'admin_cash_injection',
      'admin_emergency_tax',
      'club_checklist_issues',
      'intl_kickoff_proposal',
      'intl_kickoff_counter',
      'intl_kickoff_proposal_sent',
      'intl_kickoff_counter_sent',
      'intl_kickoff_accepted',
      'intl_kickoff_withdrawn',
      'intl_result_to_confirm',
      'intl_result_submitted',
      'intl_result_confirmed',
      'intl_result_rejected'
    )
  ) NOT VALID;

DO $$
BEGIN
  ALTER TABLE public.competition_inbox
    VALIDATE CONSTRAINT competition_inbox_message_type_check;
EXCEPTION WHEN OTHERS THEN
  RAISE NOTICE 'competition_inbox_message_type_check left NOT VALID: %', SQLERRM;
END $$;
