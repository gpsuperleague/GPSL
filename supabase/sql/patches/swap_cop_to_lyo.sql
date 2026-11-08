-- =============================================================================
-- Franchise identity swap is disabled.
-- Rewriting every club code mid-season can break fixtures, squads, injuries,
-- fitness and owner records. This function refuses and changes nothing.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.admin_franchise_identity_swap(
  p_left text,
  p_right text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  RAISE EXCEPTION
    'Club identity swap is turned off. It is not safe to rewrite club codes mid-season.';
END;
$function$;

REVOKE ALL ON FUNCTION public.admin_franchise_identity_swap(text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_franchise_identity_swap(text, text) TO authenticated;

NOTIFY pgrst, 'reload schema';
