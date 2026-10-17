-- Blind Gauntlet / special auction: Take cash (MV) was 400ing when the prize
-- player was never assigned to the winner (settle swallowed award errors) or
-- PostgREST hit ambiguous 1-arg vs 2-arg overloads.
-- Safe re-run.

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
  v_team_key text;
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

  BEGIN
    v_team_key := upper(btrim(coalesce(public.player_contracted_club_key(v_team), '')));
  EXCEPTION WHEN OTHERS THEN
    v_team_key := upper(btrim(coalesce(v_team, '')));
  END;
  v_at_winner := (v_team_key <> '' AND v_team_key = v_win);

  v_credit := greatest(round(coalesce(v_mv, 0)), 0);

  -- Close any active listing under the winner
  UPDATE public."Player_Transfer_Listings"
  SET status = 'Closed',
      transfer_completed = false
  WHERE player_id::text = v_pid
    AND upper(btrim(seller_club_id::text)) = v_win
    AND status IN ('Active', 'Review', 'Seller Review');

  -- Release only if still contracted to the winner.
  -- If award never landed (or already free), still pay MV and close options.
  IF v_at_winner THEN
    PERFORM public.player_release_from_club(v_pid);
    v_released := true;
  END IF;

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
        'was_at_club', coalesce(v_team, '')
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

NOTIFY pgrst, 'reload schema';
