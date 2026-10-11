-- =============================================================================
-- READ-ONLY: how did a club get over 28 players without overflow releases?
-- Change v_club in each query if checking another club (default ACM).
-- SQL Editor shows only the LAST result — highlight a query and run it alone
-- to see the others. The last one is the full in/out timeline.
-- =============================================================================

-- Q1: Squad now (all contracted / permanent / emergency + season loans in)
SELECT
  'ACM' AS club,
  public.club_squad_player_count('ACM') AS contracted_total,
  public.club_permanent_squad_count('ACM') AS permanent_count_used_for_cap,
  (SELECT count(*) FROM public.club_emergency_loans l
   JOIN public.competition_seasons s ON s.id = l.season_id AND s.is_current
   WHERE l.club_short_name = 'ACM' AND l.status = 'active') AS emergency_loans_active,
  (SELECT count(*) FROM public.club_season_loans l
   JOIN public.competition_seasons s ON s.id = l.season_id AND s.is_current
   WHERE l.club_short_name = 'ACM' AND l.status = 'active') AS season_loans_active,
  (SELECT count(*) FROM public."Transfer_History" th
   WHERE th.seller_club_id = 'ACM' AND th.transfer_sale_note = 'squad_overflow') AS overflow_releases_ever;

-- Q2: Players at ACM now with NO arrival record in Transfer_History
--     (came in by a path that doesn't log — and likely skipped the 28 check)
SELECT p."Konami_ID", p."Name", p."Position", p."Rating", p."Season_Signed"
FROM public."Players" p
WHERE p."Contracted_Team" = 'ACM'
  AND NOT EXISTS (
    SELECT 1 FROM public."Transfer_History" th
    WHERE th.player_id::text = p."Konami_ID"::text AND th.buyer_club_id = 'ACM'
  )
ORDER BY p."Name";

-- Q3 (LAST): Timeline of every move in/out of ACM, newest first, with the
--     squad size right after each move. Look for where squad_after first
--     goes above 28 and what kind of move did it (note / sale_note).
WITH moves AS (
  SELECT th.transfer_time AS at,
         'IN' AS dir,
         th.player_id::text AS player_id,
         coalesce(th.seller_club_id, '—') AS other_club,
         th.fee,
         coalesce(th.transfer_sale_note, '') AS sale_note,
         coalesce(th.foreign_buyer_name, '') AS note,
         th.listing_id,
         1 AS delta
  FROM public."Transfer_History" th
  WHERE th.buyer_club_id = 'ACM'
  UNION ALL
  SELECT th.transfer_time, 'OUT', th.player_id::text,
         coalesce(th.buyer_club_id, '—'), th.fee,
         coalesce(th.transfer_sale_note, ''), coalesce(th.foreign_buyer_name, ''),
         th.listing_id, -1
  FROM public."Transfer_History" th
  WHERE th.seller_club_id = 'ACM'
),
ordered AS (
  SELECT m.*,
         public.club_squad_player_count('ACM')
           - coalesce(sum(m.delta) OVER (
               ORDER BY m.at DESC, m.dir
               ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
             ), 0) AS squad_after
  FROM moves m
)
SELECT o.at AT TIME ZONE 'Europe/London' AS at_uk,
       o.dir,
       p."Name" AS player,
       p."Position",
       o.other_club,
       o.fee,
       o.sale_note,
       o.note,
       l.listing_type,
       o.squad_after,
       CASE WHEN o.squad_after > 28 AND o.dir = 'IN' THEN '⚠ over 28 after this' END AS flag
FROM ordered o
LEFT JOIN public."Players" p ON p."Konami_ID"::text = o.player_id
LEFT JOIN public."Player_Transfer_Listings" l ON l.id = o.listing_id
ORDER BY o.at DESC, o.dir
LIMIT 120;
