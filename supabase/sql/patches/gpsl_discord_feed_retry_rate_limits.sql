-- =============================================================================
-- Discord queue: reopen 429 / rate-limit errors as pending
-- Safe re-run. Then Push queue (or wait for auto-flush cron).
-- =============================================================================

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
  v_n int;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  WITH touched AS (
    UPDATE public.gpsl_discord_feed_queue q
    SET status = 'pending',
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
  SELECT count(*)::int INTO v_n FROM touched;

  BEGIN
    PERFORM public.gpsl_discord_feed_request_flush();
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;

  RETURN jsonb_build_object(
    'ok', true,
    'reopened', coalesce(v_n, 0),
    'hint', 'Items are pending again — Push queue (slowly) or wait for auto-flush.'
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.admin_discord_requeue_rate_limited(integer) TO authenticated;

-- One-shot for SQL Editor (bypass admin check)
UPDATE public.gpsl_discord_feed_queue q
SET status = 'pending',
    last_error = left(
      coalesce(q.last_error, '') || ' [reopened after rate limit]',
      500
    )
WHERE q.status = 'error'
  AND (
    q.last_error ILIKE '%429%'
    OR q.last_error ILIKE '%rate limited%'
    OR q.last_error ILIKE '%rate limit%'
  );

NOTIFY pgrst, 'reload schema';
