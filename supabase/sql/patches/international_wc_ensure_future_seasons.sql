-- =============================================================================
-- World Cup: ensure future competition seasons exist for cycle planning
--
-- Creates lightweight Season N rows up to a given ordinal so admin can bind
-- WC qualifying / finals to seasons that have not started yet.
-- Does NOT run rollover or activate seasons.
--
-- Run once in Supabase SQL Editor. Safe re-run.
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
  v_status text := 'setup';
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

  -- Prefer preseason if the DB allows it (admin_season_lifecycle); else setup
  BEGIN
    INSERT INTO public.competition_seasons (label, status, is_current)
    VALUES ('__wc_status_probe__', 'preseason', false);
    DELETE FROM public.competition_seasons WHERE label = '__wc_status_probe__';
    v_status := 'preseason';
  EXCEPTION WHEN OTHERS THEN
    DELETE FROM public.competition_seasons WHERE label = '__wc_status_probe__';
    v_status := 'setup';
  END;

  SELECT count(*)::integer INTO v_have FROM public.competition_seasons;

  FOR v_next IN (v_have + 1)..v_need LOOP
    v_label := 'Season ' || v_next::text;
    IF EXISTS (SELECT 1 FROM public.competition_seasons WHERE label = v_label) THEN
      v_label := format('Season %s (planned)', v_next);
    END IF;

    INSERT INTO public.competition_seasons (label, status, is_current)
    VALUES (v_label, v_status, false)
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

NOTIFY pgrst, 'reload schema';
