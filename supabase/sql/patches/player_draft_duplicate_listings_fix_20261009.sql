-- =============================================================================
-- Draft: one live auction per player (2026-10-09)
-- =============================================================================
-- Two bids landing together on a player with no auction yet (manual bid + max-bid
-- reply, or two clubs opening at once) could both see "no listing" and both open
-- one, so e.g. Romano / Pisilli had 3 Active draft listings, each with its own
-- random end time.
--
--   1) Merge: per player keep the oldest Active draft listing (the one
--      player_draft_ensure_listing returns), move bids onto it, close the rest,
--      resync leader/amount from the true top draft bid.
--   2) player_draft_ensure_listing takes a per-player lock before looking.
--   3) Unique index: at most one Active draft listing per player.
-- Safe re-run.
-- =============================================================================

DROP TABLE IF EXISTS _draft_dupes;
CREATE TEMP TABLE _draft_dupes AS
SELECT
  l.player_id::text AS player_id,
  min(l.id) AS keep_id,
  array_agg(l.id ORDER BY l.id) FILTER (WHERE l.id <> (
    SELECT min(x.id) FROM public."Player_Transfer_Listings" x
    WHERE x.player_id::text = l.player_id::text
      AND x.listing_type = 'draft' AND x.status = 'Active'
  )) AS extra_ids
FROM public."Player_Transfer_Listings" l
WHERE l.listing_type = 'draft'
  AND l.status = 'Active'
GROUP BY l.player_id::text
HAVING count(*) > 1;

-- 1a) bids → keeper
UPDATE public."Player_Transfer_Bids" b
SET listing_id = d.keep_id
FROM _draft_dupes d
WHERE b.listing_id = ANY (d.extra_ids);

-- 1b) close extras
UPDATE public."Player_Transfer_Listings" l
SET status = 'Closed',
    transfer_completed = false
FROM _draft_dupes d
WHERE l.id = ANY (d.extra_ids);

-- 1c) keeper leader = true top draft bid in this window
WITH bounds AS (
  SELECT * FROM public.draft_auction_window_bounds()
),
top AS (
  SELECT DISTINCT ON (d.player_id)
    d.player_id, d.keep_id, b.bid_amount, b.bidder_club_id
  FROM _draft_dupes d
  CROSS JOIN bounds w
  JOIN public."Player_Transfer_Bids" b
    ON coalesce(b.player_id, b.direct_bid_id::text) = d.player_id
   AND b.is_direct = true
   AND b.seller_club_id IS NULL
   AND b.bid_time >= w.draft_start
   AND b.bid_time < w.draft_window_end
  ORDER BY d.player_id, b.bid_amount DESC, b.bid_time ASC
)
UPDATE public."Player_Transfer_Listings" l
SET current_highest_bid = t.bid_amount,
    current_highest_bidder = t.bidder_club_id
FROM top t
WHERE l.id = t.keep_id;

-- 2) Lock per player while finding / opening the thread
CREATE OR REPLACE FUNCTION public.player_draft_ensure_listing(p_player_id text)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_pid text := btrim(p_player_id);
  v_id bigint;
  v_mv numeric;
  v_club text;
  v_legacy boolean;
  v_start timestamptz;
  v_end timestamptz;
  v_name text;
BEGIN
  IF v_pid IS NULL OR v_pid = '' THEN
    RAISE EXCEPTION 'Player id is required';
  END IF;

  IF auth.uid() IS NOT NULL
     AND NOT public.is_gpsl_admin()
     AND nullif(btrim(coalesce(public.my_club_shortname(), '')), '') IS NULL THEN
    RAISE EXCEPTION 'You must own a club to start draft auctions';
  END IF;

  -- Concurrent first bids on the same player must not each open a thread
  PERFORM pg_advisory_xact_lock(hashtext('player_draft_listing:' || v_pid));

  SELECT l.id INTO v_id
  FROM public."Player_Transfer_Listings" l
  WHERE l.player_id = v_pid
    AND l.listing_type = 'draft'
    AND l.status = 'Active'
  ORDER BY l.id
  LIMIT 1;

  IF v_id IS NOT NULL THEN
    IF EXISTS (
      SELECT 1 FROM public."Players" p
      WHERE p."Konami_ID"::text = v_pid
        AND coalesce(p.pesdb_unavailable, false)
    ) THEN
      RAISE EXCEPTION
        'This player card is no longer on pesdb.net (legacy card). It cannot be bid on until it returns on a PESDB sync.';
    END IF;
    RETURN v_id;
  END IF;

  SELECT
    p.market_value,
    nullif(btrim(p."Contracted_Team"::text), ''),
    coalesce(p.pesdb_unavailable, false),
    p."Name"
  INTO v_mv, v_club, v_legacy, v_name
  FROM public."Players" p
  WHERE p."Konami_ID"::text = v_pid;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Player not found';
  END IF;

  IF coalesce(v_legacy, false) THEN
    RAISE EXCEPTION
      'This player card is no longer on pesdb.net (legacy card). It cannot be bid on until it returns on a PESDB sync.';
  END IF;

  IF v_club IS NOT NULL THEN
    RAISE EXCEPTION '% is under contract at % and cannot open a draft auction',
      coalesce(v_name, 'Player'), v_club;
  END IF;

  IF to_regprocedure('public.auction_player_is_excluded(text)') IS NOT NULL
     AND public.auction_player_is_excluded(v_pid) THEN
    RAISE EXCEPTION 'Player is reserved for special auctions and cannot be bid on in the draft';
  END IF;

  IF to_regprocedure('public.assert_player_available_for_signing(text)') IS NOT NULL THEN
    PERFORM public.assert_player_available_for_signing(v_pid);
  END IF;

  IF to_regprocedure('public.assert_player_transferable(text)') IS NOT NULL THEN
    PERFORM public.assert_player_transferable(v_pid);
  END IF;

  SELECT draft_auction_start_time INTO v_start
  FROM public.global_settings WHERE id = 1;

  v_end := coalesce(v_start, now()) + interval '23 hours 50 minutes'
    + (floor(random() * 600)::int || ' seconds')::interval;

  PERFORM set_config('gpsl.bypass_bid_owner_check', 'on', true);

  INSERT INTO public."Player_Transfer_Listings" (
    player_id, seller_club_id, reserve_price, listing_type, market_value,
    status, start_time, end_time, initial_end_time, created_at
  )
  VALUES (
    v_pid, NULL, coalesce(v_mv, 0), 'draft', coalesce(v_mv, 0),
    'Active', coalesce(v_start, now()), v_end, v_end, now()
  )
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$function$;

REVOKE ALL ON FUNCTION public.player_draft_ensure_listing(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.player_draft_ensure_listing(text) TO authenticated;

-- 3) Hard rule: one live draft auction per player
CREATE UNIQUE INDEX IF NOT EXISTS player_transfer_listings_one_active_draft_uidx
  ON public."Player_Transfer_Listings" (player_id)
  WHERE listing_type = 'draft' AND status = 'Active';

NOTIFY pgrst, 'reload schema';

-- Report
SELECT
  p."Name" AS player,
  d.keep_id AS kept_listing,
  d.extra_ids AS closed_listings,
  l.current_highest_bidder AS leader_now,
  l.current_highest_bid AS top_bid_now,
  (SELECT count(*) FROM public."Player_Transfer_Listings" x
   WHERE x.player_id::text = d.player_id AND x.listing_type = 'draft' AND x.status = 'Active') AS active_now
FROM _draft_dupes d
LEFT JOIN public."Players" p ON p."Konami_ID"::text = d.player_id
LEFT JOIN public."Player_Transfer_Listings" l ON l.id = d.keep_id
ORDER BY p."Name";
