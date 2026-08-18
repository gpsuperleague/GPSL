-- =============================================================================
-- GPFL leaderboard: show owner name instead of club short name
-- Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.gpfl_leaderboard(p_limit int DEFAULT 60)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_gs_id bigint := public.gpfl_current_season_id();
  v_rows jsonb;
BEGIN
  IF v_gs_id IS NULL THEN
    RETURN jsonb_build_object('ok', true, 'rows', '[]'::jsonb);
  END IF;

  SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY r.rank), '[]'::jsonb)
  INTO v_rows
  FROM (
    SELECT
      row_number() OVER (ORDER BY e.total_points DESC, e.joined_at)::int AS rank,
      e.team_name,
      e.club_short_name,
      public.competition_owner_display_name(e.owner_id) AS owner_name,
      public.owner_registry_resolve_tag(e.owner_id) AS owner_tag,
      e.total_points,
      e.status,
      e.owner_id = auth.uid() AS is_me
    FROM public.gpfl_entries e
    WHERE e.gpfl_season_id = v_gs_id
      AND e.status IN ('active', 'building')
    ORDER BY e.total_points DESC, e.joined_at
    LIMIT greatest(1, least(coalesce(p_limit, 60), 200))
  ) r;

  RETURN jsonb_build_object('ok', true, 'gpfl_season_id', v_gs_id, 'rows', v_rows);
END;
$function$;

DROP VIEW IF EXISTS public.gpfl_leaderboard_public;
CREATE VIEW public.gpfl_leaderboard_public
WITH (security_invoker = true)
AS
SELECT
  e.gpfl_season_id,
  e.team_name,
  e.club_short_name,
  public.competition_owner_display_name(e.owner_id) AS owner_name,
  public.owner_registry_resolve_tag(e.owner_id) AS owner_tag,
  e.total_points,
  e.status
FROM public.gpfl_entries e
WHERE e.status IN ('active', 'building');

GRANT SELECT ON public.gpfl_leaderboard_public TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.gpfl_leaderboard(int) TO authenticated;

NOTIFY pgrst, 'reload schema';
