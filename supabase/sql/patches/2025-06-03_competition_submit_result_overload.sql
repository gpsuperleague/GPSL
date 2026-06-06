-- PATCH — fixes "Could not choose the best candidate function" on competition_submit_result.
-- Cause: legacy 4-arg overload coexists with cup 7-arg version after phase4/phase6 re-runs.
-- Run once in SQL Editor. Also deploy latest competition.js (passes all 7 RPC args).

DROP FUNCTION IF EXISTS public.competition_submit_result(bigint, smallint, smallint);
DROP FUNCTION IF EXISTS public.competition_submit_result(bigint, smallint, smallint, jsonb);
DROP FUNCTION IF EXISTS public.competition_submit_result(
  bigint, smallint, smallint, jsonb, smallint, smallint, smallint, smallint
);

GRANT EXECUTE ON FUNCTION public.competition_submit_result(
  bigint, smallint, smallint, jsonb, smallint, smallint, text
) TO authenticated;
