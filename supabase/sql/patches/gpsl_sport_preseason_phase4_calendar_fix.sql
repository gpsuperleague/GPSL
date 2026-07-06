-- =============================================================================
-- GPSL Sport Phase 4 — fix pre-season calendar window (June/July)
-- Bug: May lock_at from the in-season calendar is in the FUTURE before August,
--      so preseason_start landed after now() and every query returned 0 rows.
-- Run after gpsl_sport_preseason_phase3.sql, then regenerate June/July editions.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.gpsl_sport_preseason_window(p_season_id bigint)
RETURNS TABLE (
  august_start timestamptz,
  may_end timestamptz,
  preseason_start timestamptz,
  preseason_weeks numeric,
  june_window_start timestamptz,
  june_window_end timestamptz,
  july_window_start timestamptz,
  july_window_end timestamptz,
  publish_june_at timestamptz,
  publish_july_at timestamptz,
  include_june boolean,
  include_july boolean
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_august timestamptz;
  v_may timestamptz;
  v_draft timestamptz;
  v_now timestamptz := now();
  v_start timestamptz;
  v_mid timestamptz;
  v_weeks numeric;
BEGIN
  SELECT cfg.anchor_unlock_at INTO v_august
  FROM public.competition_season_calendar_config cfg
  WHERE cfg.season_id = p_season_id;

  IF v_august IS NULL THEN
    SELECT c.unlock_at INTO v_august
    FROM public.competition_season_calendar c
    WHERE c.season_id = p_season_id
      AND c.gpsl_month = 'august'
    LIMIT 1;
  END IF;

  IF v_august IS NULL THEN
    RETURN;
  END IF;

  SELECT g.draft_auction_start_time INTO v_draft
  FROM public.global_settings g
  WHERE g.id = 1;

  IF v_now < v_august THEN
    -- Live GPSL pre-season (June/July): gap before August unlock.
    -- Do NOT use this season's May row — that lock is ~10 months in the future.
    v_start := v_august - interval '8 weeks';
    IF v_draft IS NOT NULL AND v_draft < v_start THEN
      v_start := date_trunc('day', v_draft);
    END IF;
    IF v_start > v_now THEN
      v_start := coalesce(date_trunc('day', v_draft), v_august - interval '8 weeks');
    END IF;
    v_may := NULL;
  ELSE
    -- After August has started: May lock marks end of prior campaign (May review).
    SELECT c.lock_at INTO v_may
    FROM public.competition_season_calendar c
    WHERE c.season_id = p_season_id
      AND c.gpsl_month = 'may'
      AND c.lock_at <= v_now
    LIMIT 1;
    v_start := coalesce(v_may, v_august - interval '8 weeks');
  END IF;

  IF v_start IS NULL OR v_start >= v_august THEN
    v_start := v_august - interval '8 weeks';
  END IF;

  v_mid := v_start + ((v_august - v_start) / 2.0);
  v_weeks := greatest(0, extract(epoch FROM (v_august - v_start)) / 604800.0);

  august_start := v_august;
  may_end := v_may;
  preseason_start := v_start;
  preseason_weeks := round(v_weeks::numeric, 2);

  include_june := v_weeks >= 5;
  include_july := true;

  IF include_june THEN
    publish_june_at := v_start;
    publish_july_at := v_august - interval '4 weeks';
    june_window_start := v_start;
    june_window_end := v_mid;
    july_window_start := v_mid;
    july_window_end := v_august;
  ELSE
    publish_june_at := NULL;
    publish_july_at := v_start;
    june_window_start := NULL;
    june_window_end := NULL;
    july_window_start := v_start;
    july_window_end := v_august;
  END IF;

  RETURN NEXT;
END;
$function$;

-- Bounds used when querying transfers / auctions (caps end at now during live pre-season)
CREATE OR REPLACE FUNCTION public.gpsl_sport_preseason_data_bounds(
  p_season_id bigint,
  p_gpsl_month text
)
RETURNS TABLE (
  window_start timestamptz,
  window_end timestamptz
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_month text := lower(btrim(p_gpsl_month));
  v_win record;
  v_draft timestamptz;
  v_now timestamptz := now();
  v_start timestamptz;
  v_end timestamptz;
BEGIN
  SELECT * INTO v_win
  FROM public.gpsl_sport_preseason_window(p_season_id);

  IF NOT FOUND THEN
    RETURN;
  END IF;

  SELECT g.draft_auction_start_time INTO v_draft
  FROM public.global_settings g
  WHERE g.id = 1;

  IF v_month = 'july' THEN
    v_start := v_win.preseason_start;
    v_end := least(v_win.august_start, v_now + interval '1 second');
  ELSIF v_month = 'june' THEN
    v_start := coalesce(v_win.june_window_start, v_win.preseason_start);
    v_end := least(
      coalesce(v_win.june_window_end, v_win.preseason_start + ((v_win.august_start - v_win.preseason_start) / 2.0)),
      v_now + interval '1 second'
    );
  ELSE
    RETURN;
  END IF;

  IF v_draft IS NOT NULL AND v_draft < v_start THEN
    v_start := date_trunc('day', v_draft);
  END IF;

  IF v_end IS NULL OR v_start IS NULL OR v_end <= v_start THEN
    v_start := coalesce(v_win.preseason_start, v_win.august_start - interval '8 weeks');
    v_end := least(v_win.august_start, v_now + interval '1 second');
  END IF;

  IF v_end <= v_start THEN
    v_start := v_now - interval '90 days';
    v_end := v_now + interval '1 second';
  END IF;

  window_start := v_start;
  window_end := v_end;
  RETURN NEXT;
END;
$function$;

CREATE OR REPLACE FUNCTION public.gpsl_sport_generate_preseason_edition(
  p_season_id bigint,
  p_gpsl_month text
)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_existing bigint;
  v_month text := lower(btrim(p_gpsl_month));
  v_month_label text;
  v_win record;
  v_bounds record;
  v_built jsonb;
  v_seed text;
BEGIN
  IF v_month NOT IN ('june', 'july') THEN
    RETURN NULL;
  END IF;

  SELECT e.id INTO v_existing
  FROM public.gpsl_sport_editions e
  WHERE e.season_id = p_season_id AND e.gpsl_month = v_month;

  IF v_existing IS NOT NULL THEN
    RETURN v_existing;
  END IF;

  SELECT * INTO v_win
  FROM public.gpsl_sport_preseason_window(p_season_id);

  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  IF v_month = 'june' AND NOT coalesce(v_win.include_june, false) THEN
    RETURN NULL;
  END IF;

  SELECT * INTO v_bounds
  FROM public.gpsl_sport_preseason_data_bounds(p_season_id, v_month);

  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  v_month_label := public.gpsl_sport_month_label(v_month);
  v_seed := p_season_id::text || ':' || v_month || ':preseason';

  v_built := public.gpsl_sport_build_transfer_edition(
    v_seed,
    v_month_label,
    v_bounds.window_start,
    v_bounds.window_end,
    true
  );

  INSERT INTO public.gpsl_sport_editions (
    season_id, gpsl_month, edition_label, story_type, front_page, back_page, detail
  )
  VALUES (
    p_season_id,
    v_month,
    v_month_label,
    v_built->>'story_type',
    v_built->'front_page',
    coalesce(v_built->'back_page', '{}'::jsonb),
    jsonb_build_object(
      'generated_at', now(),
      'preseason', true,
      'preseason_weeks', v_win.preseason_weeks,
      'data_window_start', v_bounds.window_start,
      'data_window_end', v_bounds.window_end,
      'august_start', v_win.august_start,
      'managers_page', coalesce(v_built->'managers_page', '{}'::jsonb),
      'owners_page', coalesce(v_built->'owners_page', '{}'::jsonb)
    )
  )
  RETURNING id INTO v_existing;

  RETURN v_existing;
END;
$function$;

-- Prefer chronologically latest edition (July > June > May …) in nav
CREATE OR REPLACE FUNCTION public.gpsl_sport_nav_state()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_edition public.gpsl_sport_editions;
  v_unread boolean := false;
BEGIN
  IF v_uid IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_authenticated');
  END IF;

  SELECT e.* INTO v_edition
  FROM public.gpsl_sport_editions e
  JOIN public.competition_seasons s ON s.id = e.season_id AND s.is_current = true
  ORDER BY public.gpsl_sport_edition_sort_key(e.gpsl_month) DESC NULLS LAST,
           e.published_at DESC
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', true, 'has_edition', false);
  END IF;

  SELECT NOT EXISTS (
    SELECT 1 FROM public.gpsl_sport_reads r
    WHERE r.owner_id = v_uid AND r.edition_id = v_edition.id
  ) INTO v_unread;

  RETURN jsonb_build_object(
    'ok', true,
    'has_edition', true,
    'edition_id', v_edition.id,
    'edition_label', v_edition.edition_label,
    'headline', v_edition.front_page->>'headline',
    'unread', v_unread
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.gpsl_sport_preseason_data_bounds(bigint, text) TO authenticated;

-- ---------------------------------------------------------------------------
-- After applying, regenerate (SQL Editor):
-- SELECT public.gpsl_sport_regenerate_edition(
--   (SELECT id FROM competition_seasons WHERE is_current = true LIMIT 1), 'july');
-- ---------------------------------------------------------------------------
