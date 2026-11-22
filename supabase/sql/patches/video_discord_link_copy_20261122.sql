-- Copy button posts a Discord media link, not a .mp4 name.
-- Owners replace PASTE_YOUR_LINK with their YouTube or MEGA url.
-- Safe re-run.

CREATE OR REPLACE FUNCTION public.matchday_checklist_video_filename(p_fixture_id bigint)
RETURNS text
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT format(
    '[%s %s-%s %s [%s-%s]](https://youtu.be/PASTE_YOUR_LINK)',
    upper(btrim(f.home_club_short_name)),
    coalesce(f.home_goals::text, 'H'),
    coalesce(f.away_goals::text, 'A'),
    upper(btrim(f.away_club_short_name)),
    CASE
      WHEN coalesce(f.competition_type, 'league') = 'cup' THEN
        CASE lower(coalesce(f.cup_code, ''))
          WHEN 'super8' THEN 'S8'
          WHEN 'plate' THEN 'PL'
          WHEN 'shield' THEN 'SH'
          WHEN 'bowl' THEN 'BO'
          WHEN 'league_cup' THEN 'LC'
          ELSE upper(coalesce(f.cup_code, 'CUP'))
        END
      ELSE
        CASE f.division
          WHEN 'superleague' THEN 'SL'
          WHEN 'championship_a' THEN 'CA'
          WHEN 'championship_b' THEN 'CB'
          ELSE 'SL'
        END
    END,
    CASE
      WHEN coalesce(f.competition_type, 'league') = 'cup'
        THEN 'R' || coalesce(f.cup_round::text, '?')
      ELSE 'MD' || coalesce(f.matchday::text, '?')
    END
  )
  FROM public.competition_fixtures f
  WHERE f.id = p_fixture_id;
$$;

SELECT public.matchday_checklist_video_filename(8996) AS soa_acm;
