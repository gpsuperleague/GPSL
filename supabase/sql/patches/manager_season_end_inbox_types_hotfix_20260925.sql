-- =============================================================================
-- Hotfix: Process manager contracts (season end) — inbox message_type check
--
-- Error:
--   new row for relation "competition_inbox" violates check constraint
--   "competition_inbox_message_type_check"
--
-- Cause:
--   manager_process_season_end_with_inbox → owner_inbox_notify_manager_season_end
--   inserts message_type = 'season_overview'. Later patches rebuilt the CHECK as
--   (live distinct types) ∪ (short new-type list) and dropped season_overview
--   if it had never been posted yet.
--
-- Fix:
--   Widen competition_inbox_message_type_check to include season_overview
--   (+ other known types) without dropping anything already in use.
--
-- Safe re-run. After apply, retry Admin → Process manager contracts (season end).
-- =============================================================================

DO $inbox_types$
DECLARE
  v_list text;
BEGIN
  SELECT string_agg(quote_literal(t), ', ' ORDER BY t)
  INTO v_list
  FROM (
    SELECT DISTINCT message_type AS t
    FROM public.competition_inbox
    WHERE message_type IS NOT NULL
    UNION
    SELECT unnest(ARRAY[
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
      'challenge_period_bonus',
      'prize_appeal_submitted',
      'prize_appeal_resolved',
      'intl_result_to_confirm',
      'intl_kickoff_proposal',
      'admin_cash_injection',
      'admin_emergency_tax',
      'emergency_loan_available',
      'transfer_gossip_interest',
      'season1_invite'
    ])
  ) s;

  IF v_list IS NULL OR btrim(v_list) = '' THEN
    RAISE EXCEPTION 'No inbox message types to install';
  END IF;

  ALTER TABLE public.competition_inbox
    DROP CONSTRAINT IF EXISTS competition_inbox_message_type_check;

  EXECUTE format(
    'ALTER TABLE public.competition_inbox
       ADD CONSTRAINT competition_inbox_message_type_check
       CHECK (message_type IN (%s)) NOT VALID',
    v_list
  );

  ALTER TABLE public.competition_inbox
    VALIDATE CONSTRAINT competition_inbox_message_type_check;
END;
$inbox_types$;
