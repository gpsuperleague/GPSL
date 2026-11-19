-- Net league points still deducted this season, for the table asterisk
-- and the boardroom performance rating. A later restore that brings the
-- club back to zero (or better) drops them out of this view.
-- Safe re-run.

CREATE OR REPLACE VIEW public.competition_points_deducted_public
WITH (security_invoker = false)
AS
SELECT
  a.season_id,
  a.club_short_name,
  (-sum(a.points_delta))::int AS pts_deducted
FROM public.competition_league_points_adjustments a
GROUP BY a.season_id, a.club_short_name
HAVING sum(a.points_delta) < 0;

GRANT SELECT ON public.competition_points_deducted_public TO authenticated;
GRANT SELECT ON public.competition_points_deducted_public TO anon;

SELECT club_short_name, pts_deducted
FROM public.competition_points_deducted_public
WHERE season_id = (
  SELECT id FROM public.competition_seasons
  WHERE is_current = true AND status = 'active'
  ORDER BY id DESC
  LIMIT 1
)
ORDER BY pts_deducted DESC, club_short_name;
