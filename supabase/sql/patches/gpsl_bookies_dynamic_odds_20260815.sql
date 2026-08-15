-- =============================================================================
-- Bookies: dynamic odds — money shortens a selection (like a real book)
--
-- • Base weight stays from rank/stats (set when markets open/refresh)
-- • Open stakes on a selection boost its effective weight → shorter odds
-- • Other selections drift longer as the market sum moves
-- • Each slip keeps the odds locked at place time
--
-- Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.bookies_selection_open_stakes(p_selection_id bigint)
RETURNS numeric
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT coalesce(sum(b.stake), 0)::numeric
  FROM public.bookies_bets b
  WHERE b.selection_id = p_selection_id
    AND b.status = 'open';
$$;

CREATE OR REPLACE FUNCTION public.bookies_apply_odds_from_weights(p_market_id bigint)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_sum numeric := 0;
  v_margin numeric := 0.08;
  -- Stake steam: every ₿20 matched on a selection ≈ +1 weight (shortens price)
  v_steam_div numeric := 20;
  r record;
  v_eff numeric;
  v_raw numeric;
  v_odds numeric;
BEGIN
  -- Effective weights = base weight + steam from open bets
  FOR r IN
    SELECT
      s.id,
      greatest(s.weight, 0.25) AS base_w,
      public.bookies_selection_open_stakes(s.id) AS steam
    FROM public.bookies_selections s
    WHERE s.market_id = p_market_id
  LOOP
    v_eff := r.base_w + (r.steam / v_steam_div);
    v_sum := v_sum + v_eff;
  END LOOP;

  IF v_sum <= 0 THEN
    UPDATE public.bookies_selections
    SET odds_decimal = 11
    WHERE market_id = p_market_id;
    RETURN;
  END IF;

  FOR r IN
    SELECT
      s.id,
      greatest(s.weight, 0.25) AS base_w,
      public.bookies_selection_open_stakes(s.id) AS steam
    FROM public.bookies_selections s
    WHERE s.market_id = p_market_id
  LOOP
    v_eff := r.base_w + (r.steam / v_steam_div);
    v_raw := (v_sum / greatest(v_eff, 0.25)) * (1.0 + v_margin);

    IF to_regprocedure('public.bookies_snap_uk_odds(numeric)') IS NOT NULL THEN
      v_odds := public.bookies_snap_uk_odds(v_raw);
    ELSE
      v_odds := least(101, greatest(2, round(v_raw, 0)));
    END IF;

    UPDATE public.bookies_selections
    SET odds_decimal = v_odds,
        metadata = coalesce(metadata, '{}'::jsonb) || jsonb_build_object(
          'steam_stakes', r.steam,
          'effective_weight', round(v_eff, 2),
          'odds_moved', true
        )
    WHERE id = r.id;
  END LOOP;
END;
$function$;

-- After a bet is taken, move the board (slip odds already locked on the bet row)
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

  IF EXISTS (
    SELECT 1 FROM public.bookies_bets b
    WHERE b.owner_id = v_uid
      AND b.market_id = v_mkt.id
      AND b.selection_id = v_sel.id
  ) THEN
    RAISE EXCEPTION 'You already have a bet on this option (one per selection)';
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

  -- Move the board after the stake is on (this slip keeps locked odds above)
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

-- When a market is settled/voided, open stakes leave — re-run not needed for board
-- but if admin voids, optional: leave as-is until refresh.

GRANT EXECUTE ON FUNCTION public.bookies_selection_open_stakes(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.bookies_apply_odds_from_weights(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.bookies_place_bet(bigint, numeric) TO authenticated;

-- Recompute boards now from any existing open stakes
DO $$
DECLARE
  r record;
BEGIN
  FOR r IN
    SELECT id FROM public.bookies_markets WHERE status = 'open'
  LOOP
    PERFORM public.bookies_apply_odds_from_weights(r.id);
  END LOOP;
END $$;

NOTIFY pgrst, 'reload schema';
