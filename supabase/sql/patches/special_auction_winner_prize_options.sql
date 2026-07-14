-- =============================================================================
-- Special auction — harden winner prize options (squad-size keep rule)
--
-- Keep: only if winning club squad ≤ 28 (prize already assigned on settle).
-- Release: defaults to prize_player_id; cancels active listing first.
-- List: idempotent if already listed; pending stays open for 125% release.
--
-- Run after special_auction_snap_v2.sql. Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.special_auction_winner_keep_prize(p_auction_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  a public.special_auctions%rowtype;
  v_club text := public.my_club_shortname();
  v_squad int;
  v_max int := 28;
BEGIN
  SELECT * INTO a FROM public.special_auctions WHERE id = p_auction_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Auction not found'; END IF;
  IF a.status <> 'settled' OR a.prize_type <> 'player' THEN
    RAISE EXCEPTION 'Not a settled player special auction';
  END IF;
  IF a.winning_club_id IS DISTINCT FROM v_club AND NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Only the winning club can confirm';
  END IF;
  IF NOT coalesce(a.winner_prize_pending, false) THEN
    RAISE EXCEPTION 'Prize options are not open for this auction';
  END IF;

  SELECT count(*)::int INTO v_squad
  FROM public."Players" p
  WHERE p."Contracted_Team" = a.winning_club_id;

  IF coalesce(v_squad, 0) > v_max THEN
    RAISE EXCEPTION
      'Squad is over % players (%). List the prize on the market or release at 125%% MV — you cannot keep an over-size squad.',
      v_max, v_squad;
  END IF;

  UPDATE public.special_auctions
  SET winner_prize_pending = false,
      winner_prize_resolved = true,
      updated_at = now()
  WHERE id = p_auction_id;

  RETURN jsonb_build_object(
    'ok', true,
    'action', 'keep',
    'squad_size', v_squad
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.special_auction_winner_list_prize_player(p_auction_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  a public.special_auctions%rowtype;
  v_my_club text := public.my_club_shortname();
  v_pid text;
  v_mv numeric;
  v_team text;
  v_listing_id bigint;
  v_now timestamptz := now();
  v_end timestamptz := now() + interval '24 hours';
BEGIN
  SELECT * INTO a FROM public.special_auctions WHERE id = p_auction_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Auction not found'; END IF;
  IF a.status <> 'settled' OR a.prize_type <> 'player' THEN
    RAISE EXCEPTION 'Not a settled player special auction';
  END IF;
  IF a.winning_club_id IS DISTINCT FROM v_my_club AND NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Only the winning club can list the prize player';
  END IF;
  IF NOT coalesce(a.winner_prize_pending, false) THEN
    RAISE EXCEPTION 'Prize options are not open';
  END IF;

  v_pid := a.prize_player_id;
  IF v_pid IS NULL OR btrim(v_pid) = '' THEN
    RAISE EXCEPTION 'No prize player on this auction';
  END IF;

  SELECT p."market_value", p."Contracted_Team"
  INTO v_mv, v_team
  FROM public."Players" p
  WHERE p."Konami_ID"::text = v_pid
  FOR UPDATE;

  IF NOT FOUND OR v_team IS DISTINCT FROM a.winning_club_id THEN
    RAISE EXCEPTION 'Prize player is not at your club';
  END IF;

  SELECT l.id INTO v_listing_id
  FROM public."Player_Transfer_Listings" l
  WHERE l.player_id = v_pid
    AND l.seller_club_id = a.winning_club_id
    AND l.status = 'Active'
  ORDER BY l.id DESC
  LIMIT 1;

  IF v_listing_id IS NOT NULL THEN
    RETURN jsonb_build_object(
      'ok', true,
      'action', 'list',
      'already_listed', true,
      'listing_id', v_listing_id,
      'player_id', v_pid,
      'asking_price', coalesce(v_mv, 0)
    );
  END IF;

  INSERT INTO public."Player_Transfer_Listings" (
    player_id,
    seller_club_id,
    reserve_price,
    market_value,
    status,
    listing_type,
    created_at,
    start_time,
    end_time,
    initial_end_time
  )
  VALUES (
    v_pid,
    a.winning_club_id,
    coalesce(v_mv, 0),
    coalesce(v_mv, 0),
    'Active',
    'standard',
    v_now,
    v_now,
    v_end,
    v_end
  )
  RETURNING id INTO v_listing_id;

  RETURN jsonb_build_object(
    'ok', true,
    'action', 'list',
    'already_listed', false,
    'listing_id', v_listing_id,
    'player_id', v_pid,
    'asking_price', coalesce(v_mv, 0)
  );
END;
$function$;

-- Drop old 2-arg signature then recreate with default + 1-arg wrapper
DROP FUNCTION IF EXISTS public.special_auction_winner_release_player(bigint, text);
DROP FUNCTION IF EXISTS public.special_auction_winner_release_player(bigint);

CREATE OR REPLACE FUNCTION public.special_auction_winner_release_player(
  p_auction_id bigint,
  p_player_id text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  a public.special_auctions%rowtype;
  v_my_club text := public.my_club_shortname();
  v_pid text;
  v_mv numeric;
  v_credit numeric;
  v_name text;
  v_team text;
BEGIN
  SELECT * INTO a FROM public.special_auctions WHERE id = p_auction_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Auction not found'; END IF;
  IF a.status <> 'settled' OR a.prize_type <> 'player' THEN
    RAISE EXCEPTION 'Not a settled player special auction';
  END IF;
  IF a.winning_club_id IS DISTINCT FROM v_my_club AND NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Only the winning club can resolve the prize';
  END IF;
  IF NOT coalesce(a.winner_prize_pending, false) THEN
    RAISE EXCEPTION 'Prize options are not open for this auction';
  END IF;

  v_pid := nullif(btrim(coalesce(p_player_id, '')), '');
  IF v_pid IS NULL THEN
    v_pid := a.prize_player_id;
  END IF;
  IF v_pid IS NULL OR btrim(v_pid) = '' THEN
    RAISE EXCEPTION 'No prize player on this auction';
  END IF;

  SELECT p."market_value", p."Name", p."Contracted_Team"
  INTO v_mv, v_name, v_team
  FROM public."Players" p
  WHERE p."Konami_ID"::text = v_pid
  FOR UPDATE;

  IF NOT FOUND THEN RAISE EXCEPTION 'Player not found'; END IF;
  IF v_team IS DISTINCT FROM a.winning_club_id THEN
    RAISE EXCEPTION 'Player is not at the winning club';
  END IF;

  v_credit := round(coalesce(v_mv, 0) * 1.25);

  UPDATE public."Player_Transfer_Listings"
  SET status = 'Cancelled'
  WHERE player_id = v_pid
    AND seller_club_id = a.winning_club_id
    AND status = 'Active';

  UPDATE public."Players"
  SET "Contracted_Team" = NULL,
      "Season_Signed" = NULL,
      contract_seasons_remaining = NULL,
      contract_wage = NULL
  WHERE "Konami_ID"::text = v_pid;

  UPDATE public."Club_Finances"
  SET balance = balance + v_credit
  WHERE club_name = a.winning_club_id;

  UPDATE public.special_auctions
  SET winner_prize_pending = false,
      winner_prize_resolved = true,
      updated_at = now()
  WHERE id = p_auction_id;

  RETURN jsonb_build_object(
    'ok', true,
    'action', 'release_125',
    'player_id', v_pid,
    'player_name', v_name,
    'credit', v_credit,
    'rate', 1.25
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.special_auction_winner_keep_prize(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.special_auction_winner_list_prize_player(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.special_auction_winner_release_player(bigint, text) TO authenticated;

NOTIFY pgrst, 'reload schema';
