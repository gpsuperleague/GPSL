-- =============================================================================
-- PART 2/4 — assign / bid block / FA release function
-- Run after: contract_expiry_fa_central_bank_01_types_and_locks.sql
-- =============================================================================

SET statement_timeout = '120s';

DROP FUNCTION IF EXISTS public.player_assign_to_club(text, text);
DROP FUNCTION IF EXISTS public.player_assign_to_club(text, text, numeric);

CREATE OR REPLACE FUNCTION public.player_assign_to_club(
  p_player_id text,
  p_club_short_name text,
  p_wage numeric DEFAULT NULL,
  p_defer_squad_overflow boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_pid      text := btrim(p_player_id);
  v_club     text := btrim(p_club_short_name);
  v_season   text;
  v_wage     numeric;
  v_overflow jsonb;
  v_defer    boolean;
BEGIN
  IF v_pid = '' OR v_club = '' THEN
    RAISE EXCEPTION 'player_assign_to_club: player_id and club are required';
  END IF;

  v_defer := p_defer_squad_overflow
    OR coalesce(
      nullif(current_setting('gpsl.defer_squad_overflow', true), ''),
      ''
    ) = 'on';

  PERFORM public.assert_club_may_sign_expiry_fa_player(v_pid, v_club);

  IF to_regprocedure('public.assert_player_available_for_signing(text)') IS NOT NULL THEN
    PERFORM public.assert_player_available_for_signing(v_pid);
  END IF;

  v_season := public.current_gpsl_season_label();
  v_wage := coalesce(p_wage, public.calculate_player_wage_for_club(v_pid, v_club));

  UPDATE public."Players"
  SET
    "Contracted_Team" = v_club,
    "Season_Signed" = v_season,
    contract_seasons_remaining = 3,
    contract_wage = round(coalesce(v_wage, 0), 0),
    foreign_contract_club = NULL,
    foreign_contract_sold_season_id = NULL,
    foreign_contract_unlock_season_label = NULL,
    foreign_contract_lock_kind = NULL
  WHERE "Konami_ID"::text = v_pid;

  IF v_defer THEN
    v_overflow := jsonb_build_object(
      'released', false,
      'deferred', true,
      'squad_total', public.club_squad_player_count(v_club)
    );
  ELSE
    v_overflow := public.enforce_squad_overflow_after_signing(v_club, v_pid);
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'player_id', v_pid,
    'club_short_name', v_club,
    'contract_seasons_remaining', 3,
    'overflow_release', v_overflow
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.player_assign_to_club(text, text, numeric, boolean)
  TO authenticated;

CREATE OR REPLACE FUNCTION public.trg_transfer_bid_block_same_season_player()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_player_id text;
  v_bidder text;
BEGIN
  v_player_id := btrim(coalesce(NEW.player_id, NEW.direct_bid_id::text, ''));

  IF v_player_id = '' AND NEW.listing_id IS NOT NULL THEN
    SELECT btrim(l.player_id::text)
    INTO v_player_id
    FROM public."Player_Transfer_Listings" l
    WHERE l.id = NEW.listing_id;
  END IF;

  IF v_player_id IS NULL OR v_player_id = '' THEN
    RETURN NEW;
  END IF;

  PERFORM public.assert_player_transferable(v_player_id);
  PERFORM public.assert_player_available_for_signing(v_player_id);

  v_bidder := nullif(btrim(coalesce(NEW.bidder_club_id::text, '')), '');
  IF v_bidder IS NOT NULL THEN
    PERFORM public.assert_club_may_sign_expiry_fa_player(v_player_id, v_bidder);
  END IF;

  RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.contract_release_zero_year_players(
  p_ledger_season_id bigint DEFAULT NULL
)
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_count int := 0;
  v_ledger_id bigint := p_ledger_season_id;
  v_ledger_label text;
  v_ctx record;
  r record;
  v_bank_leg boolean := true;
BEGIN
  PERFORM public.ensure_foreign_buyer_club();

  IF v_ledger_id IS NULL THEN
    SELECT * INTO v_ctx FROM public.contract_rollover_finance_context();
    v_ledger_id := v_ctx.ledger_season_id;
    v_ledger_label := v_ctx.ledger_season_label;
  ELSE
    SELECT btrim(s.label) INTO v_ledger_label
    FROM public.competition_seasons s
    WHERE s.id = v_ledger_id;
  END IF;

  IF v_ledger_id IS NULL THEN
    RAISE EXCEPTION 'No ledger season for contract FA releases';
  END IF;

  IF to_regprocedure('public.finance_entry_via_central_bank(text)') IS NOT NULL THEN
    v_bank_leg := coalesce(
      public.finance_entry_via_central_bank('contract_expiry_compensation'),
      true
    );
  END IF;

  CREATE TEMP TABLE IF NOT EXISTS _contract_expire_batch (
    player_id text PRIMARY KEY,
    club text NOT NULL,
    fee numeric NOT NULL DEFAULT 0,
    player_name text
  ) ON COMMIT DROP;

  DELETE FROM _contract_expire_batch WHERE true;

  INSERT INTO _contract_expire_batch (player_id, club, fee, player_name)
  SELECT
    p."Konami_ID"::text,
    public.player_contracted_club_key(p."Contracted_Team"),
    greatest(coalesce(p.market_value::numeric, 0), 0),
    p."Name"
  FROM public."Players" p
  WHERE public.player_contracted_club_key(p."Contracted_Team") IS NOT NULL
    AND p.contract_seasons_remaining IS NOT NULL
    AND p.contract_seasons_remaining <= 0;

  GET DIAGNOSTICS v_count = ROW_COUNT;
  IF v_count = 0 THEN
    RETURN 0;
  END IF;

  FOR r IN
    SELECT * FROM _contract_expire_batch e WHERE e.fee > 0 ORDER BY e.player_id
  LOOP
    PERFORM public.post_club_ledger(
      r.club,
      'contract_expiry_compensation',
      r.fee,
      'Contract ended (free agent): ' || coalesce(r.player_name, r.player_id),
      jsonb_build_object(
        'player_id', r.player_id,
        'player_name', r.player_name,
        'holding_club', r.club,
        'market_value', r.fee,
        'ledger_season_id', v_ledger_id,
        'ledger_season_label', v_ledger_label,
        'source', 'contract_expiry_fa',
        'compensation_from', 'central_bank'
      ),
      v_ledger_id,
      NULL,
      v_bank_leg,
      true
    );
  END LOOP;

  UPDATE public."Players" p
  SET
    "Contracted_Team" = NULL,
    "Season_Signed" = NULL,
    contract_seasons_remaining = NULL,
    contract_wage = NULL,
    foreign_contract_club = e.club,
    foreign_contract_sold_season_id = v_ledger_id,
    foreign_contract_unlock_season_label = 'when signed by another club',
    foreign_contract_lock_kind = 'expiry_fa'
  FROM _contract_expire_batch e
  WHERE p."Konami_ID"::text = e.player_id;

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
  SELECT
    e.player_id,
    e.club,
    'FOREIGN',
    e.fee,
    0,
    now(),
    NULL,
    'Contract Run Down - Central Bank Compensation',
    'contract_expiry'
  FROM _contract_expire_batch e;

  RETURN v_count;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.contract_release_zero_year_players(bigint) TO authenticated;

SELECT 'PART 2 OK — assign + FA release' AS status;
