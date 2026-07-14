-- =============================================================================
-- Snap mystery finish — hide random end from owners; expose bidding-open flag
--
-- Owners must not see snap_random_end_at (that would spoil the snap).
-- They see:
--   snap_mystery_window_at = start + 50 minutes (when count-up begins)
--   snap_bidding_open      = whether bids are still accepted right now
--
-- Run after special_auction_snap_identity_hide.sql. Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.special_auction_owner_json(p_auction public.special_auctions)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  j jsonb := to_jsonb(p_auction);
  v_mins numeric := 0;
  v_mystery timestamptz;
  v_eff_end timestamptz;
  v_open boolean;
BEGIN
  IF p_auction.start_time IS NOT NULL THEN
    v_mins := greatest(0, extract(epoch FROM (now() - p_auction.start_time)) / 60.0);
  END IF;

  -- Never expose future clues on the raw row (owners use special_auction_visible_clues)
  IF p_auction.auction_type = 'snap' AND p_auction.status IN ('scheduled', 'active') THEN
    IF v_mins < 20 THEN
      j := j || jsonb_build_object('clue_2', null);
    END IF;
    IF v_mins < 40 THEN
      j := j || jsonb_build_object('clue_3', null);
    END IF;
    IF v_mins < 50 THEN
      j := j || jsonb_build_object('clue_4', null);
    END IF;
  END IF;

  IF public.special_auction_snap_identity_hidden(p_auction) THEN
    j := j || jsonb_build_object(
      'prize_player_id', null,
      'known_player_id', null
    );
  END IF;

  -- Snap: hide the secret finish; expose mystery-window start + live open flag
  IF p_auction.auction_type = 'snap' THEN
    v_mystery := p_auction.start_time + interval '50 minutes';
    v_eff_end := public.special_auction_snap_effective_end(p_auction);
    v_open :=
      p_auction.status IN ('scheduled', 'active')
      AND now() >= p_auction.start_time
      AND now() < v_eff_end;

    j := j - 'snap_random_end_at';
    j := j || jsonb_build_object(
      'snap_random_end_at', null,
      'snap_mystery_window_at', v_mystery,
      'snap_bidding_open', v_open
    );
  END IF;

  RETURN j;
END;
$function$;

COMMENT ON FUNCTION public.special_auction_owner_json(public.special_auctions) IS
  'Owner-safe auction JSON: redacts future clues, player identity while live, and snap_random_end_at; adds snap_mystery_window_at + snap_bidding_open.';

NOTIFY pgrst, 'reload schema';
