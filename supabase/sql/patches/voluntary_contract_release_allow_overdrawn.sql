-- =============================================================================
-- Voluntary contract release: allow buy-out when overdrawn
-- Buy-out still debits Club_Finances; owners manage FFP themselves.
-- Safe re-run (replaces player_voluntary_contract_release).
-- =============================================================================

CREATE OR REPLACE FUNCTION public.player_voluntary_contract_release(p_player_id text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club           text;
  v_pid            text := btrim(p_player_id);
  v_player         public."Players"%rowtype;
  v_remaining      int;
  v_cost           numeric;
  v_balance        numeric;
  v_seasons        int;
  v_wage           numeric;
  v_unlock         text;
  v_ledger_id      bigint;
  v_desc           text;
  v_season_id      bigint;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  v_club := public.my_club_shortname();
  IF v_club IS NULL OR btrim(v_club) = '' THEN
    RAISE EXCEPTION 'No club linked to this account';
  END IF;

  SELECT greatest(coalesce(c.voluntary_contract_releases_remaining, 0), 0)
  INTO v_remaining
  FROM public."Clubs" c
  WHERE c."ShortName" = v_club
  FOR UPDATE;

  IF coalesce(v_remaining, 0) <= 0 THEN
    RAISE EXCEPTION
      'No voluntary contract releases remaining this season (maximum 3).';
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

  v_seasons := coalesce(v_player.contract_seasons_remaining, 0);
  IF v_seasons < 1 THEN
    RAISE EXCEPTION 'Player has no active contract seasons remaining';
  END IF;

  v_wage := greatest(coalesce(v_player.contract_wage, 0), 0);
  v_cost := public.calculate_voluntary_contract_release_cost(v_wage, v_seasons);

  IF v_cost <= 0 THEN
    RAISE EXCEPTION 'Could not calculate contract buy-out cost for this player';
  END IF;

  SELECT balance
  INTO v_balance
  FROM public."Club_Finances"
  WHERE club_name = v_club
  FOR UPDATE;

  IF v_balance IS NULL THEN
    RAISE EXCEPTION 'Club finances not found for %', v_club;
  END IF;

  -- Buy-out always debits (may deepen a negative balance); owners manage FFP themselves.

  UPDATE public."Player_Transfer_Listings" l
  SET status = 'Closed',
      transfer_completed = false,
      winning_bid = null,
      winning_club = null
  WHERE l.player_id::text = v_pid
    AND l.seller_club_id = v_club
    AND l.status IN ('Active', 'Review');

  UPDATE public."Player_Transfer_Bids" b
  SET status = 'rejected'
  WHERE b.is_direct = true
    AND b.listing_id IS NULL
    AND lower(coalesce(b.status::text, '')) = 'active'
    AND (
      (b.player_id IS NOT NULL AND btrim(b.player_id::text) = v_pid)
      OR (b.direct_bid_id IS NOT NULL AND btrim(b.direct_bid_id::text) = v_pid)
    );

  PERFORM public.player_release_from_club(v_pid);
  PERFORM public.player_apply_overflow_paid_up_lock(v_pid, v_club);

  v_unlock := public.next_gpsl_season_label(public.current_gpsl_season_id());

  UPDATE public."Club_Finances"
  SET balance = v_balance - v_cost
  WHERE club_name = v_club;

  UPDATE public."Clubs" c
  SET voluntary_contract_releases_remaining = voluntary_contract_releases_remaining - 1
  WHERE c."ShortName" = v_club
  RETURNING c.voluntary_contract_releases_remaining INTO v_remaining;

  v_season_id := public.current_gpsl_season_id();
  v_desc := format(
    'Contract release buy-out: %s (%s seasons × wage)',
    v_player."Name",
    v_seasons
  );

  v_ledger_id := public.post_club_ledger(
    v_club,
    'contract_release_comp',
    -abs(v_cost),
    v_desc,
    jsonb_build_object(
      'player_id', v_pid,
      'player_name', v_player."Name",
      'contract_wage', v_wage,
      'contract_seasons_remaining', v_seasons,
      'voluntary_contract_release', true
    ),
    v_season_id,
    NULL,
    false,
    false
  );

  PERFORM public.ensure_foreign_buyer_club();

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
    0,
    0,
    now(),
    NULL,
    format('Voluntary contract release (₿ %s buy-out)', to_char(v_cost, 'FM999999999999')),
    'voluntary_contract_release'
  );

  RETURN jsonb_build_object(
    'ok', true,
    'player_id', v_pid,
    'player_name', v_player."Name",
    'buyout_cost', v_cost,
    'contract_wage', v_wage,
    'contract_seasons_remaining', v_seasons,
    'new_balance', v_balance - v_cost,
    'voluntary_contract_releases_remaining', v_remaining,
    'unavailable_until_season', v_unlock,
    'ledger_id', v_ledger_id
  );
END;
$function$;

NOTIFY pgrst, 'reload schema';
