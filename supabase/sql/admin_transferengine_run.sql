-- Admin-only: run transfer engine once (standard 7pm listings + draft settlement when due).
-- Run once in Supabase SQL Editor after transferengine_*.sql.

CREATE OR REPLACE FUNCTION public.admin_transferengine_run()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_stuck int;
  v_draft int;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  SELECT count(*)::int
  INTO v_stuck
  FROM "Player_Transfer_Listings" l
  WHERE l.status = 'Active'
    AND l.listing_type IS DISTINCT FROM 'draft'
    AND l.end_time <= now();

  SELECT count(*)::int
  INTO v_draft
  FROM "Player_Transfer_Listings" l
  WHERE l.listing_type = 'draft'
    AND l.status = 'Active';

  PERFORM public.transferengine_run();

  RETURN jsonb_build_object(
    'ok', true,
    'stuck_standard_before', v_stuck,
    'active_draft_before', v_draft,
    'ran_at', now()
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.admin_transferengine_run() TO authenticated;
