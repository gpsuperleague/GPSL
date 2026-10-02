-- =============================================================================
-- Diagnose how an owner's club auction bids were placed (read-only).
--
-- Club_Auction_Bids has no "source" or IP column, but every bid written in one
-- transaction shares the same now() timestamp, so:
--   * Same bid_time as ANOTHER owner's bid on that club  -> auto max-bid reply
--   * Same bid_time as the owner's club_auction_max_bids.updated_at
--                                                       -> placed instantly by
--                                                          "Set max"
--   * Otherwise                                         -> manual "Submit bid"
--                                                          (or an admin repair)
--
-- IP comes from owner_login_origin_events (recorded at login / session restore),
-- so it shows the login sessions either side of the bid, not the bid request.
--
-- Run each statement separately in the Supabase SQL Editor (it only shows the
-- last result). Change the tag / club filter at the top of each if needed.
-- =============================================================================

-- 1) Vardy_np's bids on PSG: time (UK), likely source, nearest login IPs either side
WITH target AS (
  SELECT r.owner_id FROM public.gpsl_owner_registry r
  WHERE lower(btrim(r.owner_tag)) = lower('vardy_np')
),
bids AS (
  SELECT b.*
  FROM public."Club_Auction_Bids" b
  JOIN target t ON t.owner_id = b.bidder_owner_id
  LEFT JOIN public."Clubs" c ON c."ShortName" = b.club_short_name
  WHERE b.club_short_name ILIKE 'PSG%'
     OR c."Club" ILIKE '%paris%'
     OR c."Club" ILIKE '%PSG%'
)
SELECT
  b.id                                                     AS bid_id,
  b.club_short_name,
  b.bid_amount,
  b.bid_time AT TIME ZONE 'Europe/London'                  AS bid_time_uk,
  CASE
    WHEN EXISTS (
      SELECT 1 FROM public."Club_Auction_Bids" o
      WHERE o.listing_id = b.listing_id AND o.bid_time = b.bid_time
        AND o.bidder_owner_id <> b.bidder_owner_id
    ) THEN 'AUTO — max bid replying to another owner''s bid'
    WHEN EXISTS (
      SELECT 1 FROM public.club_auction_max_bids m
      WHERE m.owner_id = b.bidder_owner_id
        AND upper(m.club_short_name) = upper(b.club_short_name)
        AND m.updated_at = b.bid_time
    ) THEN 'SET MAX — placed immediately when a max bid was set'
    ELSE 'MANUAL — Submit bid (or admin repair)'
  END                                                      AS likely_source,
  prev.logged_in_at AT TIME ZONE 'Europe/London'           AS login_before_uk,
  prev.ip_address                                          AS ip_before,
  prev.country_code                                        AS country_before,
  prev.user_agent                                          AS browser_before,
  nxt.logged_in_at AT TIME ZONE 'Europe/London'            AS login_after_uk,
  nxt.ip_address                                           AS ip_after,
  nxt.country_code                                         AS country_after,
  nxt.user_agent                                           AS browser_after
FROM bids b
LEFT JOIN LATERAL (
  SELECT e.* FROM public.owner_login_origin_events e
  WHERE e.owner_id = b.bidder_owner_id AND e.logged_in_at <= b.bid_time
  ORDER BY e.logged_in_at DESC LIMIT 1
) prev ON true
LEFT JOIN LATERAL (
  SELECT e.* FROM public.owner_login_origin_events e
  WHERE e.owner_id = b.bidder_owner_id AND e.logged_in_at > b.bid_time
  ORDER BY e.logged_in_at ASC LIMIT 1
) nxt ON true
ORDER BY b.bid_time;


-- 1b) Leftover max bids: was Vardy_np's PSG max set BEFORE the current listing
--     opened (i.e. carried over from a test auction)?
SELECT
  m.club_short_name,
  m.max_amount,
  m.updated_at AT TIME ZONE 'Europe/London' AS max_set_uk,
  l.created_at AT TIME ZONE 'Europe/London' AS listing_opened_uk,
  (m.updated_at < l.created_at)             AS left_over_from_earlier_auction
FROM public.club_auction_max_bids m
JOIN public.gpsl_owner_registry r ON r.owner_id = m.owner_id
LEFT JOIN public."Club_Auction_Listings" l
  ON upper(l.club_short_name) = upper(m.club_short_name) AND l.status = 'Active'
WHERE lower(btrim(r.owner_tag)) = lower('vardy_np')
ORDER BY m.updated_at;


-- 2) Vardy_np's login IP history (last 30 days) — spot unfamiliar IPs/countries/browsers
SELECT
  e.logged_in_at AT TIME ZONE 'Europe/London' AS logged_in_uk,
  e.ip_address,
  e.country_code,
  e.user_agent,
  e.source
FROM public.owner_login_origin_events e
JOIN public.gpsl_owner_registry r ON r.owner_id = e.owner_id
WHERE lower(btrim(r.owner_tag)) = lower('vardy_np')
  AND e.logged_in_at > now() - interval '30 days'
ORDER BY e.logged_in_at DESC;


-- 3) Other owner accounts that have logged in from any of Vardy_np's IPs
SELECT
  coalesce(r2.owner_tag, e2.owner_id::text) AS other_owner,
  e2.ip_address,
  count(*)                                  AS logins_from_ip,
  max(e2.logged_in_at) AT TIME ZONE 'Europe/London' AS last_seen_uk
FROM public.owner_login_origin_events e2
LEFT JOIN public.gpsl_owner_registry r2 ON r2.owner_id = e2.owner_id
WHERE e2.ip_address_norm IN (
  SELECT e.ip_address_norm
  FROM public.owner_login_origin_events e
  JOIN public.gpsl_owner_registry r ON r.owner_id = e.owner_id
  WHERE lower(btrim(r.owner_tag)) = lower('vardy_np')
    AND e.ip_address_norm IS NOT NULL
)
AND e2.owner_id NOT IN (
  SELECT owner_id FROM public.gpsl_owner_registry
  WHERE lower(btrim(owner_tag)) = lower('vardy_np')
)
GROUP BY 1, 2
ORDER BY last_seen_uk DESC;


-- 4) Full PSG bid history (context: who bid when, in UK time)
SELECT
  b.bid_time AT TIME ZONE 'Europe/London' AS bid_time_uk,
  coalesce(r.owner_tag, b.bidder_owner_id::text) AS bidder,
  b.bid_amount
FROM public."Club_Auction_Bids" b
LEFT JOIN public.gpsl_owner_registry r ON r.owner_id = b.bidder_owner_id
LEFT JOIN public."Clubs" c ON c."ShortName" = b.club_short_name
WHERE b.club_short_name ILIKE 'PSG%' OR c."Club" ILIKE '%paris%'
ORDER BY b.bid_time;


-- 5) Optional: Supabase auth audit log IPs for the account around that time
--    (only if your project keeps auth audit logs; empty result is normal)
SELECT
  a.created_at AT TIME ZONE 'Europe/London' AS at_uk,
  a.ip_address,
  a.payload ->> 'action' AS action
FROM auth.audit_log_entries a
WHERE a.payload ->> 'actor_id' = (
  SELECT owner_id::text FROM public.gpsl_owner_registry
  WHERE lower(btrim(owner_tag)) = lower('vardy_np') LIMIT 1
)
ORDER BY a.created_at DESC
LIMIT 50;
