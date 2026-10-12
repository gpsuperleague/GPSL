-- =============================================================================
-- READ-ONLY: matjaz (Crvena zvezda) — 7 draft players he led on Sat 10 Oct
-- (bids/max bids set Sat 12:00–12:40 UK; draft closed Sat ~19:00 UK)
--
--   Filip Stanković · Adrian Barišić · Milos Kerkez · Andrej Bacanin
--   Mateo Kovačić · S. Milinković-Savić · Luka Topalović
--
-- One row per player: blockers (legacy card / exclusions), his bids, the top
-- bid, every draft listing since Fri 9 Oct and how it closed, signing record,
-- and his max bids now. Last column = verdict.
-- =============================================================================

WITH club AS (
  SELECT c."ShortName" AS sn
  FROM public."Clubs" c
  WHERE c."Club" ILIKE '%zvezda%' OR c."Club" ILIKE '%red star%'
  LIMIT 1
),
win AS (
  SELECT (timestamp '2026-10-09 19:00' AT TIME ZONE 'Europe/London') AS s
),
targets AS (
  SELECT p.*
  FROM public."Players" p
  WHERE p."Name" ILIKE ANY (ARRAY[
    '%Stankovi%', '%Bari_i%', '%Kerkez%', '%Bacanin%',
    '%Kova_i%', '%Milinkovi%', '%Topalovi%'
  ])
),
my_bids AS (
  SELECT coalesce(b.player_id::text, b.direct_bid_id::text) AS pid,
         count(*) AS n,
         max(b.bid_amount) AS top_amt,
         min(b.bid_time) AS first_at,
         max(b.bid_time) AS last_at,
         string_agg(DISTINCT coalesce(b.status, '?'), ',') AS statuses,
         string_agg(DISTINCT coalesce(b.listing_id::text, 'null'), ',') AS listing_ids
  FROM public."Player_Transfer_Bids" b, club, win
  WHERE upper(btrim(b.bidder_club_id)) = upper(club.sn)
    AND b.bid_time >= win.s
  GROUP BY 1
)
SELECT
  t."Name" AS player,
  t."Konami_ID" AS player_id,
  t."Contracted_Team" AS club_now,
  coalesce(t.pesdb_unavailable, false) AS legacy_card,
  to_char(t.pesdb_unavailable_since AT TIME ZONE 'Europe/London', 'Dy DD Mon HH24:MI') AS legacy_since_uk,
  public.gpdb_player_is_season_excluded(t."Konami_ID"::text) AS season_excluded,
  public.auction_player_is_excluded(t."Konami_ID"::text) AS auction_excluded,
  mb.n AS his_bids,
  mb.top_amt AS his_top_bid,
  to_char(mb.first_at AT TIME ZONE 'Europe/London', 'Dy HH24:MI') AS his_first_bid_uk,
  to_char(mb.last_at AT TIME ZONE 'Europe/London', 'Dy HH24:MI') AS his_last_bid_uk,
  mb.statuses AS his_bid_statuses,
  mb.listing_ids AS his_bid_listing_ids,
  top.bidder_club_id AS top_bidder,
  top.bid_amount AS top_bid,
  (SELECT string_agg(
            format('#%s %s %s→%s lead=%s won=%s done=%s',
                   l.id, l.status,
                   to_char(l.created_at AT TIME ZONE 'Europe/London', 'DyHH24:MI'),
                   to_char(l.end_time AT TIME ZONE 'Europe/London', 'DyHH24:MI'),
                   coalesce(l.current_highest_bidder, '-'),
                   coalesce(l.winning_club, '-'),
                   coalesce(l.transfer_completed::text, '-')),
            ' | ' ORDER BY l.id)
   FROM public."Player_Transfer_Listings" l, win
   WHERE btrim(l.player_id::text) = t."Konami_ID"::text
     AND lower(coalesce(l.listing_type, '')) = 'draft'
     AND l.created_at >= win.s - interval '1 day') AS draft_listings,
  (SELECT string_agg(format('%s→%s %s', coalesce(h.seller_club_id, 'FA'), h.buyer_club_id,
                            to_char(h.transfer_time AT TIME ZONE 'Europe/London', 'DyHH24:MI')), ' | ')
   FROM public."Transfer_History" h, win
   WHERE h.player_id::text = t."Konami_ID"::text AND h.transfer_time >= win.s) AS moves_since_fri,
  (SELECT string_agg(to_jsonb(m)::text, ' | ')
   FROM public.player_draft_max_bids m, club
   WHERE btrim(m.player_id) = t."Konami_ID"::text
     AND upper(m.club_short_name) = upper(club.sn)) AS his_max_bid_now,
  CASE
    WHEN coalesce(t.pesdb_unavailable, false)
      THEN 'LEGACY CARD — auction closed unsold, signing + new bids blocked'
    WHEN public.gpdb_player_is_season_excluded(t."Konami_ID"::text)
      THEN 'SEASON EXCLUDED — auction closed unsold'
    WHEN public.auction_player_is_excluded(t."Konami_ID"::text)
      THEN 'AUCTION EXCLUDED — bids blocked'
    WHEN nullif(btrim(coalesce(t."Contracted_Team"::text, '')), '') IS NOT NULL
      THEN 'Now at ' || t."Contracted_Team"
    WHEN mb.n IS NULL THEN 'No bids from him on record since Fri 19:00'
    WHEN upper(coalesce(top.bidder_club_id, '')) = upper((SELECT sn FROM club))
      THEN 'He was top bidder — not signed (settlement skipped / failed)'
    ELSE 'Outbid by ' || coalesce(top.bidder_club_id, '?')
  END AS verdict
FROM targets t
CROSS JOIN win
LEFT JOIN my_bids mb ON mb.pid = t."Konami_ID"::text
LEFT JOIN LATERAL (
  SELECT x.bidder_club_id, x.bid_amount
  FROM public."Player_Transfer_Bids" x
  WHERE coalesce(x.player_id::text, x.direct_bid_id::text) = t."Konami_ID"::text
    AND x.bid_time >= win.s
  ORDER BY x.bid_amount DESC, x.bid_time ASC
  LIMIT 1
) top ON true
ORDER BY t."Name";
