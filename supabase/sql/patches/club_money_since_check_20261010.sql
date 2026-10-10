-- =============================================================================
-- Before / after for one club (read-only). Change club + "since" on the first lines.
--
-- Lists every ledger line posted since the time given (UK time), with the bank
-- balance walked BACKWARDS from today so you can see the balance at each point.
-- First row = balance at the "since" time (reconstructed); then each line;
-- then BALANCE NOW; then a total per money type.
-- =============================================================================

WITH params AS (
  SELECT 'BAR'::text AS club,
         (timestamp '2026-10-09 19:00' AT TIME ZONE 'Europe/London') AS since
),
now_bal AS (
  SELECT f.balance::numeric AS balance
  FROM public."Club_Finances" f, params p
  WHERE f.club_name = p.club
),
lines AS (
  SELECT l.id, l.created_at, l.entry_type, l.amount::numeric AS amount, l.description
  FROM public.competition_finance_ledger l, params p
  WHERE l.club_short_name = p.club
    AND l.created_at >= p.since
),
walked AS (
  SELECT
    li.*,
    (SELECT balance FROM now_bal)
      - coalesce(sum(li.amount) OVER (ORDER BY li.created_at DESC, li.id DESC
                                      ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING), 0)
      AS balance_after
  FROM lines li
)
SELECT when_uk, entry_type, amount, balance_after, description
FROM (
  SELECT 0 AS g, to_char(p.since AT TIME ZONE 'Europe/London', 'DD Mon HH24:MI') AS when_uk,
         'START (reconstructed)' AS entry_type, NULL::numeric AS amount,
         (SELECT balance FROM now_bal) - coalesce((SELECT sum(amount) FROM lines), 0) AS balance_after,
         'Balance at the start time = balance now − everything posted since' AS description,
         p.since AS t, 0::bigint AS id
  FROM params p
  UNION ALL
  SELECT 1, to_char(w.created_at AT TIME ZONE 'Europe/London', 'DD Mon HH24:MI:SS'),
         w.entry_type, w.amount, w.balance_after, w.description, w.created_at, w.id
  FROM walked w
  UNION ALL
  SELECT 2, 'NOW', 'BALANCE NOW', NULL, (SELECT balance FROM now_bal),
         'Totals since start — in: ' || coalesce((SELECT sum(amount) FROM lines WHERE amount > 0), 0)
         || ' · out: ' || coalesce((SELECT sum(-amount) FROM lines WHERE amount < 0), 0)
         || ' · lines: ' || (SELECT count(*) FROM lines),
         now(), 0
  UNION ALL
  SELECT 3, 'BY TYPE', l.entry_type, sum(l.amount), NULL,
         count(*) || ' line(s)', now(), 0
  FROM lines l
  GROUP BY l.entry_type
) x
ORDER BY g, t, id;
