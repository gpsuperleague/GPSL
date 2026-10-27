-- =============================================================================
-- Flamengo: leftover income tax is the season true-up, not a Marquinhos line
--
-- Diagnose showed:
--   ledger #49344  gov_income_tax  −₿1,237,500
--   "Income tax adjustment — season purchases re-taxed at 1.500%"
--   no player_id / history_id
--
-- 1.5% of ₿82,500,000 = ₿1,237,500 → this was tax on the Marquinhos fee.
-- Purchase fee was already refunded; this true-up was not.
--
-- Run diagnose, then apply if FLA has no other taxable purchases left.
-- =============================================================================

-- 1) DIAGNOSE
SELECT
  l.id, l.entry_type, l.amount, l.description, l.created_at,
  l.metadata
FROM public.competition_finance_ledger l
WHERE upper(l.club_short_name) = 'FLA'
  AND l.entry_type = 'gov_income_tax'
ORDER BY l.created_at;

-- Remaining FLA purchase spend this season (should be ~0 after Marquinhos reverse)
SELECT
  l.id, l.entry_type, l.amount, l.description, l.created_at,
  l.metadata->>'player_id' AS player_id,
  EXISTS (
    SELECT 1 FROM public.competition_finance_ledger r
    WHERE r.metadata->>'refund_of_ledger_id' = l.id::text
  ) AS already_refunded
FROM public.competition_finance_ledger l
WHERE upper(l.club_short_name) = 'FLA'
  AND l.entry_type IN ('transfer_purchase', 'transfer_fee', 'transfer_agent_fee', 'player_purchase')
ORDER BY l.created_at;

SELECT
  coalesce(sum(-l.amount) FILTER (
    WHERE l.entry_type IN ('transfer_purchase', 'transfer_fee', 'transfer_agent_fee', 'player_purchase')
      AND NOT EXISTS (
        SELECT 1 FROM public.competition_finance_ledger r
        WHERE r.metadata->>'refund_of_ledger_id' = l.id::text
      )
  ), 0) AS net_taxable_spend_still_charged,
  coalesce(sum(-l.amount) FILTER (
    WHERE l.entry_type = 'gov_income_tax'
      AND NOT EXISTS (
        SELECT 1 FROM public.competition_finance_ledger r
        WHERE r.metadata->>'refund_of_ledger_id' = l.id::text
      )
  ), 0) AS net_income_tax_still_charged
FROM public.competition_finance_ledger l
WHERE upper(l.club_short_name) = 'FLA';

-- 2) APPLY — refund true-up #49344 (and any twin unrefunded FLA income-tax true-up)
DO $fix$
DECLARE
  v_l record;
  v_n int := 0;
  v_total numeric := 0;
  v_spend numeric;
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.is_gpsl_admin()
     AND current_user NOT IN ('postgres', 'supabase_admin', 'service_role') THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  SELECT coalesce(sum(-l.amount), 0) INTO v_spend
  FROM public.competition_finance_ledger l
  WHERE upper(l.club_short_name) = 'FLA'
    AND l.entry_type IN ('transfer_purchase', 'transfer_fee', 'transfer_agent_fee', 'player_purchase')
    AND NOT EXISTS (
      SELECT 1 FROM public.competition_finance_ledger r
      WHERE r.metadata->>'refund_of_ledger_id' = l.id::text
    );

  IF v_spend > 0 THEN
    RAISE EXCEPTION
      'FLA still has ₿% of unrefunded purchase spend — refuse to wipe all income tax. Review diagnose first.',
      to_char(v_spend, 'FM999,999,999,990');
  END IF;

  FOR v_l IN
    SELECT l.*
    FROM public.competition_finance_ledger l
    WHERE upper(l.club_short_name) = 'FLA'
      AND l.entry_type = 'gov_income_tax'
      AND l.amount < 0
      AND (
        l.id = 49344
        OR l.description ILIKE '%season purchases re-taxed%'
        OR l.description ILIKE '%income tax adjustment%'
      )
      AND NOT EXISTS (
        SELECT 1 FROM public.competition_finance_ledger r
        WHERE r.metadata->>'refund_of_ledger_id' = l.id::text
      )
      AND coalesce(l.metadata->>'admin_reversal', '') IS DISTINCT FROM 'true'
  LOOP
    PERFORM public.post_club_ledger(
      v_l.club_short_name,
      v_l.entry_type,
      -v_l.amount,
      'Refund (Marquinhos true-up reversed): ' || coalesce(v_l.description, v_l.entry_type),
      jsonb_build_object(
        'refund_of_ledger_id', v_l.id,
        'admin_reversal', true,
        'reason', 'flamengo_marquinhos_trueup_refund_20261027'
      ),
      v_l.season_id,
      NULL,
      EXISTS (SELECT 1 FROM public.bank_ledger b WHERE b.club_ledger_id = v_l.id),
      true
    );
    v_n := v_n + 1;
    v_total := v_total + (-v_l.amount);
    RAISE NOTICE 'Refunded tax ledger #%s ₿%', v_l.id, to_char(-v_l.amount, 'FM999,999,999,990');
  END LOOP;

  IF v_n = 0 THEN
    RAISE NOTICE 'Nothing to refund — true-up already cleared?';
  ELSE
    RAISE NOTICE 'Done: % line(s), credited ₿%', v_n, to_char(v_total, 'FM999,999,999,990');
  END IF;
END;
$fix$;

-- 3) VERIFY
SELECT
  l.id, l.amount, l.description,
  EXISTS (
    SELECT 1 FROM public.competition_finance_ledger r
    WHERE r.metadata->>'refund_of_ledger_id' = l.id::text
  ) AS has_refund
FROM public.competition_finance_ledger l
WHERE upper(l.club_short_name) = 'FLA'
  AND l.entry_type = 'gov_income_tax'
ORDER BY l.created_at;

SELECT balance AS fla_balance
FROM public."Club_Finances"
WHERE upper(club_name) = 'FLA';
