-- FFP buy embargo: allow emergency loans when the club is already eligible
-- (fit players below min 24 from August). Transfers / draft / FA buys stay blocked.
-- Safe re-run.

-- ---------------------------------------------------------------------------
-- 1) Assert: honour transaction-local emergency-loan bypass
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.assert_club_may_sign_player(
  p_club_short_name text,
  p_player_id text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF public.player_club_rejoin_is_blocked(p_player_id, p_club_short_name) THEN
    RAISE EXCEPTION
      'Player cannot rejoin % this season (FFP release lock)',
      btrim(p_club_short_name);
  END IF;

  IF public.club_transfer_buy_embargo_active(p_club_short_name)
     AND coalesce(nullif(current_setting('gpsl.ffp_embargo_emergency_loan', true), ''), '')
         IS DISTINCT FROM 'on' THEN
    RAISE EXCEPTION
      '% is under a transfer buy embargo (FFP) and cannot sign players this window',
      btrim(p_club_short_name);
  END IF;
END;
$function$;

-- ---------------------------------------------------------------------------
-- 2) Status: surface FFP embargo + that emergency loan remains available when eligible
-- ---------------------------------------------------------------------------
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
  v_permanent int;
  v_available int;
  v_min int := public.squad_minimum_size();
  v_max int := public.squad_max_size();
  v_need int;
  v_active_loans int;
  v_slots int := 0;
  v_ends text;
  v_fee numeric := public.emergency_loan_fee_amount();
  v_balance numeric;
  v_window_open boolean;
  v_ffp_embargo boolean := false;
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
  v_permanent := public.club_permanent_squad_count(v_club);
  v_available := public.club_available_player_count(v_club);
  v_need := greatest(v_min - v_available, 0);

  SELECT count(*)::int
  INTO v_active_loans
  FROM public.club_emergency_loans l
  WHERE l.season_id = v_season_id
    AND l.club_short_name = v_club
    AND l.status = 'active';

  IF v_window_open AND v_need > 0 AND v_permanent <= v_max THEN
    v_slots := v_need;
  END IF;

  SELECT balance INTO v_balance
  FROM public."Club_Finances"
  WHERE club_name = v_club;

  BEGIN
    v_ffp_embargo := public.club_transfer_buy_embargo_active(v_club);
  EXCEPTION WHEN OTHERS THEN
    v_ffp_embargo := false;
  END;

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
    'permanent_registered', v_permanent,
    'available', v_available,
    'need', v_need,
    'slots_available', v_slots,
    'eligible', v_window_open AND v_slots > 0,
    'active_emergency_loans', v_active_loans,
    'overflow_slot_used', false,
    'loan_fee', v_fee,
    'max_rating', public.emergency_loan_max_rating(),
    'balance', coalesce(v_balance, 0),
    'can_afford', coalesce(v_balance, 0) >= v_fee,
    'ffp_buy_embargo_active', v_ffp_embargo,
    'ffp_embargo_note', CASE
      WHEN v_ffp_embargo AND v_window_open AND v_slots > 0 THEN
        'FFP buy ban is active, but emergency loans are still allowed while you are under the squad minimum.'
      WHEN v_ffp_embargo THEN
        'FFP buy ban is active — transfers and free-agent buys are blocked; emergency loans open only if fit players fall below the squad minimum.'
      ELSE NULL
    END
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

-- ---------------------------------------------------------------------------
-- 3) Take: set bypass GUC around Players assign
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.club_emergency_loan_take(p_player_id text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := public.my_club_shortname();
  v_pid text := btrim(p_player_id);
  v_status jsonb;
  v_player public."Players"%rowtype;
  v_season_id bigint;
  v_month text;
  v_ends text;
  v_fee numeric := public.emergency_loan_fee_amount();
  v_max_rating numeric := public.emergency_loan_max_rating();
  v_rating numeric;
  v_wage numeric;
  v_ledger_id bigint;
  v_loan_id bigint;
  v_history_id bigint;
  v_permanent int;
  v_season_label text;
BEGIN
  IF v_club IS NULL OR btrim(v_club) = '' THEN
    RAISE EXCEPTION 'No club linked to this account';
  END IF;
  IF v_pid IS NULL OR v_pid = '' THEN
    RAISE EXCEPTION 'Player is required';
  END IF;

  PERFORM public.club_emergency_loans_expire_due(NULL);
  v_status := public.club_emergency_loan_status(v_club);

  IF NOT coalesce((v_status->>'eligible')::boolean, false) THEN
    RAISE EXCEPTION 'Emergency loan not available (need fit players below min 24 from August)';
  END IF;
  IF NOT coalesce((v_status->>'can_afford')::boolean, false) THEN
    RAISE EXCEPTION 'Insufficient balance for emergency loan fee (need %)', v_fee;
  END IF;

  v_permanent := coalesce((v_status->>'permanent_registered')::int, public.club_permanent_squad_count(v_club));
  IF v_permanent > public.squad_max_size() THEN
    RAISE EXCEPTION 'Permanent squad already over maximum — cannot take an emergency loan';
  END IF;

  v_season_id := (v_status->>'season_id')::bigint;
  v_month := v_status->>'active_gpsl_month';
  v_ends := v_status->>'ends_gpsl_month';
  IF v_ends IS NULL THEN
    RAISE EXCEPTION 'Emergency loans are not available in the current GPSL month';
  END IF;

  SELECT * INTO v_player
  FROM public."Players"
  WHERE "Konami_ID"::text = v_pid
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Player not found';
  END IF;
  IF v_player."Contracted_Team" IS NOT NULL AND btrim(v_player."Contracted_Team") <> '' THEN
    RAISE EXCEPTION 'Player is not a free agent';
  END IF;
  IF coalesce(v_player.pesdb_unavailable, false) THEN
    RAISE EXCEPTION 'Player is unavailable (legacy / PESDB)';
  END IF;

  v_rating := public.player_rating_as_numeric(v_player."Rating"::text);
  IF v_rating IS NULL OR v_rating > v_max_rating THEN
    RAISE EXCEPTION 'Emergency loan players must be rated % or lower', v_max_rating;
  END IF;

  PERFORM 1 FROM public."Club_Finances" WHERE club_name = v_club FOR UPDATE;

  v_season_label := public.current_gpsl_season_label();
  v_wage := public.calculate_player_wage_for_club(v_pid, v_club);

  -- Allow assign through FFP buy-embargo Players trigger (eligible shortfall only)
  PERFORM set_config('gpsl.ffp_embargo_emergency_loan', 'on', true);

  UPDATE public."Players"
  SET
    "Contracted_Team" = v_club,
    "Season_Signed" = v_season_label,
    contract_seasons_remaining = 1,
    contract_wage = round(coalesce(v_wage, 0), 0),
    foreign_contract_club = NULL,
    foreign_contract_sold_season_id = NULL,
    foreign_contract_unlock_season_label = NULL,
    foreign_contract_lock_kind = NULL
  WHERE "Konami_ID"::text = v_pid;

  PERFORM set_config('gpsl.ffp_embargo_emergency_loan', 'off', true);

  v_ledger_id := public.post_club_ledger(
    v_club,
    'emergency_loan_fee',
    -abs(v_fee),
    format('Emergency loan fee — %s (until end of %s)', coalesce(v_player."Name", v_pid), initcap(v_ends)),
    jsonb_build_object(
      'player_id', v_pid,
      'season_id', v_season_id,
      'kind', 'emergency_loan',
      'ends_gpsl_month', v_ends,
      'permanent_squad_count', v_permanent,
      'ffp_embargo_bypass', coalesce((v_status->>'ffp_buy_embargo_active')::boolean, false)
    ),
    v_season_id,
    NULL,
    true,
    true
  );

  INSERT INTO public.club_emergency_loans (
    season_id,
    club_short_name,
    player_id,
    loan_fee,
    started_gpsl_month,
    ends_gpsl_month,
    status,
    loan_ledger_id,
    overflow_slot
  )
  VALUES (
    v_season_id,
    v_club,
    v_pid,
    v_fee,
    v_month,
    v_ends,
    'active',
    v_ledger_id,
    false
  )
  RETURNING id INTO v_loan_id;

  INSERT INTO public."Transfer_History" (
    player_id,
    seller_club_id,
    buyer_club_id,
    fee,
    agent_fee,
    transfer_time,
    listing_id,
    foreign_buyer_name,
    transfer_sale_note
  )
  VALUES (
    v_player."Konami_ID",
    NULL,
    v_club,
    v_fee,
    0,
    now(),
    NULL,
    NULL,
    'emergency_loan'
  )
  RETURNING id INTO v_history_id;

  RETURN jsonb_build_object(
    'ok', true,
    'loan_id', v_loan_id,
    'transfer_history_id', v_history_id,
    'player_id', v_pid,
    'player_name', v_player."Name",
    'club_short_name', v_club,
    'loan_fee', v_fee,
    'ends_gpsl_month', v_ends,
    'overflow_slot', false,
    'status', public.club_emergency_loan_status(v_club)
  );
EXCEPTION
  WHEN OTHERS THEN
    PERFORM set_config('gpsl.ffp_embargo_emergency_loan', 'off', true);
    RAISE;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.assert_club_may_sign_player(text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.club_emergency_loan_status(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.club_emergency_loan_take(text) TO authenticated;

NOTIFY pgrst, 'reload schema';
