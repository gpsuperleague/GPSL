-- =============================================================================
-- Allow handpick inbox types + send retrospective friendly welcomes
-- to current owners of clubs with an approved handpick wishlist.
-- Safe re-run.
-- =============================================================================

ALTER TABLE public.competition_inbox
  DROP CONSTRAINT IF EXISTS competition_inbox_message_type_check;

ALTER TABLE public.competition_inbox
  ADD CONSTRAINT competition_inbox_message_type_check CHECK (
    message_type = ANY (ARRAY[
      'admin_cash_injection'::text,
      'admin_emergency_tax'::text,
      'bookies_open'::text,
      'challenge_period_bonus'::text,
      'club_checklist_issues'::text,
      'commercial_offer'::text,
      'draft_autobid_live'::text,
      'draft_autobid_summary'::text,
      'draft_scheduled'::text,
      'emergency_loan_available'::text,
      'fine_applied'::text,
      'handpick_approved'::text,
      'handpick_welcome'::text,
      'intl_kickoff_accepted'::text,
      'intl_kickoff_proposal'::text,
      'intl_kickoff_proposal_sent'::text,
      'intl_kickoff_withdrawn'::text,
      'intl_result_to_confirm'::text,
      'loan_drawdown'::text,
      'loan_interest'::text,
      'loan_repayment'::text,
      'match_arrangement_deadline_warning'::text,
      'match_attempt3_awarded'::text,
      'match_attempt3_window'::text,
      'match_checkin_open'::text,
      'match_emergency_drop'::text,
      'match_forfeit_applied'::text,
      'match_mutual_override_applied'::text,
      'match_mutual_override_cancelled'::text,
      'match_mutual_override_requested'::text,
      'match_noshow_both_miss'::text,
      'match_noshow_fine'::text,
      'match_noshow_fixture_forfeit'::text,
      'match_noshow_open_play'::text,
      'match_noshow_open_play_resolved'::text,
      'match_noshow_recorded'::text,
      'match_noshow_repeat_fine'::text,
      'match_noshow_strike_triple'::text,
      'match_noshow_warning'::text,
      'match_rescheduled'::text,
      'match_response_deadline_warning'::text,
      'match_time_accepted'::text,
      'match_time_counter_sent'::text,
      'match_time_countered'::text,
      'match_time_proposal_sent'::text,
      'match_time_proposed'::text,
      'match_window_draw'::text,
      'matchday_checklist'::text,
      'matchday_squad_warning'::text,
      'monthly_fixtures'::text,
      'nation_pick_turn'::text,
      'nation_selection_open'::text,
      'owner_feedback_invite'::text,
      'owner_feedback_reminder'::text,
      'owner_holiday'::text,
      'owner_of_month'::text,
      'owner_of_season'::text,
      'owner_ready_locked'::text,
      'owner_ready_unlocked'::text,
      'player_awards'::text,
      'points_deduction'::text,
      'prize_appeal_resolved'::text,
      'prize_appeal_submitted'::text,
      'result_confirmed'::text,
      'result_rejected'::text,
      'result_submitted'::text,
      'result_to_confirm'::text,
      'season_expectations'::text,
      'season_overview'::text,
      'season1_invite'::text,
      'special_auction_scheduled'::text,
      'star_cap_demotion'::text,
      'supporter_lottery'::text,
      'supporter_new'::text,
      'supporter_thanks'::text,
      'transfer_gossip_interest'::text,
      'transfer_signed'::text,
      'transfer_sold'::text,
      'transfer_upcoming'::text,
      'underperformance_transfer'::text,
      'welcome_gpsl'::text
    ])
  );

DO $retro$
DECLARE
  r record;
  v_mgr_name text;
  v_body text;
  v_inbox_id bigint;
  v_sent int := 0;
  v_skipped int := 0;
  v_player_n int;
BEGIN
  FOR r IN
    WITH latest AS (
      SELECT DISTINCT ON (s.club_short_name)
        s.id AS submission_id,
        s.club_short_name,
        s.player_ids,
        s.manager_id,
        s.reviewed_at
      FROM public.club_handpick_submissions s
      WHERE s.status = 'approved'
      ORDER BY s.club_short_name, s.reviewed_at DESC NULLS LAST, s.id DESC
    )
    SELECT
      l.submission_id,
      l.club_short_name,
      c."Club" AS club_name,
      c.owner_id,
      l.player_ids,
      l.manager_id
    FROM latest l
    JOIN public."Clubs" c ON c."ShortName" = l.club_short_name
    WHERE c.owner_id IS NOT NULL
    ORDER BY l.club_short_name
  LOOP
    IF EXISTS (
      SELECT 1
      FROM public.competition_inbox i
      WHERE i.dedupe_key IN (
        format('handpick_approved:%s', r.submission_id),
        format('handpick_welcome_retro:%s', r.submission_id),
        format('handpick_welcome_retro_club:%s', r.club_short_name)
      )
    ) THEN
      v_skipped := v_skipped + 1;
      CONTINUE;
    END IF;

    v_mgr_name := NULL;
    IF r.manager_id IS NOT NULL THEN
      SELECT m.name INTO v_mgr_name
      FROM public."Managers" m
      WHERE m.id = r.manager_id;
    END IF;

    v_player_n := coalesce(array_length(r.player_ids, 1), 0);

    v_body := format(
      E'Welcome to GPSL — and well done on completing your mid-season handpick for %s (%s).\n\n'
      || E'Your wishlist was approved (%s players%s).\n\n'
      || E'Next steps:\n'
      || E'• Open Squad to check registration, pick One of our Own / Fan Favourite, and tidy wages\n'
      || E'• Arrange fixtures from Fixtures / Schedule\n'
      || E'• Browse the handbook (Learning GPSL) if you are new to matchdays\n\n'
      || E'If anything looks wrong with the squad or cash, message an admin.\n'
      || E'Enjoy the rest of the season — good luck!',
      coalesce(nullif(btrim(r.club_name), ''), r.club_short_name),
      r.club_short_name,
      v_player_n::text,
      CASE
        WHEN nullif(btrim(coalesce(v_mgr_name, '')), '') IS NOT NULL
          THEN format(', manager %s', v_mgr_name)
        WHEN r.manager_id IS NOT NULL
          THEN format(', manager #%s', r.manager_id::text)
        ELSE ''
      END
    );

    BEGIN
      v_inbox_id := public.owner_inbox_send(
        'handpick_welcome',
        format('Welcome — handpick complete (%s)', r.club_short_name),
        v_body,
        r.club_short_name,
        r.owner_id,
        NULL::bigint,
        NULL::bigint,
        NULL::bigint,
        NULL::bigint,
        'squad.html',
        format('handpick_welcome_retro_club:%s', r.club_short_name),
        NULL::text,
        NULL::bigint
      );
      IF v_inbox_id IS NOT NULL THEN
        v_sent := v_sent + 1;
      ELSE
        v_skipped := v_skipped + 1;
      END IF;
    EXCEPTION WHEN OTHERS THEN
      v_skipped := v_skipped + 1;
      RAISE NOTICE 'Failed %: %', r.club_short_name, SQLERRM;
    END;
  END LOOP;

  RAISE NOTICE 'Handpick retro welcome: sent=% skipped=%', v_sent, v_skipped;
END;
$retro$;

SELECT
  i.id,
  i.recipient_club_short_name AS club,
  i.message_type,
  i.title,
  i.dedupe_key,
  i.created_at
FROM public.competition_inbox i
WHERE i.message_type IN ('handpick_welcome', 'handpick_approved')
ORDER BY i.created_at DESC
LIMIT 20;
