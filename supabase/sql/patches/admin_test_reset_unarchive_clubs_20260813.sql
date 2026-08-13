-- =============================================================================
-- Vanilla reset: clear Club Management soft-archive flags
--
-- Deploy: re-run admin_prelaunch_test_reset.sql (preferred — Phase G now clears
-- is_archived / archived_at / archived_note on all club rows).
--
-- This file alone only ensures columns + a helper you can call manually.
-- =============================================================================

ALTER TABLE public."Clubs" ADD COLUMN IF NOT EXISTS is_archived boolean NOT NULL DEFAULT false;
ALTER TABLE public."Clubs" ADD COLUMN IF NOT EXISTS archived_at timestamptz;
ALTER TABLE public."Clubs" ADD COLUMN IF NOT EXISTS archived_note text;

CREATE OR REPLACE FUNCTION public.admin_test_reset_clear_soft_archived_clubs()
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  n int := 0;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  UPDATE public."Clubs"
  SET is_archived = false,
      archived_at = NULL,
      archived_note = NULL
  WHERE coalesce(is_archived, false) = true;
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END;
$function$;

REVOKE ALL ON FUNCTION public.admin_test_reset_clear_soft_archived_clubs() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_test_reset_clear_soft_archived_clubs() TO authenticated;

COMMENT ON FUNCTION public.admin_test_reset_clear_soft_archived_clubs() IS
  'Clears Club Management soft-archive flags. Vanilla reset Phase G does this automatically after admin_prelaunch_test_reset.sql is re-deployed.';
