-- =============================================================================
-- Special auction player prize — winner options v3
--
-- The prize player joins the winner's squad at settle. The winner then picks:
--   1. Keep player  — only if contracted squad + leading auction bids ≤ 28
--   2. Release current squad player(s) at market value to make room, then Keep
--      (only while still over 28; once used, cash is no longer available)
--   3. Take cash    — prize player released, club credited 100% market value
--
-- Listing the prize on the transfer market is no longer an option.
-- "Leading auction bids" = transfer / draft listings the club currently leads
-- (Active, Review, Seller Review) for players not already at the club — the
-- same rule the Squad page uses for pending "ghost" signings.
--
-- Run after special_auction_winner_keep_prep_release.sql. Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.special_auction_club_squad_space(p_club text)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := upper(btrim(coalesce(p_club, '')));
  v_max int := 28;
  v_squad int := 0;
  v_pending int := 0;
BEGIN
  IF v_club = '' THEN
    RETURN jsonb_build_object('squad', 0, 'pending', 0, 'total', 0, 'max', v_max);
  END IF;

  SELECT count(*)::int INTO v_squad
  FROM public."Players" p
  WHERE upper(btrim(coalesce(p."Contracted_Team", ''))) = v_club;

  SELECT count(DISTINCT l.player_id::text)::int INTO v_pending
  FROM public."Player_Transfer_Listings" l
  LEFT JOIN public."Players" p ON p."Konami_ID"::text = l.player_id::text
  WHERE upper(btrim(coalesce(l.current_highest_bidder::text, ''))) = v_club
    AND l.status IN ('Active', 'Review', 'Seller Review')
    AND upper(btrim(coalesce(l.seller_club_id::text, ''))) <> v_club
    AND upper(btrim(coalesce(p."Contracted_Team", ''))) <> v_club;

  RETURN jsonb_build_object(
    'squad', coalesce(v_squad, 0),
    'pending', coalesce(v_pending, 0),
    'total', coalesce(v_squad, 0) + coalesce(v_pending, 0),
    'max', v_max
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.special_auction_club_squad_space(text) FROM PUBLIC;

-- Winner panel: squad space + cash value for the prize
CREATE OR REPLACE FUNCTION public.special_auction_winner_prize_space(p_auction_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  a public.special_auctions%rowtype;
  v_club text := public.my_club_shortname();
  v_space jsonb;
  v_mv numeric;
  v_total int;
  v_max int;
BEGIN
  SELECT * INTO a FROM public.special_auctions WHERE id = p_auction_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Auction not found'; END IF;
  IF upper(btrim(coalesce(a.winning_club_id, ''))) IS DISTINCT FROM upper(btrim(coalesce(v_club, '')))
     AND NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Only the winning club can view prize options';
  END IF;

  v_space := public.special_auction_club_squad_space(a.winning_club_id);
  v_total := (v_space->>'total')::int;
  v_max := (v_space->>'max')::int;

  SELECT greatest(coalesce(nullif(btrim(p.market_value::text), '')::numeric, 0), 0)
  INTO v_mv
  FROM public."Players" p
  WHERE p."Konami_ID"::text = nullif(btrim(coalesce(a.prize_player_id, a.known_player_id, '')), '');

  RETURN v_space || jsonb_build_object(
    'can_keep', v_total <= v_max,
    'over_by', greatest(v_total - v_max, 0),
    'market_value', coalesce(v_mv, 0),
    'cash_value', round(coalesce(v_mv, 0)),
    'keep_prep_done', coalesce(a.winner_keep_prep_done, false)
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.special_auction_winner_prize_space(bigint) TO authenticated;

-- 1. Keep — contracted squad + leading auction bids must fit
CREATE OR REPLACE FUNCTION public.special_auction_winner_keep_prize(p_auction_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  a public.special_auctions%rowtype;
  v_club text := public.my_club_shortname();
  v_space jsonb;
  v_squad int;
  v_pending int;
  v_total int;
  v_max int;
BEGIN
  SELECT * INTO a FROM public.special_auctions WHERE id = p_auction_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Auction not found'; END IF;
  IF a.status <> 'settled' OR a.prize_type <> 'player' THEN
    RAISE EXCEPTION 'Not a settled player special auction';
  END IF;
  IF upper(btrim(coalesce(a.winning_club_id, ''))) IS DISTINCT FROM upper(btrim(coalesce(v_club, '')))
     AND NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Only the winning club can confirm';
  END IF;
  IF NOT coalesce(a.winner_prize_pending, false) THEN
    RAISE EXCEPTION 'Prize options are not open for this auction';
  END IF;

  v_space := public.special_auction_club_squad_space(a.winning_club_id);
  v_squad := (v_space->>'squad')::int;
  v_pending := (v_space->>'pending')::int;
  v_total := (v_space->>'total')::int;
  v_max := (v_space->>'max')::int;

  IF v_total > v_max THEN
    RAISE EXCEPTION
      'No room to keep: % contracted (incl. prize) + % leading auction bid(s) = %, max %. Release % squad player(s) at market value first, or take the cash.',
      v_squad, v_pending, v_total, v_max, v_total - v_max;
  END IF;

  UPDATE public.special_auctions
  SET winner_prize_pending = false,
      winner_prize_resolved = true,
      updated_at = now()
  WHERE id = p_auction_id;

  RETURN jsonb_build_object(
    'ok', true,
    'action', 'keep',
    'squad_size', v_squad,
    'pending_bids', v_pending,
    'total', v_total
  );
END;
$function$;

-- 2. Release a current squad player at MV to make room (repeatable while still over)
CREATE OR REPLACE FUNCTION public.special_auction_winner_release_squad_for_keep(
  p_auction_id bigint,
  p_player_id text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  a public.special_auctions%rowtype;
  v_club text := public.my_club_shortname();
  v_pid text := nullif(btrim(coalesce(p_player_id, '')), '');
  v_prize text;
  v_name text;
  v_team text;
  v_mv numeric;
  v_hist bigint;
  v_listing int;
  v_space jsonb;
  v_total int;
  v_max int;
BEGIN
  IF v_pid IS NULL THEN
    RAISE EXCEPTION 'Choose a squad player to release';
  END IF;

  SELECT * INTO a
  FROM public.special_auctions
  WHERE id = p_auction_id
  FOR UPDATE;

  IF NOT FOUND THEN RAISE EXCEPTION 'Auction not found'; END IF;
  IF a.status <> 'settled' OR a.prize_type <> 'player' THEN
    RAISE EXCEPTION 'Not a settled player special auction';
  END IF;
  IF upper(btrim(coalesce(a.winning_club_id, ''))) IS DISTINCT FROM upper(btrim(coalesce(v_club, '')))
     AND NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Only the winning club can do this';
  END IF;
  IF NOT coalesce(a.winner_prize_pending, false) THEN
    RAISE EXCEPTION 'Prize options are not open for this auction';
  END IF;

  v_prize := nullif(btrim(coalesce(a.prize_player_id, a.known_player_id, '')), '');
  IF v_prize IS NOT NULL AND v_pid = v_prize THEN
    RAISE EXCEPTION 'That is the prize player — use “Take cash (MV)” instead';
  END IF;

  SELECT count(*)::int INTO v_listing
  FROM public."Player_Transfer_Listings" l
  WHERE l.player_id::text = coalesce(v_prize, '')
    AND l.seller_club_id = a.winning_club_id
    AND l.status = 'Active';
  IF coalesce(v_listing, 0) > 0 THEN
    RAISE EXCEPTION 'Prize is listed on the market — take the cash (cancels the listing) or wait for the sale';
  END IF;

  v_space := public.special_auction_club_squad_space(a.winning_club_id);
  v_total := (v_space->>'total')::int;
  v_max := (v_space->>'max')::int;
  IF v_total <= v_max THEN
    RAISE EXCEPTION 'You already have room (% / %) — use Keep player', v_total, v_max;
  END IF;

  SELECT p."Name", p."Contracted_Team",
         greatest(coalesce(nullif(btrim(p.market_value::text), '')::numeric, 0), 0)
  INTO v_name, v_team, v_mv
  FROM public."Players" p
  WHERE p."Konami_ID"::text = v_pid
  FOR UPDATE;

  IF NOT FOUND THEN RAISE EXCEPTION 'Player not found'; END IF;
  IF v_team IS DISTINCT FROM a.winning_club_id THEN
    RAISE EXCEPTION 'That player is not at your club';
  END IF;

  UPDATE public."Player_Transfer_Listings" l
  SET status = 'Closed',
      transfer_completed = false
  WHERE l.player_id::text = v_pid
    AND l.seller_club_id = a.winning_club_id
    AND l.status IN ('Active', 'Review');

  IF to_regprocedure('public.player_release_from_club(text)') IS NOT NULL THEN
    PERFORM public.player_release_from_club(v_pid);
  ELSE
    UPDATE public."Players"
    SET "Contracted_Team" = NULL,
        "Season_Signed" = NULL,
        contract_seasons_remaining = NULL,
        contract_wage = NULL
    WHERE "Konami_ID"::text = v_pid;
  END IF;

  INSERT INTO public."Transfer_History" (
    player_id, seller_club_id, buyer_club_id, fee, agent_fee,
    transfer_time, listing_id, foreign_buyer_name, transfer_sale_note
  )
  VALUES (
    v_pid, a.winning_club_id, 'FOREIGN', v_mv, 0,
    now(), NULL, 'Special auction keep prep (market value)', 'special_auction_keep_prep'
  )
  RETURNING id INTO v_hist;

  IF to_regprocedure('public.post_transfer_ledger_for_history(bigint,boolean)') IS NOT NULL THEN
    PERFORM public.post_transfer_ledger_for_history(v_hist, true);
  ELSE
    UPDATE public."Club_Finances"
    SET balance = balance + v_mv
    WHERE club_name = a.winning_club_id;
  END IF;

  UPDATE public.special_auctions
  SET winner_keep_prep_done = true,
      winner_keep_prep_player_id = v_pid,
      updated_at = now()
  WHERE id = p_auction_id;

  v_space := public.special_auction_club_squad_space(a.winning_club_id);

  RETURN jsonb_build_object(
    'ok', true,
    'action', 'release_squad_for_keep',
    'player_id', v_pid,
    'player_name', v_name,
    'market_value', v_mv,
    'history_id', v_hist,
    'total', (v_space->>'total')::int,
    'max', (v_space->>'max')::int,
    'can_keep', (v_space->>'total')::int <= (v_space->>'max')::int
  );
END;
$function$;

-- Listing the prize is retired
CREATE OR REPLACE FUNCTION public.special_auction_winner_list_prize_player(p_auction_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  RAISE EXCEPTION 'Listing the prize is no longer an option — keep the player or take market value in cash';
END;
$function$;

-- 3. Take cash — prize released, 100% market value credited
DROP FUNCTION IF EXISTS public.special_auction_winner_release_player(bigint, text);
DROP FUNCTION IF EXISTS public.special_auction_winner_release_player(bigint);

CREATE OR REPLACE FUNCTION public.special_auction_winner_release_player(
  p_auction_id bigint
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  a public.special_auctions%rowtype;
  v_my_club text := public.my_club_shortname();
  v_win text;
  v_pid text;
  v_mv numeric;
  v_credit numeric;
  v_name text;
  v_team text;
  v_season_id bigint;
  v_ledger bigint;
BEGIN
  SELECT * INTO a FROM public.special_auctions WHERE id = p_auction_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Auction not found';
  END IF;
  IF a.status <> 'settled' OR a.prize_type <> 'player' THEN
    RAISE EXCEPTION 'Not a settled player special auction';
  END IF;

  v_win := upper(btrim(coalesce(a.winning_club_id, '')));
  IF v_my_club IS NULL OR btrim(v_my_club) = '' THEN
    RAISE EXCEPTION 'No club linked to this account';
  END IF;
  IF v_win = '' OR (
    v_win IS DISTINCT FROM upper(btrim(v_my_club))
    AND NOT public.is_gpsl_admin()
  ) THEN
    RAISE EXCEPTION 'Only the winning club (%) can resolve the prize (you are %)',
      a.winning_club_id, v_my_club;
  END IF;

  IF NOT coalesce(a.winner_prize_pending, false) THEN
    RAISE EXCEPTION 'Prize options are not open for this auction';
  END IF;
  IF coalesce(a.winner_keep_prep_done, false) THEN
    RAISE EXCEPTION 'You already released a squad player to keep this prize — use Keep player';
  END IF;

  v_pid := nullif(btrim(coalesce(a.prize_player_id, '')), '');
  IF v_pid IS NULL THEN
    RAISE EXCEPTION 'No prize player on this auction';
  END IF;

  SELECT p."market_value", p."Name", p."Contracted_Team"
  INTO v_mv, v_name, v_team
  FROM public."Players" p
  WHERE p."Konami_ID"::text = v_pid
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Prize player % not found in GPDB', v_pid;
  END IF;

  IF upper(btrim(coalesce(public.player_contracted_club_key(v_team), '')))
       IS DISTINCT FROM v_win THEN
    RAISE EXCEPTION
      'Prize player % (%) is not at % (currently %). If squad overflow released them, ask admin to clear prize options.',
      coalesce(v_name, v_pid), v_pid, a.winning_club_id, coalesce(v_team, 'free agent');
  END IF;

  v_credit := greatest(round(coalesce(v_mv, 0)), 0);

  UPDATE public."Player_Transfer_Listings"
  SET status = 'Closed',
      transfer_completed = false
  WHERE player_id::text = v_pid
    AND upper(btrim(seller_club_id::text)) = v_win
    AND status IN ('Active', 'Review', 'Seller Review');

  PERFORM public.player_release_from_club(v_pid);

  SELECT id INTO v_season_id
  FROM public.competition_seasons
  WHERE is_current = true
  ORDER BY id DESC
  LIMIT 1;

  IF to_regprocedure(
    'public.post_club_ledger(text,text,numeric,text,jsonb,bigint,bigint,boolean,boolean)'
  ) IS NOT NULL THEN
    v_ledger := public.post_club_ledger(
      a.winning_club_id,
      'special_auction_prize',
      v_credit,
      format('Special auction prize taken as cash (market value): %s', coalesce(v_name, v_pid)),
      jsonb_build_object(
        'special_auction_id', a.id,
        'player_id', v_pid,
        'player_name', v_name,
        'market_value', v_mv,
        'rate', 1.0,
        'action', 'take_cash'
      ),
      v_season_id,
      NULL,
      true,
      true
    );
  ELSE
    IF EXISTS (
      SELECT 1 FROM public."Club_Finances" f WHERE f.club_name = a.winning_club_id
    ) THEN
      UPDATE public."Club_Finances"
      SET balance = balance + v_credit
      WHERE club_name = a.winning_club_id;
    ELSE
      INSERT INTO public."Club_Finances" (club_name, balance)
      VALUES (a.winning_club_id, v_credit);
    END IF;
  END IF;

  UPDATE public.special_auctions
  SET winner_prize_pending = false,
      winner_prize_resolved = true,
      updated_at = now()
  WHERE id = p_auction_id;

  RETURN jsonb_build_object(
    'ok', true,
    'action', 'take_cash',
    'player_id', v_pid,
    'player_name', v_name,
    'credit', v_credit,
    'rate', 1.0,
    'ledger_id', v_ledger
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.special_auction_winner_release_player(
  p_auction_id bigint,
  p_player_id text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  RETURN public.special_auction_winner_release_player(p_auction_id);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.special_auction_winner_keep_prize(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.special_auction_winner_release_squad_for_keep(bigint, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.special_auction_winner_list_prize_player(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.special_auction_winner_release_player(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.special_auction_winner_release_player(bigint, text) TO authenticated;

NOTIFY pgrst, 'reload schema';

-- Report: open player prizes and each winner's room
SELECT a.id AS auction_id,
       a.title,
       a.winning_club_id,
       a.prize_player_id,
       coalesce(a.winner_keep_prep_done, false) AS keep_prep_done,
       s.space->>'squad' AS contracted,
       s.space->>'pending' AS leading_bids,
       s.space->>'total' AS total,
       ((s.space->>'total')::int <= 28) AS can_keep_now
FROM (SELECT 1) one
LEFT JOIN public.special_auctions a
  ON a.status = 'settled'
 AND a.prize_type = 'player'
 AND coalesce(a.winner_prize_pending, false)
LEFT JOIN LATERAL (
  SELECT public.special_auction_club_squad_space(a.winning_club_id) AS space
) s ON a.id IS NOT NULL
ORDER BY a.id;
