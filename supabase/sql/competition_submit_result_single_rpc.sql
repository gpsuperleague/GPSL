-- Fix: "Could not choose the best candidate function" on competition_submit_result.
-- Keeps one RPC: 4 required args + optional cup ET / pen winner (defaults NULL).
-- Safe to re-run. Run competition_cup_extra_time.sql after this if functions are missing.

DROP FUNCTION IF EXISTS public.competition_submit_result(bigint, smallint, smallint);
DROP FUNCTION IF EXISTS public.competition_submit_result(bigint, smallint, smallint, jsonb);
DROP FUNCTION IF EXISTS public.competition_submit_result(
  bigint, smallint, smallint, jsonb, smallint, smallint, smallint, smallint
);

-- Re-apply latest submit (from competition_cup_extra_time.sql body).
-- If this block fails, run the full competition_cup_extra_time.sql file instead.

DO $do$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname = 'competition_submit_result'
      AND pg_get_function_identity_arguments(p.oid) LIKE '%p_pen_winner_club%'
  ) THEN
    RAISE NOTICE 'Run competition_cup_extra_time.sql — cup submit function not found yet.';
  END IF;
END;
$do$;

GRANT EXECUTE ON FUNCTION public.competition_submit_result(
  bigint, smallint, smallint, jsonb, smallint, smallint, text
) TO authenticated;
