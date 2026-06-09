-- Manager draft shares player draft schedule (Day 1 19:00 UK). Persist times when only manager draft is on.

CREATE OR REPLACE FUNCTION public.admin_set_draft_auction_schedule(
  p_start timestamptz,
  p_finish timestamptz DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  UPDATE public.global_settings
  SET draft_auction_start_time = p_start,
      draft_random_finish_time = p_finish,
      updated_at = now()
  WHERE id = 1;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.admin_set_draft_auction_schedule(timestamptz, timestamptz) TO authenticated;
