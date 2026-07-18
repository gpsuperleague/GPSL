-- =============================================================================
-- Discord queue: unstick rows left in status = 'posting'
--
-- Cause: claim_pending sets posting, then a 429 break / edge timeout leaves the
-- rest of the batch stuck. Claim only selected pending, so they never retried.
--
-- This patch:
--   1) Adds claimed_at
--   2) Reclaims stale posting (>2 min) inside gpsl_discord_feed_claim_pending
--   3) Admin RPC to reopen posting (and 429 errors) now
-- Safe re-run.
-- =============================================================================

ALTER TABLE public.gpsl_discord_feed_queue
  ADD COLUMN IF NOT EXISTS claimed_at timestamptz;

CREATE INDEX IF NOT EXISTS gpsl_discord_feed_queue_posting_idx
  ON public.gpsl_discord_feed_queue (status, claimed_at, id)
  WHERE status = 'posting';

CREATE OR REPLACE FUNCTION public.gpsl_discord_feed_claim_pending(p_limit integer DEFAULT 10)
RETURNS SETOF public.gpsl_discord_feed_queue
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_limit int := greatest(1, least(coalesce(p_limit, 10), 25));
BEGIN
  -- Stale claims from crashed / rate-limit-aborted flushes
  UPDATE public.gpsl_discord_feed_queue q
  SET status = 'pending',
      claimed_at = NULL,
      last_error = left(
        coalesce(nullif(btrim(q.last_error), ''), 'stuck posting') || ' [auto-unstuck]',
        500
      )
  WHERE q.status = 'posting'
    AND coalesce(q.claimed_at, q.created_at) < now() - interval '2 minutes';

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
        claimed_at = now(),
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

-- Admin: reopen stuck posting + classic 429 errors
CREATE OR REPLACE FUNCTION public.admin_discord_requeue_rate_limited(
  p_limit integer DEFAULT 200
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_limit int := greatest(1, least(coalesce(p_limit, 200), 1000));
  v_posting int := 0;
  v_errors int := 0;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  WITH touched AS (
    UPDATE public.gpsl_discord_feed_queue q
    SET status = 'pending',
        claimed_at = NULL,
        last_error = left(
          coalesce(q.last_error, '') || ' [unstuck posting]',
          500
        )
    WHERE q.id IN (
      SELECT id
      FROM public.gpsl_discord_feed_queue
      WHERE status = 'posting'
      ORDER BY id
      LIMIT v_limit
    )
    RETURNING id
  )
  SELECT count(*)::int INTO v_posting FROM touched;

  WITH touched AS (
    UPDATE public.gpsl_discord_feed_queue q
    SET status = 'pending',
        claimed_at = NULL,
        last_error = left(
          coalesce(q.last_error, '') || ' [reopened after rate limit]',
          500
        )
    WHERE q.id IN (
      SELECT id
      FROM public.gpsl_discord_feed_queue
      WHERE status = 'error'
        AND (
          last_error ILIKE '%429%'
          OR last_error ILIKE '%rate limited%'
          OR last_error ILIKE '%rate limit%'
        )
      ORDER BY id
      LIMIT v_limit
    )
    RETURNING id
  )
  SELECT count(*)::int INTO v_errors FROM touched;

  BEGIN
    PERFORM public.gpsl_discord_feed_request_flush();
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;

  RETURN jsonb_build_object(
    'ok', true,
    'reopened', coalesce(v_posting, 0) + coalesce(v_errors, 0),
    'unstuck_posting', coalesce(v_posting, 0),
    'reopened_rate_limited', coalesce(v_errors, 0),
    'hint', 'Items are pending again — Push queue (slowly) or wait for auto-flush.'
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.admin_discord_requeue_rate_limited(integer) TO authenticated;

-- One-shot: free anything currently stuck in posting
UPDATE public.gpsl_discord_feed_queue q
SET status = 'pending',
    claimed_at = NULL,
    last_error = left(
      coalesce(q.last_error, '') || ' [unstuck posting]',
      500
    )
WHERE q.status = 'posting';

NOTIFY pgrst, 'reload schema';
