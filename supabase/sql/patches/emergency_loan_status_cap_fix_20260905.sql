-- =============================================================================
-- Emergency loans: status copy + permanent-squad cap semantics
--
-- Rule:
--   * Emergency loans are exempt from the 28-player squad maximum.
--   * The 28 cap still applies to permanent players.
--   * Therefore 28 permanent + N emergency is allowed, but 29 permanent is not.
--
-- This patch:
--   1) Adds a permanent-squad counter (contracted players minus active emergency loans)
--   2) Reworks emergency-loan eligibility to ignore emergency bodies for the max cap
--   3) Reworks generic overflow enforcement to only count permanent players
-- =============================================================================

CREATE OR REPLACE FUNCTION public.club_permanent_squad_count(p_club_short_name text)
RETURNS int
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := btrim(p_club_short_name);
  v_total int := 0;
  v_active_emergency int := 0;
BEGIN
  IF v_club IS NULL OR v_club = '' THEN
    RETURN 0;
  END IF;

  SELECT count(*)::int
  INTO v_total
  FROM public."Players" p
  WHERE p."Contracted_Team" = v_club;

  SELECT count(*)::int
  INTO v_active_emergency
  FROM public.club_emergency_loans l
  JOIN public.competition_seasons s ON s.id = l.season_id
  WHERE l.club_short_name = v_club
    AND l.status = 'active'
    AND s.is_current = true;

  RETURN greatest(v_total - coalesce(v_active_emergency, 0), 0);
END;
$function$;

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

CREATE OR REPLACE FUNCTION public.owner_inbox_notify_emergency_loan_available(
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
  v_permanent int;
  v_available int;
  v_min int := public.squad_minimum_size();
  v_max int := public.squad_max_size();
  v_need int;
  v_slots int;
  v_ends text;
  v_fee numeric := public.emergency_loan_fee_amount();
  v_fee_label text;
  v_dedupe text;
  v_title text;
  v_body text;
BEGIN
  IF v_club IS NULL THEN
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
  IF v_month IS NULL OR NOT public.emergency_loan_window_open(v_month) THEN
    RETURN NULL;
  END IF;

  v_permanent := public.club_permanent_squad_count(v_club);
  v_available := public.club_available_player_count(v_club);
  v_need := greatest(v_min - v_available, 0);
  v_slots := CASE
    WHEN v_need > 0 AND v_permanent <= v_max THEN v_need
    ELSE 0
  END;
  v_ends := public.emergency_loan_window_end_month(v_month);

  IF v_slots <= 0 THEN
    RETURN NULL;
  END IF;

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
      'Fit players (%s) are below the squad minimum of %s — injuries and suspensions count as unavailable.',
      v_available,
      v_min
    ),
    format(
      'You can take up to %s emergency loan%s this half-season (shortfall %s). Fee %s to Central Bank; free agents rated ≤66; returns end of %s.',
      v_slots,
      CASE WHEN v_slots = 1 THEN '' ELSE 's' END,
      v_need,
      v_fee_label,
      initcap(coalesce(v_ends, 'the window'))
    ),
    'Emergency loans do not count toward the 28 permanent-player squad cap.',
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
      'permanent_squad_count', v_permanent
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
END;
$function$;

CREATE OR REPLACE FUNCTION public.enforce_squad_overflow_after_signing(
  p_club_short_name text,
  p_new_player_id text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := btrim(p_club_short_name);
  v_total int;
  v_release text;
  v_player public."Players"%rowtype;
  v_interest int;
  v_teams text[];
  v_team text;
  v_result jsonb;
BEGIN
  v_total := public.club_permanent_squad_count(v_club);

  IF v_total <= public.squad_max_size() THEN
    RETURN jsonb_build_object('released', false, 'squad_total', v_total);
  END IF;

  v_release := public.pick_squad_overflow_release_player(v_club, p_new_player_id);

  IF v_release IS NULL THEN
    RAISE EXCEPTION
      'Permanent squad has % players (max %) but no player could be selected for overflow release',
      v_total, public.squad_max_size();
  END IF;

  SELECT * INTO v_player
  FROM public."Players" p
  WHERE p."Konami_ID"::text = v_release;

  SELECT coalesce(c.foreign_interest_remaining, 0)
  INTO v_interest
  FROM public."Clubs" c
  WHERE c."ShortName" = v_club;

  IF coalesce(v_interest, 0) > 0 THEN
    v_teams := public.sync_club_foreign_tracking(v_club);
    v_team := v_teams[1];

    IF v_team IS NULL OR btrim(v_team) = '' THEN
      v_result := public.club_release_player_mv_overflow(v_club, v_release);
    ELSE
      v_result := public.club_sell_player_to_foreign(v_club, v_release, v_team);
    END IF;
  ELSE
    v_result := public.club_release_player_mv_overflow(v_club, v_release);
  END IF;

  RETURN coalesce(v_result, '{}'::jsonb) || jsonb_build_object(
    'squad_total', public.club_permanent_squad_count(v_club)
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.club_permanent_squad_count(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.club_emergency_loan_status(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.owner_inbox_notify_emergency_loan_available(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.club_emergency_loan_take(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.enforce_squad_overflow_after_signing(text, text) TO authenticated;

NOTIFY pgrst, 'reload schema';
