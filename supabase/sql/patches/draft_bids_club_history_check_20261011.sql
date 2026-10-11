-- =============================================================================
-- READ-ONLY: what happened to one club's draft auction bids (last 4 days)
--
-- Club: Crvena zvezda (owner matjaz) — matched by name below.
-- Run each query separately (highlight → Run); the editor shows one grid per run.
--   Q0  current draft window (tonight)
--   Q1  per player per draft listing: his bids vs the outcome  ← main answer
--   Q2  every Transfer_History row involving the club (signings, overflow releases)
--   Q3  max bids / auto-bid plan targets he set up (in case he never placed a bid)
--   Q4  club money lines for the same period
-- =============================================================================

-- Q0 ---------------------------------------------------------------------------
SELECT
  c."ShortName", c."Club",
  (SELECT u.email FROM auth.users u WHERE u.id = c.owner_id) AS owner_email,
  g.draft_auction_enabled,
  g.draft_auction_start_time AT TIME ZONE 'Europe/London' AS tonight_start_uk,
  g.draft_random_finish_time AT TIME ZONE 'Europe/London' AS tonight_secret_finish_uk,
  now() AT TIME ZONE 'Europe/London' AS now_uk,
  public.club_squad_player_count(c."ShortName") AS squad_now
FROM public."Clubs" c
CROSS JOIN public.global_settings g
WHERE g.id = 1
  AND (c."Club" ILIKE '%zvezda%' OR c."Club" ILIKE '%red star%');


-- Q1 ---------------------------------------------------------------------------
WITH club AS (
  SELECT c."ShortName" AS sn
  FROM public."Clubs" c
  WHERE c."Club" ILIKE '%zvezda%' OR c."Club" ILIKE '%red star%'
  LIMIT 1
),
my_bids AS (
  SELECT
    b.*,
    coalesce(b.player_id::text, b.direct_bid_id::text) AS pid
  FROM public."Player_Transfer_Bids" b, club
  WHERE upper(btrim(b.bidder_club_id)) = upper(club.sn)
    AND b.bid_time >= now() - interval '4 days'
),
bid_listing AS (
  SELECT
    mb.*,
    (
      SELECT l.id
      FROM public."Player_Transfer_Listings" l
      WHERE l.player_id::text = mb.pid
        AND lower(coalesce(l.listing_type, '')) = 'draft'
        AND l.created_at <= mb.bid_time + interval '1 minute'
      ORDER BY l.created_at DESC
      LIMIT 1
    ) AS draft_listing_id
  FROM my_bids mb
),
per_listing AS (
  SELECT
    bl.pid,
    bl.draft_listing_id,
    count(*) AS my_bid_count,
    max(bl.bid_amount) AS my_top_bid,
    max(bl.bid_time) AS my_last_bid,
    string_agg(DISTINCT coalesce(bl.status, '?'), ', ') AS my_bid_statuses,
    bool_or(coalesce(bl.is_direct, false)) AS any_direct
  FROM bid_listing bl
  GROUP BY bl.pid, bl.draft_listing_id
)
SELECT
  to_char(l.created_at AT TIME ZONE 'Europe/London', 'Dy DD Mon HH24:MI') AS listing_opened_uk,
  p."Name" AS player,
  pl.pid AS player_id,
  pl.draft_listing_id AS listing_id,
  l.status AS listing_status,
  l.transfer_completed,
  to_char(l.end_time AT TIME ZONE 'Europe/London', 'Dy DD Mon HH24:MI') AS listing_end_uk,
  pl.my_bid_count,
  pl.my_top_bid,
  to_char(pl.my_last_bid AT TIME ZONE 'Europe/London', 'Dy DD Mon HH24:MI:SS') AS my_last_bid_uk,
  pl.my_bid_statuses,
  top.bidder_club_id AS top_bidder_on_record,
  top.bid_amount AS top_bid_on_record,
  to_char(top.bid_time AT TIME ZONE 'Europe/London', 'Dy DD Mon HH24:MI:SS') AS top_bid_time_uk,
  l.current_highest_bidder AS listing_leader,
  l.current_highest_bid AS listing_high_bid,
  l.winning_club,
  l.winning_bid,
  signed.buyer_club_id AS signed_to,
  to_char(signed.transfer_time AT TIME ZONE 'Europe/London', 'Dy DD Mon HH24:MI') AS signed_uk,
  left_club.transfer_sale_note AS then_left_note,
  left_club.buyer_club_id AS then_left_to,
  to_char(left_club.transfer_time AT TIME ZONE 'Europe/London', 'Dy DD Mon HH24:MI') AS then_left_uk,
  p."Contracted_Team" AS player_club_now,
  coalesce(p.pesdb_unavailable, false) AS legacy_card,
  CASE
    WHEN pl.draft_listing_id IS NULL THEN 'Bid not linked to a draft listing (direct/transfer bid?)'
    WHEN signed.id IS NOT NULL AND left_club.id IS NOT NULL
      THEN 'Signed to you, then left: ' || coalesce(left_club.transfer_sale_note, 'sold/released')
    WHEN signed.id IS NOT NULL THEN 'Signed to you'
    WHEN l.status = 'Active' THEN 'Still live'
    WHEN other_signed.buyer_club_id IS NOT NULL THEN 'Signed by ' || other_signed.buyer_club_id
    WHEN upper(coalesce(l.winning_club, l.current_highest_bidder, '')) = upper(club.sn)
      THEN 'You were the leader but no signing on record — settlement skipped/failed'
    WHEN top.bidder_club_id IS NOT NULL AND upper(top.bidder_club_id) <> upper(club.sn)
      THEN 'Outbid by ' || top.bidder_club_id
    ELSE 'Closed — no winner recorded'
  END AS verdict
FROM per_listing pl
CROSS JOIN club
LEFT JOIN public."Player_Transfer_Listings" l ON l.id = pl.draft_listing_id
LEFT JOIN public."Players" p ON p."Konami_ID"::text = pl.pid
LEFT JOIN LATERAL (
  SELECT x.bidder_club_id, x.bid_amount, x.bid_time
  FROM public."Player_Transfer_Bids" x
  WHERE coalesce(x.player_id::text, x.direct_bid_id::text) = pl.pid
    AND x.bid_time >= coalesce(l.created_at, now() - interval '4 days')
    AND (l.end_time IS NULL OR x.bid_time <= l.end_time + interval '1 day')
  ORDER BY x.bid_amount DESC, x.bid_time ASC
  LIMIT 1
) top ON true
LEFT JOIN LATERAL (
  SELECT h.*
  FROM public."Transfer_History" h
  WHERE h.player_id::text = pl.pid
    AND upper(coalesce(h.buyer_club_id, '')) = upper(club.sn)
    AND h.transfer_time >= coalesce(l.created_at, now() - interval '4 days')
  ORDER BY h.transfer_time
  LIMIT 1
) signed ON true
LEFT JOIN LATERAL (
  SELECT h.*
  FROM public."Transfer_History" h
  WHERE h.player_id::text = pl.pid
    AND upper(coalesce(h.seller_club_id, '')) = upper(club.sn)
    AND signed.id IS NOT NULL
    AND h.transfer_time >= signed.transfer_time
  ORDER BY h.transfer_time
  LIMIT 1
) left_club ON true
LEFT JOIN LATERAL (
  SELECT h.buyer_club_id
  FROM public."Transfer_History" h
  WHERE h.player_id::text = pl.pid
    AND upper(coalesce(h.buyer_club_id, '')) <> upper(club.sn)
    AND h.transfer_time >= coalesce(l.created_at, now() - interval '4 days')
  ORDER BY h.transfer_time
  LIMIT 1
) other_signed ON true
ORDER BY l.created_at NULLS LAST, p."Name";


-- Q2 ---------------------------------------------------------------------------
WITH club AS (
  SELECT c."ShortName" AS sn
  FROM public."Clubs" c
  WHERE c."Club" ILIKE '%zvezda%' OR c."Club" ILIKE '%red star%'
  LIMIT 1
)
SELECT
  to_char(h.transfer_time AT TIME ZONE 'Europe/London', 'Dy DD Mon HH24:MI:SS') AS when_uk,
  p."Name" AS player,
  h.player_id,
  coalesce(h.seller_club_id, '(free agent / draft)') AS from_club,
  h.buyer_club_id AS to_club,
  h.fee,
  h.transfer_sale_note,
  h.listing_id,
  h.id AS history_id
FROM public."Transfer_History" h
CROSS JOIN club
LEFT JOIN public."Players" p ON p."Konami_ID"::text = h.player_id::text
WHERE h.transfer_time >= now() - interval '4 days'
  AND (upper(coalesce(h.buyer_club_id, '')) = upper(club.sn)
       OR upper(coalesce(h.seller_club_id, '')) = upper(club.sn))
ORDER BY h.transfer_time;


-- Q3 ---------------------------------------------------------------------------
WITH club AS (
  SELECT c."ShortName" AS sn
  FROM public."Clubs" c
  WHERE c."Club" ILIKE '%zvezda%' OR c."Club" ILIKE '%red star%'
  LIMIT 1
)
SELECT 'max_bid' AS source, p."Name" AS player, to_jsonb(mb) AS detail
FROM public.player_draft_max_bids mb
CROSS JOIN club
LEFT JOIN public."Players" p ON p."Konami_ID"::text = mb.player_id::text
WHERE upper(mb.club_short_name) = upper(club.sn)
UNION ALL
SELECT 'autobid_plan_target', p."Name",
       to_jsonb(t) || jsonb_build_object('plan_status', pl.status, 'plan_id', pl.id)
FROM public.player_draft_autobid_plans pl
JOIN public.player_draft_autobid_targets t ON t.plan_id = pl.id
CROSS JOIN club
LEFT JOIN public."Players" p ON p."Konami_ID"::text = t.player_id::text
WHERE upper(pl.club_short_name) = upper(club.sn)
ORDER BY 1, 2;


-- Q4 ---------------------------------------------------------------------------
WITH club AS (
  SELECT c."ShortName" AS sn
  FROM public."Clubs" c
  WHERE c."Club" ILIKE '%zvezda%' OR c."Club" ILIKE '%red star%'
  LIMIT 1
)
SELECT
  to_char(l.created_at AT TIME ZONE 'Europe/London', 'Dy DD Mon HH24:MI:SS') AS when_uk,
  l.entry_type,
  l.amount,
  l.description
FROM public.competition_finance_ledger l
CROSS JOIN club
WHERE l.club_short_name = club.sn
  AND l.created_at >= now() - interval '4 days'
ORDER BY l.created_at;


-- Q5: the Fri 9 Oct 19:00 → Sat 10 Oct 19:00 (UK) draft only ---------------
WITH club AS (
  SELECT c."ShortName" AS sn
  FROM public."Clubs" c
  WHERE c."Club" ILIKE '%zvezda%' OR c."Club" ILIKE '%red star%'
  LIMIT 1
),
win AS (
  SELECT (timestamp '2026-10-09 19:00' AT TIME ZONE 'Europe/London') AS s,
         (timestamp '2026-10-10 19:00' AT TIME ZONE 'Europe/London') AS e
),
mine AS (
  SELECT coalesce(b.player_id::text, b.direct_bid_id::text) AS pid,
         count(*) AS my_bids,
         max(b.bid_amount) AS my_top_bid,
         max(b.bid_time) AS my_last_bid,
         string_agg(DISTINCT coalesce(b.status, '?'), ', ') AS my_statuses
  FROM public."Player_Transfer_Bids" b, club, win
  WHERE upper(btrim(b.bidder_club_id)) = upper(club.sn)
    AND b.bid_time >= win.s AND b.bid_time < win.e
  GROUP BY 1
)
SELECT
  p."Name" AS player,
  m.pid AS player_id,
  m.my_bids,
  m.my_top_bid,
  to_char(m.my_last_bid AT TIME ZONE 'Europe/London', 'Dy HH24:MI:SS') AS my_last_bid_uk,
  m.my_statuses,
  top.bidder_club_id AS highest_bidder,
  top.bid_amount AS highest_bid,
  to_char(top.bid_time AT TIME ZONE 'Europe/London', 'Dy HH24:MI:SS') AS highest_bid_uk,
  l.id AS listing_id,
  l.status AS listing_status,
  l.current_highest_bidder AS listing_leader,
  l.winning_club,
  h.buyer_club_id AS signed_to,
  to_char(h.transfer_time AT TIME ZONE 'Europe/London', 'Dy HH24:MI') AS signed_uk,
  h.transfer_sale_note,
  p."Contracted_Team" AS player_club_now,
  coalesce(p.pesdb_unavailable, false) AS legacy_card,
  CASE
    WHEN upper(coalesce(h.buyer_club_id, '')) = upper(club.sn) THEN 'Signed to him'
    WHEN h.buyer_club_id IS NOT NULL THEN 'Signed by ' || h.buyer_club_id
    WHEN upper(coalesce(top.bidder_club_id, '')) = upper(club.sn)
      THEN 'He was highest bidder — NOT signed (settlement problem)'
    WHEN top.bidder_club_id IS NOT NULL THEN 'Outbid by ' || top.bidder_club_id
    ELSE 'No outcome recorded'
  END AS verdict
FROM mine m
CROSS JOIN club
CROSS JOIN win
LEFT JOIN public."Players" p ON p."Konami_ID"::text = m.pid
LEFT JOIN LATERAL (
  SELECT x.bidder_club_id, x.bid_amount, x.bid_time
  FROM public."Player_Transfer_Bids" x
  WHERE coalesce(x.player_id::text, x.direct_bid_id::text) = m.pid
    AND x.bid_time >= win.s AND x.bid_time < win.e
  ORDER BY x.bid_amount DESC, x.bid_time ASC
  LIMIT 1
) top ON true
LEFT JOIN LATERAL (
  SELECT l.*
  FROM public."Player_Transfer_Listings" l
  WHERE l.player_id::text = m.pid
    AND lower(coalesce(l.listing_type, '')) = 'draft'
    AND l.created_at < win.e
  ORDER BY l.created_at DESC
  LIMIT 1
) l ON true
LEFT JOIN LATERAL (
  SELECT h.*
  FROM public."Transfer_History" h
  WHERE h.player_id::text = m.pid
    AND h.transfer_time >= win.s
    AND h.seller_club_id IS NULL
  ORDER BY h.transfer_time
  LIMIT 1
) h ON true
ORDER BY verdict, p."Name";

