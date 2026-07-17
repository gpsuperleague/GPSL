-- =============================================================================
-- Discord queue: claim pending rows before posting (prevents double Discord posts)
-- When two flushes race, both used to SELECT the same pending row and webhook twice.
-- Safe re-run.
-- =============================================================================

ALTER TABLE public.gpsl_discord_feed_queue
  DROP CONSTRAINT IF EXISTS gpsl_discord_feed_queue_status_check;

ALTER TABLE public.gpsl_discord_feed_queue
  ADD CONSTRAINT gpsl_discord_feed_queue_status_check
  CHECK (status IN ('pending', 'posting', 'posted', 'error', 'skipped'));

CREATE OR REPLACE FUNCTION public.gpsl_discord_feed_claim_pending(p_limit integer DEFAULT 10)
RETURNS SETOF public.gpsl_discord_feed_queue
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_limit int := greatest(1, least(coalesce(p_limit, 10), 25));
BEGIN
  RETURN QUERY
  WITH picked AS (
    SELECT q.id
    FROM public.gpsl_discord_feed_queue q
    WHERE q.status = 'pending'
    ORDER BY q.id
    FOR UPDATE SKIP LOCKED
    LIMIT v_limit
  ),
  claimed AS (
    UPDATE public.gpsl_discord_feed_queue q
    SET status = 'posting',
        last_error = NULL
    FROM picked p
    WHERE q.id = p.id
    RETURNING q.*
  )
  SELECT * FROM claimed ORDER BY id;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.gpsl_discord_feed_claim_pending(integer) TO service_role;
GRANT EXECUTE ON FUNCTION public.gpsl_discord_feed_claim_pending(integer) TO authenticated;

NOTIFY pgrst, 'reload schema';
