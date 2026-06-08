-- =============================================================================
-- Foreign sale — player unavailable as free agent until next GPSL season
-- Run after foreign_interest_teams.sql and player_contract_hooks.sql
-- =============================================================================

ALTER TABLE public."Players"
  ADD COLUMN IF NOT EXISTS foreign_contract_club text,
  ADD COLUMN IF NOT EXISTS foreign_contract_sold_season_id bigint
    REFERENCES public.competition_seasons (id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS foreign_contract_unlock_season_label text;

COMMENT ON COLUMN public."Players".foreign_contract_club IS
  'Real-world buyer name when sold abroad; player is not signable until next competition season.';
COMMENT ON COLUMN public."Players".foreign_contract_sold_season_id IS
  'Competition season id when sold abroad — locked while current season id equals this.';
COMMENT ON COLUMN public."Players".foreign_contract_unlock_season_label IS
  'Display label for GPDB (next season when sale completed).';

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.current_gpsl_season_id()
RETURNS bigint
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_id bigint;
BEGIN
  SELECT s.id
  INTO v_id
  FROM public.competition_seasons s
  WHERE s.is_current = true
    AND s.status = 'active'
  ORDER BY s.id DESC
  LIMIT 1;

  IF v_id IS NOT NULL THEN
    RETURN v_id;
  END IF;

  SELECT s.id
  INTO v_id
  FROM public.competition_seasons s
  WHERE s.is_current = true
  ORDER BY s.id DESC
  LIMIT 1;

  RETURN v_id;
END;
$function$;

CREATE OR REPLACE FUNCTION public.next_gpsl_season_label(p_from_season_id bigint)
RETURNS text
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT coalesce(
    (
      SELECT s.label
      FROM public.competition_seasons s
      WHERE s.id > coalesce(p_from_season_id, 0)
      ORDER BY s.id ASC
      LIMIT 1
    ),
    'Next season'
  );
$$;

CREATE OR REPLACE FUNCTION public.player_foreign_contract_locked(p_player_id text)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public."Players" p
    WHERE p."Konami_ID"::text = btrim(p_player_id)
      AND p.foreign_contract_club IS NOT NULL
      AND btrim(p.foreign_contract_club) <> ''
      AND p.foreign_contract_sold_season_id IS NOT NULL
      AND p.foreign_contract_sold_season_id = public.current_gpsl_season_id()
  );
$$;

CREATE OR REPLACE FUNCTION public.player_foreign_contract_status(p_player_id text)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_player public."Players"%rowtype;
  v_locked boolean;
BEGIN
  SELECT *
  INTO v_player
  FROM public."Players" p
  WHERE p."Konami_ID"::text = btrim(p_player_id);

  IF NOT FOUND THEN
    RETURN jsonb_build_object('locked', false);
  END IF;

  v_locked := public.player_foreign_contract_locked(p_player_id);

  RETURN jsonb_build_object(
    'locked', v_locked,
    'foreign_contract_club', v_player.foreign_contract_club,
    'sold_season_id', v_player.foreign_contract_sold_season_id,
    'unlock_season_label', coalesce(
      nullif(btrim(v_player.foreign_contract_unlock_season_label), ''),
      public.next_gpsl_season_label(v_player.foreign_contract_sold_season_id)
    )
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.player_apply_foreign_contract_lock(
  p_player_id text,
  p_foreign_club_name text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_pid text := btrim(p_player_id);
  v_club text := btrim(p_foreign_club_name);
  v_sold_season_id bigint;
  v_unlock_label text;
BEGIN
  IF v_pid = '' THEN
    RAISE EXCEPTION 'player_apply_foreign_contract_lock: player_id required';
  END IF;

  IF v_club = '' THEN
    v_club := 'Foreign club';
  END IF;

  v_sold_season_id := public.current_gpsl_season_id();

  IF v_sold_season_id IS NULL THEN
    RAISE EXCEPTION 'No current competition season — cannot record foreign contract lock';
  END IF;

  v_unlock_label := public.next_gpsl_season_label(v_sold_season_id);

  UPDATE public."Players"
  SET
    foreign_contract_club = v_club,
    foreign_contract_sold_season_id = v_sold_season_id,
    foreign_contract_unlock_season_label = v_unlock_label
  WHERE "Konami_ID"::text = v_pid;
END;
$function$;

CREATE OR REPLACE FUNCTION public.player_clear_foreign_contract_lock(p_player_id text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  UPDATE public."Players"
  SET
    foreign_contract_club = NULL,
    foreign_contract_sold_season_id = NULL,
    foreign_contract_unlock_season_label = NULL
  WHERE "Konami_ID"::text = btrim(p_player_id);
END;
$function$;

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
BEGIN
  IF NOT public.player_foreign_contract_locked(p_player_id) THEN
    RETURN;
  END IF;

  v_status := public.player_foreign_contract_status(p_player_id);
  v_club := coalesce(v_status ->> 'foreign_contract_club', 'a foreign club');
  v_unlock := coalesce(v_status ->> 'unlock_season_label', 'next season');

  RAISE EXCEPTION
    'Player is unavailable until % — contracted to %',
    v_unlock,
    v_club;
END;
$function$;

-- Signing clears the abroad lock
CREATE OR REPLACE FUNCTION public.player_assign_to_club(
  p_player_id text,
  p_club_short_name text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_pid text := btrim(p_player_id);
  v_club text := btrim(p_club_short_name);
  v_season text;
  v_wage numeric;
BEGIN
  IF v_pid = '' OR v_club = '' THEN
    RAISE EXCEPTION 'player_assign_to_club: player_id and club are required';
  END IF;

  PERFORM public.assert_player_available_for_signing(v_pid);

  v_season := public.current_gpsl_season_label();
  v_wage := public.calculate_player_wage_for_club(v_pid, v_club);

  UPDATE public."Players"
  SET
    "Contracted_Team" = v_club,
    "Season_Signed" = v_season,
    contract_seasons_remaining = 3,
    contract_wage = v_wage,
    foreign_contract_club = NULL,
    foreign_contract_sold_season_id = NULL,
    foreign_contract_unlock_season_label = NULL
  WHERE "Konami_ID"::text = v_pid;
END;
$function$;

-- Block bids / listings on abroad-locked free agents
CREATE OR REPLACE FUNCTION public.trg_transfer_bid_block_same_season_player()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_player_id text;
BEGIN
  v_player_id := btrim(coalesce(NEW.player_id, NEW.direct_bid_id::text, ''));

  IF v_player_id = '' AND NEW.listing_id IS NOT NULL THEN
    SELECT btrim(l.player_id::text)
    INTO v_player_id
    FROM public."Player_Transfer_Listings" l
    WHERE l.id = NEW.listing_id;
  END IF;

  IF v_player_id IS NULL OR v_player_id = '' THEN
    RETURN NEW;
  END IF;

  PERFORM public.assert_player_transferable(v_player_id);
  PERFORM public.assert_player_available_for_signing(v_player_id);
  RETURN NEW;
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
  PERFORM public.assert_player_transferable(btrim(NEW.player_id::text));
  PERFORM public.assert_player_available_for_signing(btrim(NEW.player_id::text));
  RETURN NEW;
END;
$function$;

-- Draft settlement
CREATE OR REPLACE FUNCTION public.transferengine_accept_draft_sale(p_listing_id bigint)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
  v_listing        "Player_Transfer_Listings"%rowtype;
  v_buyer_balance  numeric;
  v_amount         numeric;
  v_buyer          text;
  v_player         "Players"%rowtype;
BEGIN
  SELECT *
  INTO v_listing
  FROM "Player_Transfer_Listings"
  WHERE id = p_listing_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE NOTICE 'Draft listing % not found', p_listing_id;
    RETURN;
  END IF;

  IF v_listing.listing_type IS DISTINCT FROM 'draft' THEN
    RAISE NOTICE 'Listing % is not draft', p_listing_id;
    RETURN;
  END IF;

  IF v_listing.status NOT IN ('Active', 'Review') THEN
    RAISE NOTICE 'Draft listing % already processed', p_listing_id;
    RETURN;
  END IF;

  SELECT b.bid_amount, b.bidder_club_id
  INTO v_amount, v_buyer
  FROM "Player_Transfer_Bids" b
  WHERE b.is_direct = true
    AND (
      b.listing_id = v_listing.id
      OR btrim(coalesce(b.player_id, b.direct_bid_id::text, '')) = btrim(v_listing.player_id)
    )
  ORDER BY b.bid_amount DESC, b.bid_time ASC
  LIMIT 1;

  IF v_buyer IS NULL OR v_amount IS NULL THEN
    UPDATE "Player_Transfer_Listings"
    SET status = 'Closed',
        transfer_completed = false
    WHERE id = v_listing.id;
    RETURN;
  END IF;

  UPDATE "Player_Transfer_Listings"
  SET current_highest_bid = v_amount,
      current_highest_bidder = v_buyer
  WHERE id = v_listing.id;

  SELECT balance
  INTO v_buyer_balance
  FROM "Club_Finances"
  WHERE club_name = v_buyer
  FOR UPDATE;

  IF v_buyer_balance IS NULL THEN
    RAISE NOTICE 'Buyer finance missing for draft listing %', p_listing_id;
    RETURN;
  END IF;

  SELECT *
  INTO v_player
  FROM "Players"
  WHERE "Konami_ID"::text = v_listing.player_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE NOTICE 'Player not found for draft listing %', p_listing_id;
    RETURN;
  END IF;

  IF v_player."Contracted_Team" IS NOT NULL
     AND btrim(v_player."Contracted_Team") <> '' THEN
    RAISE NOTICE 'Player already contracted for draft listing %', p_listing_id;
    RETURN;
  END IF;

  PERFORM public.assert_player_available_for_signing(v_listing.player_id);

  UPDATE "Club_Finances"
  SET balance = v_buyer_balance - v_amount
  WHERE club_name = v_buyer;

  PERFORM public.player_assign_to_club(v_listing.player_id, v_buyer);

  INSERT INTO "Transfer_History" (
    player_id,
    seller_club_id,
    buyer_club_id,
    fee,
    agent_fee,
    transfer_time,
    listing_id
  )
  VALUES (
    v_listing.player_id,
    NULL,
    v_buyer,
    v_amount,
    0,
    now(),
    v_listing.id
  );

  UPDATE "Player_Transfer_Listings"
  SET status = 'Closed',
      transfer_completed = true,
      winning_bid = v_amount,
      winning_club = v_buyer
  WHERE id = v_listing.id;
END;
$function$;

-- Squad sell-to-foreign (owner action)
CREATE OR REPLACE FUNCTION public.sell_player_to_foreign_club(
  p_player_id text,
  p_foreign_team_name text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club           text;
  v_player         public."Players"%rowtype;
  v_pid            text;
  v_fee            numeric;
  v_seller_balance numeric;
  v_buyer          text := 'FOREIGN';
  v_interest       int;
  v_interest_after int;
  v_teams          text[];
  v_team           text;
  v_unlock_label   text;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  PERFORM public.ensure_foreign_buyer_club();

  v_club := public.my_club_shortname();
  IF v_club IS NULL OR btrim(v_club) = '' THEN
    RAISE EXCEPTION 'No club linked to this account';
  END IF;

  SELECT c.foreign_interest_remaining, coalesce(c.foreign_tracking_teams, '{}')
  INTO v_interest, v_teams
  FROM public."Clubs" c
  WHERE c."ShortName" = v_club
  FOR UPDATE;

  IF coalesce(v_interest, 0) <= 0 THEN
    RAISE EXCEPTION
      'No foreign clubs are interested in your players (maximum foreign sales reached).';
  END IF;

  v_teams := public.sync_club_foreign_tracking(v_club);

  v_team := btrim(coalesce(p_foreign_team_name, ''));
  IF v_team = '' THEN
    RAISE EXCEPTION 'Choose which foreign club to sell to.';
  END IF;

  IF NOT (v_team = ANY (v_teams)) THEN
    RAISE EXCEPTION 'That club is not currently tracking your players.';
  END IF;

  v_pid := btrim(p_player_id);

  SELECT *
  INTO v_player
  FROM public."Players"
  WHERE "Konami_ID"::text = v_pid
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Player not found';
  END IF;

  IF public.player_contracted_club_key(v_player."Contracted_Team") IS DISTINCT FROM v_club THEN
    RAISE EXCEPTION 'Player is not at your club';
  END IF;

  PERFORM public.assert_player_transferable(v_pid);

  v_fee := greatest(coalesce(v_player.market_value::numeric, 0::numeric), 0::numeric);

  SELECT balance
  INTO v_seller_balance
  FROM public."Club_Finances"
  WHERE club_name = v_club
  FOR UPDATE;

  IF v_seller_balance IS NULL THEN
    RAISE EXCEPTION 'Club finances not found for %', v_club;
  END IF;

  UPDATE public."Player_Transfer_Listings" l
  SET status = 'Closed',
      transfer_completed = false,
      winning_bid = null,
      winning_club = null
  WHERE l.player_id::text = v_pid
    AND l.seller_club_id = v_club
    AND l.status IN ('Active', 'Review');

  UPDATE public."Player_Transfer_Bids" b
  SET status = 'rejected'
  WHERE b.is_direct = true
    AND b.listing_id IS NULL
    AND lower(coalesce(b.status::text, '')) = 'active'
    AND (
      (b.player_id IS NOT NULL AND btrim(b.player_id::text) = v_pid)
      OR (b.direct_bid_id IS NOT NULL AND btrim(b.direct_bid_id::text) = v_pid)
    );

  PERFORM public.player_release_from_club(v_pid);
  PERFORM public.player_apply_foreign_contract_lock(v_pid, v_team);

  v_unlock_label := public.next_gpsl_season_label(public.current_gpsl_season_id());

  UPDATE public."Club_Finances"
  SET balance = v_seller_balance + v_fee
  WHERE club_name = v_club;

  v_teams := array_remove(v_teams, v_team);

  UPDATE public."Clubs" c
  SET foreign_interest_remaining = foreign_interest_remaining - 1,
      foreign_tracking_teams = v_teams
  WHERE c."ShortName" = v_club
  RETURNING c.foreign_interest_remaining INTO v_interest_after;

  INSERT INTO public."Transfer_History" (
    player_id,
    seller_club_id,
    buyer_club_id,
    fee,
    agent_fee,
    transfer_time,
    listing_id,
    foreign_buyer_name
  )
  VALUES (
    v_player."Konami_ID",
    v_club,
    v_buyer,
    v_fee,
    0,
    now(),
    NULL,
    v_team
  );

  RETURN jsonb_build_object(
    'ok', true,
    'player_id', v_player."Konami_ID",
    'player_name', v_player."Name",
    'seller_club_id', v_club,
    'buyer_club_id', v_buyer,
    'foreign_buyer_name', v_team,
    'fee', v_fee,
    'new_balance', v_seller_balance + v_fee,
    'foreign_interest_remaining', v_interest_after,
    'tracking_teams', to_jsonb(v_teams),
    'unavailable_until_season', v_unlock_label
  );
END;
$function$;

-- Squad overflow foreign sale
CREATE OR REPLACE FUNCTION public.club_release_player_foreign_overflow(
  p_club_short_name text,
  p_player_id text,
  p_foreign_team_name text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club           text := btrim(p_club_short_name);
  v_pid            text := btrim(p_player_id);
  v_team           text := btrim(p_foreign_team_name);
  v_player         public."Players"%rowtype;
  v_fee            numeric;
  v_bal            numeric;
  v_interest       int;
  v_interest_after int;
  v_teams          text[];
  v_unlock_label   text;
BEGIN
  PERFORM public.ensure_foreign_buyer_club();

  IF v_team = '' THEN
    RAISE EXCEPTION 'Foreign buyer name required for overflow foreign sale';
  END IF;

  SELECT c.foreign_interest_remaining, coalesce(c.foreign_tracking_teams, '{}')
  INTO v_interest, v_teams
  FROM public."Clubs" c
  WHERE c."ShortName" = v_club
  FOR UPDATE;

  IF coalesce(v_interest, 0) <= 0 THEN
    RAISE EXCEPTION 'No foreign club interest remaining for %', v_club;
  END IF;

  v_teams := public.sync_club_foreign_tracking(v_club);

  IF NOT (v_team = ANY (v_teams)) THEN
    RAISE EXCEPTION 'Club % is not tracking your players', v_team;
  END IF;

  SELECT *
  INTO v_player
  FROM public."Players"
  WHERE "Konami_ID"::text = v_pid
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Player not found';
  END IF;

  IF public.player_contracted_club_key(v_player."Contracted_Team") IS DISTINCT FROM v_club THEN
    RAISE EXCEPTION 'Player is not at club %', v_club;
  END IF;

  v_fee := greatest(coalesce(v_player.market_value::numeric, 0), 0);

  SELECT balance INTO v_bal
  FROM public."Club_Finances"
  WHERE club_name = v_club
  FOR UPDATE;

  IF v_bal IS NULL THEN
    RAISE EXCEPTION 'Club finances not found for %', v_club;
  END IF;

  UPDATE public."Player_Transfer_Listings" l
  SET status = 'Closed',
      transfer_completed = false,
      winning_bid = null,
      winning_club = null
  WHERE l.player_id::text = v_pid
    AND l.seller_club_id = v_club
    AND l.status IN ('Active', 'Review');

  UPDATE public."Player_Transfer_Bids" b
  SET status = 'rejected'
  WHERE b.is_direct = true
    AND b.listing_id IS NULL
    AND lower(coalesce(b.status::text, '')) = 'active'
    AND (
      (b.player_id IS NOT NULL AND btrim(b.player_id::text) = v_pid)
      OR (b.direct_bid_id IS NOT NULL AND btrim(b.direct_bid_id::text) = v_pid)
    );

  PERFORM public.player_release_from_club(v_pid);
  PERFORM public.player_apply_foreign_contract_lock(v_pid, v_team);

  v_unlock_label := public.next_gpsl_season_label(public.current_gpsl_season_id());

  UPDATE public."Club_Finances"
  SET balance = v_bal + v_fee
  WHERE club_name = v_club;

  v_teams := array_remove(v_teams, v_team);

  UPDATE public."Clubs" c
  SET foreign_interest_remaining = foreign_interest_remaining - 1,
      foreign_tracking_teams = v_teams
  WHERE c."ShortName" = v_club
  RETURNING c.foreign_interest_remaining INTO v_interest_after;

  INSERT INTO public."Transfer_History" (
    player_id,
    seller_club_id,
    buyer_club_id,
    fee,
    agent_fee,
    transfer_time,
    listing_id,
    foreign_buyer_name,
    transfer_sale_note
  )
  VALUES (
    v_player."Konami_ID",
    v_club,
    'FOREIGN',
    v_fee,
    0,
    now(),
    NULL,
    v_team,
    'squad_overflow'
  );

  RETURN jsonb_build_object(
    'ok', true,
    'method', 'foreign',
    'player_id', v_pid,
    'player_name', v_player."Name",
    'rating', v_player."Rating",
    'fee', v_fee,
    'foreign_buyer_name', v_team,
    'foreign_interest_remaining', v_interest_after,
    'unavailable_until_season', v_unlock_label
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.current_gpsl_season_id() TO authenticated;
GRANT EXECUTE ON FUNCTION public.next_gpsl_season_label(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.player_foreign_contract_locked(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.player_foreign_contract_status(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.assert_player_available_for_signing(text) TO authenticated;

-- Backfill: abroad sales this competition season (free agents missing lock rows)
UPDATE public."Players" p
SET
  foreign_contract_club = coalesce(
    nullif(btrim(h.foreign_buyer_name), ''),
    'Foreign club'
  ),
  foreign_contract_sold_season_id = public.current_gpsl_season_id(),
  foreign_contract_unlock_season_label = public.next_gpsl_season_label(
    public.current_gpsl_season_id()
  )
FROM (
  SELECT DISTINCT ON (h.player_id)
    h.player_id,
    h.foreign_buyer_name,
    h.transfer_time
  FROM public."Transfer_History" h
  WHERE h.buyer_club_id = 'FOREIGN'
  ORDER BY h.player_id, h.transfer_time DESC
) h
WHERE p."Konami_ID" = h.player_id
  AND public.player_contracted_club_key(p."Contracted_Team") IS NULL
  AND p.foreign_contract_club IS NULL
  AND public.current_gpsl_season_id() IS NOT NULL
  AND h.transfer_time >= coalesce(
    (
      SELECT s.started_at
      FROM public.competition_seasons s
      WHERE s.id = public.current_gpsl_season_id()
    ),
    '-infinity'::timestamptz
  );

NOTIFY pgrst, 'reload schema';
