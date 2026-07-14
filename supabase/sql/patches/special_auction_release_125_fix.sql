-- =============================================================================
-- Fix special auction 125% prize release (winner options)
--
-- Issues addressed:
--   • Club compare is case/trim sensitive (NMU vs nmu)
--   • Listing cancel used status 'Cancelled' (player listings often use Closed)
--   • Balance update alone can miss Club_Finances / ledger visibility
--   • Ambiguous/2-arg RPC calling from PostgREST — use single-arg only
--
-- Run once. Safe re-run. Then New Mexico can click Release again.
-- =============================================================================

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

  -- Must still be at the winning club (overflow exclude should keep the prize)
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

  -- Close any active listing (use Closed — Cancelled may violate listing checks)
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

  -- Credit via ledger when available (updates balance + finances history)
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

-- Keep 2-arg alias for older clients (ignores p_player_id; uses auction prize)
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

GRANT EXECUTE ON FUNCTION public.special_auction_winner_release_player(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.special_auction_winner_release_player(bigint, text) TO authenticated;

NOTIFY pgrst, 'reload schema';
