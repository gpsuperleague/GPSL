-- =============================================================================
-- Expiry bid audit — AFTER Create Pre-Season / Tick
--
-- Requires: admin_expiry_bid_rollover_audit.sql STEP A already run (snapshot).
-- Run this alone after the tick to see moves / wages / fees.
-- =============================================================================

SELECT
  s.player_id,
  s.player_name,
  s.holding_club AS club_before,
  s.expected_winner_club,
  s.expected_winning_wage,
  public.player_contracted_club_key(p."Contracted_Team") AS club_after,
  p.contract_wage AS wage_after,
  p.contract_seasons_remaining AS seasons_after,
  p."Season_Signed" AS season_signed_after,
  CASE
    WHEN p."Konami_ID" IS NULL THEN 'FAIL: player row missing'
    WHEN public.player_contracted_club_key(p."Contracted_Team") IS NULL
      THEN 'UNEXPECTED FA (had winning bid expected)'
    WHEN public.player_contracted_club_key(p."Contracted_Team")
         IS NOT DISTINCT FROM s.expected_winner_club
     AND round(coalesce(p.contract_wage, 0), 0)
         = round(coalesce(s.expected_winning_wage, 0), 0)
     AND coalesce(p.contract_seasons_remaining, 0) = 3
      THEN 'OK'
    WHEN public.player_contracted_club_key(p."Contracted_Team")
         IS NOT DISTINCT FROM s.expected_winner_club
     AND coalesce(p.contract_seasons_remaining, 0) = 3
      THEN 'CHECK wage'
    ELSE 'CHECK club/wage/seasons'
  END AS contract_status,
  s.expected_mv_to_holder,
  coalesce(led.purchase_amt, 0) AS ledger_purchase_on_new_season,
  coalesce(led.sale_amt, 0) AS ledger_sale_on_new_season,
  coalesce(led.signing_fee_amt, 0) AS ledger_champ_signing_fee,
  CASE
    WHEN s.expected_mv_to_holder <= 0 THEN 'n/a (holder won / no MV)'
    WHEN coalesce(led.sale_amt, 0) >= s.expected_mv_to_holder * 0.999
     AND coalesce(led.purchase_amt, 0) <= -s.expected_mv_to_holder * 0.999
      THEN 'OK MV posted'
    ELSE 'CHECK MV ledger'
  END AS mv_status,
  CASE
    WHEN s.expected_champ_sl_signing_fee <= 0 THEN 'n/a'
    WHEN coalesce(led.signing_fee_amt, 0) <= -s.expected_champ_sl_signing_fee * 0.999
      THEN 'OK signing fee'
    ELSE 'CHECK signing fee'
  END AS signing_fee_status,
  th.transfer_time AS transfer_history_at,
  th.buyer_club_id AS th_buyer,
  th.fee AS th_fee
FROM public.admin_expiry_bid_audit_snapshot s
LEFT JOIN public."Players" p
  ON p."Konami_ID"::text = s.player_id
LEFT JOIN LATERAL (
  SELECT
    sum(CASE WHEN l.entry_type = 'transfer_purchase' THEN l.amount ELSE 0 END) AS purchase_amt,
    sum(CASE WHEN l.entry_type = 'transfer_sale' THEN l.amount ELSE 0 END) AS sale_amt,
    sum(CASE WHEN l.entry_type = 'contract_expiry_champ_signing_fee' THEN l.amount ELSE 0 END)
      AS signing_fee_amt
  FROM public.competition_finance_ledger l
  WHERE l.metadata->>'player_id' = s.player_id
    AND coalesce(l.metadata->>'source', '') = 'contract_expiry'
    AND l.season_id = (
      SELECT cs.id
      FROM public.competition_seasons cs
      WHERE cs.status IN ('preseason', 'setup', 'active')
      ORDER BY cs.id DESC
      LIMIT 1
    )
) led ON true
LEFT JOIN LATERAL (
  SELECT h.transfer_time, h.buyer_club_id, h.fee
  FROM public."Transfer_History" h
  WHERE h.player_id = s.player_id
    AND h.transfer_time >= s.snapped_at
  ORDER BY h.transfer_time DESC
  LIMIT 1
) th ON true
WHERE s.snapped_at = (
  SELECT max(s2.snapped_at) FROM public.admin_expiry_bid_audit_snapshot s2
)
ORDER BY
  CASE
    WHEN public.player_contracted_club_key(p."Contracted_Team")
         IS NOT DISTINCT FROM s.expected_winner_club
     AND round(coalesce(p.contract_wage, 0), 0)
         = round(coalesce(s.expected_winning_wage, 0), 0)
      THEN 1
    ELSE 0
  END,
  s.player_name;
