-- Removing an owner was rolling back when the transfer tick held a
-- kick-off row. The owner stays on the club, and the page looks unchanged.
-- A locked schedule row must not undo the move. The clear is retried
-- after the owner is off the club.

ALTER FUNCTION public.competition_clear_arranged_fixtures_for_club(text, timestamptz)
  SET lock_timeout = '3s';

CREATE OR REPLACE FUNCTION public.trg_clubs_owner_leave_reset_arrangements()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $gpsl$
BEGIN
  IF OLD.owner_id IS NULL OR NEW.owner_id IS NOT DISTINCT FROM OLD.owner_id THEN
    RETURN NEW;
  END IF;

  BEGIN
    PERFORM public.competition_clear_arranged_fixtures_for_club(NEW."ShortName");
    PERFORM set_config('gpsl.owner_leave_reset', 'cleared', true);
  EXCEPTION
    WHEN lock_not_available OR query_canceled THEN
      PERFORM set_config('gpsl.owner_leave_reset', 'locked', true);
      RAISE WARNING 'owner leave fixture reset skipped for %: %', NEW."ShortName", SQLERRM;
  END;

  RETURN NEW;
END;
$gpsl$;

CREATE OR REPLACE FUNCTION public.admin_owner_leave_reset_retry(p_club text)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
SET lock_timeout = '3s'
SET statement_timeout = '20s'
AS $gpsl$
BEGIN
  PERFORM public.competition_clear_arranged_fixtures_for_club(p_club);
  RETURN 'cleared';
EXCEPTION
  WHEN lock_not_available OR query_canceled THEN
    RETURN 'locked';
END;
$gpsl$;

REVOKE ALL ON FUNCTION public.admin_owner_leave_reset_retry(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_owner_leave_reset_retry(text) TO authenticated, service_role;

SELECT 'ready' AS ready;
