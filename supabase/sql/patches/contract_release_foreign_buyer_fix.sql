-- =============================================================================
-- Fix: Create Season fails — Transfer_History.buyer_club_id NOT NULL
--
-- Cause: competition_create_season → contract_tick_season_rollover →
--   contract_release_zero_year_players() inserted buyer_club_id = NULL for
--   natural contract ends (free agent). Column is NOT NULL.
--
-- Fix: use FOREIGN sentinel + foreign_buyer_name / transfer_sale_note
-- (same pattern as FFP release / voluntary contract release).
-- Also harden player_contract_expire the same way.
--
-- Run in Supabase SQL Editor, then retry Create Pre-Season.
-- Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.contract_release_zero_year_players()
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_player public."Players"%rowtype;
  v_club   text;
  v_fee    numeric;
  v_bal    numeric;
  v_count  int := 0;
BEGIN
  PERFORM public.ensure_foreign_buyer_club();

  FOR v_player IN
    SELECT *
    FROM public."Players" p
    WHERE public.player_contracted_club_key(p."Contracted_Team") IS NOT NULL
      AND p.contract_seasons_remaining IS NOT NULL
      AND p.contract_seasons_remaining <= 0
    FOR UPDATE
  LOOP
    v_club := public.player_contracted_club_key(v_player."Contracted_Team");
    v_fee := greatest(coalesce(v_player.market_value::numeric, 0), 0);

    SELECT balance INTO v_bal
    FROM public."Club_Finances"
    WHERE club_name = v_club
    FOR UPDATE;

    IF v_bal IS NOT NULL THEN
      UPDATE public."Club_Finances"
      SET balance = v_bal + v_fee
      WHERE club_name = v_club;
    END IF;

    PERFORM public.player_release_from_club(v_player."Konami_ID"::text);

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
      v_club,
      'FOREIGN',
      v_fee,
      0,
      now(),
      NULL,
      'Contract expired (free agent)',
      'contract_expiry'
    );

    v_count := v_count + 1;
  END LOOP;

  RETURN v_count;
END;
$function$;

CREATE OR REPLACE FUNCTION public.player_contract_expire(p_player_id text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club           text;
  v_player         public."Players"%rowtype;
  v_pid            text := btrim(p_player_id);
  v_fee            numeric;
  v_seller_balance numeric;
  v_history_id     bigint;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  v_club := public.my_club_shortname();
  IF v_club IS NULL OR btrim(v_club) = '' THEN
    RAISE EXCEPTION 'No club linked to this account';
  END IF;

  SELECT *
  INTO v_player
  FROM public."Players"
  WHERE "Konami_ID"::text = v_pid
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Player not found';
  END IF;

  IF public.player_contracted_club_key(v_player."Contracted_Team") IS DISTINCT FROM v_club THEN
    RAISE EXCEPTION 'Player is not at your club';
  END IF;

  IF coalesce(v_player.contract_seasons_remaining, 0) <> 1 THEN
    RAISE EXCEPTION 'Contract expiry is only available in the final contract year (1 season remaining)';
  END IF;

  v_fee := greatest(coalesce(v_player.market_value::numeric, 0::numeric), 0::numeric);

  UPDATE public."Player_Transfer_Listings" l
  SET status = 'Closed',
      transfer_completed = false
  WHERE l.player_id::text = v_pid
    AND l.seller_club_id = v_club
    AND l.status IN ('Active', 'Review');

  SELECT balance
  INTO v_seller_balance
  FROM public."Club_Finances"
  WHERE club_name = v_club
  FOR UPDATE;

  IF v_seller_balance IS NULL THEN
    RAISE EXCEPTION 'Club finances not found for %', v_club;
  END IF;

  PERFORM public.ensure_foreign_buyer_club();
  PERFORM public.player_release_from_club(v_pid);

  UPDATE public."Club_Finances"
  SET balance = v_seller_balance + v_fee
  WHERE club_name = v_club;

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
    v_club,
    'FOREIGN',
    v_fee,
    0,
    now(),
    NULL,
    'Contract expired (free agent)',
    'contract_expiry'
  )
  RETURNING id INTO v_history_id;

  IF to_regprocedure('public.post_transfer_ledger_for_history(bigint, boolean)') IS NOT NULL THEN
    PERFORM public.post_transfer_ledger_for_history(v_history_id, false);
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'player_id', v_player."Konami_ID",
    'player_name', v_player."Name",
    'fee', v_fee,
    'new_balance', v_seller_balance + v_fee
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.contract_release_zero_year_players() TO authenticated;
GRANT EXECUTE ON FUNCTION public.player_contract_expire(text) TO authenticated;

NOTIFY pgrst, 'reload schema';
