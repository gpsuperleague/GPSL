-- =============================================================================
-- Record site activity as a login (remembered sessions / returning visits)
--
-- Client calls record_owner_site_login on each authenticated page open (and when
-- the tab becomes visible again). Debounce widened so multi-page browsing in the
-- same hour does not create dozens of events; a later visit still counts.
-- Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.record_owner_site_login()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_uid uuid := auth.uid();
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not signed in';
  END IF;

  -- Debounce: same browsing burst / multi-tab / login→redirect.
  -- Client also uses a 1h localStorage cooldown for "opened the site".
  IF EXISTS (
    SELECT 1
    FROM public.owner_site_login_events e
    WHERE e.owner_id = v_uid
      AND e.logged_in_at > now() - interval '1 hour'
  ) THEN
    RETURN;
  END IF;

  INSERT INTO public.owner_site_login_events (owner_id, logged_in_at)
  VALUES (v_uid, now());
END;
$function$;

GRANT EXECUTE ON FUNCTION public.record_owner_site_login() TO authenticated;

COMMENT ON FUNCTION public.record_owner_site_login() IS
  'Records a site visit/login for the current user. Debounced to once per hour. '
  'Called from password sign-in and from initGlobal when a remembered session is active.';

NOTIFY pgrst, 'reload schema';
