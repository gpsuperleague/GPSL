-- =============================================================================
-- Bookies: cancel rotavator66's open betting slips
--
-- Each open bet is marked 'void' (frees the one-bet-per-market slot) and its stake goes back to the owner
-- balance as a reversing bookies_expenditure line (so his bookies spend nets
-- to zero rather than showing as winnings). Affected markets are re-priced so
-- the steam from those stakes comes off the board.
-- Only touches bets still 'open' — safe re-run.
-- =============================================================================

DO $$
DECLARE
  v_tag text := 'rotavator66';
  v_owner uuid;
  v_owner_count int;
  b record;
  v_ledger bigint;
  v_markets bigint[] := '{}';
  v_mid bigint;
BEGIN
  SELECT count(DISTINCT x.owner_id), min(x.owner_id::text)::uuid
  INTO v_owner_count, v_owner
  FROM (
    SELECT r.owner_id FROM public.gpsl_owner_registry r
    WHERE lower(btrim(r.owner_tag)) = lower(v_tag)
    UNION
    SELECT c.owner_id FROM public."Clubs" c
    WHERE lower(btrim(c.owner)) = lower(v_tag) AND c.owner_id IS NOT NULL
  ) x;

  IF v_owner_count = 0 THEN
    RAISE EXCEPTION 'No owner found with tag %', v_tag;
  ELSIF v_owner_count > 1 THEN
    RAISE EXCEPTION 'More than one owner matches tag % — check before cancelling', v_tag;
  END IF;

  FOR b IN
    SELECT bb.*, m.title AS market_title, s.label AS sel_label
    FROM public.bookies_bets bb
    JOIN public.bookies_markets m ON m.id = bb.market_id
    JOIN public.bookies_selections s ON s.id = bb.selection_id
    WHERE bb.owner_id = v_owner AND bb.status = 'open'
    ORDER BY bb.id
    FOR UPDATE OF bb
  LOOP
    v_ledger := public._post_owner_ledger_internal(
      v_owner,
      'bookies_expenditure',
      abs(b.stake),
      format('Bookies bet cancelled (refund): %s — %s (stake ₿%s)',
             b.market_title, b.sel_label, to_char(b.stake, 'FM999999990.00')),
      jsonb_build_object(
        'bookies', true,
        'bet_id', b.id,
        'market_id', b.market_id,
        'refund', true,
        'club_short_name', b.club_short_name
      ),
      b.season_id
    );

    UPDATE public.bookies_bets
    SET status = 'void',
        settled_at = now(),
        metadata = coalesce(metadata, '{}'::jsonb) || jsonb_build_object(
          'cancelled_by_admin', true,
          'refund_ledger_id', v_ledger,
          'cancelled_at', now()
        )
    WHERE id = b.id;

    IF NOT b.market_id = ANY (v_markets) THEN
      v_markets := v_markets || b.market_id;
    END IF;
  END LOOP;

  FOREACH v_mid IN ARRAY v_markets LOOP
    PERFORM public.bookies_apply_odds_from_weights(v_mid);
  END LOOP;
END $$;

-- Report: rotavator66's bets after the cancel
SELECT bb.id, m.title AS market, s.label AS selection, bb.stake,
       bb.status, bb.metadata->>'refund_ledger_id' AS refund_ledger_id,
       w.balance AS owner_balance_now
FROM public.bookies_bets bb
JOIN public.bookies_markets m ON m.id = bb.market_id
JOIN public.bookies_selections s ON s.id = bb.selection_id
LEFT JOIN public.owner_wallets w ON w.owner_id = bb.owner_id
WHERE bb.owner_id IN (
  SELECT r.owner_id FROM public.gpsl_owner_registry r WHERE lower(btrim(r.owner_tag)) = 'rotavator66'
  UNION
  SELECT c.owner_id FROM public."Clubs" c WHERE lower(btrim(c.owner)) = 'rotavator66'
)
ORDER BY bb.id;
