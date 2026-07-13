-- =============================================================================
-- Snap: hide prize player identity until random finish (not before).
-- Owner fetch RPC redacts prize_player_id / known_player_id / future clues.
-- Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.special_auction_snap_identity_hidden(p_auction public.special_auctions)
RETURNS boolean
LANGUAGE sql
STABLE
AS $$
  SELECT
    p_auction.auction_type = 'snap'
    AND p_auction.status IN ('scheduled', 'active')
    AND now() < coalesce(p_auction.snap_random_end_at, p_auction.end_time);
$$;

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

  RETURN j;
END;
$function$;

-- Active / published auction for owners (identity redacted while snap live)
-- Prefer live scheduled/active; only show revealed briefly after close.
CREATE OR REPLACE FUNCTION public.special_auction_fetch_owner_active()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  a public.special_auctions;
BEGIN
  SELECT * INTO a
  FROM public.special_auctions
  WHERE status IN ('scheduled', 'active')
  ORDER BY start_time ASC
  LIMIT 1;

  IF FOUND THEN
    RETURN public.special_auction_owner_json(a);
  END IF;

  SELECT * INTO a
  FROM public.special_auctions
  WHERE status = 'revealed'
    AND coalesce(end_time, start_time) > (now() - interval '7 days')
  ORDER BY id DESC
  LIMIT 1;

  IF FOUND THEN
    RETURN public.special_auction_owner_json(a);
  END IF;

  RETURN NULL;
END;
$function$;

CREATE OR REPLACE FUNCTION public.special_auction_fetch_owner_by_id(p_auction_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  a public.special_auctions;
BEGIN
  SELECT * INTO a
  FROM public.special_auctions
  WHERE id = p_auction_id;

  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  -- Draft/cancelled only for admins
  IF a.status IN ('draft', 'cancelled') AND NOT public.is_gpsl_admin() THEN
    RETURN NULL;
  END IF;

  RETURN public.special_auction_owner_json(a);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.special_auction_snap_identity_hidden(public.special_auctions) TO authenticated;
GRANT EXECUTE ON FUNCTION public.special_auction_owner_json(public.special_auctions) TO authenticated;
GRANT EXECUTE ON FUNCTION public.special_auction_fetch_owner_active() TO authenticated;
GRANT EXECUTE ON FUNCTION public.special_auction_fetch_owner_by_id(bigint) TO authenticated;

NOTIFY pgrst, 'reload schema';
