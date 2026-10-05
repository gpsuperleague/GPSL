-- =============================================================================
-- Natter — one post per owner in Pre-season and one in Summer Break
-- =============================================================================
-- Windows (one post per club per window, same as a GPSL month):
--   • Pre-season: current season in setup / preseason, or active before the
--     first GPSL month unlocks → key 'preseason' on that season.
--   • GPSL months (June … May): unchanged; Playoffs week stays closed.
--   • Summer Break: no current season (last season ended) → key 'summer_break'
--     on the most recently completed season.
-- Pre-season posts were previously keyed 'july' and blocked the real July post;
-- those are moved to 'preseason' while the season has not started yet.
-- =============================================================================

ALTER TABLE public.natter_posts
  DROP CONSTRAINT IF EXISTS natter_posts_month_check;

ALTER TABLE public.natter_posts
  ADD CONSTRAINT natter_posts_month_check CHECK (
    gpsl_month IN (
      'june', 'july', 'august', 'september', 'october', 'november', 'december',
      'january', 'february', 'march', 'april', 'may',
      'preseason', 'summer_break'
    )
  );

CREATE OR REPLACE FUNCTION public.competition_gpsl_month_label(p_month text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE lower(btrim(coalesce(p_month, '')))
    WHEN 'playoffs' THEN 'Playoffs'
    WHEN 'preseason' THEN 'Pre-season'
    WHEN 'summer_break' THEN 'Summer Break'
    ELSE initcap(lower(btrim(coalesce(p_month, ''))))
  END;
$$;

CREATE OR REPLACE FUNCTION public.natter_month_sort(p_month text)
RETURNS integer
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE lower(btrim(coalesce(p_month, '')))
    WHEN 'preseason' THEN 0
    WHEN 'summer_break' THEN 99
    ELSE coalesce(public.competition_gpsl_month_sort(p_month)::int, 50)
  END;
$$;

-- Current Natter window: season + key, or NULL key when closed
CREATE OR REPLACE FUNCTION public.natter_current_window()
RETURNS TABLE (season_id bigint, season_label text, season_status text, gpsl_month text)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_id bigint;
  v_label text;
  v_status text;
  v_month text;
  v_first_unlock timestamptz;
BEGIN
  SELECT s.id, s.label, s.status
  INTO v_id, v_label, v_status
  FROM public.competition_seasons s
  WHERE s.is_current = true
  ORDER BY s.id DESC
  LIMIT 1;

  IF v_id IS NOT NULL THEN
    v_status := lower(coalesce(v_status, ''));
    IF v_status IN ('setup', 'preseason') THEN
      v_month := 'preseason';
    ELSIF v_status = 'active' THEN
      v_month := lower(nullif(btrim(coalesce(
        public.competition_active_gpsl_month(v_id, now()), ''
      )), ''));
      IF v_month = 'playoffs' THEN
        v_month := NULL;
      ELSIF v_month IS NULL THEN
        SELECT min(m.unlock_at) INTO v_first_unlock
        FROM public.competition_season_calendar m
        WHERE m.season_id = v_id;
        IF v_first_unlock IS NULL OR now() < v_first_unlock THEN
          v_month := 'preseason';
        END IF;
      END IF;
    END IF;

    season_id := v_id;
    season_label := v_label;
    season_status := v_status;
    gpsl_month := v_month;
    RETURN NEXT;
    RETURN;
  END IF;

  -- No current season → Summer Break on the last completed season
  SELECT s.id, s.label, s.status
  INTO v_id, v_label, v_status
  FROM public.competition_seasons s
  WHERE s.status IN ('complete', 'summer_break')
  ORDER BY coalesce(s.ended_at, s.created_at) DESC NULLS LAST, s.id DESC
  LIMIT 1;

  IF v_id IS NULL THEN
    RETURN;
  END IF;

  season_id := v_id;
  season_label := v_label;
  season_status := 'summer_break';
  gpsl_month := 'summer_break';
  RETURN NEXT;
END;
$function$;

CREATE OR REPLACE FUNCTION public.natter_compose_open()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT coalesce((SELECT w.gpsl_month IS NOT NULL FROM public.natter_current_window() w LIMIT 1), false);
$$;

CREATE OR REPLACE FUNCTION public.natter_active_month_context()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  w record;
BEGIN
  SELECT * INTO w FROM public.natter_current_window() LIMIT 1;

  IF w.season_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_season');
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'season_id', w.season_id,
    'season_label', w.season_label,
    'season_status', w.season_status,
    'gpsl_month', w.gpsl_month,
    'month_label', CASE WHEN w.gpsl_month IS NULL THEN NULL
                        ELSE public.competition_gpsl_month_label(w.gpsl_month) END,
    'compose_open', w.gpsl_month IS NOT NULL
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.natter_list_months(p_season_id bigint DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season_id bigint := p_season_id;
BEGIN
  IF v_season_id IS NULL THEN
    SELECT w.season_id INTO v_season_id FROM public.natter_current_window() w LIMIT 1;
  END IF;

  IF v_season_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_season');
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'season_id', v_season_id,
    'months', coalesce((
      SELECT jsonb_agg(
        jsonb_build_object(
          'gpsl_month', q.gpsl_month,
          'month_label', public.competition_gpsl_month_label(q.gpsl_month),
          'post_count', q.post_count,
          'sort_key', public.natter_month_sort(q.gpsl_month)
        )
        ORDER BY public.natter_month_sort(q.gpsl_month) DESC
      )
      FROM (
        SELECT p.gpsl_month, count(*)::int AS post_count
        FROM public.natter_posts p
        WHERE p.season_id = v_season_id
        GROUP BY p.gpsl_month
      ) q
    ), '[]'::jsonb)
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.natter_unread_count()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_season_id bigint;
  v_last_seen timestamptz;
  v_count int := 0;
BEGIN
  IF v_uid IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_authenticated', 'count', 0);
  END IF;

  SELECT w.season_id INTO v_season_id FROM public.natter_current_window() w LIMIT 1;

  IF v_season_id IS NULL THEN
    RETURN jsonb_build_object('ok', true, 'count', 0, 'season_id', NULL);
  END IF;

  SELECT r.last_seen_at INTO v_last_seen
  FROM public.natter_reads r
  WHERE r.owner_id = v_uid;

  SELECT count(*)::int INTO v_count
  FROM public.natter_posts p
  WHERE p.season_id = v_season_id
    AND p.owner_id IS DISTINCT FROM v_uid
    AND (v_last_seen IS NULL OR p.created_at > v_last_seen);

  RETURN jsonb_build_object(
    'ok', true,
    'count', coalesce(v_count, 0),
    'season_id', v_season_id
  );
END;
$function$;

-- Pre-season posts previously stored as 'july' → 'preseason' (season not started yet)
UPDATE public.natter_posts p
SET gpsl_month = 'preseason'
FROM public.natter_current_window() w
WHERE w.gpsl_month = 'preseason'
  AND p.season_id = w.season_id
  AND p.gpsl_month = 'july'
  AND NOT EXISTS (
    SELECT 1 FROM public.natter_posts x
    WHERE x.season_id = p.season_id
      AND x.club_short_name = p.club_short_name
      AND x.gpsl_month = 'preseason'
  );

GRANT EXECUTE ON FUNCTION public.natter_month_sort(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.natter_current_window() TO authenticated;
GRANT EXECUTE ON FUNCTION public.natter_compose_open() TO authenticated;
GRANT EXECUTE ON FUNCTION public.natter_active_month_context() TO authenticated;
GRANT EXECUTE ON FUNCTION public.natter_list_months(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.natter_unread_count() TO authenticated;

NOTIFY pgrst, 'reload schema';

SELECT * FROM public.natter_current_window();
