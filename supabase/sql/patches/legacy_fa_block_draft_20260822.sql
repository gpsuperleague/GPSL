-- =============================================================================
-- Legacy cards (pesdb_unavailable): block draft / FA signing until PESDB restore
--
-- Bug: assert_player_transferable returned early for free agents, so a released
-- legacy card could open a draft auction / be signed before reappearing on sync.
--
-- Fix:
--   • Legacy check runs for contracted AND free agents
--   • player_draft_ensure_listing hard-blocks legacy
--   • assert_player_available_for_signing hard-blocks legacy
--   • Close any active draft listings already open on legacy cards
--
-- Safe re-run.
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

  -- Legacy always blocked (club sale OR free-agent draft) until PESDB sync restores
  IF coalesce(v_legacy, false) THEN
    RAISE EXCEPTION
      'This player card is no longer on pesdb.net (legacy card). It cannot be sold, listed, or signed until it returns on a PESDB sync.';
  END IF;

  -- Free agents are not "listed for sale" by a club — draft / FA market uses them
  -- (sale-style same-season / final-year blocks do not apply).
  IF v_club IS NULL THEN
    RETURN;
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

  SELECT l.id INTO v_id
  FROM public."Player_Transfer_Listings" l
  WHERE l.player_id = v_pid
    AND l.listing_type = 'draft'
    AND l.status = 'Active'
  ORDER BY l.id
  LIMIT 1;

  IF v_id IS NOT NULL THEN
    -- Existing thread: still refuse if the card is now legacy
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

-- Keep season-exclusion + foreign-lock checks; add legacy gate
CREATE OR REPLACE FUNCTION public.assert_player_available_for_signing(p_player_id text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_status jsonb;
  v_club text;
  v_unlock text;
  v_kind text;
  v_legacy boolean;
BEGIN
  IF to_regprocedure('public.assert_player_not_season_excluded(text)') IS NOT NULL THEN
    PERFORM public.assert_player_not_season_excluded(p_player_id);
  END IF;

  SELECT coalesce(p.pesdb_unavailable, false)
  INTO v_legacy
  FROM public."Players" p
  WHERE p."Konami_ID"::text = btrim(p_player_id);

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Player not found';
  END IF;

  IF coalesce(v_legacy, false) THEN
    RAISE EXCEPTION
      'This player card is no longer on pesdb.net (legacy card). It cannot be signed until it returns on a PESDB sync.';
  END IF;

  IF to_regprocedure('public.player_foreign_contract_locked(text)') IS NULL THEN
    RETURN;
  END IF;

  IF NOT public.player_foreign_contract_locked(p_player_id) THEN
    RETURN;
  END IF;

  v_status := public.player_foreign_contract_status(p_player_id);
  v_club := coalesce(v_status ->> 'foreign_contract_club', 'their previous club');
  v_unlock := coalesce(v_status ->> 'unlock_season_label', 'next season');
  v_kind := coalesce(v_status ->> 'lock_kind', 'foreign');

  IF v_kind = 'paid_up' THEN
    RAISE EXCEPTION
      'Player is unavailable until % — contract paid up by % (squad overflow release)',
      v_unlock,
      v_club;
  END IF;

  RAISE EXCEPTION
    'Player is unavailable until % — contracted to %',
    v_unlock,
    v_club;
END;
$function$;

-- Close any open draft threads on legacy cards (no bids settle after this)
UPDATE public."Player_Transfer_Listings" l
SET
  status = 'Closed',
  transfer_completed = false
WHERE l.listing_type = 'draft'
  AND l.status IN ('Active', 'Review')
  AND EXISTS (
    SELECT 1
    FROM public."Players" p
    WHERE p."Konami_ID"::text = l.player_id::text
      AND coalesce(p.pesdb_unavailable, false)
  );

REVOKE ALL ON FUNCTION public.player_draft_ensure_listing(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.player_draft_ensure_listing(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.assert_player_transferable(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.assert_player_available_for_signing(text) TO authenticated;

NOTIFY pgrst, 'reload schema';
