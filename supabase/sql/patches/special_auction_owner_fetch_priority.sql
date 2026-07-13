-- =============================================================================
-- Owner special-auction fetch: prefer live/upcoming over stale "revealed" LUBs
-- (weeks-old revealed auctions were blocking the owner page / nav).
-- Safe re-run. Requires special_auction_snap_identity_hide.sql helpers.
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
BEGIN
  -- 1) Live / upcoming always wins over an old revealed LUB
  SELECT * INTO a
  FROM public.special_auctions
  WHERE status IN ('scheduled', 'active')
  ORDER BY start_time ASC
  LIMIT 1;

  IF FOUND THEN
    RETURN public.special_auction_owner_json(a);
  END IF;

  -- 2) Recently revealed only (results window) — hide stale weeks-old auctions
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

NOTIFY pgrst, 'reload schema';
