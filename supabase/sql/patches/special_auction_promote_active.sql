-- Promote scheduled special auctions to active once start_time is reached (e.g. 8pm UK).
-- Runs at the start of every transferengine_run() tick (pg_cron + admin manual run).

CREATE OR REPLACE FUNCTION public.special_auction_promote_scheduled()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_count integer;
BEGIN
  UPDATE public.special_auctions
  SET status = 'active',
      updated_at = now()
  WHERE status = 'scheduled'
    AND start_time <= now()
    AND end_time > now();

  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$function$;

COMMENT ON FUNCTION public.special_auction_promote_scheduled IS
  'Flip special_auctions from scheduled → active when start_time passes; never before start_time.';

REVOKE ALL ON FUNCTION public.special_auction_promote_scheduled() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.special_auction_promote_scheduled() TO postgres, service_role;

CREATE OR REPLACE FUNCTION public.transferengine_run()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  PERFORM public.special_auction_promote_scheduled();

  PERFORM set_config('gpsl.defer_squad_overflow', 'on', true);

  PERFORM public.transferengine_process_standard_listings(now());
  PERFORM public.transferengine_settle_draft_auctions();

  PERFORM public.transferengine_finalize_deferred_squad_overflow();
  PERFORM set_config('gpsl.defer_squad_overflow', '', true);
END;
$function$;

NOTIFY pgrst, 'reload schema';
