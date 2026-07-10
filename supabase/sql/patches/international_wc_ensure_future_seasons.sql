-- =============================================================================
-- WC future seasons: use status 'setup' (planned), not 'preseason'
--
-- 'preseason' means the league is in pre-season for that season row.
-- Placeholder Season 3 / 4 for WC binding should read as planned/setup.
--
-- Also re-tags existing non-current, never-started preseason rows that sit
-- after the latest real season as setup.
--
-- Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.international_admin_ensure_seasons_through(
  p_through_ordinal integer
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_have integer;
  v_need integer := greatest(coalesce(p_through_ordinal, 0), 0);
  v_next integer;
  v_label text;
  v_id bigint;
  v_created integer := 0;
  v_ids bigint[] := ARRAY[]::bigint[];
  v_retagged integer := 0;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF v_need < 1 THEN
    RAISE EXCEPTION 'through_ordinal must be >= 1';
  END IF;

  IF v_need > 40 THEN
    RAISE EXCEPTION 'Refusing to create more than 40 seasons at once';
  END IF;

  -- Fix earlier WC placeholders wrongly marked preseason
  WITH latest_real AS (
    SELECT coalesce(max(id), 0) AS id
    FROM public.competition_seasons
    WHERE is_current = true
       OR status IN ('active', 'complete', 'summer_break')
       OR started_at IS NOT NULL
  )
  UPDATE public.competition_seasons s
  SET status = 'setup'
  FROM latest_real r
  WHERE s.id > r.id
    AND s.is_current IS NOT TRUE
    AND s.status = 'preseason'
    AND s.started_at IS NULL;

  GET DIAGNOSTICS v_retagged = ROW_COUNT;

  SELECT count(*)::integer INTO v_have FROM public.competition_seasons;

  FOR v_next IN (v_have + 1)..v_need LOOP
    v_label := 'Season ' || v_next::text;
    IF EXISTS (SELECT 1 FROM public.competition_seasons WHERE label = v_label) THEN
      v_label := format('Season %s (planned)', v_next);
    END IF;

    -- Always setup for future placeholders (not preseason)
    INSERT INTO public.competition_seasons (label, status, is_current)
    VALUES (v_label, 'setup', false)
    RETURNING id INTO v_id;

    BEGIN
      INSERT INTO public.competition_club_seasons (season_id, club_short_name, division)
      SELECT v_id, c."ShortName", 'unassigned'
      FROM public."Clubs" c
      WHERE c."ShortName" <> 'FOREIGN'
      ORDER BY c."ShortName";
    EXCEPTION WHEN OTHERS THEN
      NULL;
    END;

    v_created := v_created + 1;
    v_ids := v_ids || v_id;
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true,
    'had', v_have,
    'through_ordinal', v_need,
    'created', v_created,
    'retagged_to_setup', v_retagged,
    'created_ids', to_jsonb(v_ids),
    'seasons', (
      SELECT coalesce(jsonb_agg(
        jsonb_build_object(
          'id', s.id,
          'label', s.label,
          'status', s.status,
          'is_current', s.is_current,
          'ordinal', s.ordinal
        )
        ORDER BY s.ordinal
      ), '[]'::jsonb)
      FROM (
        SELECT
          id,
          label,
          status,
          is_current,
          row_number() OVER (ORDER BY id) AS ordinal
        FROM public.competition_seasons
      ) s
    )
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.international_admin_ensure_seasons_through(integer) TO authenticated;

-- One-shot retag even without creating new seasons
DO $$
DECLARE
  v_n integer;
BEGIN
  IF NOT public.is_gpsl_admin() AND current_user NOT IN ('postgres', 'supabase_admin', 'service_role') THEN
    RAISE NOTICE 'Skip one-shot retag (not admin in this session)';
    RETURN;
  END IF;

  WITH latest_real AS (
    SELECT coalesce(max(id), 0) AS id
    FROM public.competition_seasons
    WHERE is_current = true
       OR status IN ('active', 'complete', 'summer_break')
       OR started_at IS NOT NULL
  )
  UPDATE public.competition_seasons s
  SET status = 'setup'
  FROM latest_real r
  WHERE s.id > r.id
    AND s.is_current IS NOT TRUE
    AND s.status = 'preseason'
    AND s.started_at IS NULL;

  GET DIAGNOSTICS v_n = ROW_COUNT;
  RAISE NOTICE 'Retagged % future season row(s) from preseason → setup', v_n;
EXCEPTION WHEN OTHERS THEN
  -- Constraint may still use old check without setup; ignore in editor if needed
  RAISE NOTICE 'Retag skipped: %', SQLERRM;
END $$;

NOTIFY pgrst, 'reload schema';
