-- =============================================================================
-- PREVIEW: retrofit One of our Own fees to current market values (READ-ONLY)
-- =============================================================================
-- OooO fee at draw = Players.market_value. After MV recalc, set fee → new MV
-- and show club/bank money delta (positive delta = club pays more / gets less
-- refund; negative = club is refunded).
-- =============================================================================

WITH cur AS (
  SELECT id AS season_id, label AS season_label
  FROM public.competition_seasons
  WHERE is_current = true
  ORDER BY id DESC
  LIMIT 1
),
draws AS (
  SELECT
    d.id AS draw_id,
    d.club_short_name,
    d.player_id::text AS player_id,
    d.fee::numeric AS old_fee,
    d.season_id,
    d.transfer_history_id,
    p."Name"::text AS player_name,
    round(coalesce(nullif(btrim(p.market_value::text), '')::numeric, 0)) AS new_fee,
    h.fee::numeric AS history_fee,
    h.buyer_club_id,
    h.transfer_time
  FROM public.club_one_of_our_own_draws d
  JOIN cur ON cur.season_id = d.season_id
  JOIN public."Players" p
    ON btrim(p."Konami_ID"::text) = btrim(d.player_id::text)
  LEFT JOIN public."Transfer_History" h ON h.id = d.transfer_history_id
),
ledger AS (
  SELECT
    (l.metadata->>'transfer_history_id')::bigint AS transfer_history_id,
    l.id AS ledger_id,
    l.amount::numeric AS ledger_amount,
    l.club_short_name
  FROM public.competition_finance_ledger l
  WHERE l.entry_type = 'transfer_purchase'
    AND coalesce(l.metadata->>'one_of_our_own', '') IN ('true', 't', '1')
)
SELECT
  d.player_name,
  d.player_id,
  d.club_short_name,
  d.old_fee,
  d.new_fee,
  (d.new_fee - d.old_fee) AS fee_delta,
  -(d.new_fee - d.old_fee) AS club_balance_delta,
  (d.new_fee - d.old_fee) AS bank_reserves_delta,
  d.history_fee,
  lg.ledger_id,
  lg.ledger_amount AS current_ledger_amount,
  -d.new_fee AS target_ledger_amount,
  d.transfer_history_id,
  d.draw_id
FROM draws d
LEFT JOIN ledger lg ON lg.transfer_history_id = d.transfer_history_id
WHERE d.new_fee > 0
  AND d.old_fee IS DISTINCT FROM d.new_fee
ORDER BY abs(d.new_fee - d.old_fee) DESC, d.player_name;

-- Summary
WITH cur AS (
  SELECT id AS season_id
  FROM public.competition_seasons
  WHERE is_current = true
  ORDER BY id DESC
  LIMIT 1
),
draws AS (
  SELECT
    d.fee::numeric AS old_fee,
    round(coalesce(nullif(btrim(p.market_value::text), '')::numeric, 0)) AS new_fee
  FROM public.club_one_of_our_own_draws d
  JOIN cur ON cur.season_id = d.season_id
  JOIN public."Players" p
    ON btrim(p."Konami_ID"::text) = btrim(d.player_id::text)
)
SELECT
  count(*)::int AS ooo_draws_this_season,
  count(*) FILTER (WHERE old_fee IS DISTINCT FROM new_fee)::int AS needing_fee_update,
  count(*) FILTER (WHERE old_fee IS NOT DISTINCT FROM new_fee)::int AS already_matched,
  coalesce(sum(new_fee - old_fee) FILTER (WHERE old_fee IS DISTINCT FROM new_fee), 0) AS total_fee_delta,
  coalesce(sum(-(new_fee - old_fee)) FILTER (WHERE old_fee IS DISTINCT FROM new_fee), 0) AS total_club_refunds
FROM draws;
