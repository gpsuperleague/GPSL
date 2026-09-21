-- =============================================================================
-- Match report / fixture unavailable list
--
-- 1) Any authenticated user can read unavailable for a fixture (match centre).
-- 2) Fixture-scoped list includes served rows so played match reports still
--    show who was suspended / injured for that game.
--
-- Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.competition_fixture_unavailable_players(
  p_fixture_id bigint
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_fixture public.competition_fixtures%rowtype;
  v_home jsonb;
  v_away jsonb;
  v_played boolean := false;
BEGIN
  SELECT * INTO v_fixture
  FROM public.competition_fixtures
  WHERE id = p_fixture_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Fixture not found';
  END IF;

  -- Keep assignment fresh for upcoming fixtures; skip for played (historical).
  v_played := lower(coalesce(v_fixture.status, '')) IN ('played', 'completed', 'forfeit');

  IF NOT v_played
     AND to_regprocedure('public.competition_resync_pending_suspensions(bigint, text)') IS NOT NULL THEN
    PERFORM public.competition_resync_pending_suspensions(
      v_fixture.season_id, v_fixture.home_club_short_name
    );
    PERFORM public.competition_resync_pending_suspensions(
      v_fixture.season_id, v_fixture.away_club_short_name
    );
  END IF;

  -- Public match-centre info: any signed-in owner may read.
  -- (Previously restricted to participating clubs only.)

  WITH suspended AS (
    SELECT
      s.club_short_name,
      s.player_id,
      p."Name" AS player_name,
      p."Position" AS position,
      'suspended'::text AS reason,
      CASE
        WHEN s.reason = 'red_card' THEN 'Suspended — red card (2-match ban)'
        WHEN s.reason = 'yellow_accumulation' THEN
          format(
            'Suspended — %s yellows (2-match ban)',
            coalesce(s.yellow_count_at_issue, 8)
          )
        ELSE 'Suspended'
      END AS detail,
      s.id AS source_id
    FROM public.competition_player_suspension_matches sm
    JOIN public.competition_player_suspensions s ON s.id = sm.suspension_id
    LEFT JOIN public."Players" p ON p."Konami_ID"::text = s.player_id
    WHERE sm.fixture_id = p_fixture_id
      -- No served filter: link to this fixture is the historical record for match reports.
      AND (s.status = 'active' OR v_played)
  ),
  injured AS (
    SELECT
      i.club_short_name,
      i.player_id,
      p."Name" AS player_name,
      p."Position" AS position,
      CASE
        WHEN iff.phase = 'recovery' THEN 'recovery'
        ELSE 'injured'
      END AS reason,
      CASE
        WHEN iff.phase = 'recovery' THEN
          format('Gaining match fitness — %s', coalesce(i.label, 'Injury'))
        ELSE
          format('Injured — %s', coalesce(i.label, 'Injured'))
      END AS detail,
      i.id AS source_id
    FROM public.competition_player_injury_fixtures iff
    JOIN public.competition_player_injuries i ON i.id = iff.injury_id
    LEFT JOIN public."Players" p ON p."Konami_ID"::text = i.player_id
    WHERE iff.fixture_id = p_fixture_id
      AND (
        i.status = 'active'
        OR v_played
      )
  ),
  combined AS (
    SELECT * FROM suspended
    UNION ALL
    SELECT * FROM injured
  )
  SELECT
    coalesce((
      SELECT jsonb_agg(
        jsonb_build_object(
          'player_id', c.player_id,
          'player_name', coalesce(c.player_name, c.player_id),
          'position', c.position,
          'reason', c.reason,
          'detail', c.detail,
          'source_id', c.source_id
        )
        ORDER BY c.reason, c.player_name
      )
      FROM combined c
      WHERE c.club_short_name = v_fixture.home_club_short_name
    ), '[]'::jsonb),
    coalesce((
      SELECT jsonb_agg(
        jsonb_build_object(
          'player_id', c.player_id,
          'player_name', coalesce(c.player_name, c.player_id),
          'position', c.position,
          'reason', c.reason,
          'detail', c.detail,
          'source_id', c.source_id
        )
        ORDER BY c.reason, c.player_name
      )
      FROM combined c
      WHERE c.club_short_name = v_fixture.away_club_short_name
    ), '[]'::jsonb)
  INTO v_home, v_away;

  RETURN jsonb_build_object(
    'fixture_id', p_fixture_id,
    'home_club_short_name', v_fixture.home_club_short_name,
    'away_club_short_name', v_fixture.away_club_short_name,
    'home', coalesce(v_home, '[]'::jsonb),
    'away', coalesce(v_away, '[]'::jsonb)
  );
END;
$function$;

COMMENT ON FUNCTION public.competition_fixture_unavailable_players(bigint) IS
  'Suspended / injured / recovery players for a fixture. Readable by any authenticated user; includes served rows for played fixtures (match report).';

GRANT EXECUTE ON FUNCTION public.competition_fixture_unavailable_players(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.competition_fixture_unavailable_players(bigint) TO anon;

NOTIFY pgrst, 'reload schema';
