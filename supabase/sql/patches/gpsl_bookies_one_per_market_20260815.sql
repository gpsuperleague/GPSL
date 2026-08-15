-- Bookies: one bet per owner per market (not per selection)
-- Safe re-run.

ALTER TABLE public.bookies_bets
  DROP CONSTRAINT IF EXISTS bookies_bets_once_per_option;

DROP INDEX IF EXISTS public.bookies_bets_once_per_market_uidx;

CREATE UNIQUE INDEX bookies_bets_once_per_market_uidx
  ON public.bookies_bets (owner_id, market_id)
  WHERE status IS DISTINCT FROM 'void';

CREATE OR REPLACE FUNCTION public.bookies_place_bet(
  p_selection_id bigint,
  p_stake numeric
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_club text;
  v_sel public.bookies_selections%rowtype;
  v_mkt public.bookies_markets%rowtype;
  v_stake numeric := round(coalesce(p_stake, 0)::numeric, 2);
  v_bet_id bigint;
  v_ledger bigint;
  v_ret numeric;
  v_desc text;
  v_frac text;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  v_club := public.my_club_shortname();
  IF v_club IS NULL OR btrim(v_club) = '' THEN
    RAISE EXCEPTION 'No club linked to your account';
  END IF;

  IF v_stake IS NULL OR v_stake <= 0 THEN
    RAISE EXCEPTION 'Stake must be greater than zero';
  END IF;
  IF v_stake > 1000 THEN
    RAISE EXCEPTION 'Maximum stake is ₿1,000 per bet';
  END IF;

  SELECT * INTO v_sel FROM public.bookies_selections WHERE id = p_selection_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Selection not found';
  END IF;

  SELECT * INTO v_mkt FROM public.bookies_markets WHERE id = v_sel.market_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Market not found';
  END IF;

  IF v_mkt.status <> 'open' THEN
    RAISE EXCEPTION 'Market is not open for betting';
  END IF;
  IF v_mkt.closes_at IS NOT NULL AND v_mkt.closes_at <= now() THEN
    RAISE EXCEPTION 'Market betting window has closed';
  END IF;

  -- One bet per owner per market
  IF EXISTS (
    SELECT 1 FROM public.bookies_bets b
    WHERE b.owner_id = v_uid
      AND b.market_id = v_mkt.id
      AND b.status IS DISTINCT FROM 'void'
  ) THEN
    RAISE EXCEPTION 'You already have a bet on this market (one bet per market)';
  END IF;

  v_ret := round(v_stake * v_sel.odds_decimal, 2);

  IF to_regprocedure('public.bookies_fractional_odds_label(numeric)') IS NOT NULL THEN
    v_frac := public.bookies_fractional_odds_label(v_sel.odds_decimal);
  ELSE
    v_frac := to_char(v_sel.odds_decimal, 'FM999999990.00');
  END IF;

  v_desc := format(
    'Bookies stake: %s — %s @ %s (stake ₿%s)',
    v_mkt.title,
    v_sel.label,
    v_frac,
    to_char(v_stake, 'FM999999990.00')
  );

  v_ledger := public.post_club_ledger(
    v_club,
    'bookies_expenditure',
    -abs(v_stake),
    v_desc,
    jsonb_build_object(
      'bookies', true,
      'market_id', v_mkt.id,
      'selection_id', v_sel.id,
      'market_code', v_mkt.market_code,
      'odds', v_sel.odds_decimal,
      'odds_fractional', v_frac,
      'stake', v_stake
    ),
    v_mkt.season_id,
    NULL,
    false,
    true
  );

  INSERT INTO public.bookies_bets (
    season_id, market_id, selection_id, owner_id, club_short_name,
    stake, odds_decimal, potential_return, status, ledger_stake_id, metadata
  )
  VALUES (
    v_mkt.season_id, v_mkt.id, v_sel.id, v_uid, v_club,
    v_stake, v_sel.odds_decimal, v_ret, 'open', v_ledger,
    jsonb_build_object(
      'selection_label', v_sel.label,
      'market_title', v_mkt.title,
      'odds_fractional', v_frac
    )
  )
  RETURNING id INTO v_bet_id;

  PERFORM public.bookies_apply_odds_from_weights(v_mkt.id);

  RETURN jsonb_build_object(
    'ok', true,
    'bet_id', v_bet_id,
    'stake', v_stake,
    'odds', v_sel.odds_decimal,
    'odds_fractional', v_frac,
    'potential_return', v_ret,
    'ledger_id', v_ledger,
    'board_moved', true
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.bookies_place_bet(bigint, numeric) TO authenticated;

NOTIFY pgrst, 'reload schema';
