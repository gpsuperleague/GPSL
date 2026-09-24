-- =============================================================================
-- match_video_reported_sides — fixtures UI (report locks per side)
-- =============================================================================
-- Fixes: POST /rpc/match_video_reported_sides → 404 / schema cache miss
-- Requires: public.match_video_breach_reports (from match video patches).
-- Safe re-run. Apply in Supabase SQL Editor, then hard-refresh Fixtures.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.match_video_reported_sides(
  p_fixture_ids bigint[]
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF p_fixture_ids IS NULL OR cardinality(p_fixture_ids) = 0 THEN
    RETURN '[]'::jsonb;
  END IF;

  RETURN coalesce((
    SELECT jsonb_agg(
      jsonb_build_object(
        'fixture_id', r.fixture_id,
        'side', r.side,
        'status', r.status,
        'report_id', r.id
      )
    )
    FROM public.match_video_breach_reports r
    WHERE r.fixture_id = ANY (p_fixture_ids)
  ), '[]'::jsonb);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.match_video_reported_sides(bigint[]) TO authenticated;

NOTIFY pgrst, 'reload schema';
