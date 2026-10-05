-- =============================================================================
-- Natter → Discord: send the full post body
-- =============================================================================
-- Natter posts allow 1000 chars but the Discord enqueue cut the body at 900,
-- chopping the end off longer posts. Discord embed descriptions allow 4096.
-- Also refreshes the body of any still-pending Natter queue rows.
-- =============================================================================

DO $patch$
DECLARE
  v_def text;
  v_new text;
BEGIN
  SELECT pg_get_functiondef('public.gpsl_discord_feed_enqueue_natter_post(bigint)'::regprocedure)
  INTO v_def;

  IF position('left(btrim(r.body), 900)' IN v_def) = 0 THEN
    RAISE NOTICE 'Natter Discord enqueue: 900-char cut not found (already patched?)';
    RETURN;
  END IF;

  v_new := replace(v_def, 'left(btrim(r.body), 900)', 'btrim(r.body)');
  EXECUTE v_new;
  RAISE NOTICE 'Natter Discord enqueue: full body enabled';
END;
$patch$;

-- Pending (not yet posted) Natter rows: rebuild body with the full text
UPDATE public.gpsl_discord_feed_queue q
SET body = split_part(q.body, E'\n\n', 1) || E'\n\n' || btrim(p.body)
FROM public.natter_posts p
WHERE q.event_type = 'natter'
  AND q.status IN ('pending', 'error', 'skipped')
  AND q.dedupe_key = 'natter:' || p.id::text;

NOTIFY pgrst, 'reload schema';
