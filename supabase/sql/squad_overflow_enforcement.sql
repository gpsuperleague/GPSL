-- =============================================================================
-- Squad size overflow (max 28): allow 29th signing, auto-release highest rated
-- Run AFTER squad_composition_rules.sql, sell_to_foreign_club.sql,
-- foreign_interest_teams.sql, player_contracts_phase3_expiry.sql
-- =============================================================================

-- Supabase SQL Editor runs as postgres (no JWT) — allow admin RPCs there too
CREATE OR REPLACE FUNCTION public.is_gpsl_admin()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    lower(coalesce(auth.jwt() ->> 'email', '')) = 'rotavator66@outlook.com'
    OR current_user IN ('postgres', 'supabase_admin')
    OR coalesce(auth.jwt() ->> 'role', '') = 'service_role';
$$;

-- Label overflow / special sales in Transfer Centre (Season Sales)
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'Transfer_History'
      AND column_name = 'transfer_sale_note'
  ) THEN
    ALTER TABLE public."Transfer_History"
      ADD COLUMN transfer_sale_note text;
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.squad_max_size()
RETURNS int
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT 28;
$$;

CREATE OR REPLACE FUNCTION public.player_rating_as_numeric(p_rating text)
RETURNS numeric
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE
    WHEN p_rating IS NULL OR btrim(p_rating::text) = '' THEN 0::numeric
    ELSE btrim(p_rating::text)::numeric
  END;
$$;

CREATE OR REPLACE FUNCTION public.club_squad_player_count(p_club_short_name text)
RETURNS int
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT count(*)::int
  FROM public."Players" p
  WHERE p."Contracted_Team" = btrim(p_club_short_name);
$$;

-- Highest rated squad player eligible for overflow release (not signed this season).
CREATE OR REPLACE FUNCTION public.pick_squad_overflow_release_player(
  p_club_short_name text,
  p_exclude_player_id text DEFAULT NULL
)
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := btrim(p_club_short_name);
  v_exclude text := nullif(btrim(coalesce(p_exclude_player_id, '')), '');
  v_pid text;
BEGIN
  SELECT p."Konami_ID"::text
  INTO v_pid
  FROM public."Players" p
  WHERE p."Contracted_Team" = v_club
    AND (v_exclude IS NULL OR p."Konami_ID"::text IS DISTINCT FROM v_exclude)
    AND NOT public.player_signed_this_season(p."Season_Signed")
  ORDER BY public.player_rating_as_numeric(p."Rating"::text) DESC, p."Name"
  LIMIT 1;

  IF v_pid IS NOT NULL THEN
    RETURN v_pid;
  END IF;

  -- Fallback: every remaining player signed this season — release highest rated other than new signing
  SELECT p."Konami_ID"::text
  INTO v_pid
  FROM public."Players" p
  WHERE p."Contracted_Team" = v_club
    AND (v_exclude IS NULL OR p."Konami_ID"::text IS DISTINCT FROM v_exclude)
  ORDER BY public.player_rating_as_numeric(p."Rating"::text) DESC, p."Name"
  LIMIT 1;

  RETURN v_pid;
END;
$function$;

-- MV credit + free agent (squad overflow; not final-year only)
CREATE OR REPLACE FUNCTION public.club_release_player_mv_overflow(
  p_club_short_name text,
  p_player_id text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club   text := btrim(p_club_short_name);
  v_pid    text := btrim(p_player_id);
  v_player public."Players"%rowtype;
  v_fee    numeric;
  v_bal    numeric;
BEGIN
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

  SELECT balance INTO v_bal
  FROM public."Club_Finances"
  WHERE club_name = v_club
  FOR UPDATE;

  IF v_bal IS NULL THEN
    RAISE EXCEPTION 'Club finances not found for %', v_club;
  END IF;

  PERFORM public.player_release_from_club(v_pid);

  UPDATE public."Club_Finances"
  SET balance = v_bal + v_fee
  WHERE club_name = v_club;

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
    NULL,
    v_fee,
    0,
    now(),
    NULL,
    'Market value (squad over 28)',
    'squad_overflow'
  );

  RETURN jsonb_build_object(
    'ok', true,
    'method', 'market_value',
    'player_id', v_pid,
    'player_name', v_player."Name",
    'rating', v_player."Rating",
    'fee', v_fee
  );
END;
$function$;

-- Foreign sale slot (squad overflow; uses one tracking club if available)
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
    'foreign_interest_remaining', v_interest_after
  );
END;
$function$;

-- After a signing: if squad > 28, release one player (foreign slot if any, else MV)
CREATE OR REPLACE FUNCTION public.enforce_squad_overflow_after_signing(
  p_club_short_name text,
  p_new_player_id text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club     text := btrim(p_club_short_name);
  v_total    int;
  v_release  text;
  v_player   public."Players"%rowtype;
  v_interest int;
  v_teams    text[];
  v_team     text;
  v_result   jsonb;
BEGIN
  v_total := public.club_squad_player_count(v_club);

  IF v_total <= public.squad_max_size() THEN
    RETURN jsonb_build_object('released', false, 'squad_total', v_total);
  END IF;

  v_release := public.pick_squad_overflow_release_player(v_club, p_new_player_id);

  IF v_release IS NULL THEN
    RAISE EXCEPTION
      'Squad has % players (max %) but no player could be selected for overflow release',
      v_total, public.squad_max_size();
  END IF;

  SELECT * INTO v_player
  FROM public."Players" p
  WHERE p."Konami_ID"::text = v_release;

  SELECT coalesce(c.foreign_interest_remaining, 0)
  INTO v_interest
  FROM public."Clubs" c
  WHERE c."ShortName" = v_club;

  IF coalesce(v_interest, 0) > 0 THEN
    v_teams := public.sync_club_foreign_tracking(v_club);
    v_team := v_teams[1];

    IF v_team IS NULL OR btrim(v_team) = '' THEN
      v_result := public.club_release_player_mv_overflow(v_club, v_release);
      v_result := v_result || jsonb_build_object(
        'released', true,
        'squad_total_before', v_total,
        'reason', 'no_tracking_team'
      );
    ELSE
      v_result := public.club_release_player_foreign_overflow(v_club, v_release, v_team);
      v_result := v_result || jsonb_build_object(
        'released', true,
        'squad_total_before', v_total
      );
    END IF;
  ELSE
    v_result := public.club_release_player_mv_overflow(v_club, v_release);
    v_result := v_result || jsonb_build_object(
      'released', true,
      'squad_total_before', v_total
    );
  END IF;

  RETURN v_result;
END;
$function$;

-- Signing hook: always 3 seasons; auto-release if squad exceeds 28
-- (void → jsonb return type requires drop first if phase 1/3 version exists)
DROP FUNCTION IF EXISTS public.player_assign_to_club(text, text);
DROP FUNCTION IF EXISTS public.player_assign_to_club(text, text, numeric);

CREATE OR REPLACE FUNCTION public.player_assign_to_club(
  p_player_id text,
  p_club_short_name text,
  p_wage numeric DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_pid      text := btrim(p_player_id);
  v_club     text := btrim(p_club_short_name);
  v_season   text;
  v_wage     numeric;
  v_overflow jsonb;
BEGIN
  IF v_pid = '' OR v_club = '' THEN
    RAISE EXCEPTION 'player_assign_to_club: player_id and club are required';
  END IF;

  v_season := public.current_gpsl_season_label();
  v_wage := coalesce(p_wage, public.calculate_player_wage_for_club(v_pid, v_club));

  UPDATE public."Players"
  SET
    "Contracted_Team" = v_club,
    "Season_Signed" = v_season,
    contract_seasons_remaining = 3,
    contract_wage = round(coalesce(v_wage, 0), 0)
  WHERE "Konami_ID"::text = v_pid;

  v_overflow := public.enforce_squad_overflow_after_signing(v_club, v_pid);

  RETURN jsonb_build_object(
    'ok', true,
    'player_id', v_pid,
    'club_short_name', v_club,
    'contract_seasons_remaining', 3,
    'overflow_release', v_overflow
  );
END;
$function$;

-- Preview who would be released (admin / SQL editor only — not granted to app users)
CREATE OR REPLACE FUNCTION public.preview_squad_overflow_release(
  p_club_short_name text,
  p_exclude_player_id text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club   text := btrim(p_club_short_name);
  v_total  int;
  v_pid    text;
  v_player public."Players"%rowtype;
  v_interest int;
  v_teams  text[];
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  v_total := public.club_squad_player_count(v_club);
  v_pid := public.pick_squad_overflow_release_player(v_club, p_exclude_player_id);

  IF v_pid IS NULL THEN
    RETURN jsonb_build_object(
      'club_short_name', v_club,
      'squad_total', v_total,
      'would_release', false,
      'reason', 'no_eligible_player'
    );
  END IF;

  SELECT * INTO v_player FROM public."Players" p WHERE p."Konami_ID"::text = v_pid;

  SELECT coalesce(c.foreign_interest_remaining, 0)
  INTO v_interest
  FROM public."Clubs" c
  WHERE c."ShortName" = v_club;

  v_teams := public.sync_club_foreign_tracking(v_club);

  RETURN jsonb_build_object(
    'club_short_name', v_club,
    'squad_total', v_total,
    'would_release', true,
    'player_id', v_pid,
    'player_name', v_player."Name",
    'rating', v_player."Rating",
    'season_signed', v_player."Season_Signed",
    'signed_this_season', public.player_signed_this_season(v_player."Season_Signed"),
    'market_value', v_player.market_value,
    'release_method',
      CASE
        WHEN coalesce(v_interest, 0) > 0 AND v_teams[1] IS NOT NULL
          THEN 'foreign'
        ELSE 'market_value'
      END,
    'foreign_buyer_name', CASE WHEN coalesce(v_interest, 0) > 0 THEN v_teams[1] ELSE NULL END,
    'foreign_interest_remaining', v_interest
  );
END;
$function$;

-- Admin: fix squad already over 28 without adding a player (retrospective cleanup / test)
CREATE OR REPLACE FUNCTION public.admin_enforce_squad_overflow(p_club_short_name text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  RETURN public.enforce_squad_overflow_after_signing(btrim(p_club_short_name), NULL);
END;
$function$;

REVOKE ALL ON FUNCTION public.enforce_squad_overflow_after_signing(text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.club_release_player_mv_overflow(text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.club_release_player_foreign_overflow(text, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.pick_squad_overflow_release_player(text, text) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.squad_max_size() TO authenticated;
GRANT EXECUTE ON FUNCTION public.club_squad_player_count(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.player_assign_to_club(text, text, numeric) TO authenticated;
GRANT EXECUTE ON FUNCTION public.preview_squad_overflow_release(text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_enforce_squad_overflow(text) TO authenticated;
