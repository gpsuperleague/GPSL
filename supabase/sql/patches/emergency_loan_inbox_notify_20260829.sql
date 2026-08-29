-- =============================================================================
-- Emergency loan eligibility → owner inbox notification
--
-- When fit squad drops below 24 (Aug–May) and a loan slot is available, notify
-- the club once per GPSL month (dedupe). Hooks: new injuries, new/reactivated
-- suspensions, and club_emergency_loan_status (catch-all on Squad/GPDB load).
--
-- Run after emergency_loan_injury_suspension_20260828.sql (+ transfer history
-- patch if used). Safe re-run.
-- =============================================================================

-- Allow message type (keep every type already in use)
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
      'emergency_loan_available'
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

  BEGIN
    ALTER TABLE public.competition_inbox
      VALIDATE CONSTRAINT competition_inbox_message_type_check;
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'competition_inbox_message_type_check left NOT VALID: %', SQLERRM;
  END;
END;
$inbox_types$;

CREATE OR REPLACE FUNCTION public.owner_inbox_notify_emergency_loan_available(
  p_club_short_name text
)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := nullif(btrim(p_club_short_name), '');
  v_season_id bigint;
  v_month text;
  v_registered int;
  v_available int;
  v_min int;
  v_max int;
  v_need int;
  v_overflow_used int;
  v_slots int := 0;
  v_ends text;
  v_fee numeric;
  v_fee_label text;
  v_window_open boolean;
  v_title text;
  v_body text;
  v_dedupe text;
BEGIN
  IF v_club IS NULL OR v_club = 'FOREIGN' THEN
    RETURN NULL;
  END IF;

  IF to_regprocedure('public.club_available_player_count(text)') IS NULL
     OR to_regprocedure('public.emergency_loan_window_open(text)') IS NULL THEN
    RETURN NULL;
  END IF;

  IF to_regprocedure(
    'public.owner_inbox_send(text,text,text,text,uuid,bigint,bigint,bigint,bigint,text,text,text,bigint,bigint)'
  ) IS NULL
     AND to_regprocedure(
    'public.owner_inbox_send(text,text,text,text,uuid,bigint,bigint,bigint,bigint,text,text,text,bigint)'
  ) IS NULL THEN
    RETURN NULL;
  END IF;

  SELECT id INTO v_season_id
  FROM public.competition_seasons
  WHERE is_current = true
  ORDER BY id DESC
  LIMIT 1;

  IF v_season_id IS NULL THEN
    RETURN NULL;
  END IF;

  v_month := public.competition_active_gpsl_month(v_season_id, now());
  IF v_month IS NULL THEN
    RETURN NULL;
  END IF;

  v_window_open := public.emergency_loan_window_open(v_month);
  IF NOT v_window_open THEN
    RETURN NULL;
  END IF;

  v_ends := public.emergency_loan_window_end_month(v_month);
  v_min := public.squad_minimum_size();
  v_max := public.squad_max_size();
  v_fee := public.emergency_loan_fee_amount();
  v_registered := public.club_registered_squad_count(v_club);
  v_available := public.club_available_player_count(v_club);
  v_need := greatest(v_min - v_available, 0);

  IF v_need <= 0 THEN
    RETURN NULL;
  END IF;

  SELECT count(*) FILTER (WHERE overflow_slot)::int
  INTO v_overflow_used
  FROM public.club_emergency_loans l
  WHERE l.season_id = v_season_id
    AND l.club_short_name = v_club
    AND l.status = 'active';

  IF v_registered < v_max THEN
    v_slots := least(v_need, v_max - v_registered);
  ELSIF v_registered = v_max AND coalesce(v_overflow_used, 0) = 0 THEN
    v_slots := least(v_need, 1);
  ELSE
    v_slots := 0;
  END IF;

  IF v_slots <= 0 THEN
    RETURN NULL;
  END IF;

  -- One alert per club per GPSL month
  v_dedupe := format(
    'emergency_loan_available:%s:%s:%s',
    v_season_id::text,
    v_club,
    lower(v_month)
  );

  IF EXISTS (
    SELECT 1 FROM public.competition_inbox i WHERE i.dedupe_key = v_dedupe
  ) THEN
    RETURN NULL;
  END IF;

  IF to_regprocedure('public.transfer_format_money(numeric)') IS NOT NULL THEN
    v_fee_label := public.transfer_format_money(v_fee);
  ELSE
    v_fee_label := '₿' || to_char(v_fee, 'FM999,999,999,999');
  END IF;

  v_title := 'Emergency loan available';
  v_body := concat_ws(
    E'\n',
    format(
      'Fit players (%s) are below the squad minimum of 24 — injuries and suspensions count as unavailable.',
      v_available
    ),
    format(
      'You can take up to %s emergency loan%s this half-season (shortfall %s). Fee %s to Central Bank; free agents rated ≤66; returns end of %s.',
      v_slots,
      CASE WHEN v_slots = 1 THEN '' ELSE 's' END,
      v_need,
      v_fee_label,
      initcap(coalesce(v_ends, 'the window'))
    ),
    'Open Squad or GPDB to choose a player.'
  );

  RETURN public.owner_inbox_send(
    'emergency_loan_available',
    v_title,
    v_body,
    v_club,
    NULL,
    NULL,
    NULL,
    NULL,
    NULL,
    'squad.html',
    v_dedupe,
    v_month,
    v_season_id
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.trg_emergency_loan_eligibility_inbox()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text;
BEGIN
  IF lower(coalesce(NEW.status, '')) IS DISTINCT FROM 'active' THEN
    RETURN NEW;
  END IF;

  IF TG_OP = 'UPDATE'
     AND lower(coalesce(OLD.status, '')) = 'active' THEN
    RETURN NEW;
  END IF;

  v_club := nullif(btrim(NEW.club_short_name), '');
  IF v_club IS NULL THEN
    RETURN NEW;
  END IF;

  BEGIN
    PERFORM public.owner_inbox_notify_emergency_loan_available(v_club);
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;

  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS emergency_loan_eligibility_inbox_injury
  ON public.competition_player_injuries;
CREATE TRIGGER emergency_loan_eligibility_inbox_injury
  AFTER INSERT OR UPDATE OF status
  ON public.competition_player_injuries
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_emergency_loan_eligibility_inbox();

DROP TRIGGER IF EXISTS emergency_loan_eligibility_inbox_suspension
  ON public.competition_player_suspensions;
CREATE TRIGGER emergency_loan_eligibility_inbox_suspension
  AFTER INSERT OR UPDATE OF status
  ON public.competition_player_suspensions
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_emergency_loan_eligibility_inbox();

-- Catch-all when Squad/GPDB loads status (window open, already short, etc.)
CREATE OR REPLACE FUNCTION public.club_emergency_loan_status(
  p_club_short_name text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := nullif(btrim(coalesce(p_club_short_name, public.my_club_shortname())), '');
  v_season_id bigint;
  v_month text;
  v_registered int;
  v_available int;
  v_min int := public.squad_minimum_size();
  v_max int := public.squad_max_size();
  v_need int;
  v_active_loans int;
  v_overflow_used int;
  v_slots int := 0;
  v_ends text;
  v_fee numeric := public.emergency_loan_fee_amount();
  v_balance numeric;
  v_window_open boolean;
  v_result jsonb;
BEGIN
  PERFORM public.club_emergency_loans_expire_due(NULL);

  IF v_club IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_club', 'eligible', false);
  END IF;

  SELECT id INTO v_season_id
  FROM public.competition_seasons
  WHERE is_current = true
  ORDER BY id DESC
  LIMIT 1;

  v_month := public.competition_active_gpsl_month(v_season_id, now());
  v_window_open := public.emergency_loan_window_open(v_month);
  v_ends := public.emergency_loan_window_end_month(v_month);

  v_registered := public.club_registered_squad_count(v_club);
  v_available := public.club_available_player_count(v_club);
  v_need := greatest(v_min - v_available, 0);

  SELECT count(*)::int, count(*) FILTER (WHERE overflow_slot)::int
  INTO v_active_loans, v_overflow_used
  FROM public.club_emergency_loans l
  WHERE l.season_id = v_season_id
    AND l.club_short_name = v_club
    AND l.status = 'active';

  IF v_window_open AND v_need > 0 THEN
    IF v_registered < v_max THEN
      v_slots := least(v_need, v_max - v_registered);
    ELSIF v_registered = v_max AND v_overflow_used = 0 THEN
      v_slots := least(v_need, 1);
    ELSIF v_registered = v_max + 1 AND v_overflow_used > 0 THEN
      v_slots := 0;
    ELSE
      v_slots := 0;
    END IF;
  END IF;

  SELECT balance INTO v_balance
  FROM public."Club_Finances"
  WHERE club_name = v_club;

  v_result := jsonb_build_object(
    'ok', true,
    'club_short_name', v_club,
    'season_id', v_season_id,
    'active_gpsl_month', v_month,
    'window_open', v_window_open,
    'ends_gpsl_month', v_ends,
    'min_squad', v_min,
    'max_squad', v_max,
    'registered', v_registered,
    'available', v_available,
    'need', v_need,
    'slots_available', v_slots,
    'eligible', v_window_open AND v_slots > 0,
    'active_emergency_loans', v_active_loans,
    'overflow_slot_used', v_overflow_used > 0,
    'loan_fee', v_fee,
    'max_rating', public.emergency_loan_max_rating(),
    'balance', coalesce(v_balance, 0),
    'can_afford', coalesce(v_balance, 0) >= v_fee
  );

  IF coalesce((v_result->>'eligible')::boolean, false) THEN
    BEGIN
      PERFORM public.owner_inbox_notify_emergency_loan_available(v_club);
    EXCEPTION WHEN OTHERS THEN
      NULL;
    END;
  END IF;

  RETURN v_result;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.owner_inbox_notify_emergency_loan_available(text)
  TO authenticated;

GRANT EXECUTE ON FUNCTION public.club_emergency_loan_status(text) TO authenticated;

NOTIFY pgrst, 'reload schema';
