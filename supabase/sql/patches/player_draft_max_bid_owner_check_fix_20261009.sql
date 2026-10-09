-- =============================================================================
-- Fix: draft max bids (bid modal) not answering a rival's manual bid
-- =============================================================================
-- When club A bids manually, the max-bid trigger runs inside A's session and
-- places club B's counter-bid. player_transfer_bids_00_require_owned_club then
-- saw "A inserting a bid for B" and raised 'bidder_club_id must be your own
-- club'. The resolver swallowed the error, so B's max bid silently did nothing.
-- The owner-check bypass was only set when a NEW thread was opened (inside
-- player_draft_ensure_listing), never for existing threads. Cron / auto-bid
-- plans were unaffected (no logged-in user), which is why plan targets worked.
--
-- Fix: player_draft_place_auto_bid sets the transaction-local bypass for its
-- own insert, then switches it off again. Then a one-off catch-up runs every
-- max bid that should already have answered.
--
-- Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.player_draft_place_auto_bid(
  p_club_short_name text,
  p_player_id text,
  p_amount numeric
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_pid text := btrim(p_player_id);
  v_listing_id bigint;
  v_bounds record;
  v_has_bids boolean;
  v_has_mine boolean;
  v_is_first boolean;
  v_is_join boolean;
  v_consume boolean := false;
  v_credits int;
  v_leader text;
  v_min numeric;
BEGIN
  SELECT * INTO v_bounds FROM public.draft_auction_window_bounds();
  IF NOT v_bounds.draft_enabled OR v_bounds.draft_start IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'skipped', 'disabled');
  END IF;
  IF now() < v_bounds.draft_start OR now() >= v_bounds.draft_window_end THEN
    RETURN jsonb_build_object('ok', false, 'skipped', 'window_closed');
  END IF;

  v_min := public.player_draft_min_next_bid(v_pid);
  IF p_amount < v_min THEN
    RETURN jsonb_build_object('ok', true, 'skipped', 'below_min');
  END IF;

  SELECT b.bidder_club_id INTO v_leader
  FROM public."Player_Transfer_Bids" b
  WHERE coalesce(b.player_id, b.direct_bid_id::text) = v_pid
    AND b.is_direct = true
    AND b.seller_club_id IS NULL
    AND b.bid_time >= v_bounds.draft_start
    AND b.bid_time < v_bounds.draft_window_end
  ORDER BY b.bid_amount DESC, b.bid_time DESC
  LIMIT 1;

  IF v_leader IS NOT DISTINCT FROM p_club_short_name THEN
    RETURN jsonb_build_object('ok', true, 'skipped', 'already_leading');
  END IF;

  v_has_bids := v_leader IS NOT NULL;
  v_has_mine := public.player_draft_club_has_bid(p_club_short_name, v_pid);

  IF NOT v_has_bids THEN
    IF now() >= v_bounds.draft_cutoff THEN
      RETURN jsonb_build_object('ok', false, 'skipped', 'cutoff');
    END IF;
    v_is_first := true;
    v_is_join := false;
  ELSIF v_has_mine THEN
    v_is_first := false;
    v_is_join := EXISTS (
      SELECT 1 FROM public."Player_Transfer_Bids" b
      WHERE b.bidder_club_id = p_club_short_name
        AND coalesce(b.player_id, b.direct_bid_id::text) = v_pid
        AND b.is_draft_join = true
        AND b.bid_time >= v_bounds.draft_start
    );
  ELSE
    v_is_first := false;
    v_is_join := true;
    v_credits := public.club_draft_auction_credits(
      p_club_short_name,
      v_bounds.draft_start,
      v_bounds.draft_cutoff,
      v_bounds.draft_window_end
    );
    IF v_credits <= 0 THEN
      RETURN jsonb_build_object(
        'ok', false,
        'skipped', 'no_credits',
        'msg', 'Not enough draft credits to join this auction.'
      );
    END IF;
    v_consume := true;
  END IF;

  v_listing_id := public.player_draft_ensure_listing(v_pid);

  -- Proxy bid on behalf of p_club_short_name (may run in a rival's session)
  PERFORM set_config('gpsl.bypass_bid_owner_check', 'on', true);

  -- player_id holds Konami id (text). direct_bid_id is integer legacy — leave NULL.
  INSERT INTO public."Player_Transfer_Bids" (
    listing_id, player_id, direct_bid_id, bidder_club_id, seller_club_id,
    bid_amount, is_direct, is_first_draft_bid, is_draft_join, draft_join_consumed, bid_time
  )
  VALUES (
    v_listing_id, v_pid, NULL, p_club_short_name, NULL,
    p_amount, true, v_is_first, v_is_join, v_consume, now()
  );

  PERFORM set_config('gpsl.bypass_bid_owner_check', 'off', true);

  UPDATE public."Player_Transfer_Listings"
  SET current_highest_bid = p_amount,
      current_highest_bidder = p_club_short_name
  WHERE id = v_listing_id;

  RETURN jsonb_build_object('ok', true, 'bid_amount', p_amount, 'auto', true);
END;
$function$;

REVOKE ALL ON FUNCTION public.player_draft_place_auto_bid(text, text, numeric) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.player_draft_place_auto_bid(text, text, numeric) TO authenticated;

-- ---------------------------------------------------------------------------
-- Catch-up: answer every max bid that is currently outbid but still in range
-- ---------------------------------------------------------------------------
CREATE TEMP TABLE IF NOT EXISTS _gpsl_max_bid_catchup (player text, bids_placed int, leader_now text)
  ON COMMIT PRESERVE ROWS;
TRUNCATE _gpsl_max_bid_catchup;

DO $catchup$
DECLARE
  b record;
  r record;
  v_n int;
  v_leader text;
BEGIN
  SELECT * INTO b FROM public.draft_auction_window_bounds();
  IF NOT coalesce(b.draft_enabled, false) OR b.draft_start IS NULL
     OR now() < b.draft_start OR now() >= b.draft_window_end THEN
    RETURN;
  END IF;

  FOR r IN
    SELECT DISTINCT mb.player_id
    FROM public.player_draft_max_bids mb
    WHERE mb.max_amount >= coalesce(public.player_draft_min_next_bid(mb.player_id), mb.max_amount + 1)
  LOOP
    PERFORM set_config('gpsl.max_bid_resolving', '', true);
    BEGIN
      v_n := public.player_draft_resolve_max_bids(r.player_id);
    EXCEPTION WHEN OTHERS THEN
      v_n := -1;
    END;

    IF coalesce(v_n, 0) <> 0 THEN
      SELECT x.bidder_club_id INTO v_leader
      FROM public."Player_Transfer_Bids" x
      WHERE coalesce(x.player_id, x.direct_bid_id::text) = r.player_id
        AND x.is_direct AND x.seller_club_id IS NULL
        AND x.bid_time >= b.draft_start AND x.bid_time < b.draft_window_end
      ORDER BY x.bid_amount DESC, x.bid_time DESC
      LIMIT 1;

      INSERT INTO _gpsl_max_bid_catchup
      SELECT coalesce(p."Name", r.player_id), v_n, v_leader
      FROM (SELECT 1) one
      LEFT JOIN public."Players" p ON p."Konami_ID"::text = r.player_id;
    END IF;
  END LOOP;
END
$catchup$;

SELECT
  c.*,
  (SELECT count(*) FROM _gpsl_max_bid_catchup) AS players_caught_up,
  pg_get_functiondef('public.player_draft_place_auto_bid(text,text,numeric)'::regprocedure)
    ILIKE '%bypass_bid_owner_check%' AS fix_installed
FROM _gpsl_max_bid_catchup c
UNION ALL
SELECT NULL, NULL, NULL,
  0,
  pg_get_functiondef('public.player_draft_place_auto_bid(text,text,numeric)'::regprocedure)
    ILIKE '%bypass_bid_owner_check%'
WHERE NOT EXISTS (SELECT 1 FROM _gpsl_max_bid_catchup);
