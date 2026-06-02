-- Run once if you already applied special_auctions.sql — adds "scheduled" (visible in nav, bidding opens at start_time)

ALTER TABLE public.special_auctions
  DROP CONSTRAINT IF EXISTS special_auctions_status_check;

ALTER TABLE public.special_auctions
  ADD CONSTRAINT special_auctions_status_check CHECK (
    status IN ('draft', 'scheduled', 'active', 'revealed', 'settled', 'cancelled')
  );

DROP INDEX IF EXISTS public.special_auctions_one_active_idx;

CREATE UNIQUE INDEX IF NOT EXISTS special_auctions_one_live_idx
  ON public.special_auctions ((true))
  WHERE status IN ('scheduled', 'active');

CREATE OR REPLACE FUNCTION public.special_auction_activate(p_auction_id bigint)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_start timestamptz;
BEGIN
  IF NOT public.is_gpsl_admin() THEN RAISE EXCEPTION 'Admin only'; END IF;

  SELECT start_time INTO v_start FROM public.special_auctions WHERE id = p_auction_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Auction not found'; END IF;

  UPDATE public.special_auctions
  SET status = 'draft', updated_at = now()
  WHERE status IN ('scheduled', 'active');

  UPDATE public.special_auctions
  SET status = CASE WHEN now() < v_start THEN 'scheduled' ELSE 'active' END,
      updated_at = now()
  WHERE id = p_auction_id;
END;
$function$;
