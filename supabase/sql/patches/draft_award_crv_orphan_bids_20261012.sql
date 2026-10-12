-- =============================================================================
-- Award matjaz (CRV) the draft players he won on Sat 10 Oct (2026-10-12)
-- =============================================================================
-- His Saturday bids (placed via max bid, 12:24–12:34 UK) were saved without a
-- draft auction (listing_id NULL) and no auction was ever opened, so the 7pm
-- settlement had nothing to settle. He was the only bidder on each.
--
-- For each player below that is still a free agent:
--   1) open a draft listing for the Fri 9 Oct 19:00 → Sat 10 Oct 18:55 window
--      with CRV as leader at his bid,
--   2) attach his bid to it,
--   3) settle it through transferengine_accept_draft_sale (normal draft
--      signing: contract, Transfer_History, ledger charge),
--   4) clear his stale max bid on that player.
--
-- Mateo Kovačić (43135) is NOT included: TIG won him in Sunday's auction.
-- Add 43135 to v_players only if you decide to reverse that.
--
-- Safe re-run: players already contracted are skipped.
-- =============================================================================

CREATE TEMP TABLE IF NOT EXISTS _crv_award (
  player_id text, player text, amount numeric, listing_id bigint, result text
) ON COMMIT PRESERVE ROWS;
TRUNCATE _crv_award;

DO $award$
DECLARE
  v_players text[] := ARRAY['135365','152162','146650','178388','16886591','170983'];
  v_club    text := 'CRV';
  v_from    timestamptz := timestamp '2026-10-09 19:00' AT TIME ZONE 'Europe/London';
  v_to      timestamptz := timestamp '2026-10-10 19:00' AT TIME ZONE 'Europe/London';
  v_end     timestamptz := timestamp '2026-10-10 18:55' AT TIME ZONE 'Europe/London';
  v_pid     text;
  v_bid     record;
  v_p       record;
  v_lid     bigint;
  v_team    text;
BEGIN
  PERFORM set_config('gpsl.bypass_bid_owner_check', 'on', true);

  FOREACH v_pid IN ARRAY v_players LOOP
    v_lid := NULL;
    SELECT "Konami_ID"::text AS id, "Name",
           coalesce(nullif(regexp_replace(coalesce(market_value::text, ''), '[^0-9.]', '', 'g'), '')::numeric, 0) AS mv,
           nullif(btrim(coalesce("Contracted_Team"::text, '')), '') AS team
    INTO v_p
    FROM public."Players" WHERE "Konami_ID"::text = v_pid;

    IF NOT FOUND THEN
      INSERT INTO _crv_award VALUES (v_pid, NULL, NULL, NULL, 'player not found');
      CONTINUE;
    END IF;

    IF v_p.team IS NOT NULL THEN
      INSERT INTO _crv_award VALUES (v_pid, v_p."Name", NULL, NULL, 'skipped — already at ' || v_p.team);
      CONTINUE;
    END IF;

    SELECT b.bid_id, b.bid_amount, b.bid_time, b.listing_id
    INTO v_bid
    FROM public."Player_Transfer_Bids" b
    WHERE coalesce(b.player_id::text, b.direct_bid_id::text) = v_pid
      AND upper(btrim(b.bidder_club_id)) = v_club
      AND b.is_direct = true
      AND b.seller_club_id IS NULL
      AND b.bid_time >= v_from AND b.bid_time < v_to
    ORDER BY b.bid_amount DESC, b.bid_time ASC
    LIMIT 1;

    IF NOT FOUND THEN
      INSERT INTO _crv_award VALUES (v_pid, v_p."Name", NULL, NULL, 'no CRV bid in Sat window');
      CONTINUE;
    END IF;

    BEGIN
      v_lid := v_bid.listing_id;
      IF v_lid IS NULL OR NOT EXISTS (
        SELECT 1 FROM public."Player_Transfer_Listings" WHERE id = v_lid
      ) THEN
        INSERT INTO public."Player_Transfer_Listings" (
          player_id, seller_club_id, reserve_price, listing_type, market_value,
          status, start_time, end_time, initial_end_time, created_at,
          current_highest_bid, current_highest_bidder
        )
        VALUES (
          v_pid, NULL, v_p.mv, 'draft', v_p.mv,
          'Active', v_from, v_end, v_end, v_bid.bid_time,
          v_bid.bid_amount, v_club
        )
        RETURNING id INTO v_lid;

        UPDATE public."Player_Transfer_Bids"
        SET listing_id = v_lid
        WHERE coalesce(player_id::text, direct_bid_id::text) = v_pid
          AND upper(btrim(bidder_club_id)) = v_club
          AND is_direct = true AND seller_club_id IS NULL
          AND bid_time >= v_from AND bid_time < v_to
          AND listing_id IS NULL;
      END IF;

      PERFORM public.transferengine_accept_draft_sale(v_lid);

      SELECT nullif(btrim(coalesce("Contracted_Team"::text, '')), '') INTO v_team
      FROM public."Players" WHERE "Konami_ID"::text = v_pid;

      DELETE FROM public.player_draft_max_bids
      WHERE btrim(player_id) = v_pid AND upper(club_short_name) = v_club;

      INSERT INTO _crv_award VALUES (
        v_pid, v_p."Name", v_bid.bid_amount, v_lid,
        CASE WHEN v_team = v_club THEN 'SIGNED to CRV'
             ELSE 'not signed — listing closed, player at ' || coalesce(v_team, 'nobody') END
      );
    EXCEPTION WHEN OTHERS THEN
      INSERT INTO _crv_award VALUES (v_pid, v_p."Name", v_bid.bid_amount, v_lid, 'ERROR: ' || SQLERRM);
    END;
  END LOOP;

  PERFORM set_config('gpsl.bypass_bid_owner_check', 'off', true);
END
$award$;

-- Kovačić: TIG has him; clear CRV's stale max bid so the box stops prefilling
DELETE FROM public.player_draft_max_bids
WHERE btrim(player_id) = '43135' AND upper(club_short_name) = 'CRV';

NOTIFY pgrst, 'reload schema';

SELECT
  a.player,
  a.player_id,
  a.amount,
  a.listing_id,
  a.result,
  (SELECT h.fee FROM public."Transfer_History" h
   WHERE h.listing_id = a.listing_id ORDER BY h.id DESC LIMIT 1) AS history_fee,
  (SELECT count(*) FROM public."Players" p
   WHERE btrim(coalesce(p."Contracted_Team"::text, '')) = 'CRV') AS crv_squad_now,
  public.club_permanent_squad_count('CRV') AS crv_permanent_count,
  pg_get_functiondef('public.player_draft_place_auto_bid(text,text,numeric)'::regprocedure)
    ILIKE '%player_draft_ensure_listing%' AS live_auto_bid_opens_listing,
  pg_get_functiondef('public.player_draft_set_max_bid(text,numeric)'::regprocedure)
    ILIKE '%player_draft_place_auto_bid%' AS live_set_max_uses_auto_bid
FROM _crv_award a
ORDER BY a.player;
