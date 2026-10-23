-- =============================================================================
-- Admin: force-rescan Discord match video channels (ignore cursors)
-- =============================================================================
-- Uses stored edge URL + invoke key (same as auto-poll). Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.admin_discord_match_videos_request_rescan(
  p_limit int DEFAULT 100
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions, net
AS $function$
DECLARE
  v_url text;
  v_key text;
  v_limit int := greatest(1, least(coalesce(p_limit, 100), 100));
  v_req_id bigint;
BEGIN
  IF NOT public.is_gpsl_admin()
     AND coalesce(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  SELECT s.edge_function_url, s.invoke_key
  INTO v_url, v_key
  FROM public.gpsl_discord_match_videos_settings s
  WHERE s.id = 1;

  IF v_url IS NULL OR btrim(v_url) = '' THEN
    v_url := 'https://omyyogfumrjoaweuawjn.supabase.co/functions/v1/discord-match-videos-ingest';
  END IF;

  IF v_key IS NULL OR btrim(v_key) = '' THEN
    RETURN jsonb_build_object(
      'ok', false,
      'reason', 'No invoke key in match videos settings — save auto-poll URL/key on Admin → Match videos first'
    );
  END IF;

  -- Clear cursors so the next poll walks recent history from scratch
  UPDATE public.gpsl_discord_match_videos_settings
  SET channel_cursors = '{}'::jsonb,
      updated_at = now()
  WHERE id = 1;

  SELECT net.http_post(
    url := v_url,
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || v_key
    ),
    body := jsonb_build_object(
      'poll', true,
      'rescan', true,
      'limit', v_limit
    ),
    timeout_milliseconds := 120000
  ) INTO v_req_id;

  RETURN jsonb_build_object(
    'ok', true,
    'request_id', v_req_id,
    'limit', v_limit,
    'note', 'Rescan queued via pg_net — check Discord reactions / Admin Match videos ingest log in ~1–2 min'
  );
EXCEPTION
  WHEN undefined_function THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'pg_net missing');
  WHEN OTHERS THEN
    RETURN jsonb_build_object('ok', false, 'reason', SQLERRM);
END;
$function$;

REVOKE ALL ON FUNCTION public.admin_discord_match_videos_request_rescan(int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_discord_match_videos_request_rescan(int) TO authenticated, service_role;

-- Convenience overload
CREATE OR REPLACE FUNCTION public.admin_discord_match_videos_request_rescan()
RETURNS jsonb
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT public.admin_discord_match_videos_request_rescan(100);
$$;

REVOKE ALL ON FUNCTION public.admin_discord_match_videos_request_rescan() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_discord_match_videos_request_rescan() TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';
