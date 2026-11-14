-- ACM 0-8 BAR, fixture 9053, October MD10.
-- The score is 8, the stat lines only add to 7, so the missing goal
-- shows as an own goal for Barcelona. It was Albert Guðmundsson,
-- assisted by Isco. The score stays 0-8.

UPDATE public.competition_match_player_stats
SET goals = goals + 1
WHERE fixture_id = 9053
  AND player_id = '116710'
  AND club_short_name = 'BAR'
  AND goals = 2;

UPDATE public.competition_match_player_stats
SET assists = assists + 1
WHERE fixture_id = 9053
  AND player_id = '42556'
  AND club_short_name = 'BAR'
  AND assists = 1;

UPDATE public.competition_result_submissions s
SET player_stats = (
  SELECT jsonb_agg(
    CASE
      WHEN e->>'player_id' = '116710' AND coalesce(e->>'goals', '0') = '2' THEN
        jsonb_set(e, '{goals}', to_jsonb(((e->>'goals')::int + 1)::text))
      WHEN e->>'player_id' = '42556' AND coalesce(e->>'assists', '0') = '1' THEN
        jsonb_set(e, '{assists}', to_jsonb(((e->>'assists')::int + 1)::text))
      ELSE e
    END
    ORDER BY ord
  )
  FROM jsonb_array_elements(s.player_stats) WITH ORDINALITY AS t(e, ord)
)
WHERE s.id = 186
  AND s.fixture_id = 9053
  AND s.status = 'confirmed';

SELECT jsonb_build_object(
  'gudmundsson', (
    SELECT jsonb_build_object('goals', goals, 'assists', assists)
    FROM public.competition_match_player_stats
    WHERE fixture_id = 9053 AND player_id = '116710'
  ),
  'isco', (
    SELECT jsonb_build_object('goals', goals, 'assists', assists)
    FROM public.competition_match_player_stats
    WHERE fixture_id = 9053 AND player_id = '42556'
  ),
  'bar_goals', (
    SELECT coalesce(sum(goals), 0)
    FROM public.competition_match_player_stats
    WHERE fixture_id = 9053 AND club_short_name = 'BAR'
  ),
  'bar_assists', (
    SELECT coalesce(sum(assists), 0)
    FROM public.competition_match_player_stats
    WHERE fixture_id = 9053 AND club_short_name = 'BAR'
  ),
  'score', (
    SELECT home_goals::text || '-' || away_goals::text
    FROM public.competition_fixtures WHERE id = 9053
  )
);
