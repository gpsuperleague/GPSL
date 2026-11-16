-- Admin-only "checked, no issues" mark on a match video side.
-- Owners can still report that side. The mark does not charge a fine.

CREATE TABLE IF NOT EXISTS public.match_video_admin_clear (
  fixture_id bigint NOT NULL REFERENCES public.competition_fixtures (id) ON DELETE CASCADE,
  side text NOT NULL,
  cleared_by uuid,
  cleared_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (fixture_id, side),
  CONSTRAINT match_video_admin_clear_side CHECK (side IN ('home', 'away'))
);

ALTER TABLE public.match_video_admin_clear ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.match_video_admin_clear FROM PUBLIC, anon, authenticated;
GRANT ALL ON public.match_video_admin_clear TO service_role;

CREATE OR REPLACE FUNCTION public.match_video_admin_cleared_sides(
  p_fixture_ids bigint[]
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_gpsl_admin() THEN
    RETURN '[]'::jsonb;
  END IF;
  IF p_fixture_ids IS NULL OR cardinality(p_fixture_ids) = 0 THEN
    RETURN '[]'::jsonb;
  END IF;

  RETURN coalesce((
    SELECT jsonb_agg(
      jsonb_build_object(
        'fixture_id', c.fixture_id,
        'side', c.side
      )
    )
    FROM public.match_video_admin_clear c
    WHERE c.fixture_id = ANY (p_fixture_ids)
  ), '[]'::jsonb);
END;
$function$;

REVOKE ALL ON FUNCTION public.match_video_admin_cleared_sides(bigint[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.match_video_admin_cleared_sides(bigint[]) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.match_video_admin_set_clear(
  p_fixture_id bigint,
  p_side text,
  p_cleared boolean
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_side text := lower(btrim(coalesce(p_side, '')));
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;
  IF p_fixture_id IS NULL OR v_side NOT IN ('home', 'away') THEN
    RAISE EXCEPTION 'fixture_id and side (home|away) required';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.competition_fixtures f WHERE f.id = p_fixture_id
  ) THEN
    RAISE EXCEPTION 'Fixture not found';
  END IF;

  IF coalesce(p_cleared, false) THEN
    INSERT INTO public.match_video_admin_clear (fixture_id, side, cleared_by, cleared_at)
    VALUES (p_fixture_id, v_side, auth.uid(), now())
    ON CONFLICT (fixture_id, side) DO UPDATE
      SET cleared_by = EXCLUDED.cleared_by,
          cleared_at = EXCLUDED.cleared_at;
  ELSE
    DELETE FROM public.match_video_admin_clear
    WHERE fixture_id = p_fixture_id
      AND side = v_side;
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'fixture_id', p_fixture_id,
    'side', v_side,
    'cleared', coalesce(p_cleared, false)
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.match_video_admin_set_clear(bigint, text, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.match_video_admin_set_clear(bigint, text, boolean) TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';

SELECT
  to_regclass('public.match_video_admin_clear') IS NOT NULL AS clear_table,
  to_regprocedure('public.match_video_admin_cleared_sides(bigint[])') IS NOT NULL AS list_fn,
  to_regprocedure('public.match_video_admin_set_clear(bigint,text,boolean)') IS NOT NULL AS set_fn;
