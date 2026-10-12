-- =============================================================================
-- Mateo Kovačić (43135): TIG → CRV reversal + TIG free pick (2026-10-12)
-- =============================================================================
-- matjaz (CRV) led Kovačić in Saturday's draft (₿21,000,000) but his bid was
-- saved without an auction, so it never settled. TIG then won him in Sunday's
-- auction (#3112).
--
--   1) Free pick feature: draft_free_picks + draft_free_pick_claim(player).
--      A club with an unused pick signs any free agent at market value, now,
--      through the normal draft signing (contract, history, ledger, tax).
--   2) Refund TIG every ledger line from that purchase (fee + income tax),
--      including the central bank leg where there was one.
--   3) Release Kovačić from TIG, close #3112 as not completed, remove TIG's
--      Transfer_History row (kept in refund metadata).
--   4) Sign him to CRV via a Saturday draft listing at his ₿21,000,000 bid.
--   5) Grant TIG one free pick.
--
-- Safe re-run: each step checks whether it is already done.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1) Free picks
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.draft_free_picks (
  id bigserial PRIMARY KEY,
  club_short_name text NOT NULL,
  reason text NOT NULL,
  granted_at timestamptz NOT NULL DEFAULT now(),
  used_at timestamptz,
  player_id text,
  listing_id bigint,
  fee numeric
);

CREATE UNIQUE INDEX IF NOT EXISTS draft_free_picks_club_reason_uidx
  ON public.draft_free_picks (club_short_name, reason);

ALTER TABLE public.draft_free_picks ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS draft_free_picks_select_own ON public.draft_free_picks;
CREATE POLICY draft_free_picks_select_own ON public.draft_free_picks
  FOR SELECT TO authenticated
  USING (
    public.is_gpsl_admin()
    OR upper(club_short_name) = upper(coalesce(public.my_club_shortname(), ''))
  );

GRANT SELECT ON public.draft_free_picks TO authenticated;

CREATE OR REPLACE FUNCTION public.draft_free_pick_my_status()
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT jsonb_build_object(
    'club', public.my_club_shortname(),
    'available', count(*) FILTER (WHERE f.used_at IS NULL)
  )
  FROM public.draft_free_picks f
  WHERE upper(f.club_short_name) = upper(coalesce(public.my_club_shortname(), ''));
$$;

REVOKE ALL ON FUNCTION public.draft_free_pick_my_status() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.draft_free_pick_my_status() TO authenticated;

CREATE OR REPLACE FUNCTION public.draft_free_pick_claim(p_player_id text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := upper(btrim(coalesce(public.my_club_shortname(), '')));
  v_pid text := btrim(coalesce(p_player_id, ''));
  v_pick public.draft_free_picks%rowtype;
  v_p record;
  v_mv numeric;
  v_lid bigint;
  v_team text;
BEGIN
  IF v_club = '' THEN
    RAISE EXCEPTION 'You must own a club to use a free pick';
  END IF;
  IF v_pid = '' THEN
    RAISE EXCEPTION 'Player id is required';
  END IF;

  SELECT * INTO v_pick
  FROM public.draft_free_picks
  WHERE upper(club_short_name) = v_club AND used_at IS NULL
  ORDER BY granted_at
  LIMIT 1
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Your club has no free pick available';
  END IF;

  SELECT "Konami_ID"::text AS id, "Name",
         nullif(btrim(coalesce("Contracted_Team"::text, '')), '') AS team,
         coalesce(pesdb_unavailable, false) AS legacy,
         coalesce(nullif(regexp_replace(coalesce(market_value::text, ''), '[^0-9.]', '', 'g'), '')::numeric, 0) AS mv
  INTO v_p
  FROM public."Players"
  WHERE "Konami_ID"::text = v_pid
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Player not found';
  END IF;
  IF v_p.team IS NOT NULL THEN
    RAISE EXCEPTION '% is under contract at % — free picks are for free agents only', v_p."Name", v_p.team;
  END IF;
  IF v_p.legacy THEN
    RAISE EXCEPTION '% is a legacy card and cannot be signed', v_p."Name";
  END IF;
  IF public.gpdb_player_is_season_excluded(v_pid) THEN
    RAISE EXCEPTION '% is unavailable this season', v_p."Name";
  END IF;
  IF to_regprocedure('public.auction_player_is_excluded(text)') IS NOT NULL
     AND public.auction_player_is_excluded(v_pid) THEN
    RAISE EXCEPTION '% is reserved for special auctions', v_p."Name";
  END IF;
  IF to_regprocedure('public.assert_player_available_for_signing(text)') IS NOT NULL THEN
    PERFORM public.assert_player_available_for_signing(v_pid);
  END IF;
  IF to_regprocedure('public.assert_player_transferable(text)') IS NOT NULL THEN
    PERFORM public.assert_player_transferable(v_pid);
  END IF;
  IF EXISTS (
    SELECT 1 FROM public."Player_Transfer_Listings" l
    WHERE btrim(l.player_id::text) = v_pid
      AND l.listing_type = 'draft' AND l.status = 'Active'
  ) THEN
    RAISE EXCEPTION '% is in a live draft auction — pick someone else or bid in the auction', v_p."Name";
  END IF;
  IF public.club_permanent_squad_count(v_club) >= public.squad_max_size() THEN
    RAISE EXCEPTION 'Your squad is full (% players) — release a player before using the free pick',
      public.squad_max_size();
  END IF;

  v_mv := v_p.mv;
  IF v_mv <= 0 THEN
    RAISE EXCEPTION '% has no market value set', v_p."Name";
  END IF;

  INSERT INTO public."Player_Transfer_Listings" (
    player_id, seller_club_id, reserve_price, listing_type, market_value,
    status, start_time, end_time, initial_end_time, created_at,
    current_highest_bid, current_highest_bidder
  )
  VALUES (
    v_pid, NULL, v_mv, 'draft', v_mv,
    'Active', now(), now(), now(), now(),
    v_mv, v_club
  )
  RETURNING id INTO v_lid;

  PERFORM public.transferengine_accept_draft_sale(v_lid);

  SELECT upper(nullif(btrim(coalesce("Contracted_Team"::text, '')), '')) INTO v_team
  FROM public."Players" WHERE "Konami_ID"::text = v_pid;

  IF v_team IS DISTINCT FROM v_club THEN
    RAISE EXCEPTION 'Signing % did not complete — your free pick has not been used', v_p."Name";
  END IF;

  UPDATE public.draft_free_picks
  SET used_at = now(), player_id = v_pid, listing_id = v_lid, fee = v_mv
  WHERE id = v_pick.id;

  RETURN jsonb_build_object(
    'ok', true, 'player_id', v_pid, 'player', v_p."Name",
    'fee', v_mv, 'listing_id', v_lid
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.draft_free_pick_claim(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.draft_free_pick_claim(text) TO authenticated;

-- ---------------------------------------------------------------------------
-- 2–5) Kovačić reversal + CRV award + TIG pick
-- ---------------------------------------------------------------------------
CREATE TEMP TABLE IF NOT EXISTS _kovacic_log (step int, detail text) ON COMMIT PRESERVE ROWS;
TRUNCATE _kovacic_log;

DO $kov$
DECLARE
  v_pid  text := '43135';
  v_from_club text := 'TIG';
  v_to_club   text := 'CRV';
  v_from timestamptz := timestamp '2026-10-09 19:00' AT TIME ZONE 'Europe/London';
  v_to   timestamptz := timestamp '2026-10-10 19:00' AT TIME ZONE 'Europe/London';
  v_end  timestamptz := timestamp '2026-10-10 18:55' AT TIME ZONE 'Europe/London';
  v_h    record;
  v_l    record;
  v_team text;
  v_mv   numeric;
  v_bid  record;
  v_lid  bigint;
  v_refunded numeric := 0;
BEGIN
  SELECT upper(nullif(btrim(coalesce("Contracted_Team"::text, '')), '')),
         coalesce(nullif(regexp_replace(coalesce(market_value::text, ''), '[^0-9.]', '', 'g'), '')::numeric, 0)
  INTO v_team, v_mv
  FROM public."Players" WHERE "Konami_ID"::text = v_pid;

  SELECT h.* INTO v_h
  FROM public."Transfer_History" h
  WHERE h.player_id::text = v_pid AND upper(h.buyer_club_id) = v_from_club
  ORDER BY h.id DESC
  LIMIT 1;

  -- 2) refund TIG
  IF v_h.id IS NOT NULL THEN
    FOR v_l IN
      SELECT l.*
      FROM public.competition_finance_ledger l
      WHERE upper(l.club_short_name) = v_from_club
        AND l.metadata->>'transfer_history_id' = v_h.id::text
        AND l.amount < 0
        AND NOT EXISTS (
          SELECT 1 FROM public.competition_finance_ledger r
          WHERE r.metadata->>'refund_of_ledger_id' = l.id::text
        )
    LOOP
      PERFORM public.post_club_ledger(
        v_l.club_short_name,
        v_l.entry_type,
        -v_l.amount,
        'Refund (draft reversed by admin): ' || coalesce(v_l.description, v_l.entry_type),
        jsonb_build_object(
          'refund_of_ledger_id', v_l.id,
          'refund_of_transfer_history_id', v_h.id,
          'reversed_history', to_jsonb(v_h),
          'player_id', v_pid,
          'admin_reversal', true
        ),
        v_l.season_id,
        NULL,
        EXISTS (SELECT 1 FROM public.bank_ledger b WHERE b.club_ledger_id = v_l.id),
        true
      );
      v_refunded := v_refunded + (-v_l.amount);
    END LOOP;
    INSERT INTO _kovacic_log VALUES (2, format('TIG refunded ₿%s (history #%s, fee ₿%s)',
      to_char(v_refunded, 'FM999,999,999,990'), v_h.id, to_char(v_h.fee, 'FM999,999,999,990')));
  ELSE
    INSERT INTO _kovacic_log VALUES (2, 'No TIG purchase history found (already reversed?)');
  END IF;

  -- 3) release from TIG
  IF v_team = v_from_club THEN
    PERFORM public.player_release_from_club(v_pid);
    v_team := NULL;
    INSERT INTO _kovacic_log VALUES (3, 'Kovačić released from TIG');
  ELSE
    INSERT INTO _kovacic_log VALUES (3, 'Not at TIG (now: ' || coalesce(v_team, 'free agent') || ')');
  END IF;

  IF v_h.id IS NOT NULL THEN
    UPDATE public."Player_Transfer_Listings"
    SET transfer_completed = false, winning_bid = NULL, winning_club = NULL, status = 'Closed'
    WHERE id = v_h.listing_id;

    BEGIN
      DELETE FROM public."Transfer_History" WHERE id = v_h.id;
      INSERT INTO _kovacic_log VALUES (3, format('TIG history #%s removed, listing #%s marked not completed', v_h.id, v_h.listing_id));
    EXCEPTION WHEN OTHERS THEN
      UPDATE public."Transfer_History" SET transfer_sale_note = 'admin_reversed' WHERE id = v_h.id;
      INSERT INTO _kovacic_log VALUES (3, format('TIG history #%s kept (referenced) and marked admin_reversed: %s', v_h.id, SQLERRM));
    END;
  END IF;

  -- 4) CRV signing at Saturday bid
  IF v_team IS NULL THEN
    SELECT b.bid_id, b.bid_amount, b.bid_time INTO v_bid
    FROM public."Player_Transfer_Bids" b
    WHERE coalesce(b.player_id::text, b.direct_bid_id::text) = v_pid
      AND upper(btrim(b.bidder_club_id)) = v_to_club
      AND b.is_direct = true AND b.seller_club_id IS NULL
      AND b.bid_time >= v_from AND b.bid_time < v_to
    ORDER BY b.bid_amount DESC, b.bid_time ASC
    LIMIT 1;

    IF v_bid.bid_id IS NULL THEN
      INSERT INTO _kovacic_log VALUES (4, 'No CRV Saturday bid found — not signed');
    ELSE
      PERFORM set_config('gpsl.bypass_bid_owner_check', 'on', true);

      INSERT INTO public."Player_Transfer_Listings" (
        player_id, seller_club_id, reserve_price, listing_type, market_value,
        status, start_time, end_time, initial_end_time, created_at,
        current_highest_bid, current_highest_bidder
      )
      VALUES (
        v_pid, NULL, v_mv, 'draft', v_mv,
        'Active', v_from, v_end, v_end, v_bid.bid_time,
        v_bid.bid_amount, v_to_club
      )
      RETURNING id INTO v_lid;

      UPDATE public."Player_Transfer_Bids"
      SET listing_id = v_lid
      WHERE coalesce(player_id::text, direct_bid_id::text) = v_pid
        AND upper(btrim(bidder_club_id)) = v_to_club
        AND is_direct = true AND seller_club_id IS NULL
        AND bid_time >= v_from AND bid_time < v_to
        AND listing_id IS NULL;

      PERFORM public.transferengine_accept_draft_sale(v_lid);
      PERFORM set_config('gpsl.bypass_bid_owner_check', 'off', true);

      SELECT upper(nullif(btrim(coalesce("Contracted_Team"::text, '')), '')) INTO v_team
      FROM public."Players" WHERE "Konami_ID"::text = v_pid;

      IF v_team IS DISTINCT FROM v_to_club THEN
        RAISE EXCEPTION 'CRV signing did not complete (player now at %) — nothing applied', coalesce(v_team, 'nobody');
      END IF;

      INSERT INTO _kovacic_log VALUES (4, format('Signed to CRV for ₿%s (listing #%s)',
        to_char(v_bid.bid_amount, 'FM999,999,999,990'), v_lid));
    END IF;
  ELSIF v_team = v_to_club THEN
    INSERT INTO _kovacic_log VALUES (4, 'Already at CRV');
  ELSE
    INSERT INTO _kovacic_log VALUES (4, 'Not signed — player is at ' || v_team);
  END IF;

  DELETE FROM public.player_draft_max_bids
  WHERE btrim(player_id) = v_pid AND upper(club_short_name) = v_to_club;

  -- 5) TIG free pick
  INSERT INTO public.draft_free_picks (club_short_name, reason)
  VALUES (v_from_club, 'kovacic_reversal_20261012')
  ON CONFLICT (club_short_name, reason) DO NOTHING;
  INSERT INTO _kovacic_log VALUES (5, 'TIG free pick granted (unused picks: ' ||
    (SELECT count(*) FROM public.draft_free_picks WHERE club_short_name = v_from_club AND used_at IS NULL) || ')');
END
$kov$;

NOTIFY pgrst, 'reload schema';

SELECT step, detail FROM _kovacic_log
UNION ALL
SELECT 9, format('Kovačić now at %s | TIG balance ₿%s | CRV balance ₿%s | CRV permanent squad %s',
  coalesce((SELECT "Contracted_Team"::text FROM public."Players" WHERE "Konami_ID"::text = '43135'), 'free agent'),
  to_char((SELECT balance FROM public."Club_Finances" WHERE club_name = 'TIG'), 'FM999,999,999,990'),
  to_char((SELECT balance FROM public."Club_Finances" WHERE club_name = 'CRV'), 'FM999,999,999,990'),
  public.club_permanent_squad_count('CRV'))
ORDER BY 1;
