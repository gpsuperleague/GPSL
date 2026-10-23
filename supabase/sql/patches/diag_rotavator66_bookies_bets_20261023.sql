-- =============================================================================
-- DIAGNOSTIC (read-only): all bookies bets for rotavator66
-- =============================================================================
-- Cancelled slips stay in bookies_bets as status = 'void' (they are not deleted).
-- "No open bets" ⇒ count(status='open') = 0; void history may still appear in My Bets.
-- Safe re-run. No writes.
-- =============================================================================

WITH owners AS (
  SELECT DISTINCT owner_id, src
  FROM (
    SELECT r.owner_id, 'registry:' || r.owner_tag AS src
    FROM public.gpsl_owner_registry r
    WHERE lower(btrim(r.owner_tag)) = 'rotavator66'
    UNION ALL
    SELECT c.owner_id, 'clubs.owner:' || c.owner AS src
    FROM public."Clubs" c
    WHERE lower(btrim(coalesce(c.owner, ''))) = 'rotavator66'
      AND c.owner_id IS NOT NULL
  ) x
)
SELECT * FROM owners;

-- Every bet ever (open / void / settled)
WITH owners AS (
  SELECT owner_id FROM public.gpsl_owner_registry
  WHERE lower(btrim(owner_tag)) = 'rotavator66'
  UNION
  SELECT owner_id FROM public."Clubs"
  WHERE lower(btrim(coalesce(owner, ''))) = 'rotavator66' AND owner_id IS NOT NULL
)
SELECT
  bb.id AS bet_id,
  bb.status,
  bb.stake,
  bb.odds_decimal,
  bb.placed_at,
  bb.settled_at,
  m.id AS market_id,
  m.title AS market,
  m.market_code,
  s.label AS selection,
  bb.club_short_name AS bettor_club,
  bb.metadata->>'cancelled_by_admin' AS admin_cancel,
  bb.metadata->>'void_reason' AS void_reason,
  bb.metadata->>'refund_ledger_id' AS refund_ledger_id,
  bb.ledger_stake_id
FROM public.bookies_bets bb
JOIN public.bookies_markets m ON m.id = bb.market_id
JOIN public.bookies_selections s ON s.id = bb.selection_id
WHERE bb.owner_id IN (SELECT owner_id FROM owners)
ORDER BY bb.placed_at NULLS LAST, bb.id;

-- Counts by status
WITH owners AS (
  SELECT owner_id FROM public.gpsl_owner_registry
  WHERE lower(btrim(owner_tag)) = 'rotavator66'
  UNION
  SELECT owner_id FROM public."Clubs"
  WHERE lower(btrim(coalesce(owner, ''))) = 'rotavator66' AND owner_id IS NOT NULL
)
SELECT
  coalesce(bb.status, '(null)') AS status,
  count(*) AS bets,
  sum(bb.stake)::numeric(14, 2) AS stake_total
FROM public.bookies_bets bb
WHERE bb.owner_id IN (SELECT owner_id FROM owners)
GROUP BY bb.status
ORDER BY bets DESC;
