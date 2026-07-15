-- =============================================================================
-- Bank / loan inbox notifications + message types for inbox "Bank" filter
--
-- Notifies clubs on Central Bank loan drawdowns, principal repayments, and
-- interest payments (from competition_finance_ledger inserts).
--
-- Run in Supabase SQL Editor. Safe re-run.
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
      'intl_result_to_confirm',
      'intl_kickoff_proposal'
    )
  ) NOT VALID;

ALTER TABLE public.competition_inbox
  VALIDATE CONSTRAINT competition_inbox_message_type_check;

CREATE OR REPLACE FUNCTION public.owner_inbox_notify_bank_ledger(p_ledger_id bigint)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_row public.competition_finance_ledger%rowtype;
  v_type text;
  v_title text;
  v_body text;
  v_href text;
  v_amount_label text;
  v_loan_id text;
BEGIN
  IF to_regprocedure(
    'public.owner_inbox_send(text,text,text,text,uuid,bigint,bigint,bigint,bigint,text,text,text,bigint)'
  ) IS NULL THEN
    RETURN NULL;
  END IF;

  SELECT * INTO v_row
  FROM public.competition_finance_ledger
  WHERE id = p_ledger_id;

  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  IF v_row.entry_type = 'loan_drawdown' THEN
    v_type := 'loan_drawdown';
    v_title := 'Loan drawdown';
    v_href := 'central_bank_loans.html';
  ELSIF v_row.entry_type = 'loan_repayment_principal' THEN
    v_type := 'loan_repayment';
    v_title := 'Loan repayment';
    v_href := 'central_bank_counter.html';
  ELSIF v_row.entry_type = 'loan_interest_payment' THEN
    v_type := 'loan_interest';
    v_title := 'Loan interest';
    v_href := 'central_bank_counter.html';
  ELSE
    RETURN NULL;
  END IF;

  IF to_regprocedure('public.transfer_format_money(numeric)') IS NOT NULL THEN
    v_amount_label := public.transfer_format_money(abs(v_row.amount));
  ELSE
    v_amount_label := to_char(abs(v_row.amount), 'FM999,999,999,999');
  END IF;

  v_loan_id := nullif(btrim(coalesce(v_row.metadata ->> 'loan_id', '')), '');

  v_body := concat_ws(
    E'\n',
    coalesce(nullif(btrim(v_row.description), ''), v_title),
    CASE
      WHEN v_row.entry_type = 'loan_drawdown' THEN 'Credited: ' || v_amount_label
      ELSE 'Debited: ' || v_amount_label
    END,
    CASE WHEN v_loan_id IS NOT NULL THEN 'Loan #' || v_loan_id ELSE NULL END,
    'See Central Bank → League loans / Service counter.'
  );

  RETURN public.owner_inbox_send(
    v_type,
    v_title,
    v_body,
    v_row.club_short_name,
    NULL,
    NULL,
    NULL,
    NULL,
    NULL,
    v_href,
    'bank_ledger:' || v_row.id::text,
    NULL,
    v_row.season_id
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.trg_bank_loan_ledger_inbox()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF NEW.entry_type IN (
    'loan_drawdown',
    'loan_repayment_principal',
    'loan_interest_payment'
  ) THEN
    PERFORM public.owner_inbox_notify_bank_ledger(NEW.id);
  END IF;
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS bank_loan_ledger_inbox_notify ON public.competition_finance_ledger;
CREATE TRIGGER bank_loan_ledger_inbox_notify
  AFTER INSERT ON public.competition_finance_ledger
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_bank_loan_ledger_inbox();

GRANT EXECUTE ON FUNCTION public.owner_inbox_notify_bank_ledger(bigint) TO authenticated;

NOTIFY pgrst, 'reload schema';
