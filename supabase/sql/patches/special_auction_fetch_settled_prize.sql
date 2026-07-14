-- =============================================================================
-- Owner fetch: include recently settled auctions (prize options + results)
--
-- Bug: after Settle, status=settled so special_auction_fetch_owner_active
-- returned NULL → owners saw "No special auction" and winners never saw
-- Keep / List / 125% release options.
--
-- Run once. Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.special_auction_fetch_owner_active()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  a public.special_auctions;
  v_club text := public.my_club_shortname();
BEGIN
  -- 1) Live / upcoming
  SELECT * INTO a
  FROM public.special_auctions
  WHERE status IN ('scheduled', 'active')
  ORDER BY start_time ASC
  LIMIT 1;

  IF FOUND THEN
    RETURN public.special_auction_owner_json(a);
  END IF;

  -- 2) Settled with prize still pending for this club (no time limit)
  IF v_club IS NOT NULL AND btrim(v_club) <> '' THEN
    SELECT * INTO a
    FROM public.special_auctions
    WHERE status = 'settled'
      AND coalesce(winner_prize_pending, false) = true
      AND upper(btrim(winning_club_id)) = upper(btrim(v_club))
    ORDER BY id DESC
    LIMIT 1;

    IF FOUND THEN
      RETURN public.special_auction_owner_json(a);
    END IF;
  END IF;

  -- 3) Any recent settled (results / fee table for all owners)
  SELECT * INTO a
  FROM public.special_auctions
  WHERE status = 'settled'
    AND coalesce(end_time, start_time, updated_at) > (now() - interval '7 days')
  ORDER BY id DESC
  LIMIT 1;

  IF FOUND THEN
    RETURN public.special_auction_owner_json(a);
  END IF;

  -- 4) Recent revealed LUB (awaiting settle)
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

GRANT EXECUTE ON FUNCTION public.special_auction_fetch_owner_active() TO authenticated;

COMMENT ON FUNCTION public.special_auction_fetch_owner_active() IS
  'Owner auction: live first; then this club''s pending prize settle; then recent settled/revealed.';

NOTIFY pgrst, 'reload schema';
