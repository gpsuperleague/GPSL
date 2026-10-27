-- =============================================================================
-- Flamengo (FLA): reverse Marquinhos signing → refund + free agent
--
-- Does NOT touch opening balance / club start / other ledger lines.
-- Only:
--   • refund FLA ledger rows tied to that purchase (fee + tax if any)
--   • release player to free agent
--   • clear matchday/designation rows
--   • mark Transfer_History admin_reversed (or delete if unreferenced)
--
-- Run sections in order. Apply is idempotent.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1) DIAGNOSE — who is Marquinhos at FLA / recent FLA buys
-- ---------------------------------------------------------------------------
SELECT
  p."Konami_ID"::text AS player_id,
  p."Name",
  p."Position",
  p."Rating",
  nullif(btrim(p."Contracted_Team"::text), '') AS contracted_team,
  p.market_value
FROM public."Players" p
WHERE p."Name" ILIKE '%marquinhos%'
   OR p."Name" ILIKE '%marquinh%'
ORDER BY
  CASE WHEN upper(nullif(btrim(p."Contracted_Team"::text), '')) = 'FLA' THEN 0 ELSE 1 END,
  p."Name";

SELECT
  h.id AS history_id,
  h.player_id::text,
  pl."Name" AS player_name,
  h.buyer_club_id,
  h.seller_club_id,
  h.foreign_buyer_name,
  h.fee,
  h.agent_fee,
  h.transfer_time,
  h.listing_id,
  h.transfer_sale_note
FROM public."Transfer_History" h
LEFT JOIN public."Players" pl ON pl."Konami_ID"::text = h.player_id::text
WHERE upper(h.buyer_club_id) = 'FLA'
  AND (
    pl."Name" ILIKE '%marquinhos%'
    OR pl."Name" ILIKE '%marquinh%'
    OR h.transfer_time > now() - interval '60 days'
  )
ORDER BY h.transfer_time DESC
LIMIT 30;

-- FLA finance snapshot (should only change by the Marquinhos refund)
SELECT
  cf.club_name,
  cf.balance AS current_balance,
  (
    SELECT count(*) FROM public.competition_finance_ledger l
    WHERE upper(l.club_short_name) = 'FLA'
  ) AS ledger_rows
FROM public."Club_Finances" cf
WHERE upper(cf.club_name) = 'FLA';

-- ---------------------------------------------------------------------------
-- 2) APPLY — set v_pid from diagnose if auto-detect is wrong
-- ---------------------------------------------------------------------------
DO $apply$
DECLARE
  v_club text := 'FLA';
  v_pid  text;
  v_name text;
  v_team text;
  v_h    record;
  v_l    record;
  v_n    int;
  v_refunded numeric := 0;
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.is_gpsl_admin()
     AND current_user NOT IN ('postgres', 'supabase_admin', 'service_role') THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  -- Prefer Marquinhos currently at FLA; else latest FLA purchase matching name
  SELECT p."Konami_ID"::text, p."Name",
         upper(nullif(btrim(coalesce(p."Contracted_Team"::text, '')), ''))
  INTO v_pid, v_name, v_team
  FROM public."Players" p
  WHERE p."Name" ILIKE '%marquinhos%'
  ORDER BY
    CASE WHEN upper(nullif(btrim(p."Contracted_Team"::text), '')) = v_club THEN 0 ELSE 1 END,
    p."Rating" DESC NULLS LAST
  LIMIT 1;

  IF v_pid IS NULL THEN
    RAISE EXCEPTION 'No player matching Marquinhos found';
  END IF;

  SELECT h.* INTO v_h
  FROM public."Transfer_History" h
  WHERE h.player_id::text = v_pid
    AND upper(h.buyer_club_id) = v_club
    AND coalesce(h.transfer_sale_note, '') IS DISTINCT FROM 'admin_reversed'
    AND coalesce(h.transfer_sale_note, '') NOT LIKE 'admin_reversed%'
  ORDER BY h.transfer_time DESC, h.id DESC
  LIMIT 1;

  RAISE NOTICE 'Target: % (%) team=% history=%', v_name, v_pid, coalesce(v_team, 'FA'), coalesce(v_h.id::text, 'none');

  -- Refund FLA debit lines for this purchase (fee + income tax etc.)
  IF v_h.id IS NOT NULL THEN
    FOR v_l IN
      SELECT l.*
      FROM public.competition_finance_ledger l
      WHERE upper(l.club_short_name) = v_club
        AND l.amount < 0
        AND (
          l.metadata->>'transfer_history_id' = v_h.id::text
          OR (
            l.metadata->>'player_id' = v_pid
            AND l.created_at BETWEEN v_h.transfer_time - interval '1 hour'
                                AND v_h.transfer_time + interval '6 hours'
            AND l.entry_type IN (
              'transfer_purchase', 'transfer_fee', 'player_purchase',
              'gov_income_tax', 'income_tax', 'transfer_income_tax',
              'transfer_agent_fee', 'agent_fee'
            )
          )
        )
        AND NOT EXISTS (
          SELECT 1 FROM public.competition_finance_ledger r
          WHERE r.metadata->>'refund_of_ledger_id' = l.id::text
        )
    LOOP
      PERFORM public.post_club_ledger(
        v_l.club_short_name,
        v_l.entry_type,
        -v_l.amount,
        'Refund (Marquinhos reversed by admin): ' || coalesce(v_l.description, v_l.entry_type),
        jsonb_build_object(
          'refund_of_ledger_id', v_l.id,
          'refund_of_transfer_history_id', v_h.id,
          'reversed_history', to_jsonb(v_h),
          'player_id', v_pid,
          'admin_reversal', true,
          'reason', 'flamengo_marquinhos_reverse_20261027'
        ),
        v_l.season_id,
        NULL,
        EXISTS (SELECT 1 FROM public.bank_ledger b WHERE b.club_ledger_id = v_l.id),
        true
      );
      v_refunded := v_refunded + (-v_l.amount);
    END LOOP;
    RAISE NOTICE 'FLA refunded ₿%', to_char(v_refunded, 'FM999,999,999,990');
  ELSE
    RAISE NOTICE 'No FLA Transfer_History for % — skipping ledger refund', v_pid;
  END IF;

  -- Squad cleanup
  IF to_regclass('public.club_matchday_squad_player') IS NOT NULL THEN
    DELETE FROM public.club_matchday_squad_player WHERE player_id = v_pid;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    IF v_n > 0 THEN RAISE NOTICE 'Removed % matchday squad row(s)', v_n; END IF;
  END IF;
  IF to_regclass('public.club_squad_player_designations') IS NOT NULL THEN
    DELETE FROM public.club_squad_player_designations WHERE player_id = v_pid;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    IF v_n > 0 THEN RAISE NOTICE 'Removed % designation(s)', v_n; END IF;
  END IF;

  -- Release to free agent
  IF v_team = v_club THEN
    PERFORM public.player_release_from_club(v_pid);
    RAISE NOTICE '% released from FLA → free agent', v_name;
  ELSE
    RAISE NOTICE 'Player not at FLA (now: %) — no release needed', coalesce(v_team, 'free agent');
  END IF;

  -- History / listing
  IF v_h.id IS NOT NULL THEN
    IF v_h.listing_id IS NOT NULL THEN
      UPDATE public."Player_Transfer_Listings"
      SET transfer_completed = false,
          winning_bid = NULL,
          winning_club = NULL,
          status = 'Closed'
      WHERE id = v_h.listing_id;
    END IF;

    BEGIN
      DELETE FROM public."Transfer_History" WHERE id = v_h.id;
      RAISE NOTICE 'Transfer_History #%s deleted', v_h.id;
    EXCEPTION WHEN OTHERS THEN
      UPDATE public."Transfer_History"
      SET transfer_sale_note = 'admin_reversed'
      WHERE id = v_h.id;
      RAISE NOTICE 'Transfer_History #%s marked admin_reversed (%s)', v_h.id, SQLERRM;
    END;
  END IF;

  -- Drop open bids on this player from FLA if any
  DELETE FROM public."Player_Transfer_Bids" b
  WHERE coalesce(b.player_id::text, b.direct_bid_id::text) = v_pid
    AND upper(btrim(b.bidder_club_id)) = v_club
    AND coalesce(b.status, '') ILIKE ANY (ARRAY['open', 'active', 'winning', '']);
END;
$apply$;

-- ---------------------------------------------------------------------------
-- 3) VERIFY
-- ---------------------------------------------------------------------------
SELECT
  p."Konami_ID"::text AS player_id,
  p."Name",
  coalesce(nullif(btrim(p."Contracted_Team"::text), ''), 'FREE AGENT') AS team
FROM public."Players" p
WHERE p."Name" ILIKE '%marquinhos%'
ORDER BY p."Name";

SELECT
  cf.balance AS fla_balance_after,
  (
    SELECT coalesce(sum(l.amount), 0)
    FROM public.competition_finance_ledger l
    WHERE upper(l.club_short_name) = 'FLA'
      AND l.metadata->>'reason' = 'flamengo_marquinhos_reverse_20261027'
  ) AS marquinhos_refund_total
FROM public."Club_Finances" cf
WHERE upper(cf.club_name) = 'FLA';
