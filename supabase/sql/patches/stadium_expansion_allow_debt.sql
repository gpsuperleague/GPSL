-- =============================================================================
-- Stadium expansion: allow orders into debt
--
-- Clubs may place expansion orders regardless of balance. The ledger still
-- debits the full quote cost (balance can go further negative).
-- Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.stadium_expansion_place_order(p_quote_id bigint)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text;
  v_season_id bigint;
  v_quote public.stadium_expansion_quotes;
  v_base int;
  v_current int;
  v_max int;
  v_balance numeric;
  v_order_id bigint;
  v_ledger_id bigint;
  v_bank_leg boolean := false;
BEGIN
  v_club := public.my_club_shortname();
  IF v_club IS NULL OR v_club = '' THEN
    RAISE EXCEPTION 'No club linked to this account';
  END IF;

  SELECT id INTO v_season_id
  FROM public.competition_seasons
  WHERE is_current = true AND status = 'active'
  LIMIT 1;

  IF v_season_id IS NULL THEN
    RAISE EXCEPTION 'No active competition season';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.stadium_expansion_orders o
    WHERE o.club_short_name = v_club AND o.season_id_ordered = v_season_id
  ) THEN
    RAISE EXCEPTION 'Only one stadium expansion order per season';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.stadium_expansion_orders o
    WHERE o.club_short_name = v_club
      AND o.status IN ('pre_build', 'awaiting_goahead', 'building')
  ) THEN
    RAISE EXCEPTION 'An expansion is already in progress';
  END IF;

  SELECT * INTO v_quote
  FROM public.stadium_expansion_quotes q
  WHERE q.id = p_quote_id
    AND q.club_short_name = v_club
    AND q.consumed_at IS NULL;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Quote not found or already used';
  END IF;

  PERFORM public.stadium_expansion_sync_progress(v_club);

  SELECT coalesce(c."Capacity", 0)::int, coalesce(c.base_capacity, c."Capacity", 0)::int
  INTO v_current, v_base
  FROM public."Clubs" c
  WHERE c."ShortName" = v_club;

  v_max := public.stadium_max_capacity(v_base);

  IF v_quote.seats > public.stadium_expansion_headroom(v_club) THEN
    RAISE EXCEPTION 'Quote is no longer valid — capacity headroom changed';
  END IF;

  -- Lock finances for the ledger debit (no balance gate — debt is allowed)
  SELECT balance INTO v_balance
  FROM public."Club_Finances"
  WHERE club_name = v_club
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Club finances not found';
  END IF;

  IF to_regprocedure('public.finance_entry_via_central_bank(text)') IS NOT NULL THEN
    v_bank_leg := coalesce(public.finance_entry_via_central_bank('infra_expansion'), false);
  END IF;

  v_ledger_id := public.post_club_ledger(
    v_club,
    'infra_expansion',
    -v_quote.total_cost,
    format('Stadium expansion — %s seats ordered', v_quote.seats),
    jsonb_build_object('quote_id', p_quote_id, 'seats', v_quote.seats),
    v_season_id,
    NULL,
    v_bank_leg,
    true
  );

  INSERT INTO public.stadium_expansion_orders (
    club_short_name,
    season_id_ordered,
    quote_id,
    seats_ordered,
    total_cost_paid,
    cost_per_seat,
    capacity_at_order,
    base_capacity_at_order,
    max_capacity_at_order,
    status,
    ledger_payment_id
  )
  VALUES (
    v_club,
    v_season_id,
    p_quote_id,
    v_quote.seats,
    v_quote.total_cost,
    v_quote.cost_per_seat,
    v_current,
    v_base,
    v_max,
    'pre_build',
    v_ledger_id
  )
  RETURNING id INTO v_order_id;

  UPDATE public.stadium_expansion_quotes
  SET consumed_at = now(), consumed_order_id = v_order_id
  WHERE id = p_quote_id;

  RETURN v_order_id;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.stadium_expansion_place_order(bigint) TO authenticated;

NOTIFY pgrst, 'reload schema';
