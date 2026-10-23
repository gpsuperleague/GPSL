-- =============================================================================
-- Bookies: PURGE all rotavator66 bets + bookies ledger (2026-10-23)
-- =============================================================================
-- Removes every bookies_bets row for rotavator66 (open / void / settled) and
-- every owner_finance_ledger bookies_* line, reversing their effect on the
-- owner wallet so balance stays correct (test stakes / refunds gone).
-- Reprices markets that had his stakes. Safe re-run (no-op if already clean).
-- =============================================================================

DO $purge$
DECLARE
  v_tag text := 'rotavator66';
  v_owner uuid;
  v_owner_count int;
  b record;
  v_ledger bigint;
  v_markets bigint[] := '{}';
  v_mid bigint;
  v_bookies_sum numeric := 0;
  v_bets_deleted int := 0;
  v_ledger_deleted int := 0;
  v_open_refunded int := 0;
  v_bal numeric;
BEGIN
  SELECT count(DISTINCT x.owner_id), (array_agg(DISTINCT x.owner_id))[1]
  INTO v_owner_count, v_owner
  FROM (
    SELECT r.owner_id FROM public.gpsl_owner_registry r
    WHERE lower(btrim(r.owner_tag)) = lower(v_tag)
    UNION
    SELECT c.owner_id FROM public."Clubs" c
    WHERE lower(btrim(coalesce(c.owner, ''))) = lower(v_tag)
      AND c.owner_id IS NOT NULL
  ) x;

  IF v_owner_count = 0 THEN
    RAISE EXCEPTION 'No owner found with tag %', v_tag;
  ELSIF v_owner_count > 1 THEN
    RAISE EXCEPTION 'More than one owner matches tag % — check before purge', v_tag;
  END IF;

  RAISE NOTICE 'Purging bookies for % (%)', v_tag, v_owner;

  -- 1) Refund any still-open slips (same style as cancel patch)
  FOR b IN
    SELECT bb.*, m.title AS market_title, s.label AS sel_label
    FROM public.bookies_bets bb
    JOIN public.bookies_markets m ON m.id = bb.market_id
    JOIN public.bookies_selections s ON s.id = bb.selection_id
    WHERE bb.owner_id = v_owner
      AND bb.status = 'open'
    ORDER BY bb.id
    FOR UPDATE OF bb
  LOOP
    v_ledger := public._post_owner_ledger_internal(
      v_owner,
      'bookies_expenditure',
      abs(b.stake),
      format(
        'Bookies bet cancelled (refund): %s — %s (stake ₿%s)',
        b.market_title,
        b.sel_label,
        to_char(b.stake, 'FM999999990.00')
      ),
      jsonb_build_object(
        'bookies', true,
        'bet_id', b.id,
        'market_id', b.market_id,
        'refund', true,
        'purge', true,
        'club_short_name', b.club_short_name
      ),
      b.season_id
    );

    UPDATE public.bookies_bets
    SET
      status = 'void',
      settled_at = now(),
      metadata = coalesce(metadata, '{}'::jsonb) || jsonb_build_object(
        'cancelled_by_admin', true,
        'refund_ledger_id', v_ledger,
        'cancelled_at', now(),
        'purged', true
      )
    WHERE id = b.id;

    v_open_refunded := v_open_refunded + 1;
    IF NOT b.market_id = ANY (v_markets) THEN
      v_markets := v_markets || b.market_id;
    END IF;
  END LOOP;

  -- Collect markets from any remaining bets (void/settled) for reprice
  SELECT coalesce(array_agg(DISTINCT market_id), v_markets)
  INTO v_markets
  FROM public.bookies_bets
  WHERE owner_id = v_owner;

  -- 2) Reverse + delete all bookies ledger lines (stakes, refunds, wins)
  SELECT coalesce(sum(l.amount), 0)
  INTO v_bookies_sum
  FROM public.owner_finance_ledger l
  WHERE l.owner_id = v_owner
    AND (
      l.entry_type IN ('bookies_expenditure', 'bookies_income')
      OR coalesce((l.metadata->>'bookies')::boolean, false) = true
    );

  DELETE FROM public.owner_finance_ledger l
  WHERE l.owner_id = v_owner
    AND (
      l.entry_type IN ('bookies_expenditure', 'bookies_income')
      OR coalesce((l.metadata->>'bookies')::boolean, false) = true
    );
  GET DIAGNOSTICS v_ledger_deleted = ROW_COUNT;

  IF v_bookies_sum <> 0 THEN
    UPDATE public.owner_wallets
    SET
      balance = round(balance - v_bookies_sum, 2),
      updated_at = now()
    WHERE owner_id = v_owner;
  END IF;

  -- 3) Delete every bet row (open already voided above; all statuses go)
  DELETE FROM public.bookies_bets
  WHERE owner_id = v_owner;
  GET DIAGNOSTICS v_bets_deleted = ROW_COUNT;

  -- 4) Reprice affected markets
  IF v_markets IS NOT NULL THEN
    FOREACH v_mid IN ARRAY v_markets LOOP
      IF v_mid IS NULL THEN CONTINUE; END IF;
      IF to_regprocedure('public.bookies_apply_odds_from_weights(bigint)') IS NOT NULL THEN
        BEGIN
          PERFORM public.bookies_apply_odds_from_weights(v_mid);
        EXCEPTION WHEN OTHERS THEN
          RAISE WARNING 'odds reprice failed for market %: %', v_mid, SQLERRM;
        END;
      END IF;
    END LOOP;
  END IF;

  SELECT balance INTO v_bal FROM public.owner_wallets WHERE owner_id = v_owner;

  RAISE NOTICE
    'Purge done: open_refunded=% bets_deleted=% ledger_deleted=% bookies_sum_reversed=% balance_now=%',
    v_open_refunded, v_bets_deleted, v_ledger_deleted, v_bookies_sum, v_bal;
END;
$purge$;

-- Expect: no rows
SELECT bb.*
FROM public.bookies_bets bb
WHERE bb.owner_id IN (
  SELECT r.owner_id FROM public.gpsl_owner_registry r
  WHERE lower(btrim(r.owner_tag)) = 'rotavator66'
  UNION
  SELECT c.owner_id FROM public."Clubs" c
  WHERE lower(btrim(coalesce(c.owner, ''))) = 'rotavator66' AND c.owner_id IS NOT NULL
);

SELECT l.id, l.entry_type, l.amount, l.description, l.created_at
FROM public.owner_finance_ledger l
WHERE l.owner_id IN (
  SELECT r.owner_id FROM public.gpsl_owner_registry r
  WHERE lower(btrim(r.owner_tag)) = 'rotavator66'
  UNION
  SELECT c.owner_id FROM public."Clubs" c
  WHERE lower(btrim(coalesce(c.owner, ''))) = 'rotavator66' AND c.owner_id IS NOT NULL
)
  AND (
    l.entry_type IN ('bookies_expenditure', 'bookies_income')
    OR coalesce((l.metadata->>'bookies')::boolean, false) = true
  )
ORDER BY l.created_at DESC;

SELECT w.owner_id, w.balance
FROM public.owner_wallets w
WHERE w.owner_id IN (
  SELECT r.owner_id FROM public.gpsl_owner_registry r
  WHERE lower(btrim(r.owner_tag)) = 'rotavator66'
  UNION
  SELECT c.owner_id FROM public."Clubs" c
  WHERE lower(btrim(coalesce(c.owner, ''))) = 'rotavator66' AND c.owner_id IS NOT NULL
);
