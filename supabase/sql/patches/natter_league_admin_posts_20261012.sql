-- =============================================================================
-- Natter: league / admin posts (2026-10-12)
-- =============================================================================
-- GPSL admins can post on Natter as ADMIN, SUPERLEAGUE, CHAMPIONSHIP A,
-- CHAMPIONSHIP B or CHAMPIONSHIP (pool) — separate from their own club:
--   * no club attached (club_short_name NULL, author_kind set)
--   * does not use the admin's club post allowance; no per-window limit
--   * shows in the feed with the league / GPSL badge; posted to Discord
--   * excluded from GPSL Sport club news
-- Only is_gpsl_admin() can call natter_admin_create_league_post.
-- Safe re-run.
-- =============================================================================

ALTER TABLE public.natter_posts
  ALTER COLUMN club_short_name DROP NOT NULL;

ALTER TABLE public.natter_posts
  ADD COLUMN IF NOT EXISTS author_kind text;

ALTER TABLE public.natter_posts
  DROP CONSTRAINT IF EXISTS natter_posts_author_kind_check;
ALTER TABLE public.natter_posts
  ADD CONSTRAINT natter_posts_author_kind_check CHECK (
    author_kind IS NULL
    OR author_kind IN ('ADMIN', 'SUPERLEAGUE', 'CHAMPIONSHIP_A', 'CHAMPIONSHIP_B', 'CHAMPIONSHIP')
  );

ALTER TABLE public.natter_posts
  DROP CONSTRAINT IF EXISTS natter_posts_author_check;
ALTER TABLE public.natter_posts
  ADD CONSTRAINT natter_posts_author_check CHECK (
    club_short_name IS NOT NULL OR author_kind IS NOT NULL
  );

CREATE OR REPLACE FUNCTION public.natter_author_label(p_kind text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE p_kind
    WHEN 'ADMIN' THEN 'GPSL Admin'
    WHEN 'SUPERLEAGUE' THEN 'SuperLeague'
    WHEN 'CHAMPIONSHIP_A' THEN 'Championship A'
    WHEN 'CHAMPIONSHIP_B' THEN 'Championship B'
    WHEN 'CHAMPIONSHIP' THEN 'Championship'
  END;
$$;

GRANT EXECUTE ON FUNCTION public.natter_author_label(text) TO authenticated;

-- ---------------------------------------------------------------------------
-- Admin: create a league post
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.natter_admin_create_league_post(
  p_author_kind text,
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
  v_kind text := upper(btrim(coalesce(p_author_kind, '')));
  v_label text;
  v_ctx jsonb;
  v_month text;
  v_season_id bigint;
  v_body text;
  v_image text;
  v_id bigint;
  v_month_label text;
BEGIN
  IF v_uid IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_authenticated');
  END IF;
  IF NOT public.is_gpsl_admin() THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'admin_only');
  END IF;

  v_label := public.natter_author_label(v_kind);
  IF v_label IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'bad_author');
  END IF;

  v_ctx := public.natter_active_month_context();
  v_month := nullif(v_ctx->>'gpsl_month', '');
  v_season_id := nullif(v_ctx->>'season_id', '')::bigint;
  IF v_month IS NULL OR v_season_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_active_month');
  END IF;

  v_body := nullif(btrim(coalesce(p_body, '')), '');
  IF v_body IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'empty');
  END IF;
  IF char_length(v_body) > 1000 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'too_long', 'max_chars', 1000);
  END IF;

  v_image := nullif(btrim(coalesce(p_image_path, '')), '');

  INSERT INTO public.natter_posts (
    season_id, gpsl_month, club_short_name, author_kind, owner_id, owner_tag, body, image_path
  )
  VALUES (
    v_season_id, v_month, NULL, v_kind, v_uid, '', v_body, v_image
  )
  RETURNING id INTO v_id;

  BEGIN
    v_month_label := public.competition_gpsl_month_label(v_month);
  EXCEPTION WHEN OTHERS THEN
    v_month_label := initcap(v_month);
  END;

  BEGIN
    PERFORM public.gpsl_discord_feed_enqueue(
      'natter',
      format('📣 NATTER — %s', v_label),
      coalesce(v_month_label, initcap(v_month)) || E'\n\n' || left(v_body, 900),
      5763839,
      'natter:' || v_id::text,
      jsonb_build_object('post_id', v_id, 'author_kind', v_kind, 'image_path', v_image)
    );
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'natter league post % discord enqueue failed: %', v_id, SQLERRM;
  END;

  RETURN jsonb_build_object(
    'ok', true,
    'id', v_id,
    'author_kind', v_kind,
    'author_label', v_label,
    'gpsl_month', v_month
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.natter_admin_create_league_post(text, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.natter_admin_create_league_post(text, text, text) TO authenticated;

-- ---------------------------------------------------------------------------
-- Feed: author fields for league posts
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.natter_list_posts(
  p_season_id bigint DEFAULT NULL,
  p_gpsl_month text DEFAULT NULL,
  p_limit int DEFAULT 100
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season_id bigint := p_season_id;
  v_month text := lower(nullif(btrim(coalesce(p_gpsl_month, '')), ''));
  v_lim int := greatest(1, least(coalesce(p_limit, 100), 200));
  v_uid uuid := auth.uid();
  v_can_react boolean := false;
BEGIN
  IF v_season_id IS NULL THEN
    SELECT id INTO v_season_id
    FROM public.competition_seasons
    WHERE is_current = true
    ORDER BY id DESC
    LIMIT 1;
  END IF;

  IF v_season_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_season', 'posts', '[]'::jsonb);
  END IF;

  IF v_uid IS NOT NULL THEN
    v_can_react := EXISTS (
      SELECT 1 FROM public."Clubs" c WHERE c.owner_id = v_uid LIMIT 1
    );
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'season_id', v_season_id,
    'gpsl_month', v_month,
    'can_react', v_can_react,
    'reaction_emojis', to_jsonb(public.natter_allowed_reaction_emojis()),
    'posts', coalesce((
      SELECT jsonb_agg(row_data ORDER BY sort_at DESC)
      FROM (
        SELECT
          jsonb_build_object(
            'id', p.id,
            'season_id', p.season_id,
            'gpsl_month', p.gpsl_month,
            'month_label', public.competition_gpsl_month_label(p.gpsl_month),
            'club_short', p.club_short_name,
            'club_name', coalesce(
              public.natter_author_label(p.author_kind),
              public.natter_club_display_name(p.club_short_name)
            ),
            'author_kind', p.author_kind,
            'owner_tag', p.owner_tag,
            'body', p.body,
            'image_path', p.image_path,
            'created_at', p.created_at,
            'reactions', public.natter_reaction_details(p.id),
            'my_reactions', coalesce((
              SELECT jsonb_agg(r.emoji ORDER BY r.emoji)
              FROM public.natter_reactions r
              WHERE r.post_id = p.id
                AND r.owner_id = v_uid
            ), '[]'::jsonb)
          ) AS row_data,
          p.created_at AS sort_at
        FROM public.natter_posts p
        WHERE p.season_id = v_season_id
          AND (v_month IS NULL OR p.gpsl_month = v_month)
        ORDER BY p.created_at DESC
        LIMIT v_lim
      ) q
    ), '[]'::jsonb)
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.natter_list_posts(bigint, text, int) TO authenticated;

-- ---------------------------------------------------------------------------
-- Club post limits / GPSL Sport club news ignore league posts
-- ---------------------------------------------------------------------------
DO $sport$
DECLARE
  v_def text;
BEGIN
  SELECT pg_get_functiondef('public.gpsl_sport_fetch_club_news(bigint, text)'::regprocedure)
  INTO v_def;
  IF position('p.club_short_name IS NOT NULL' IN v_def) = 0
     AND position('AND p.gpsl_month = v_prev_month' IN v_def) > 0 THEN
    EXECUTE replace(v_def,
      'AND p.gpsl_month = v_prev_month',
      'AND p.gpsl_month = v_prev_month AND p.club_short_name IS NOT NULL');
  END IF;
END
$sport$;

NOTIFY pgrst, 'reload schema';

SELECT
  (SELECT count(*) FROM public.natter_posts WHERE author_kind IS NOT NULL) AS league_posts_so_far,
  public.natter_active_month_context()->>'gpsl_month' AS current_window;
