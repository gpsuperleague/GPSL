-- =============================================================================
-- International / World Cup match notifications (owner inbox parity)
--
-- Mirrors league/cup owner inbox for:
--   kickoff propose / counter / accept
--   result submit / confirm / reject
-- Covers qualifying + finals (shared international_fixtures).
--
-- Also allows intl_kickoff_counter (already sent but was missing from CHECK).
--
-- Discord weekly reminders (optional): only if you already run
--   gpsl_discord_notifications_channel.sql
-- then re-run that file (or its tick) for WC lines in MATCHES DUE.
-- This patch intentionally does NOT recreate gpsl_discord_notifications_tick
-- so it installs on DBs without the Discord notifications tables.
--
-- Safe re-run. Run in Supabase SQL Editor.
-- =============================================================================

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
    '-'
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
-- Propose kickoff -notify opponent + proposer ack (same rules as availability patch)
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
    RAISE EXCEPTION 'Your nation has no owner club -cannot propose kick-off';
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
    RAISE EXCEPTION 'You are not available at that time -set weekly availability on Owner Details first';
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

  -- Vacant opponent - auto-agree
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
        format(E'%s\nKick-off: %s\nOpponent nation is vacant -time auto-agreed.', v_matchup, v_ko_label),
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
-- Accept kickoff -notify both owners
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
    RAISE EXCEPTION 'Proposed kick-off is in the past -ask for a new time';
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
-- Submit result -notify opponent + submitter ack
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
  v_score := format('%s %s-%s %s', v_home_name, p_home_goals, p_away_goals, v_away_name);

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
-- Confirm result -notify both owners
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
    '%s %s-%s %s',
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
-- Reject result -notify submitter
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
      '%s %s-%s %s',
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
