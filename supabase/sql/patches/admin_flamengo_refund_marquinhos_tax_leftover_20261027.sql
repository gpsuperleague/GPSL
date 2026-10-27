-- =============================================================================
-- Flamengo: refund leftover Marquinhos income tax (and any unrefunded purchase)
--
-- Why tax can still show: the first reverse often deleted Transfer_History, so
-- re-running the original apply finds no history and skips ledger refunds.
-- Tax rows remain with metadata.player_id / description "Income tax — …".
--
-- Safe re-run. Does not touch opening balance or unrelated ledger lines.
-- =============================================================================

-- 1) DIAGNOSE — Marquinhos card(s) + FLA tax/purchase lines that mention him
WITH marquinhos AS (
  SELECT p."Konami_ID"::text AS player_id, p."Name" AS player_name
  FROM public."Players" p
  WHERE p."Name" ILIKE '%marquinhos%'
)
SELECT
  l.id AS ledger_id,
  l.entry_type,
  l.amount,
  l.description,
  l.created_at,
  l.metadata->>'player_id' AS meta_player_id,
  l.metadata->>'transfer_history_id' AS meta_history_id,
  EXISTS (
    SELECT 1 FROM public.competition_finance_ledger r
    WHERE r.metadata->>'refund_of_ledger_id' = l.id::text
  ) AS already_refunded
FROM public.competition_finance_ledger l
WHERE upper(l.club_short_name) = 'FLA'
  AND l.amount < 0
  AND l.entry_type IN (
    'gov_income_tax', 'transfer_purchase', 'transfer_fee',
    'transfer_agent_fee', 'player_purchase'
  )
  AND (
    l.metadata->>'player_id' IN (SELECT player_id FROM marquinhos)
    OR l.description ILIKE '%marquinhos%'
    OR l.metadata->>'transfer_history_id' IN (
      SELECT h.id::text
      FROM public."Transfer_History" h
      WHERE h.player_id::text IN (SELECT player_id FROM marquinhos)
        AND upper(h.buyer_club_id) = 'FLA'
    )
    OR l.metadata->'reversed_history'->>'player_id' IN (SELECT player_id FROM marquinhos)
  )
ORDER BY l.created_at;

-- All FLA income tax this season (see if anything else remains)
SELECT
  l.id, l.amount, l.description, l.created_at,
  l.metadata->>'player_id' AS player_id,
  l.metadata->>'transfer_history_id' AS history_id,
  EXISTS (
    SELECT 1 FROM public.competition_finance_ledger r
    WHERE r.metadata->>'refund_of_ledger_id' = l.id::text
  ) AS already_refunded
FROM public.competition_finance_ledger l
WHERE upper(l.club_short_name) = 'FLA'
  AND l.entry_type = 'gov_income_tax'
ORDER BY l.created_at;

-- 2) APPLY — refund any still-unrefunded Marquinhos-linked debits
DO $fix$
DECLARE
  v_l record;
  v_n int := 0;
  v_total numeric := 0;
  v_pids text[];
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.is_gpsl_admin()
     AND current_user NOT IN ('postgres', 'supabase_admin', 'service_role') THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  SELECT array_agg(p."Konami_ID"::text)
  INTO v_pids
  FROM public."Players" p
  WHERE p."Name" ILIKE '%marquinhos%';

  IF v_pids IS NULL OR array_length(v_pids, 1) IS NULL THEN
    RAISE EXCEPTION 'No Marquinhos player found';
  END IF;

  FOR v_l IN
    SELECT l.*
    FROM public.competition_finance_ledger l
    WHERE upper(l.club_short_name) = 'FLA'
      AND l.amount < 0
      AND l.entry_type IN (
        'gov_income_tax', 'transfer_purchase', 'transfer_fee',
        'transfer_agent_fee', 'player_purchase'
      )
      AND (
        l.metadata->>'player_id' = ANY (v_pids)
        OR l.description ILIKE '%marquinhos%'
        OR l.metadata->'reversed_history'->>'player_id' = ANY (v_pids)
        OR l.metadata->>'transfer_history_id' IN (
          SELECT h.id::text FROM public."Transfer_History" h
          WHERE h.player_id::text = ANY (v_pids)
            AND upper(h.buyer_club_id) = 'FLA'
        )
        -- also catch history ids stored on earlier refund rows' metadata
        OR l.metadata->>'transfer_history_id' IN (
          SELECT DISTINCT r.metadata->>'refund_of_transfer_history_id'
          FROM public.competition_finance_ledger r
          WHERE upper(r.club_short_name) = 'FLA'
            AND r.metadata->>'reason' = 'flamengo_marquinhos_reverse_20261027'
            AND r.metadata->>'refund_of_transfer_history_id' IS NOT NULL
        )
      )
      AND NOT EXISTS (
        SELECT 1 FROM public.competition_finance_ledger r
        WHERE r.metadata->>'refund_of_ledger_id' = l.id::text
      )
      -- don't refund our own prior refund credits
      AND coalesce(l.metadata->>'admin_reversal', '') IS DISTINCT FROM 'true'
      AND coalesce(l.metadata->>'reason', '') IS DISTINCT FROM 'flamengo_marquinhos_reverse_20261027'
      AND coalesce(l.metadata->>'reason', '') IS DISTINCT FROM 'flamengo_marquinhos_tax_leftover_20261027'
  LOOP
    PERFORM public.post_club_ledger(
      v_l.club_short_name,
      v_l.entry_type,
      -v_l.amount,
      'Refund (Marquinhos leftover): ' || coalesce(v_l.description, v_l.entry_type),
      jsonb_build_object(
        'refund_of_ledger_id', v_l.id,
        'player_id', coalesce(v_l.metadata->>'player_id', v_pids[1]),
        'admin_reversal', true,
        'reason', 'flamengo_marquinhos_tax_leftover_20261027'
      ),
      v_l.season_id,
      NULL,
      EXISTS (SELECT 1 FROM public.bank_ledger b WHERE b.club_ledger_id = v_l.id),
      true
    );
    v_n := v_n + 1;
    v_total := v_total + (-v_l.amount);
    RAISE NOTICE 'Refunded ledger #%s %s ₿%', v_l.id, v_l.entry_type, to_char(-v_l.amount, 'FM999,999,999,990');
  END LOOP;

  RAISE NOTICE 'Done: % line(s), total credit ₿%', v_n, to_char(v_total, 'FM999,999,999,990');
END;
$fix$;

-- 3) VERIFY — FLA income tax should net to ~0 for Marquinhos (or show only non-Marquinhos)
SELECT
  l.entry_type,
  l.amount,
  l.description,
  l.metadata->>'player_id' AS player_id,
  EXISTS (
    SELECT 1 FROM public.competition_finance_ledger r
    WHERE r.metadata->>'refund_of_ledger_id' = l.id::text
  ) AS has_refund
FROM public.competition_finance_ledger l
WHERE upper(l.club_short_name) = 'FLA'
  AND (
    l.entry_type = 'gov_income_tax'
    OR l.description ILIKE '%marquinhos%'
    OR l.metadata->>'reason' LIKE 'flamengo_marquinhos%'
  )
ORDER BY l.created_at;

SELECT balance AS fla_balance
FROM public."Club_Finances"
WHERE upper(club_name) = 'FLA';
