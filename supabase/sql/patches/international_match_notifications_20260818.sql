-- =============================================================================
-- International / World Cup match notifications (inbox + Discord parity)
--
-- Mirrors league/cup owner inbox for:
--   kickoff propose / counter / accept
--   result submit / confirm / reject
-- Covers qualifying + finals (shared international_fixtures).
--
-- Also:
--   allows intl_kickoff_counter (already sent but missing from CHECK)
--   Discord weekly match reminder includes outstanding WC/intl fixtures
--
-- Safe re-run. Run in Supabase SQL Editor.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Message types
-- ---------------------------------------------------------------------------
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
      -- International / World Cup
      'intl_kickoff_proposal',
      'intl_kickoff_counter',
      'intl_kickoff_proposal_sent',
      'intl_kickoff_counter_sent',
      'intl_kickoff_accepted',
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

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.international_fixture_phase_label(p_phase text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE lower(btrim(coalesce(p_phase, '')))
    WHEN 'qualifying' THEN 'WC Qualifying'
    WHEN 'finals_group' THEN 'WC Finals (group)'
    WHEN 'knockout' THEN 'WC Finals (knockout)'
    ELSE 'International'
  END;
$$;

CREATE OR REPLACE FUNCTION public.international_nation_display_name(p_code text)
RETURNS text
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT coalesce(
    (SELECT n.name FROM public.international_nations n WHERE n.code = p_code LIMIT 1),
    nullif(btrim(p_code), ''),
    '—'
  );
$$;

CREATE OR REPLACE FUNCTION public.international_fixture_matchup_label(p_fixture_id bigint)
RETURNS text
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT format(
    '%s vs %s',
    public.international_nation_display_name(f.home_nation),
    public.international_nation_display_name(f.away_nation)
  )
  FROM public.international_fixtures f
  WHERE f.id = p_fixture_id;
$$;

-- ---------------------------------------------------------------------------
-- Propose kickoff — notify opponent + proposer ack (same rules as availability patch)
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
  v_my_club := public.international_club_for_nation(v_nation);
  IF v_my_club IS NULL AND NOT v_staff THEN
    RAISE EXCEPTION 'Your nation has no owner club — cannot propose kick-off';
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
    RAISE EXCEPTION 'You are not available at that time — set weekly availability on Owner Details first';
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

  IF v_sched.status = 'unscheduled' THEN
    IF v_nation <> v_fix.home_nation AND NOT v_staff THEN
      RAISE EXCEPTION 'Home nation must propose the first kick-off time';
    END IF;
  ELSE
    IF v_sched.pending_proposal_id IS NULL THEN
      RAISE EXCEPTION 'No pending proposal to respond to';
    END IF;
    IF EXISTS (
      SELECT 1
      FROM public.international_fixture_schedule_proposal p
      WHERE p.id = v_sched.pending_proposal_id
        AND p.proposed_by_nation = v_nation
    ) THEN
      RAISE EXCEPTION 'Wait for your opponent to respond to your proposal';
    END IF;
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

  -- Vacant opponent → auto-agree
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
        format(E'%s\nKick-off: %s\nOpponent nation is vacant — time auto-agreed.', v_matchup, v_ko_label),
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

  -- Opponent
  PERFORM public.owner_inbox_send(
    CASE WHEN NOT v_is_counter THEN 'intl_kickoff_proposal' ELSE 'intl_kickoff_counter' END,
    CASE
      WHEN NOT v_is_counter THEN format('%s kick-off proposed', v_phase)
      ELSE format('%s counter-proposal', v_phase)
    END,
    format(
      E'%s\nProposed kick-off: %s\nOpen International Matchday to accept or counter.',
      v_matchup, v_ko_label
    ),
    v_opp_club, NULL, NULL, NULL, NULL, NULL,
    v_href,
    'intl_ko:' || v_prop_id::text,
    v_fix.gpsl_month, v_fix.season_id
  );

  -- Proposer ack
  IF v_my_club IS NOT NULL THEN
    PERFORM public.owner_inbox_send(
      CASE WHEN NOT v_is_counter THEN 'intl_kickoff_proposal_sent' ELSE 'intl_kickoff_counter_sent' END,
      CASE
        WHEN NOT v_is_counter THEN format('%s kick-off proposal sent', v_phase)
        ELSE format('%s counter-proposal sent', v_phase)
      END,
      format(E'%s\nYou proposed: %s\nWaiting for the opponent to respond.', v_matchup, v_ko_label),
      v_my_club, NULL, NULL, NULL, NULL, NULL,
      v_href,
      'intl_ko_sent:' || v_prop_id::text,
      v_fix.gpsl_month, v_fix.season_id
    );
  END IF;

  RETURN v_prop_id;
END;
$function$;

-- ---------------------------------------------------------------------------
-- Accept kickoff — notify both owners
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.international_accept_kickoff(p_proposal_id bigint)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_nation text := public.international_my_nation_code();
  v_prop public.international_fixture_schedule_proposal;
  v_fix public.international_fixtures;
  v_my_club text;
  v_home_club text;
  v_away_club text;
  v_unlock timestamptz;
  v_lock timestamptz;
  v_phase text;
  v_matchup text;
  v_ko_label text;
  v_href text;
  v_body text;
BEGIN
  SELECT * INTO v_prop
  FROM public.international_fixture_schedule_proposal
  WHERE id = p_proposal_id
  FOR UPDATE;

  IF NOT FOUND OR v_prop.status <> 'pending' THEN
    RAISE EXCEPTION 'Proposal not available';
  END IF;

  SELECT * INTO v_fix FROM public.international_fixtures WHERE id = v_prop.fixture_id;
  IF v_nation NOT IN (v_fix.home_nation, v_fix.away_nation) THEN
    RAISE EXCEPTION 'Not your fixture';
  END IF;
  IF v_nation = v_prop.proposed_by_nation AND NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Opponent must accept';
  END IF;
  IF v_fix.played THEN
    RAISE EXCEPTION 'Already played';
  END IF;

  IF NOT public.match_schedule_kickoff_is_slot(v_prop.kickoff_at) THEN
    RAISE EXCEPTION 'Proposed kick-off is not a valid 30-minute UK slot';
  END IF;

  IF v_prop.kickoff_at <= now() THEN
    RAISE EXCEPTION 'Proposed kick-off is in the past — ask for a new time';
  END IF;

  SELECT w.unlock_at, w.lock_at
  INTO v_unlock, v_lock
  FROM public.international_match_schedule_proposal_window(v_prop.fixture_id) w;

  IF v_unlock IS NULL OR v_lock IS NULL
     OR v_prop.kickoff_at < v_unlock
     OR v_prop.kickoff_at + interval '30 minutes' > v_lock
  THEN
    RAISE EXCEPTION 'Proposed kick-off is outside the GPSL month window';
  END IF;

  v_my_club := public.international_club_for_nation(v_nation);
  IF v_my_club IS NOT NULL
     AND public.match_schedule_club_busy_at(
           v_my_club, v_prop.kickoff_at, NULL, v_fix.season_id
         )
  THEN
    RAISE EXCEPTION 'You already have a club match overlapping that kick-off';
  END IF;

  UPDATE public.international_fixture_schedule_proposal
  SET status = 'accepted'
  WHERE id = p_proposal_id;

  UPDATE public.international_fixture_schedule_proposal
  SET status = 'superseded'
  WHERE fixture_id = v_prop.fixture_id
    AND id <> p_proposal_id
    AND status = 'pending';

  UPDATE public.international_fixture_schedule
  SET status = 'agreed',
      agreed_kickoff_at = v_prop.kickoff_at,
      pending_proposal_id = NULL,
      updated_at = now()
  WHERE fixture_id = v_prop.fixture_id;

  v_phase := public.international_fixture_phase_label(v_fix.phase);
  v_matchup := public.international_fixture_matchup_label(v_prop.fixture_id);
  v_ko_label := to_char(v_prop.kickoff_at AT TIME ZONE 'Europe/London', 'Dy DD Mon HH24:MI') || ' UK';
  v_href := 'international_matchday.html?fixture=' || v_prop.fixture_id::text;
  v_body := format(E'%s\nAgreed kick-off: %s\nOpen International Matchday when ready to play.', v_matchup, v_ko_label);

  v_home_club := public.international_club_for_nation(v_fix.home_nation);
  v_away_club := public.international_club_for_nation(v_fix.away_nation);

  IF v_home_club IS NOT NULL THEN
    PERFORM public.owner_inbox_send(
      'intl_kickoff_accepted',
      format('%s kick-off agreed', v_phase),
      v_body,
      v_home_club, NULL, NULL, NULL, NULL, NULL,
      v_href,
      'intl_ko_ok_h:' || p_proposal_id::text,
      v_fix.gpsl_month, v_fix.season_id
    );
  END IF;
  IF v_away_club IS NOT NULL THEN
    PERFORM public.owner_inbox_send(
      'intl_kickoff_accepted',
      format('%s kick-off agreed', v_phase),
      v_body,
      v_away_club, NULL, NULL, NULL, NULL, NULL,
      v_href,
      'intl_ko_ok_a:' || p_proposal_id::text,
      v_fix.gpsl_month, v_fix.season_id
    );
  END IF;
END;
$function$;

-- ---------------------------------------------------------------------------
-- Submit result — notify opponent + submitter ack
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.international_submit_result(
  p_fixture_id bigint,
  p_home_goals smallint,
  p_away_goals smallint,
  p_player_stats jsonb DEFAULT '[]'::jsonb,
  p_home_goals_et smallint DEFAULT NULL,
  p_away_goals_et smallint DEFAULT NULL,
  p_home_pens smallint DEFAULT NULL,
  p_away_pens smallint DEFAULT NULL
)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_nation text := public.international_my_nation_code();
  v_fix public.international_fixtures;
  v_opp text;
  v_opp_club text;
  v_my_club text;
  v_sub_id bigint;
  v_home_name text;
  v_away_name text;
  v_phase text;
  v_href text;
  v_score text;
BEGIN
  IF v_nation IS NULL OR v_nation = '' THEN
    RAISE EXCEPTION 'No national team linked to your club';
  END IF;

  IF p_home_goals IS NULL OR p_away_goals IS NULL OR p_home_goals < 0 OR p_away_goals < 0 THEN
    RAISE EXCEPTION 'Invalid score';
  END IF;

  SELECT * INTO v_fix
  FROM public.international_fixtures
  WHERE id = p_fixture_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Fixture not found';
  END IF;

  IF v_fix.played OR v_fix.status = 'played' THEN
    RAISE EXCEPTION 'Fixture already played';
  END IF;

  IF v_nation NOT IN (v_fix.home_nation, v_fix.away_nation) THEN
    RAISE EXCEPTION 'Your nation is not in this fixture';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.international_result_submissions s
    WHERE s.fixture_id = p_fixture_id AND s.status = 'pending'
  ) THEN
    RAISE EXCEPTION 'A result is already awaiting confirmation';
  END IF;

  v_opp := CASE WHEN v_nation = v_fix.home_nation THEN v_fix.away_nation ELSE v_fix.home_nation END;
  v_opp_club := public.international_club_for_nation(v_opp);
  v_my_club := public.international_club_for_nation(v_nation);

  INSERT INTO public.international_result_submissions (
    fixture_id, submitted_by_nation, home_goals, away_goals,
    home_goals_et, away_goals_et, home_pens, away_pens,
    player_stats, status
  )
  VALUES (
    p_fixture_id, v_nation, p_home_goals, p_away_goals,
    p_home_goals_et, p_away_goals_et, p_home_pens, p_away_pens,
    coalesce(p_player_stats, '[]'::jsonb), 'pending'
  )
  RETURNING id INTO v_sub_id;

  v_home_name := public.international_nation_display_name(v_fix.home_nation);
  v_away_name := public.international_nation_display_name(v_fix.away_nation);
  v_phase := public.international_fixture_phase_label(v_fix.phase);
  v_href := 'international_matchday.html?fixture=' || p_fixture_id::text;
  v_score := format('%s %s–%s %s', v_home_name, p_home_goals, p_away_goals, v_away_name);

  IF v_opp_club IS NOT NULL THEN
    PERFORM public.owner_inbox_send(
      'intl_result_to_confirm',
      format('Confirm %s result', v_phase),
      format(
        E'%s submitted:\n%s\nConfirm or reject on International Matchday.',
        public.international_nation_display_name(v_nation),
        v_score
      ),
      v_opp_club,
      NULL,
      NULL, NULL, NULL, NULL,
      v_href,
      'intl_result:' || v_sub_id::text,
      v_fix.gpsl_month,
      v_fix.season_id
    );
  END IF;

  IF v_my_club IS NOT NULL THEN
    PERFORM public.owner_inbox_send(
      'intl_result_submitted',
      format('%s result submitted', v_phase),
      format(E'You submitted:\n%s\nWaiting for the opponent to confirm.', v_score),
      v_my_club,
      NULL,
      NULL, NULL, NULL, NULL,
      v_href,
      'intl_result_sent:' || v_sub_id::text,
      v_fix.gpsl_month,
      v_fix.season_id
    );
  END IF;

  RETURN v_sub_id;
END;
$function$;

-- ---------------------------------------------------------------------------
-- Confirm result — notify both owners
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.international_confirm_result(
  p_submission_id bigint,
  p_confirmer_player_stats jsonb DEFAULT '[]'::jsonb
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_nation text := public.international_my_nation_code();
  v_sub public.international_result_submissions;
  v_fix public.international_fixtures;
  v_merged jsonb;
  v_phase text;
  v_score text;
  v_href text;
  v_home_club text;
  v_away_club text;
  v_body text;
BEGIN
  IF v_nation IS NULL THEN
    RAISE EXCEPTION 'No national team linked to your club';
  END IF;

  SELECT * INTO v_sub
  FROM public.international_result_submissions
  WHERE id = p_submission_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Submission not found';
  END IF;

  IF v_sub.status <> 'pending' THEN
    RAISE EXCEPTION 'Submission is not pending';
  END IF;

  SELECT * INTO v_fix FROM public.international_fixtures WHERE id = v_sub.fixture_id;

  IF v_nation NOT IN (v_fix.home_nation, v_fix.away_nation) THEN
    RAISE EXCEPTION 'Your nation is not in this fixture';
  END IF;

  IF v_nation = v_sub.submitted_by_nation AND NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Opponent must confirm the result';
  END IF;

  v_merged := coalesce(v_sub.player_stats, '[]'::jsonb);
  IF p_confirmer_player_stats IS NOT NULL
     AND jsonb_typeof(p_confirmer_player_stats) = 'array'
     AND jsonb_array_length(p_confirmer_player_stats) > 0 THEN
    v_merged := v_merged || p_confirmer_player_stats;
  END IF;

  PERFORM public.international_apply_fixture_result(
    v_sub.fixture_id,
    v_sub.home_goals,
    v_sub.away_goals,
    v_merged,
    v_sub.home_goals_et,
    v_sub.away_goals_et,
    v_sub.home_pens,
    v_sub.away_pens
  );

  UPDATE public.international_result_submissions
  SET status = 'confirmed', resolved_at = now()
  WHERE id = p_submission_id;

  v_phase := public.international_fixture_phase_label(v_fix.phase);
  v_score := format(
    '%s %s–%s %s',
    public.international_nation_display_name(v_fix.home_nation),
    v_sub.home_goals,
    v_sub.away_goals,
    public.international_nation_display_name(v_fix.away_nation)
  );
  v_href := 'international_matchday.html?fixture=' || v_sub.fixture_id::text;
  v_body := format(E'%s result confirmed:\n%s', v_phase, v_score);

  v_home_club := public.international_club_for_nation(v_fix.home_nation);
  v_away_club := public.international_club_for_nation(v_fix.away_nation);

  IF v_home_club IS NOT NULL THEN
    PERFORM public.owner_inbox_send(
      'intl_result_confirmed',
      format('%s result confirmed', v_phase),
      v_body,
      v_home_club, NULL, NULL, NULL, NULL, NULL,
      v_href,
      'intl_result_ok_h:' || p_submission_id::text,
      v_fix.gpsl_month, v_fix.season_id
    );
  END IF;
  IF v_away_club IS NOT NULL THEN
    PERFORM public.owner_inbox_send(
      'intl_result_confirmed',
      format('%s result confirmed', v_phase),
      v_body,
      v_away_club, NULL, NULL, NULL, NULL, NULL,
      v_href,
      'intl_result_ok_a:' || p_submission_id::text,
      v_fix.gpsl_month, v_fix.season_id
    );
  END IF;
END;
$function$;

-- ---------------------------------------------------------------------------
-- Reject result — notify submitter
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.international_reject_result(p_submission_id bigint)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_nation text := public.international_my_nation_code();
  v_sub public.international_result_submissions;
  v_fix public.international_fixtures;
  v_submitter_club text;
  v_phase text;
  v_score text;
BEGIN
  SELECT * INTO v_sub FROM public.international_result_submissions WHERE id = p_submission_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Submission not found'; END IF;
  IF v_sub.status <> 'pending' THEN RAISE EXCEPTION 'Submission is not pending'; END IF;

  SELECT * INTO v_fix FROM public.international_fixtures WHERE id = v_sub.fixture_id;
  IF v_nation NOT IN (v_fix.home_nation, v_fix.away_nation)
     AND NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Not allowed';
  END IF;

  UPDATE public.international_result_submissions
  SET status = 'rejected', resolved_at = now()
  WHERE id = p_submission_id;

  v_submitter_club := public.international_club_for_nation(v_sub.submitted_by_nation);
  IF v_submitter_club IS NOT NULL THEN
    v_phase := public.international_fixture_phase_label(v_fix.phase);
    v_score := format(
      '%s %s–%s %s',
      public.international_nation_display_name(v_fix.home_nation),
      v_sub.home_goals,
      v_sub.away_goals,
      public.international_nation_display_name(v_fix.away_nation)
    );
    PERFORM public.owner_inbox_send(
      'intl_result_rejected',
      format('%s result rejected', v_phase),
      format(
        E'Your submitted score was rejected:\n%s\nRe-submit on International Matchday.',
        v_score
      ),
      v_submitter_club, NULL, NULL, NULL, NULL, NULL,
      'international_matchday.html?fixture=' || v_sub.fixture_id::text,
      'intl_result_rej:' || p_submission_id::text,
      v_fix.gpsl_month, v_fix.season_id
    );
  END IF;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.international_fixture_phase_label(text) TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.international_nation_display_name(text) TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.international_fixture_matchup_label(bigint) TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.international_propose_kickoff(bigint, timestamptz) TO authenticated;
GRANT EXECUTE ON FUNCTION public.international_accept_kickoff(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.international_submit_result(bigint, smallint, smallint, jsonb, smallint, smallint, smallint, smallint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.international_confirm_result(bigint, jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.international_reject_result(bigint) TO authenticated;

NOTIFY pgrst, 'reload schema';

-- ---------------------------------------------------------------------------
-- Discord weekly reminders (league + cup + World Cup / international)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.gpsl_discord_notifications_tick()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_state public.gpsl_discord_notifications_state%rowtype;
  v_month text;
  v_prev_month text;
  v_month_label text;
  v_season_id bigint;
  v_key text;
  v_count int;
  v_cup int;
  v_intl int;
  v_names text;
  v_done text[] := ARRAY[]::text[];
  v_gs public.global_settings%rowtype;
  r record;
BEGIN
  SELECT * INTO v_state FROM public.gpsl_discord_notifications_state WHERE id = 1;
  IF NOT FOUND THEN
    INSERT INTO public.gpsl_discord_notifications_state (id) VALUES (1);
    SELECT * INTO v_state FROM public.gpsl_discord_notifications_state WHERE id = 1;
  END IF;

  v_prev_month := v_state.last_gpsl_month;

  SELECT id INTO v_season_id
  FROM public.competition_seasons
  WHERE is_current = true
  ORDER BY id DESC
  LIMIT 1;

  -- Current GPSL month
  BEGIN
    IF to_regprocedure('public.competition_active_gpsl_month()') IS NOT NULL THEN
      v_month := public.competition_active_gpsl_month();
    END IF;
  EXCEPTION WHEN OTHERS THEN
    v_month := NULL;
  END;

  -- Challenge close when month ticks past gpsl_month_to (use previous month before updating state)
  IF v_season_id IS NOT NULL
     AND v_month IS NOT NULL
     AND v_prev_month IS NOT NULL
     AND lower(v_month) IS DISTINCT FROM lower(v_prev_month)
     AND to_regclass('public.competition_challenge_config') IS NOT NULL THEN
    FOR r IN
      SELECT c.id, c.title, c.window_phase, c.gpsl_month_to
      FROM public.competition_challenge_config c
      WHERE c.season_id = v_season_id
        AND lower(c.gpsl_month_to) = lower(v_prev_month)
    LOOP
      PERFORM public.gpsl_discord_feed_enqueue_notification(
        'notification',
        format('🎯 CHALLENGES CLOSING  E%s', initcap(coalesce(r.window_phase, 'window'))),
        format('%s has closed with the end of %s.', coalesce(r.title, 'Season challenges'), initcap(r.gpsl_month_to)),
        10038562,
        'chal_close:' || r.id::text || ':' || r.gpsl_month_to,
        jsonb_build_object('kind', 'challenge_close', 'challenge_id', r.id)
      );
      v_done := v_done || ARRAY['challenge_close'];
    END LOOP;
  END IF;

  IF v_month IS NOT NULL AND v_month IS DISTINCT FROM v_prev_month THEN
    BEGIN
      v_month_label := public.competition_gpsl_month_label(v_month);
    EXCEPTION WHEN OTHERS THEN
      v_month_label := initcap(v_month);
    END;

    PERFORM public.gpsl_discord_feed_enqueue_notification(
      'notification',
      format('📅 GPSL MONTH  E%s', v_month_label),
      format('We are now in %s. Fixtures, challenges, and calendars have moved on.', v_month_label),
      5793266,
      'gpsl_month:' || coalesce(v_season_id::text, 'x') || ':' || v_month,
      jsonb_build_object('kind', 'gpsl_month', 'gpsl_month', v_month)
    );
    UPDATE public.gpsl_discord_notifications_state
    SET last_gpsl_month = v_month, updated_at = now()
    WHERE id = 1;
    v_done := v_done || ARRAY['gpsl_month'];
  END IF;

  -- Draft auction "open now" (time-based)
  SELECT * INTO v_gs FROM public.global_settings LIMIT 1;
  IF FOUND
     AND v_gs.draft_auction_start_time IS NOT NULL
     AND now() >= v_gs.draft_auction_start_time
     AND (
       coalesce(v_gs.draft_auction_enabled, false)
       OR coalesce(v_gs.manager_draft_auction_enabled, false)
     ) THEN
    v_key := 'draft_open:' || to_char(v_gs.draft_auction_start_time AT TIME ZONE 'UTC', 'YYYYMMDDHH24MI');
    IF v_state.last_draft_open_key IS DISTINCT FROM v_key THEN
      PERFORM public.gpsl_discord_feed_enqueue_notification(
        'draft',
        '🧾 DRAFT AUCTION LIVE',
        concat_ws(
          E'\n',
          CASE WHEN coalesce(v_gs.draft_auction_enabled, false) THEN 'Player draft bidding is open.' END,
          CASE WHEN coalesce(v_gs.manager_draft_auction_enabled, false) THEN 'Manager draft bidding is open.' END
        ),
        8070335,
        v_key,
        jsonb_build_object('kind', 'draft_open')
      );
      UPDATE public.gpsl_discord_notifications_state
      SET last_draft_open_key = v_key, updated_at = now()
      WHERE id = 1;
      v_done := v_done || ARRAY['draft_open'];
    END IF;
  END IF;

  -- Challenges starting (dedupe_key prevents repeats)
  IF v_season_id IS NOT NULL AND v_month IS NOT NULL
     AND to_regclass('public.competition_challenge_config') IS NOT NULL THEN
    FOR r IN
      SELECT c.id, c.title, c.window_phase, c.gpsl_month_from
      FROM public.competition_challenge_config c
      WHERE c.season_id = v_season_id
        AND lower(c.gpsl_month_from) = lower(v_month)
    LOOP
      PERFORM public.gpsl_discord_feed_enqueue_notification(
        'notification',
        format('🎯 CHALLENGES STARTING  E%s', initcap(coalesce(r.window_phase, 'window'))),
        format('%s is now open for %s.', coalesce(r.title, 'Season challenges'), initcap(v_month)),
        15844367,
        'chal_start:' || r.id::text || ':' || v_month,
        jsonb_build_object('kind', 'challenge_start', 'challenge_id', r.id)
      );
      v_done := v_done || ARRAY['challenge_start'];
    END LOOP;
  END IF;

  -- International match week (fixtures exist for current month)
  IF v_season_id IS NOT NULL AND v_month IS NOT NULL
     AND to_regclass('public.international_fixtures') IS NOT NULL THEN
    BEGIN
      SELECT count(*)::int INTO v_count
      FROM public.international_fixtures f
      WHERE lower(f.gpsl_month) = lower(v_month)
        AND coalesce(f.played, false) = false
        AND coalesce(f.status, '') IS DISTINCT FROM 'played';
    EXCEPTION WHEN OTHERS THEN
      v_count := 0;
    END;

    IF coalesce(v_count, 0) > 0 THEN
      v_key := 'intl:' || v_season_id::text || ':' || v_month;
      IF v_state.last_intl_week_key IS DISTINCT FROM v_key THEN
        PERFORM public.gpsl_discord_feed_enqueue_notification(
          'notification',
          format('🌐 INTERNATIONAL / WORLD CUP  E%s', initcap(v_month)),
          format(
            E'%s international fixture(s) this GPSL month (qualifiers / finals).\nArrange kick-offs and submit results on International Matchday.',
            v_count
          ),
          5793266,
          v_key,
          jsonb_build_object('kind', 'international_week', 'count', v_count)
        );
        UPDATE public.gpsl_discord_notifications_state
        SET last_intl_week_key = v_key, updated_at = now()
        WHERE id = 1;
        v_done := v_done || ARRAY['international_week'];
      END IF;
    END IF;
  END IF;

  -- Match reminders: league + cup + international still outstanding this month
  IF v_season_id IS NOT NULL AND v_month IS NOT NULL THEN
    v_key := 'matches:' || v_season_id::text || ':' || v_month || ':' ||
             to_char(now() AT TIME ZONE 'Europe/London', 'IYYY-IW');

    IF v_state.last_match_reminder_key IS DISTINCT FROM v_key THEN
      SELECT count(*)::int INTO v_count
      FROM public.competition_fixtures f
      WHERE f.season_id = v_season_id
        AND lower(f.gpsl_month) = lower(v_month)
        AND f.status = 'scheduled'
        AND f.competition_type = 'league';

      SELECT count(*)::int INTO v_cup
      FROM public.competition_fixtures f
      WHERE f.season_id = v_season_id
        AND lower(f.gpsl_month) = lower(v_month)
        AND f.status = 'scheduled'
        AND f.competition_type = 'cup';

      v_intl := 0;
      IF to_regclass('public.international_fixtures') IS NOT NULL THEN
        BEGIN
          SELECT count(*)::int INTO v_intl
          FROM public.international_fixtures f
          WHERE lower(f.gpsl_month) = lower(v_month)
            AND coalesce(f.played, false) = false
            AND coalesce(f.status, '') IS DISTINCT FROM 'played';
        EXCEPTION WHEN OTHERS THEN
          v_intl := 0;
        END;
      END IF;

      IF coalesce(v_count, 0) > 0 OR coalesce(v_cup, 0) > 0 OR coalesce(v_intl, 0) > 0 THEN
        PERFORM public.gpsl_discord_feed_enqueue_notification(
          'notification',
          format('⚽ MATCHES DUE  E%s', initcap(v_month)),
          format(
            E'Weekly reminder for outstanding fixtures this GPSL month:\nLeague: %s scheduled\nCup: %s scheduled\nWorld Cup / international: %s outstanding\nPlease arrange kick-offs and submit results.',
            coalesce(v_count, 0),
            coalesce(v_cup, 0),
            coalesce(v_intl, 0)
          ),
          15158332,
          v_key,
          jsonb_build_object(
            'kind', 'match_reminder',
            'league_scheduled', coalesce(v_count, 0),
            'cup_scheduled', coalesce(v_cup, 0),
            'intl_outstanding', coalesce(v_intl, 0)
          )
        );
        UPDATE public.gpsl_discord_notifications_state
        SET last_match_reminder_key = v_key, updated_at = now()
        WHERE id = 1;
        v_done := v_done || ARRAY['match_reminder'];
      END IF;
    END IF;
  END IF;

  -- Vacant clubs (daily digest while any remain)
  v_key := 'vacant:' || to_char(now() AT TIME ZONE 'Europe/London', 'YYYY-MM-DD');
  IF v_state.last_vacant_key IS DISTINCT FROM v_key THEN
    SELECT count(*)::int,
           string_agg(c."Club", ', ' ORDER BY c."Club")
    INTO v_count, v_names
    FROM public."Clubs" c
    WHERE c.owner_id IS NULL;

    IF coalesce(v_count, 0) > 0 THEN
      PERFORM public.gpsl_discord_feed_enqueue_notification(
        'notification',
        format('🏚�E�EVACANT CLUBS  E%s', v_count),
        left(coalesce(v_names, 'Vacant clubs listed in club auction.'), 900),
        10038562,
        v_key,
        jsonb_build_object('kind', 'vacant_clubs', 'count', v_count)
      );
      UPDATE public.gpsl_discord_notifications_state
      SET last_vacant_key = v_key, updated_at = now()
      WHERE id = 1;
      v_done := v_done || ARRAY['vacant_clubs'];
    END IF;
  END IF;

  -- Out of contract  Esingle batch message (defensive column probing)
  v_key := 'ooc:' || coalesce(v_season_id::text, 'x') || ':' || coalesce(v_month, 'x');
  IF v_state.last_ooc_key IS DISTINCT FROM v_key THEN
    v_count := NULL;
    BEGIN
      SELECT count(*)::int INTO v_count
      FROM public."Players" p
      WHERE p.contract_seasons_remaining = 0
        AND nullif(btrim(p."Club"::text), '') IS NOT NULL
        AND p."Club"::text IS DISTINCT FROM 'FOREIGN';
    EXCEPTION WHEN undefined_column THEN
      BEGIN
        SELECT count(*)::int INTO v_count
        FROM public."Players" p
        WHERE nullif(btrim(p."Contract"::text), '') IN ('0', '0.0')
          AND nullif(btrim(p."Club"::text), '') IS NOT NULL;
      EXCEPTION WHEN OTHERS THEN
        v_count := NULL;
      END;
    WHEN OTHERS THEN
      v_count := NULL;
    END;

    IF coalesce(v_count, 0) > 0 THEN
      PERFORM public.gpsl_discord_feed_enqueue_notification(
        'notification',
        format('📋 OUT OF CONTRACT  E%s players', v_count),
        format(
          '%s player(s) are out of contract (batch notice). Check contracts / free agents  Enot listed individually here.',
          v_count
        ),
        12370112,
        v_key,
        jsonb_build_object('kind', 'out_of_contract_batch', 'count', v_count)
      );
      UPDATE public.gpsl_discord_notifications_state
      SET last_ooc_key = v_key, updated_at = now()
      WHERE id = 1;
      v_done := v_done || ARRAY['out_of_contract'];
    END IF;
  END IF;

  BEGIN
    PERFORM public.gpsl_discord_feed_request_flush();
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;

  RETURN jsonb_build_object(
    'ok', true,
    'announced', to_jsonb(v_done),
    'gpsl_month', v_month,
    'season_id', v_season_id
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.gpsl_discord_notifications_tick() TO authenticated, service_role;

GRANT EXECUTE ON FUNCTION public.gpsl_discord_notifications_tick() TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';

