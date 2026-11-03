-- =============================================================================
-- Limited Player Draft: max N signings per club, no credits.
--
-- global_settings.player_draft_max_signings_per_club:
--   NULL / 0 = Unlimited (existing credit draft, unchanged)
--   3 (etc.) = Limited Draft — max that many wins AND concurrent leads; no credits
--
-- Safe re-run. Does not change manager/club drafts.
-- =============================================================================

ALTER TABLE public.global_settings
  ADD COLUMN IF NOT EXISTS player_draft_max_signings_per_club integer;

COMMENT ON COLUMN public.global_settings.player_draft_max_signings_per_club IS
  'NULL/0 = unlimited player draft (credits on). Positive = Limited Draft: max wins+leads per club, no credits.';

ALTER TABLE public.global_settings
  DROP CONSTRAINT IF EXISTS global_settings_player_draft_max_signings_chk;
ALTER TABLE public.global_settings
  ADD CONSTRAINT global_settings_player_draft_max_signings_chk
  CHECK (
    player_draft_max_signings_per_club IS NULL
    OR player_draft_max_signings_per_club = 0
    OR player_draft_max_signings_per_club BETWEEN 1 AND 28
  );

-- ---------------------------------------------------------------------------
-- Mode helpers
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.player_draft_max_signings()
RETURNS integer
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT CASE
    WHEN coalesce(g.player_draft_max_signings_per_club, 0) > 0
      THEN g.player_draft_max_signings_per_club
    ELSE NULL
  END
  FROM public.global_settings g
  WHERE g.id = 1;
$$;

CREATE OR REPLACE FUNCTION public.player_draft_credits_disabled()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT public.player_draft_max_signings() IS NOT NULL;
$$;

CREATE OR REPLACE FUNCTION public.player_draft_club_wins_this_window(p_club text)
RETURNS integer
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := upper(nullif(btrim(coalesce(p_club, '')), ''));
  v_start timestamptz;
  v_n int := 0;
BEGIN
  IF v_club IS NULL THEN
    RETURN 0;
  END IF;

  SELECT g.draft_auction_start_time INTO v_start
  FROM public.global_settings g WHERE g.id = 1;

  IF v_start IS NULL THEN
    RETURN 0;
  END IF;

  SELECT count(*)::int INTO v_n
  FROM public."Player_Transfer_Listings" l
  WHERE l.listing_type = 'draft'
    AND coalesce(l.transfer_completed, false) = true
    AND upper(nullif(btrim(coalesce(l.winning_club, '')), '')) = v_club
    AND coalesce(l.end_time, l.created_at, v_start) >= v_start;

  RETURN coalesce(v_n, 0);
END;
$function$;

-- Current high bidder for an active draft listing (from bids in window)
CREATE OR REPLACE FUNCTION public.player_draft_listing_leader(p_listing_id bigint)
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_start timestamptz;
  v_finish timestamptz;
  v_player text;
  v_leader text;
BEGIN
  SELECT g.draft_auction_start_time, g.draft_random_finish_time
  INTO v_start, v_finish
  FROM public.global_settings g WHERE g.id = 1;

  SELECT l.player_id::text INTO v_player
  FROM public."Player_Transfer_Listings" l
  WHERE l.id = p_listing_id;

  IF v_player IS NULL OR v_start IS NULL THEN
    RETURN NULL;
  END IF;

  SELECT upper(nullif(btrim(b.bidder_club_id), ''))
  INTO v_leader
  FROM public."Player_Transfer_Bids" b
  WHERE b.is_direct = true
    AND b.seller_club_id IS NULL
    AND (
      b.listing_id = p_listing_id
      OR coalesce(b.player_id, b.direct_bid_id::text) = v_player
    )
    AND b.bid_time >= v_start
    AND (v_finish IS NULL OR b.bid_time < v_finish)
  ORDER BY b.bid_amount DESC, b.bid_time ASC
  LIMIT 1;

  RETURN v_leader;
END;
$function$;

CREATE OR REPLACE FUNCTION public.player_draft_club_lead_count(
  p_club text,
  p_exclude_player_id text DEFAULT NULL
)
RETURNS integer
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := upper(nullif(btrim(coalesce(p_club, '')), ''));
  v_ex text := nullif(btrim(coalesce(p_exclude_player_id, '')), '');
  v_n int := 0;
BEGIN
  IF v_club IS NULL THEN
    RETURN 0;
  END IF;

  SELECT count(*)::int INTO v_n
  FROM public."Player_Transfer_Listings" l
  WHERE l.listing_type = 'draft'
    AND l.status = 'Active'
    AND (v_ex IS NULL OR l.player_id::text IS DISTINCT FROM v_ex)
    AND public.player_draft_listing_leader(l.id) = v_club;

  RETURN coalesce(v_n, 0);
END;
$function$;

-- True if club may become / stay high bidder on this player under Limited rules.
-- Unlimited mode always returns true.
CREATE OR REPLACE FUNCTION public.player_draft_club_can_take_lead(
  p_club text,
  p_player_id text
)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_max int := public.player_draft_max_signings();
  v_club text := upper(nullif(btrim(coalesce(p_club, '')), ''));
  v_pid text := nullif(btrim(coalesce(p_player_id, '')), '');
  v_wins int;
  v_leads int;
  v_already_leading boolean := false;
BEGIN
  IF v_max IS NULL THEN
    RETURN true;
  END IF;
  IF v_club IS NULL OR v_pid IS NULL THEN
    RETURN false;
  END IF;

  v_wins := public.player_draft_club_wins_this_window(v_club);
  IF v_wins >= v_max THEN
    RETURN false;
  END IF;

  SELECT EXISTS (
    SELECT 1
    FROM public."Player_Transfer_Listings" l
    WHERE l.listing_type = 'draft'
      AND l.status = 'Active'
      AND l.player_id::text = v_pid
      AND public.player_draft_listing_leader(l.id) = v_club
  ) INTO v_already_leading;

  IF v_already_leading THEN
    RETURN true;
  END IF;

  v_leads := public.player_draft_club_lead_count(v_club, v_pid);
  RETURN (v_wins + v_leads) < v_max;
END;
$function$;

CREATE OR REPLACE FUNCTION public.player_draft_mode_state(p_club text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := upper(nullif(btrim(coalesce(
    nullif(btrim(coalesce(p_club, '')), ''),
    public.my_club_shortname()
  )), ''));
  v_max int := public.player_draft_max_signings();
  v_enabled boolean;
  v_wins int := 0;
  v_leads int := 0;
BEGIN
  SELECT coalesce(g.draft_auction_enabled, false) INTO v_enabled
  FROM public.global_settings g WHERE g.id = 1;

  IF v_club IS NOT NULL THEN
    v_wins := public.player_draft_club_wins_this_window(v_club);
    v_leads := public.player_draft_club_lead_count(v_club, NULL);
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'enabled', coalesce(v_enabled, false),
    'limited', v_max IS NOT NULL,
    'max_signings', v_max,
    'credits_disabled', v_max IS NOT NULL,
    'club', v_club,
    'my_wins', v_wins,
    'my_leads', v_leads,
    'slots_left', CASE
      WHEN v_max IS NULL THEN NULL
      ELSE greatest(v_max - v_wins - v_leads, 0)
    END
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_set_player_draft_style(p_max_signings integer DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_max int := p_max_signings;
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF v_max IS NOT NULL AND v_max <= 0 THEN
    v_max := NULL;
  END IF;
  IF v_max IS NOT NULL AND v_max > 28 THEN
    RAISE EXCEPTION 'Max signings must be between 1 and 28';
  END IF;

  UPDATE public.global_settings
  SET player_draft_max_signings_per_club = v_max,
      updated_at = now()
  WHERE id = 1;

  RETURN jsonb_build_object(
    'ok', true,
    'limited', v_max IS NOT NULL,
    'max_signings', v_max,
    'credits_disabled', v_max IS NOT NULL
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.player_draft_max_signings() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.player_draft_credits_disabled() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.player_draft_club_wins_this_window(text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.player_draft_listing_leader(bigint) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.player_draft_club_lead_count(text, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.player_draft_club_can_take_lead(text, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.player_draft_mode_state(text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_set_player_draft_style(integer) FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.player_draft_max_signings() TO authenticated;
GRANT EXECUTE ON FUNCTION public.player_draft_credits_disabled() TO authenticated;
GRANT EXECUTE ON FUNCTION public.player_draft_club_wins_this_window(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.player_draft_listing_leader(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.player_draft_club_lead_count(text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.player_draft_club_can_take_lead(text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.player_draft_mode_state(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_set_player_draft_style(integer) TO authenticated;

-- ---------------------------------------------------------------------------
-- Bid guard: Limited Draft lead+win cap (BEFORE INSERT)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.trg_player_draft_limited_lead_guard()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_max int := public.player_draft_max_signings();
  v_type text;
  v_pid text;
  v_club text;
BEGIN
  IF v_max IS NULL THEN
    RETURN NEW;
  END IF;

  IF coalesce(NEW.is_direct, false) IS NOT TRUE THEN
    RETURN NEW;
  END IF;

  IF NEW.listing_id IS NOT NULL THEN
    SELECT l.listing_type, l.player_id::text
    INTO v_type, v_pid
    FROM public."Player_Transfer_Listings" l
    WHERE l.id = NEW.listing_id;
  ELSE
    v_type := 'draft';
    v_pid := coalesce(NEW.player_id, NEW.direct_bid_id::text);
  END IF;

  -- Only player draft (FA) bids — seller null / listing_type draft
  IF NEW.seller_club_id IS NOT NULL AND v_type IS DISTINCT FROM 'draft' THEN
    RETURN NEW;
  END IF;
  IF v_type IS NOT NULL AND v_type IS DISTINCT FROM 'draft' THEN
    RETURN NEW;
  END IF;

  v_club := upper(nullif(btrim(coalesce(NEW.bidder_club_id, '')), ''));
  v_pid := nullif(btrim(coalesce(v_pid, NEW.player_id, NEW.direct_bid_id::text)), '');

  IF v_club IS NULL OR v_pid IS NULL THEN
    RETURN NEW;
  END IF;

  -- Limited mode: never consume join credits
  NEW.is_draft_join := false;
  NEW.draft_join_consumed := false;

  IF NOT public.player_draft_club_can_take_lead(v_club, v_pid) THEN
    RAISE EXCEPTION
      'Limited Draft: you already have % win(s) and/or high bid(s). Max % signing(s) this draft.',
      public.player_draft_club_wins_this_window(v_club)
        + public.player_draft_club_lead_count(v_club, v_pid),
      v_max;
  END IF;

  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS player_draft_limited_lead_guard ON public."Player_Transfer_Bids";
CREATE TRIGGER player_draft_limited_lead_guard
  BEFORE INSERT ON public."Player_Transfer_Bids"
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_player_draft_limited_lead_guard();

-- ---------------------------------------------------------------------------
-- Auto-bid: skip credits in Limited; enforce lead+win cap
-- ---------------------------------------------------------------------------

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
  v_limited boolean := public.player_draft_credits_disabled();
  v_max int := public.player_draft_max_signings();
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

  IF v_limited AND NOT public.player_draft_club_can_take_lead(p_club_short_name, v_pid) THEN
    RETURN jsonb_build_object(
      'ok', false,
      'skipped', 'limited_cap',
      'msg', format('Limited Draft: max %s signings (wins + high bids).', v_max)
    );
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
    v_is_join := CASE
      WHEN v_limited THEN false
      ELSE EXISTS (
        SELECT 1 FROM public."Player_Transfer_Bids" b
        WHERE b.bidder_club_id = p_club_short_name
          AND coalesce(b.player_id, b.direct_bid_id::text) = v_pid
          AND b.is_draft_join = true
          AND b.bid_time >= v_bounds.draft_start
      )
    END;
  ELSE
    v_is_first := false;
    IF v_limited THEN
      v_is_join := false;
      v_consume := false;
    ELSE
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
  END IF;

  v_listing_id := public.player_draft_ensure_listing(v_pid);

  PERFORM set_config('gpsl.bypass_bid_owner_check', 'on', true);

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
-- Settlement: skip buyers already at win cap; fall through to next eligible bid
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.transferengine_accept_draft_sale(p_listing_id bigint)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_listing public."Player_Transfer_Listings"%rowtype;
  v_amount  numeric;
  v_buyer   text;
  v_player  public."Players"%rowtype;
  v_history_id bigint;
  v_draft_start timestamptz;
  v_pid     text;
  v_max int := public.player_draft_max_signings();
  v_tried text[] := ARRAY[]::text[];
  v_pick record;
BEGIN
  SELECT draft_auction_start_time INTO v_draft_start
  FROM public.global_settings WHERE id = 1;

  SELECT *
  INTO v_listing
  FROM public."Player_Transfer_Listings"
  WHERE id = p_listing_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN;
  END IF;

  IF v_listing.listing_type IS DISTINCT FROM 'draft' THEN
    RETURN;
  END IF;

  IF v_listing.status NOT IN ('Active', 'Review') THEN
    RETURN;
  END IF;

  IF to_regprocedure('public.transferengine_normalize_club_short_name(text)') IS NOT NULL THEN
    v_buyer := public.transferengine_normalize_club_short_name(
      v_listing.current_highest_bidder::text
    );
  ELSE
    v_buyer := nullif(btrim(v_listing.current_highest_bidder::text), '');
  END IF;
  v_amount := v_listing.current_highest_bid;

  IF v_buyer IS NULL OR v_amount IS NULL OR v_amount <= 0 THEN
    SELECT b.bid_amount, b.bidder_club_id
    INTO v_amount, v_buyer
    FROM public."Player_Transfer_Bids" b
    WHERE b.is_direct = true
      AND b.listing_id = v_listing.id
      AND (v_draft_start IS NULL OR b.bid_time >= v_draft_start)
    ORDER BY b.bid_amount DESC, b.bid_time ASC
    LIMIT 1;

    IF to_regprocedure('public.transferengine_normalize_club_short_name(text)') IS NOT NULL THEN
      v_buyer := public.transferengine_normalize_club_short_name(v_buyer);
    ELSE
      v_buyer := nullif(btrim(v_buyer), '');
    END IF;
  END IF;

  -- Limited Draft: walk bid ladder until a club under the win cap
  IF v_max IS NOT NULL THEN
    LOOP
      EXIT WHEN v_buyer IS NULL OR v_amount IS NULL OR v_amount <= 0;
      EXIT WHEN public.player_draft_club_wins_this_window(v_buyer) < v_max;

      v_tried := array_append(v_tried, upper(v_buyer));
      RAISE NOTICE
        'Draft listing %: skip buyer % (already at Limited Draft win cap %)',
        p_listing_id, v_buyer, v_max;

      SELECT b.bid_amount, b.bidder_club_id
      INTO v_pick
      FROM public."Player_Transfer_Bids" b
      WHERE b.is_direct = true
        AND (
          b.listing_id = v_listing.id
          OR coalesce(b.player_id, b.direct_bid_id::text) = v_listing.player_id::text
        )
        AND b.seller_club_id IS NULL
        AND (v_draft_start IS NULL OR b.bid_time >= v_draft_start)
        AND NOT (upper(nullif(btrim(b.bidder_club_id), '')) = ANY (v_tried))
      ORDER BY b.bid_amount DESC, b.bid_time ASC
      LIMIT 1;

      IF NOT FOUND THEN
        v_buyer := NULL;
        v_amount := NULL;
        EXIT;
      END IF;

      v_amount := v_pick.bid_amount;
      IF to_regprocedure('public.transferengine_normalize_club_short_name(text)') IS NOT NULL THEN
        v_buyer := public.transferengine_normalize_club_short_name(v_pick.bidder_club_id);
      ELSE
        v_buyer := nullif(btrim(v_pick.bidder_club_id), '');
      END IF;
    END LOOP;
  END IF;

  IF v_buyer IS NULL OR v_amount IS NULL OR v_amount <= 0 THEN
    PERFORM public.transferengine_close_listing_incomplete(v_listing.id);
    RETURN;
  END IF;

  UPDATE public."Player_Transfer_Listings"
  SET current_highest_bid = v_amount,
      current_highest_bidder = v_buyer
  WHERE id = v_listing.id;

  v_pid := btrim(v_listing.player_id::text);

  SELECT *
  INTO v_player
  FROM public."Players"
  WHERE "Konami_ID"::text = v_pid
  FOR UPDATE;

  IF NOT FOUND THEN
    PERFORM public.transferengine_close_listing_incomplete(v_listing.id);
    RETURN;
  END IF;

  IF v_player."Contracted_Team" IS NOT NULL
     AND btrim(v_player."Contracted_Team"::text) <> '' THEN
    UPDATE public."Player_Transfer_Listings"
    SET status = 'Closed',
        transfer_completed = (btrim(v_player."Contracted_Team"::text) = v_buyer),
        winning_bid = CASE WHEN btrim(v_player."Contracted_Team"::text) = v_buyer THEN v_amount ELSE winning_bid END,
        winning_club = CASE WHEN btrim(v_player."Contracted_Team"::text) = v_buyer THEN v_buyer ELSE winning_club END
    WHERE id = v_listing.id;
    RETURN;
  END IF;

  IF to_regprocedure('public.gpdb_player_is_season_excluded(text)') IS NOT NULL
     AND public.gpdb_player_is_season_excluded(v_pid) THEN
    PERFORM public.transferengine_close_listing_incomplete(v_listing.id);
    RAISE NOTICE
      'Draft listing % skipped — player % (%) is season-excluded',
      p_listing_id, v_pid, coalesce(v_player."Name", '?');
    RETURN;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public."Club_Finances" f WHERE f.club_name = v_buyer
  ) THEN
    RAISE EXCEPTION 'Club_Finances missing for buyer % (listing %)', v_buyer, p_listing_id;
  END IF;

  BEGIN
    IF to_regprocedure('public.player_assign_to_club(text, text, numeric, boolean)') IS NOT NULL THEN
      PERFORM public.player_assign_to_club(v_pid, v_buyer, NULL::numeric, false);
    ELSIF to_regprocedure('public.player_assign_to_club(text, text, numeric)') IS NOT NULL THEN
      PERFORM public.player_assign_to_club(v_pid, v_buyer, NULL::numeric);
    ELSE
      PERFORM public.player_assign_to_club(v_pid, v_buyer);
    END IF;
  EXCEPTION WHEN OTHERS THEN
    IF to_regprocedure('public.transferengine_is_exclusion_error(text)') IS NOT NULL
       AND public.transferengine_is_exclusion_error(SQLERRM) THEN
      PERFORM public.transferengine_close_listing_incomplete(v_listing.id);
      RAISE NOTICE 'Draft listing % skipped after assign guard: %', p_listing_id, SQLERRM;
      RETURN;
    END IF;
    RAISE;
  END;

  INSERT INTO public."Transfer_History" (
    player_id,
    seller_club_id,
    buyer_club_id,
    fee,
    agent_fee,
    transfer_time,
    listing_id
  )
  VALUES (
    v_pid,
    NULL,
    v_buyer,
    v_amount,
    0,
    now(),
    v_listing.id
  )
  RETURNING id INTO v_history_id;

  IF to_regprocedure('public.post_transfer_ledger_for_history(bigint, boolean)') IS NOT NULL THEN
    PERFORM public.post_transfer_ledger_for_history(v_history_id, true);
  ELSIF to_regprocedure('public.post_transfer_ledger_for_history(bigint)') IS NOT NULL THEN
    PERFORM public.post_transfer_ledger_for_history(v_history_id);
  ELSE
    RAISE EXCEPTION
      'post_transfer_ledger_for_history missing — draft listing % cannot settle without ledger',
      p_listing_id;
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.competition_finance_ledger l
    WHERE l.metadata->>'transfer_history_id' = v_history_id::text
      AND l.entry_type = 'transfer_purchase'
  ) THEN
    RAISE EXCEPTION
      'Draft listing % settled history % but transfer_purchase ledger row missing',
      p_listing_id, v_history_id;
  END IF;

  UPDATE public."Player_Transfer_Listings"
  SET status = 'Closed',
      transfer_completed = true,
      winning_bid = v_amount,
      winning_club = v_buyer
  WHERE id = v_listing.id;
END;
$function$;

COMMENT ON FUNCTION public.transferengine_accept_draft_sale(bigint) IS
  'Settle GPDB draft win; Limited Draft skips buyers already at win cap.';

-- ---------------------------------------------------------------------------
-- Expose style on public settings view (additive column)
-- ---------------------------------------------------------------------------

DROP VIEW IF EXISTS public.global_settings_public;
CREATE VIEW public.global_settings_public
WITH (security_invoker = false)
AS
SELECT
  id,
  transfer_window_open,
  draft_auction_enabled,
  manager_draft_auction_enabled,
  club_auction_enabled,
  draft_auction_start_time,
  manager_draft_auction_start_time,
  club_auction_start_time,
  updated_at,
  league_phase,
  wage_pct_superleague,
  wage_pct_championship,
  stadium_cost_tier1,
  stadium_cost_tier2,
  stadium_cost_tier3,
  stadium_capacity_tier_mid,
  stadium_capacity_tier_high,
  stadium_expansion_cancel_penalty,
  hg_sub_band1_max,
  hg_sub_band1_per_player,
  hg_sub_band2_max,
  hg_sub_band2_per_player,
  hg_sub_band3_per_player,
  youth_sub_band1_max,
  youth_sub_band1_per_player,
  youth_sub_band2_max,
  youth_sub_band2_per_player,
  youth_sub_band3_max,
  youth_sub_band3_per_player,
  youth_sub_band4_per_player,
  bnb_max_rating,
  bnb_min_players,
  bnb_per_player,
  tv_per_match_amount,
  tv_matches_per_month,
  tv_club_min_season,
  tv_club_max_season,
  tv_weight_top8_clash,
  tv_weight_title_race,
  tv_weight_promotion,
  tv_weight_relegation,
  tv_weight_super8,
  tv_weight_playoff,
  tv_weight_dry_spell,
  tv_weight_below_min,
  challenge_default_prize,
  challenge_period_bonus,
  wage_34plus_min_rating,
  wage_34plus_per_player,
  star_tax_min_rating,
  star_tax_per_player,
  emergency_tac_pct,
  emergency_tac_threshold,
  gov_income_tax_pct,
  player_draft_max_signings_per_club,
  (
    COALESCE(draft_auction_enabled, false)
    AND draft_auction_start_time IS NOT NULL
    AND draft_random_finish_time IS NOT NULL
    AND now() >= draft_auction_start_time
    AND now() < draft_random_finish_time
  ) AS draft_bidding_open,
  (
    COALESCE(manager_draft_auction_enabled, false)
    AND manager_draft_auction_start_time IS NOT NULL
    AND manager_draft_random_finish_time IS NOT NULL
    AND now() >= manager_draft_auction_start_time
    AND now() < manager_draft_random_finish_time
  ) AS manager_draft_bidding_open,
  (
    COALESCE(club_auction_enabled, false)
    AND club_auction_start_time IS NOT NULL
    AND club_auction_random_finish_time IS NOT NULL
    AND now() >= club_auction_start_time
    AND now() < club_auction_random_finish_time
  ) AS club_auction_bidding_open,
  CASE
    WHEN draft_random_finish_time IS NOT NULL
     AND now() >= draft_random_finish_time
    THEN draft_random_finish_time
    ELSE NULL
  END AS draft_random_finish_revealed,
  CASE
    WHEN manager_draft_random_finish_time IS NOT NULL
     AND now() >= manager_draft_random_finish_time
    THEN manager_draft_random_finish_time
    ELSE NULL
  END AS manager_draft_random_finish_revealed,
  CASE
    WHEN club_auction_random_finish_time IS NOT NULL
     AND now() >= club_auction_random_finish_time
    THEN club_auction_random_finish_time
    ELSE NULL
  END AS club_auction_random_finish_revealed
FROM public.global_settings;

GRANT SELECT ON public.global_settings_public TO authenticated;
GRANT SELECT ON public.global_settings_public TO anon;

NOTIFY pgrst, 'reload schema';
