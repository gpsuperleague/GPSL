-- Preview calls approve with two arguments. A two-arg copy and a
-- three-arg copy (with a default) both match, so Postgres refuses.
-- Keep the three-arg function. Safe re-run.

DROP FUNCTION IF EXISTS public.admin_handpick_approve_submission(bigint, boolean);

NOTIFY pgrst, 'reload schema';

SELECT
  to_regprocedure('public.admin_handpick_approve_submission(bigint,boolean)') IS NOT NULL AS approve_2arg,
  to_regprocedure('public.admin_handpick_approve_submission(bigint,boolean,boolean)') IS NOT NULL AS approve_3arg;
