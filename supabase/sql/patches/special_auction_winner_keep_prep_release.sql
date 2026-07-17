-- =============================================================================
-- Special auction prize options: release a current squad player to prepare Keep
--
-- Flow:
--   • Default: Keep / List prize / Release prize @125% / Release squad player @MV
--   • After releasing a squad member: only Keep remains (list + 125% hidden)
--   • After listing the prize: squad-release path hidden
--
-- Does not use voluntary contract release quota. Credits market value.
-- Safe re-run.
-- =============================================================================

ALTER TABLE public.special_auctions
  ADD COLUMN IF NOT EXISTS winner_keep_prep_done boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS winner_keep_prep_player_id text;

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
  IF a.winning_club_id IS DISTINCT FROM v_club AND NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Only the winning club can do this';
  END IF;
  IF NOT coalesce(a.winner_prize_pending, false) THEN
    RAISE EXCEPTION 'Prize options are not open for this auction';
  END IF;
  IF coalesce(a.winner_keep_prep_done, false) THEN
    RAISE EXCEPTION 'You already released a squad player for this prize — use Keep player';
  END IF;

  v_prize := nullif(btrim(coalesce(a.prize_player_id, a.known_player_id, '')), '');
  IF v_prize IS NOT NULL AND v_pid = v_prize THEN
    RAISE EXCEPTION 'Use “Release at 125%% MV” for the prize player — pick a different squad player here';
  END IF;

  -- Cannot prep-keep while prize is listed
  SELECT count(*)::int INTO v_listing
  FROM public."Player_Transfer_Listings" l
  WHERE l.player_id::text = coalesce(v_prize, '')
    AND l.seller_club_id = a.winning_club_id
    AND l.status = 'Active';
  IF coalesce(v_listing, 0) > 0 THEN
    RAISE EXCEPTION 'Prize is listed on the market — cancel that path or wait; squad release for Keep is unavailable';
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

  RETURN jsonb_build_object(
    'ok', true,
    'action', 'release_squad_for_keep',
    'player_id', v_pid,
    'player_name', v_name,
    'market_value', v_mv,
    'history_id', v_hist
  );
END;
$function$;

-- Block listing once keep-prep path started
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
  IF coalesce(a.winner_keep_prep_done, false) THEN
    RAISE EXCEPTION 'You already released a squad player to keep this prize — use Keep player only';
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

-- Block 125% prize release once keep-prep started (preserves release_125_fix body)
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
    RAISE EXCEPTION 'You already released a squad player to keep this prize — use Keep player only';
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

  v_credit := round(coalesce(v_mv, 0) * 1.25);
  IF v_credit < 0 THEN
    v_credit := 0;
  END IF;

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
      format('Special auction 125%% release: %s', coalesce(v_name, v_pid)),
      jsonb_build_object(
        'special_auction_id', a.id,
        'player_id', v_pid,
        'player_name', v_name,
        'market_value', v_mv,
        'rate', 1.25,
        'action', 'release_125'
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
    'action', 'release_125',
    'player_id', v_pid,
    'player_name', v_name,
    'credit', v_credit,
    'rate', 1.25,
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

GRANT EXECUTE ON FUNCTION public.special_auction_winner_release_squad_for_keep(bigint, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.special_auction_winner_list_prize_player(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.special_auction_winner_release_player(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.special_auction_winner_release_player(bigint, text) TO authenticated;

-- Expose keep-prep flag on gauntlet owner state
CREATE OR REPLACE FUNCTION public.special_auction_gauntlet_owner_state(p_auction_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  a public.special_auctions%rowtype;
  v_club text := public.my_club_shortname();
  v_p1 public.special_auction_gauntlet_bids%rowtype;
  v_p2 public.special_auction_gauntlet_bids%rowtype;
  v_phase2_bids jsonb := '[]'::jsonb;
  v_phase1_bids jsonb := '[]'::jsonb;
  v_reveal boolean := false;
BEGIN
  PERFORM public.special_auction_gauntlet_tick(p_auction_id);

  SELECT * INTO a FROM public.special_auctions WHERE id = p_auction_id;
  IF NOT FOUND OR a.auction_type <> 'blind_gauntlet' THEN
    RAISE EXCEPTION 'Blind Gauntlet auction not found';
  END IF;

  SELECT * INTO v_p1
  FROM public.special_auction_gauntlet_bids
  WHERE auction_id = p_auction_id AND club_id = v_club AND phase = 1;

  SELECT * INTO v_p2
  FROM public.special_auction_gauntlet_bids
  WHERE auction_id = p_auction_id AND club_id = v_club AND phase = 2;

  v_reveal := a.gauntlet_phase IN ('complete', 'failed') OR a.status = 'settled';

  IF v_reveal THEN
    SELECT coalesce(jsonb_agg(
      jsonb_build_object(
        'club_id', b.club_id,
        'bid_amount', b.bid_amount,
        'bid_time', b.bid_time,
        'is_winner', b.is_winner
      )
      ORDER BY b.bid_amount DESC, b.bid_time ASC
    ), '[]'::jsonb)
    INTO v_phase2_bids
    FROM public.special_auction_gauntlet_bids b
    WHERE b.auction_id = p_auction_id AND b.phase = 2;

    SELECT coalesce(jsonb_agg(
      jsonb_build_object(
        'club_id', b.club_id,
        'bid_amount', b.bid_amount,
        'bid_time', b.bid_time,
        'tier', b.tier,
        'phase1_fee', b.phase1_fee
      )
      ORDER BY b.bid_amount DESC, b.bid_time ASC
    ), '[]'::jsonb)
    INTO v_phase1_bids
    FROM public.special_auction_gauntlet_bids b
    WHERE b.auction_id = p_auction_id AND b.phase = 1;
  END IF;

  RETURN jsonb_build_object(
    'auction_id', a.id,
    'title', a.title,
    'status', a.status,
    'gauntlet_phase', a.gauntlet_phase,
    'start_time', a.start_time,
    'phase1_end_at', a.gauntlet_phase1_end_at,
    'reveal_end_at', a.gauntlet_reveal_end_at,
    'phase2_end_at', a.gauntlet_phase2_end_at,
    'prize_type', a.prize_type,
    'prize_player_id', a.prize_player_id,
    'known_player_id', a.known_player_id,
    'prize_cash_amount', a.prize_cash_amount,
    'prize_discount_label', a.prize_discount_label,
    'player_mode', a.player_mode,
    'gauntlet_prize_pack', a.gauntlet_prize_pack,
    'winning_club_id', a.winning_club_id,
    'winning_amount', a.winning_amount,
    'winner_prize_pending', coalesce(a.winner_prize_pending, false),
    'winner_keep_prep_done', coalesce(a.winner_keep_prep_done, false),
    'winner_keep_prep_player_id', a.winner_keep_prep_player_id,
    'my_club', v_club,
    'my_phase1', CASE WHEN v_p1.id IS NULL THEN NULL ELSE jsonb_build_object(
      'bid_amount', v_p1.bid_amount,
      'tier', v_p1.tier,
      'phase1_fee', v_p1.phase1_fee,
      'bid_time', v_p1.bid_time
    ) END,
    'my_phase2', CASE WHEN v_p2.id IS NULL THEN NULL ELSE jsonb_build_object(
      'bid_amount', v_p2.bid_amount,
      'phase2_fee', v_p2.phase2_fee,
      'is_winner', v_p2.is_winner,
      'bid_time', v_p2.bid_time
    ) END,
    'can_bid_phase1', a.status = 'active' AND a.gauntlet_phase = 'phase1'
      AND now() < a.gauntlet_phase1_end_at AND v_p1.id IS NULL,
    'can_bid_phase2', a.status = 'active' AND a.gauntlet_phase = 'phase2'
      AND now() < a.gauntlet_phase2_end_at
      AND v_p1.tier = 'top' AND v_p2.id IS NULL,
    'phase2_min', v_p1.bid_amount,
    'revealed', v_reveal,
    'phase1_bids', v_phase1_bids,
    'phase2_bids', v_phase2_bids,
    'i_won', (
      v_club IS NOT NULL
      AND a.winning_club_id IS NOT NULL
      AND upper(btrim(a.winning_club_id)) = upper(btrim(v_club))
    )
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.special_auction_gauntlet_owner_state(bigint) TO authenticated;

NOTIFY pgrst, 'reload schema';
