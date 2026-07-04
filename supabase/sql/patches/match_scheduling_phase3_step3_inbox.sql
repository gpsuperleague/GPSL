-- Phase 3 step 3/3 — inbox message types (run last; close GPSL tabs first if possible)

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
      'draft_scheduled',
      'fine_applied',
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
      'match_mutual_override_applied'
    )
  ) NOT VALID;

ALTER TABLE public.competition_inbox
  VALIDATE CONSTRAINT competition_inbox_message_type_check;

NOTIFY pgrst, 'reload schema';
