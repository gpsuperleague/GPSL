-- =============================================================================
-- Special auction player prize: decide FIRST, sign only on Keep / Sign+release
--
-- Bug (Mystery Snap settle):
--   award_prize called player_assign_to_club immediately → at 28 players,
--   enforce_squad_overflow auto-released the highest-rated squad player (MV).
--   "Take cash" then only released the prize — damage already done.
--
-- New rules (prize stays FA until the winner chooses):
--   1. Take cash (MV) — never signs; club credited prize MV; prize stays FA
--   2. Sign prize — only if squad + leading bids + 1 ≤ 28
--   3. Sign prize & release a squad player at MV — when already at 28
--
-- Safe re-run. Run BEFORE the Besiktas repair patch if both are needed.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Award: open options only — do NOT assign the prize player
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.special_auction_award_prize(public.special_auctions, text, numeric);

CREATE OR REPLACE FUNCTION public.special_auction_award_prize(
  p_auction public.special_auctions,
  p_winner_club text,
  p_win_amount numeric
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_team text;
  v_pct int;
  v_season bigint;
  v_inv_id bigint;
  v_label text;
BEGIN
  IF p_winner_club IS NULL THEN
    RETURN;
  END IF;

  IF p_auction.prize_type = 'player' AND p_auction.prize_player_id IS NOT NULL THEN
    SELECT nullif(btrim(coalesce(p."Contracted_Team"::text, '')), '')
    INTO v_team
    FROM public."Players" p
    WHERE p."Konami_ID"::text = p_auction.prize_player_id
    FOR UPDATE;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'Prize player % not found', p_auction.prize_player_id;
    END IF;

    -- Must still be a free agent (or already at the winner from a prior partial run)
    IF v_team IS NOT NULL
       AND upper(btrim(v_team)) IS DISTINCT FROM upper(btrim(p_winner_club)) THEN
      RAISE EXCEPTION
        'Prize player % is contracted to % — cannot open special-auction options',
        p_auction.prize_player_id, v_team;
    END IF;

    -- Leave auction_exclusion until the winner claims (draft stays blocked).
    UPDATE public.special_auctions
    SET winner_prize_pending = true,
        winner_prize_resolved = false,
        winner_keep_prep_done = false,
        winner_keep_prep_player_id = NULL,
        updated_at = now()
    WHERE id = p_auction.id;

  ELSIF p_auction.prize_type = 'cash' AND coalesce(p_auction.prize_cash_amount, 0) > 0 THEN
    UPDATE public."Club_Finances"
    SET balance = balance + p_auction.prize_cash_amount
    WHERE club_name = p_winner_club;

    IF to_regprocedure(
      'public.post_special_auction_ledger_line(text,text,numeric,text,bigint,boolean,jsonb)'
    ) IS NOT NULL THEN
      PERFORM public.post_special_auction_ledger_line(
        p_winner_club,
        'special_auction_prize',
        abs(p_auction.prize_cash_amount),
        format('Special auction cash prize — %s', coalesce(p_auction.title, 'Auction #' || p_auction.id)),
        p_auction.id,
        false,
        jsonb_build_object('ledger_role', 'cash_prize', 'prize_type', 'cash')
      );
    END IF;

  ELSIF p_auction.prize_type = 'discount' THEN
    v_pct := p_auction.prize_discount_pct;
    IF v_pct IS NULL OR v_pct <= 0 THEN
      BEGIN
        v_pct := nullif(
          substring(coalesce(p_auction.prize_discount_label, '') from '([0-9]{1,2})'),
          ''
        )::int;
      EXCEPTION WHEN OTHERS THEN
        v_pct := NULL;
      END;
    END IF;

    IF v_pct IS NULL OR v_pct <= 0 OR v_pct > 50 THEN
      RAISE EXCEPTION
        'Discount prize needs prize_discount_pct between 1 and 50 (got %)',
        coalesce(v_pct::text, 'null');
    END IF;

    v_label := nullif(btrim(coalesce(p_auction.prize_discount_label, '')), '');
    IF v_label IS NULL THEN
      v_label := format('%s%% fee discount', v_pct);
      UPDATE public.special_auctions
      SET prize_discount_label = v_label,
          prize_discount_pct = v_pct,
          updated_at = now()
      WHERE id = p_auction.id
        AND (prize_discount_label IS NULL OR btrim(prize_discount_label) = '');
    ELSIF p_auction.prize_discount_pct IS NULL THEN
      UPDATE public.special_auctions
      SET prize_discount_pct = v_pct,
          updated_at = now()
      WHERE id = p_auction.id;
    END IF;

    IF EXISTS (
      SELECT 1
      FROM public.club_prize_inventory i
      WHERE i.club_short_name = p_winner_club
        AND i.prize_type = 'fee_discount'
        AND i.source = 'special_auction'
        AND coalesce((i.metadata->>'auction_id')::bigint, -1) = p_auction.id
    ) THEN
      RETURN;
    END IF;

    IF to_regprocedure(
      'public.prize_grant_inventory_item(text,text,int,text,bigint,text,jsonb)'
    ) IS NULL THEN
      RAISE EXCEPTION
        'prize_grant_inventory_item missing — run competition_challenge_prize_packs.sql';
    END IF;

    SELECT id INTO v_season
    FROM public.competition_seasons
    WHERE is_current = true
    ORDER BY id DESC
    LIMIT 1;

    v_inv_id := public.prize_grant_inventory_item(
      p_winner_club,
      'fee_discount',
      v_pct,
      'special_auction',
      v_season,
      NULL,
      jsonb_build_object(
        'auction_id', p_auction.id,
        'auction_title', coalesce(p_auction.title, ''),
        'label', coalesce(v_label, format('%s%% fee discount', v_pct))
      )
    );

    IF v_inv_id IS NULL THEN
      RAISE EXCEPTION 'Failed to grant fee_discount inventory for auction %', p_auction.id;
    END IF;
  END IF;
END;
$function$;

COMMENT ON FUNCTION public.special_auction_award_prize(public.special_auctions, text, numeric) IS
  'Cash/discount grant immediately; player prizes only open winner options (sign deferred until Keep / Sign+release).';

-- ---------------------------------------------------------------------------
-- Shared: assign prize to winner (never auto-overflow-release)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.special_auction_assign_prize_player(
  p_auction public.special_auctions,
  p_winner_club text,
  p_win_amount numeric
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_pid text := nullif(btrim(coalesce(p_auction.prize_player_id, '')), '');
  v_team text;
  v_seller text;
  v_title text;
  v_note text := 'special_auction';
  v_fee numeric := greatest(coalesce(p_win_amount, 0), 0);
  v_hist bigint;
  v_squad int;
  v_max int := 28;
BEGIN
  IF v_pid IS NULL THEN
    RAISE EXCEPTION 'No prize player on this auction';
  END IF;

  SELECT nullif(btrim(coalesce(p."Contracted_Team"::text, '')), '')
  INTO v_team
  FROM public."Players" p
  WHERE p."Konami_ID"::text = v_pid
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Prize player % not found', v_pid;
  END IF;

  -- Already at winner (legacy settle) — nothing to assign
  IF v_team IS NOT NULL
     AND upper(btrim(v_team)) = upper(btrim(p_winner_club)) THEN
    DELETE FROM public.auction_exclusion_players WHERE player_id = v_pid;
    RETURN;
  END IF;

  IF v_team IS NOT NULL THEN
    RAISE EXCEPTION 'Prize player is contracted to %', v_team;
  END IF;

  IF to_regprocedure('public.player_clear_foreign_contract_lock(text)') IS NOT NULL THEN
    PERFORM public.player_clear_foreign_contract_lock(v_pid);
  ELSE
    UPDATE public."Players"
    SET foreign_contract_club = NULL,
        foreign_contract_sold_season_id = NULL,
        foreign_contract_unlock_season_label = NULL,
        foreign_contract_lock_kind = NULL
    WHERE "Konami_ID"::text = v_pid;
  END IF;

  -- Defer overflow so we never auto-release a squad player; room is pre-checked.
  PERFORM public.player_assign_to_club(v_pid, p_winner_club, NULL::numeric, true);

  SELECT count(*)::int INTO v_squad
  FROM public."Players" p
  WHERE upper(btrim(coalesce(p."Contracted_Team", ''))) = upper(btrim(p_winner_club));

  IF v_squad > v_max THEN
    RAISE EXCEPTION
      'Cannot sign prize — squad would be % (max %). Release a squad player first or take cash.',
      v_squad, v_max;
  END IF;

  DELETE FROM public.auction_exclusion_players WHERE player_id = v_pid;

  v_seller := NULL;
  v_title := coalesce(nullif(btrim(p_auction.title), ''), 'Special auction');

  SELECT h.id INTO v_hist
  FROM public."Transfer_History" h
  WHERE h.player_id::text = v_pid
    AND upper(btrim(h.buyer_club_id::text)) = upper(btrim(p_winner_club))
    AND coalesce(h.transfer_sale_note, '') = v_note
  ORDER BY h.id DESC
  LIMIT 1;

  IF v_hist IS NULL THEN
    INSERT INTO public."Transfer_History" (
      player_id, seller_club_id, buyer_club_id, fee, agent_fee,
      transfer_time, listing_id, foreign_buyer_name, transfer_sale_note
    )
    VALUES (
      v_pid, v_seller, p_winner_club, v_fee, 0,
      now(), NULL, v_title, v_note
    );
  END IF;
END;
$function$;

REVOKE ALL ON FUNCTION public.special_auction_assign_prize_player(public.special_auctions, text, numeric) FROM PUBLIC;

-- ---------------------------------------------------------------------------
-- Prize space: can_keep accounts for unsigned prize (+1)
-- ---------------------------------------------------------------------------
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
  v_pid text;
  v_team text;
  v_signed boolean := false;
  v_slots_needed int := 1;
  v_can_keep boolean;
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

  v_pid := nullif(btrim(coalesce(a.prize_player_id, a.known_player_id, '')), '');
  IF v_pid IS NOT NULL THEN
    SELECT nullif(btrim(coalesce(p."Contracted_Team"::text, '')), ''),
           greatest(coalesce(nullif(btrim(p.market_value::text), '')::numeric, 0), 0)
    INTO v_team, v_mv
    FROM public."Players" p
    WHERE p."Konami_ID"::text = v_pid;

    v_signed := (
      v_team IS NOT NULL
      AND upper(btrim(v_team)) = upper(btrim(coalesce(a.winning_club_id, '')))
    );
  END IF;

  v_slots_needed := CASE WHEN v_signed THEN 0 ELSE 1 END;
  v_can_keep := (v_total + v_slots_needed) <= v_max;

  RETURN v_space || jsonb_build_object(
    'cash_value', coalesce(v_mv, 0),
    'keep_prep_done', coalesce(a.winner_keep_prep_done, false),
    'prize_signed', v_signed,
    'slots_needed', v_slots_needed,
    'can_keep', v_can_keep
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.special_auction_winner_prize_space(bigint) TO authenticated;

-- ---------------------------------------------------------------------------
-- 1. Sign / Keep — assign only when there is room
-- ---------------------------------------------------------------------------
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
  v_total int;
  v_max int;
  v_signed boolean;
  v_needed int;
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

  v_space := public.special_auction_winner_prize_space(p_auction_id);
  v_total := (v_space->>'total')::int;
  v_max := (v_space->>'max')::int;
  v_signed := coalesce((v_space->>'prize_signed')::boolean, false);
  v_needed := coalesce((v_space->>'slots_needed')::int, 1);

  IF (v_total + v_needed) > v_max THEN
    RAISE EXCEPTION
      'No room to sign: squad+bids = %, need % slot(s), max %. Release a squad player at MV and sign, or take the cash.',
      v_total, v_needed, v_max;
  END IF;

  IF NOT v_signed THEN
    PERFORM public.special_auction_assign_prize_player(
      a, a.winning_club_id, coalesce(a.winning_amount, a.winner_purchase_amount, 0)
    );
  END IF;

  UPDATE public.special_auctions
  SET winner_prize_pending = false,
      winner_prize_resolved = true,
      updated_at = now()
  WHERE id = p_auction_id;

  RETURN jsonb_build_object(
    'ok', true,
    'action', 'keep',
    'assigned', NOT v_signed,
    'squad_size', (v_space->>'squad')::int,
    'pending_bids', (v_space->>'pending')::int,
    'total', v_total
  );
END;
$function$;

-- ---------------------------------------------------------------------------
-- 2. Sign + release a squad player at MV (full squad path)
-- ---------------------------------------------------------------------------
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
  v_space jsonb;
  v_total int;
  v_max int;
  v_signed boolean;
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

  v_space := public.special_auction_winner_prize_space(p_auction_id);
  v_total := (v_space->>'total')::int;
  v_max := (v_space->>'max')::int;
  v_signed := coalesce((v_space->>'prize_signed')::boolean, false);

  -- Only required when signing would overflow
  IF v_signed THEN
    RAISE EXCEPTION 'Prize is already signed — use Keep player, or take cash';
  END IF;
  IF (v_total + 1) <= v_max THEN
    RAISE EXCEPTION 'You already have room (% / %) — use Sign player', v_total, v_max;
  END IF;

  SELECT p."Name", p."Contracted_Team",
         greatest(coalesce(nullif(btrim(p.market_value::text), '')::numeric, 0), 0)
  INTO v_name, v_team, v_mv
  FROM public."Players" p
  WHERE p."Konami_ID"::text = v_pid
  FOR UPDATE;

  IF NOT FOUND THEN RAISE EXCEPTION 'Player not found'; END IF;
  IF upper(btrim(coalesce(v_team, ''))) IS DISTINCT FROM upper(btrim(a.winning_club_id)) THEN
    RAISE EXCEPTION 'That player is not at your club';
  END IF;

  UPDATE public."Player_Transfer_Listings" l
  SET status = 'Closed',
      transfer_completed = false
  WHERE l.player_id::text = v_pid
    AND upper(btrim(l.seller_club_id::text)) = upper(btrim(a.winning_club_id))
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
    now(), NULL, 'Special auction sign room (market value)', 'special_auction_keep_prep'
  )
  RETURNING id INTO v_hist;

  IF to_regprocedure('public.post_transfer_ledger_for_history(bigint,boolean)') IS NOT NULL THEN
    PERFORM public.post_transfer_ledger_for_history(v_hist, true);
  ELSE
    UPDATE public."Club_Finances"
    SET balance = balance + v_mv
    WHERE club_name = a.winning_club_id;
  END IF;

  PERFORM public.special_auction_assign_prize_player(
    a, a.winning_club_id, coalesce(a.winning_amount, a.winner_purchase_amount, 0)
  );

  UPDATE public.special_auctions
  SET winner_keep_prep_done = true,
      winner_keep_prep_player_id = v_pid,
      winner_prize_pending = false,
      winner_prize_resolved = true,
      updated_at = now()
  WHERE id = p_auction_id;

  v_space := public.special_auction_club_squad_space(a.winning_club_id);

  RETURN jsonb_build_object(
    'ok', true,
    'action', 'sign_with_release',
    'player_id', v_pid,
    'player_name', v_name,
    'market_value', v_mv,
    'history_id', v_hist,
    'total', (v_space->>'total')::int,
    'max', (v_space->>'max')::int,
    'can_keep', true,
    'resolved', true
  );
END;
$function$;

-- ---------------------------------------------------------------------------
-- 3. Take cash — never signs the prize; credit MV
-- ---------------------------------------------------------------------------
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
  v_at_winner boolean := false;
  v_season_id bigint;
  v_ledger bigint;
  v_released boolean := false;
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

  IF coalesce(a.winner_prize_resolved, false) THEN
    RETURN jsonb_build_object('ok', true, 'already_resolved', true);
  END IF;

  IF NOT coalesce(a.winner_prize_pending, false) THEN
    RAISE EXCEPTION 'Prize options are not open for this auction';
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

  v_at_winner := (
    nullif(btrim(coalesce(v_team, '')), '') IS NOT NULL
    AND upper(btrim(v_team)) = v_win
  );

  v_credit := greatest(round(coalesce(v_mv, 0)), 0);

  UPDATE public."Player_Transfer_Listings"
  SET status = 'Closed',
      transfer_completed = false
  WHERE player_id::text = v_pid
    AND upper(btrim(seller_club_id::text)) = v_win
    AND status IN ('Active', 'Review', 'Seller Review');

  -- Legacy: if settle wrongly assigned the prize, release him. Prefer never signed.
  IF v_at_winner THEN
    PERFORM public.player_release_from_club(v_pid);
    v_released := true;
  END IF;

  -- Prize stays free agent; drop exclusion so he can return to draft pool
  DELETE FROM public.auction_exclusion_players WHERE player_id = v_pid;

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
        'action', 'take_cash',
        'released_from_club', v_at_winner,
        'was_at_club', coalesce(v_team, ''),
        'never_signed', NOT v_at_winner
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
    'released', v_released,
    'was_at_winner', v_at_winner,
    'ledger_id', v_ledger
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.special_auction_winner_release_player(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.special_auction_winner_keep_prize(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.special_auction_winner_release_squad_for_keep(bigint, text) TO authenticated;

NOTIFY pgrst, 'reload schema';
