-- =============================================================================
-- Fix: "Error creating draft listing" for free agents (e.g. opening GPDB draft bid)
--
-- Cause: assert_player_transferable() treats contract_seasons_remaining <= 1 and
-- Season_Signed as listing blocks — aimed at club sales. Free agents often still
-- have stale remaining=0/1 after expiry, so opening a draft thread fails.
--
-- This patch:
--   1) Skips sale-style transferability for uncontracted players
--   2) Skips it for listing_type = 'draft' (FA auction threads)
--   3) Hardens player_draft_ensure_listing + grants EXECUTE to authenticated
--
-- Run once in Supabase SQL Editor. Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.assert_player_transferable(p_player_id text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_signed   text;
  v_seasons  smallint;
  v_club     text;
  v_legacy   boolean;
BEGIN
  SELECT
    p."Season_Signed",
    p.contract_seasons_remaining,
    nullif(btrim(p."Contracted_Team"::text), ''),
    coalesce(p.pesdb_unavailable, false)
  INTO v_signed, v_seasons, v_club, v_legacy
  FROM public."Players" p
  WHERE p."Konami_ID"::text = btrim(p_player_id);

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Player not found';
  END IF;

  -- Free agents are not "listed for sale" by a club — draft / FA market uses them.
  IF v_club IS NULL THEN
    RETURN;
  END IF;

  IF coalesce(v_legacy, false) THEN
    RAISE EXCEPTION
      'This player card is no longer on pesdb.net (legacy card). It cannot be sold or listed. Renew for one season at a time from your squad.';
  END IF;

  IF public.player_signed_this_season(v_signed) THEN
    RAISE EXCEPTION
      'This player was signed in the current season and cannot be sold or listed until the next season.';
  END IF;

  IF v_seasons IS NOT NULL AND v_seasons <= 1 THEN
    RAISE EXCEPTION
      'Player is in the final year of their contract and cannot be sold or listed. Renew or expire the contract from your squad page.';
  END IF;
END;
$function$;

CREATE OR REPLACE FUNCTION public.trg_listing_block_same_season_sale()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF NEW.player_id IS NULL OR btrim(NEW.player_id::text) = '' THEN
    RETURN NEW;
  END IF;

  -- Draft / FA auction threads are not club sales
  IF lower(coalesce(NEW.listing_type::text, '')) = 'draft'
     OR nullif(btrim(coalesce(NEW.seller_club_id::text, '')), '') IS NULL THEN
    RETURN NEW;
  END IF;

  IF coalesce(NEW.new_owner_slot, false) THEN
    RETURN NEW;
  END IF;

  IF coalesce(NEW.perpetual_renew, false)
     AND coalesce(NEW.special_rules ->> 'source', '') = 'underperformance' THEN
    RETURN NEW;
  END IF;

  PERFORM public.assert_player_transferable(btrim(NEW.player_id::text));
  RETURN NEW;
END;
$function$;

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

  SELECT l.id INTO v_id
  FROM public."Player_Transfer_Listings" l
  WHERE l.player_id = v_pid
    AND l.listing_type = 'draft'
    AND l.status = 'Active'
  ORDER BY l.id
  LIMIT 1;

  IF v_id IS NOT NULL THEN
    RETURN v_id;
  END IF;

  SELECT
    p.market_value,
    nullif(btrim(p."Contracted_Team"::text), ''),
    p."Name"
  INTO v_mv, v_club, v_name
  FROM public."Players" p
  WHERE p."Konami_ID"::text = v_pid;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Player not found';
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

NOTIFY pgrst, 'reload schema';
