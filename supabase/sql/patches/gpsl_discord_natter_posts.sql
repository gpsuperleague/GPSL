-- =============================================================================
-- Discord: push new Natter posts (with image) to #gpsl-natter
--
-- 1) Discord: create #gpsl-natter → Integrations → Webhooks → New Webhook → copy URL
-- 2) Supabase → Edge Functions → Secrets:
--      DISCORD_NATTER_WEBHOOK_URL = #gpsl-natter webhook
-- 3) Run this SQL in Supabase SQL Editor
-- 4) Redeploy: supabase functions deploy discord-sky-feed
-- 5) Admin Discord page → Push queue (or wait for auto-flush)
--
-- Safe re-run. Re-running also backfills recent Natters that never reached Discord.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.gpsl_discord_feed_enqueue_natter_post(p_post_id bigint)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  r public.natter_posts%rowtype;
  v_club text;
  v_month text;
  v_owner text;
  v_headline text;
  v_body text;
  v_id bigint;
  v_dedupe text;
BEGIN
  SELECT * INTO r FROM public.natter_posts WHERE id = p_post_id;
  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  v_dedupe := 'natter:' || r.id::text;

  -- Re-open failed/skipped rows so Push can retry
  UPDATE public.gpsl_discord_feed_queue q
  SET status = 'pending',
      last_error = NULL,
      headline = q.headline,
      body = q.body,
      metadata = q.metadata
  WHERE q.dedupe_key = v_dedupe
    AND q.status IN ('error', 'skipped');

  IF EXISTS (
    SELECT 1
    FROM public.gpsl_discord_feed_queue q
    WHERE q.dedupe_key = v_dedupe
      AND q.status IN ('pending', 'posted')
  ) THEN
    SELECT q.id INTO v_id
    FROM public.gpsl_discord_feed_queue q
    WHERE q.dedupe_key = v_dedupe
    LIMIT 1;
    RETURN v_id;
  END IF;

  SELECT c."Club" INTO v_club
  FROM public."Clubs" c
  WHERE c."ShortName" = r.club_short_name;
  v_club := coalesce(nullif(btrim(v_club), ''), r.club_short_name);

  BEGIN
    v_month := public.competition_gpsl_month_label(r.gpsl_month);
  EXCEPTION WHEN OTHERS THEN
    v_month := initcap(coalesce(r.gpsl_month, ''));
  END;
  IF nullif(btrim(coalesce(v_month, '')), '') IS NULL THEN
    v_month := coalesce(r.gpsl_month, 'Month');
  END IF;

  v_owner := nullif(btrim(coalesce(r.owner_tag, '')), '');
  IF v_owner IS NOT NULL AND left(v_owner, 1) <> '@' THEN
    v_owner := '@' || v_owner;
  END IF;

  v_headline := format('💬 NATTER — %s', v_club);

  v_body := v_month;
  IF v_owner IS NOT NULL THEN
    v_body := v_body || ' · ' || v_owner;
  END IF;
  v_body := v_body || E'\n\n' || left(btrim(r.body), 900);

  v_id := public.gpsl_discord_feed_enqueue(
    'natter',
    v_headline,
    v_body,
    5763839, -- 0x57f287 Discord green
    v_dedupe,
    jsonb_build_object(
      'post_id', r.id,
      'club_short_name', r.club_short_name,
      'gpsl_month', r.gpsl_month,
      'image_path', r.image_path,
      'channel', 'natter'
    )
  );

  RETURN v_id;
END;
$function$;

CREATE OR REPLACE FUNCTION public.gpsl_discord_feed_on_natter_post()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  PERFORM public.gpsl_discord_feed_enqueue_natter_post(NEW.id);
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_gpsl_discord_feed_natter_post ON public.natter_posts;
CREATE TRIGGER trg_gpsl_discord_feed_natter_post
  AFTER INSERT ON public.natter_posts
  FOR EACH ROW
  EXECUTE FUNCTION public.gpsl_discord_feed_on_natter_post();

-- Also enqueue from create RPC so Discord still fires even if the trigger was missing
CREATE OR REPLACE FUNCTION public.natter_create_post(
  p_body text,
  p_image_path text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_club text;
  v_club_name text;
  v_tag text;
  v_ctx jsonb;
  v_month text;
  v_season_id bigint;
  v_body text;
  v_image text;
  v_id bigint;
BEGIN
  IF v_uid IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_authenticated');
  END IF;

  SELECT c."ShortName", c."Club",
         coalesce(
           nullif(btrim(c.owner), ''),
           nullif(btrim(public.owner_registry_resolve_tag(c.owner_id)), ''),
           ''
         )
  INTO v_club, v_club_name, v_tag
  FROM public."Clubs" c
  WHERE c.owner_id = v_uid
  LIMIT 1;

  IF v_club IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_club');
  END IF;

  v_ctx := public.natter_active_month_context();
  IF NOT coalesce((v_ctx->>'compose_open')::boolean, false) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'window_closed');
  END IF;

  v_month := nullif(v_ctx->>'gpsl_month', '');
  v_season_id := nullif(v_ctx->>'season_id', '')::bigint;
  IF v_month IS NULL OR v_season_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_active_month');
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.natter_posts p
    WHERE p.season_id = v_season_id
      AND p.gpsl_month = v_month
      AND p.club_short_name = v_club
  ) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'already_posted');
  END IF;

  v_body := nullif(btrim(coalesce(p_body, '')), '');
  IF v_body IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'empty');
  END IF;
  IF char_length(v_body) > 1000 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'too_long', 'max_chars', 1000);
  END IF;

  v_image := nullif(btrim(coalesce(p_image_path, '')), '');
  IF v_image IS NOT NULL AND split_part(v_image, '/', 1) IS DISTINCT FROM v_club THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_image_path');
  END IF;

  INSERT INTO public.natter_posts (
    season_id, gpsl_month, club_short_name, owner_id, owner_tag, body, image_path
  )
  VALUES (
    v_season_id, v_month, v_club, v_uid, coalesce(v_tag, ''), v_body, v_image
  )
  RETURNING id INTO v_id;

  -- Belt-and-suspenders with AFTER INSERT trigger (dedupe_key prevents doubles)
  PERFORM public.gpsl_discord_feed_enqueue_natter_post(v_id);

  RETURN jsonb_build_object(
    'ok', true,
    'id', v_id,
    'club_short_name', v_club,
    'club_name', coalesce(v_club_name, v_club),
    'gpsl_month', v_month,
    'month_label', public.competition_gpsl_month_label(v_month),
    'body', v_body,
    'image_path', v_image
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.natter_create_post(text, text) TO authenticated;

-- Admin: enqueue / retry Natters missing from Discord (or stuck in error)
CREATE OR REPLACE FUNCTION public.admin_discord_requeue_natter_posts(
  p_days integer DEFAULT 30
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_days int := greatest(1, least(coalesce(p_days, 30), 365));
  v_post_id bigint;
  v_queued int := 0;
  v_ids bigint[] := ARRAY[]::bigint[];
  v_qid bigint;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  FOR v_post_id IN
    SELECT p.id
    FROM public.natter_posts p
    WHERE p.created_at >= now() - make_interval(days => v_days)
      AND NOT EXISTS (
        SELECT 1
        FROM public.gpsl_discord_feed_queue q
        WHERE q.dedupe_key = 'natter:' || p.id::text
          AND q.status = 'posted'
      )
    ORDER BY p.id
  LOOP
    v_qid := public.gpsl_discord_feed_enqueue_natter_post(v_post_id);
    IF v_qid IS NOT NULL THEN
      v_queued := v_queued + 1;
      v_ids := v_ids || v_post_id;
    END IF;
  END LOOP;

  -- Kick auto-flush if configured
  BEGIN
    PERFORM public.gpsl_discord_feed_request_flush();
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;

  RETURN jsonb_build_object(
    'ok', true,
    'queued_or_reopened', v_queued,
    'post_ids', to_jsonb(v_ids),
    'hint', 'Push queue to Discord (or wait for auto-flush) if items stay pending.'
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.admin_discord_requeue_natter_posts(integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.gpsl_discord_feed_enqueue_natter_post(bigint) TO service_role;

-- One-shot backfill (SQL Editor runs as postgres — skip is_gpsl_admin gate)
DO $$
DECLARE
  v_post_id bigint;
BEGIN
  FOR v_post_id IN
    SELECT p.id
    FROM public.natter_posts p
    WHERE p.created_at >= now() - interval '60 days'
      AND NOT EXISTS (
        SELECT 1
        FROM public.gpsl_discord_feed_queue q
        WHERE q.dedupe_key = 'natter:' || p.id::text
          AND q.status = 'posted'
      )
    ORDER BY p.id
  LOOP
    PERFORM public.gpsl_discord_feed_enqueue_natter_post(v_post_id);
  END LOOP;

  BEGIN
    PERFORM public.gpsl_discord_feed_request_flush();
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;
END $$;

NOTIFY pgrst, 'reload schema';
