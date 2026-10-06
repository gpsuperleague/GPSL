-- =============================================================================
-- Natter: 2 posts per club in Pre-season, GPSL June and GPSL July.
-- Every other window (August … May, Summer Break) stays at 1 post.
-- Replaces the one-row-per-window unique constraint with a per-window limit
-- enforced in natter_create_post (serialised per club with an advisory lock).
-- Run once in the Supabase SQL Editor.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.natter_post_limit(p_month text)
RETURNS integer
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE lower(btrim(coalesce(p_month, '')))
    WHEN 'preseason' THEN 2
    WHEN 'june' THEN 2
    WHEN 'july' THEN 2
    ELSE 1
  END;
$$;

GRANT EXECUTE ON FUNCTION public.natter_post_limit(text) TO authenticated;

ALTER TABLE public.natter_posts DROP CONSTRAINT IF EXISTS natter_posts_unique;
CREATE INDEX IF NOT EXISTS natter_posts_window_club_idx
  ON public.natter_posts (season_id, gpsl_month, club_short_name);

-- ---------------------------------------------------------------------------
-- Compose state: posts used / limit for the current window
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.natter_get_compose_state()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text;
  v_club_name text;
  v_ctx jsonb;
  v_month text;
  v_used int := 0;
  v_limit int := 1;
  v_post jsonb;
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_authenticated');
  END IF;

  SELECT c."ShortName", c."Club"
  INTO v_club, v_club_name
  FROM public."Clubs" c
  WHERE c.owner_id = auth.uid()
  LIMIT 1;

  v_ctx := public.natter_active_month_context();
  v_month := nullif(v_ctx->>'gpsl_month', '');
  v_limit := public.natter_post_limit(v_month);

  IF v_club IS NOT NULL
    AND coalesce((v_ctx->>'ok')::boolean, false)
    AND v_month IS NOT NULL THEN
    SELECT count(*)::int INTO v_used
    FROM public.natter_posts p
    WHERE p.season_id = (v_ctx->>'season_id')::bigint
      AND p.gpsl_month = v_month
      AND p.club_short_name = v_club;

    SELECT jsonb_build_object(
             'id', p.id,
             'body', p.body,
             'image_path', p.image_path,
             'created_at', p.created_at
           )
    INTO v_post
    FROM public.natter_posts p
    WHERE p.season_id = (v_ctx->>'season_id')::bigint
      AND p.gpsl_month = v_month
      AND p.club_short_name = v_club
    ORDER BY p.created_at DESC
    LIMIT 1;
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'club_short_name', v_club,
    'club_name', coalesce(v_club_name, v_club),
    'context', v_ctx,
    'posts_used', v_used,
    'post_limit', v_limit,
    'posts_remaining', greatest(v_limit - v_used, 0),
    'already_posted', v_used >= v_limit,
    'my_post', v_post,
    'max_chars', 1000,
    'can_compose', (
      v_club IS NOT NULL
      AND coalesce((v_ctx->>'compose_open')::boolean, false)
      AND v_used < v_limit
    )
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.natter_get_compose_state() TO authenticated;

-- ---------------------------------------------------------------------------
-- Create post: allow up to natter_post_limit(window) per club
-- ---------------------------------------------------------------------------
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
  v_used int;
  v_limit int;
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

  PERFORM pg_advisory_xact_lock(hashtext('natter:' || v_season_id || ':' || v_month || ':' || v_club));

  v_limit := public.natter_post_limit(v_month);
  SELECT count(*)::int INTO v_used
  FROM public.natter_posts p
  WHERE p.season_id = v_season_id
    AND p.gpsl_month = v_month
    AND p.club_short_name = v_club;

  IF v_used >= v_limit THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'already_posted', 'post_limit', v_limit);
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

  PERFORM public.gpsl_discord_feed_enqueue_natter_post(v_id);

  RETURN jsonb_build_object(
    'ok', true,
    'id', v_id,
    'club_short_name', v_club,
    'club_name', coalesce(v_club_name, v_club),
    'gpsl_month', v_month,
    'month_label', public.competition_gpsl_month_label(v_month),
    'body', v_body,
    'image_path', v_image,
    'posts_used', v_used + 1,
    'post_limit', v_limit
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.natter_create_post(text, text) TO authenticated;

NOTIFY pgrst, 'reload schema';

SELECT w.gpsl_month AS current_window,
       public.natter_post_limit(w.gpsl_month) AS posts_per_club
FROM public.natter_current_window() w;
