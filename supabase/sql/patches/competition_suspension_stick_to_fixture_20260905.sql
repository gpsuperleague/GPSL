-- =============================================================================
-- Club suspensions stick to assigned fixture ids
--
-- Rule clarified:
-- - Issue bans against upcoming club fixture rows from the next GPSL month
-- - Do NOT require an agreed/scheduled kick-off
-- - Once assigned, pending ban rows stay on those fixture ids
-- - Player is simply unavailable for those fixtures
--
-- This patch:
--   1) keeps competition_next_club_fixtures month-based and fixture-based
--   2) removes automatic resync-on-read wrappers
--   3) performs one final repair now, then leaves assignments sticky
--
-- Run after competition_suspension_next_month_20260905.sql
-- Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.competition_next_club_fixtures(
  p_season_id bigint,
  p_club text,
  p_after_fixture_id bigint,
  p_limit int DEFAULT 2
)
RETURNS TABLE (fixture_id bigint, seq int)
LANGUAGE sql
STABLE
SET search_path = public
AS $function$
  WITH src AS (
    SELECT
      f.id,
      coalesce(public.competition_gpsl_month_sort(lower(coalesce(f.gpsl_month, ''))), 0) AS month_sort
    FROM public.competition_fixtures f
    WHERE f.id = p_after_fixture_id
  ),
  upcoming AS (
    SELECT
      f.id,
      row_number() OVER (
        ORDER BY
          coalesce(public.competition_gpsl_month_sort(lower(coalesce(f.gpsl_month, ''))), 99),
          coalesce(f.matchday, 9999),
          f.id
      )::int AS seq
    FROM public.competition_fixtures f
    LEFT JOIN src s ON true
    WHERE f.season_id = p_season_id
      AND f.status = 'scheduled'
      AND f.id IS DISTINCT FROM p_after_fixture_id
      AND (f.home_club_short_name = p_club OR f.away_club_short_name = p_club)
      AND (
        s.id IS NULL
        OR coalesce(public.competition_gpsl_month_sort(lower(coalesce(f.gpsl_month, ''))), 99) > coalesce(s.month_sort, 0)
      )
  )
  SELECT u.id, u.seq
  FROM upcoming u
  WHERE u.seq <= greatest(p_limit, 1);
$function$;

-- One last repair of current active suspensions onto the new rule
SELECT public.competition_resync_pending_suspensions(NULL, NULL);

-- After assignment, just read the stored fixture links; do not reshuffle on read.
CREATE OR REPLACE FUNCTION public.competition_active_suspensions(
  p_club text DEFAULT NULL,
  p_player_ids text[] DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := nullif(btrim(p_club), '');
BEGIN
  RETURN coalesce((
    SELECT jsonb_agg(row_to_json(x) ORDER BY x.player_id, x.suspension_id)
    FROM (
      SELECT
        s.id AS suspension_id,
        s.player_id,
        s.club_short_name,
        s.season_id,
        s.reason,
        s.yellow_count_at_issue,
        s.ban_matches,
        s.status,
        s.source_fixture_id,
        s.created_at,
        coalesce((
          SELECT jsonb_agg(
            jsonb_build_object(
              'fixture_id', sm.fixture_id,
              'sequence_no', sm.sequence_no,
              'served', sm.served,
              'label', public.competition_fixture_discipline_label(f, s.club_short_name),
              'matchday', f.matchday,
              'competition_type', f.competition_type
            )
            ORDER BY sm.sequence_no
          )
          FROM public.competition_player_suspension_matches sm
          JOIN public.competition_fixtures f ON f.id = sm.fixture_id
          WHERE sm.suspension_id = s.id
            AND sm.served = false
        ), '[]'::jsonb) AS pending_matches,
        (
          SELECT count(*)::int
          FROM public.competition_match_player_stats m
          WHERE m.season_id = s.season_id
            AND m.player_id = s.player_id
            AND m.yellow_card = true
        ) AS season_yellows,
        (
          SELECT count(*)::int
          FROM public.competition_match_player_stats m
          WHERE m.season_id = s.season_id
            AND m.player_id = s.player_id
            AND m.red_card = true
        ) AS season_reds,
        CASE
          WHEN to_regclass('public.competition_suspension_appeals') IS NULL THEN false
          ELSE EXISTS (
            SELECT 1
            FROM public.competition_suspension_appeals a
            WHERE a.suspension_id = s.id
              AND a.status = 'pending'
          )
        END AS appeal_pending
      FROM public.competition_player_suspensions s
      WHERE s.status = 'active'
        AND (v_club IS NULL OR s.club_short_name = v_club)
        AND (
          p_player_ids IS NULL
          OR cardinality(p_player_ids) = 0
          OR s.player_id = ANY (p_player_ids)
        )
        AND EXISTS (
          SELECT 1 FROM public.competition_player_suspension_matches sm
          WHERE sm.suspension_id = s.id AND sm.served = false
        )
    ) x
  ), '[]'::jsonb);
END;
$function$;

CREATE OR REPLACE FUNCTION public.competition_fixture_unavailable_players(
  p_fixture_id bigint
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_fixture public.competition_fixtures%rowtype;
  v_club text := public.my_club_shortname();
  v_home jsonb;
  v_away jsonb;
BEGIN
  SELECT * INTO v_fixture
  FROM public.competition_fixtures
  WHERE id = p_fixture_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Fixture not found';
  END IF;

  IF NOT public.is_gpsl_admin()
     AND current_user NOT IN ('postgres', 'supabase_admin', 'service_role')
     AND (
       v_club IS NULL
       OR v_club NOT IN (v_fixture.home_club_short_name, v_fixture.away_club_short_name)
     ) THEN
    RAISE EXCEPTION 'Only participating clubs can view unavailable players for this fixture';
  END IF;

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
      AND sm.served = false
      AND s.status = 'active'
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
      AND iff.served = false
      AND i.status = 'active'
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

CREATE OR REPLACE FUNCTION public.competition_player_unavailable_for_fixture(
  p_fixture_id bigint,
  p_player_id text
)
RETURNS text
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
  SELECT detail
  FROM (
    SELECT
      CASE
        WHEN s.reason = 'red_card' THEN 'Suspended — red card'
        WHEN s.reason = 'yellow_accumulation' THEN 'Suspended — yellow accumulation'
        ELSE 'Suspended'
      END AS detail,
      1 AS ord
    FROM public.competition_player_suspension_matches sm
    JOIN public.competition_player_suspensions s ON s.id = sm.suspension_id
    WHERE sm.fixture_id = p_fixture_id
      AND sm.served = false
      AND s.status = 'active'
      AND s.player_id = p_player_id

    UNION ALL

    SELECT
      CASE
        WHEN iff.phase = 'recovery' THEN
          format('Gaining match fitness — %s', coalesce(nullif(btrim(i.label), ''), 'Injury'))
        ELSE
          format('Injured — %s', coalesce(nullif(btrim(i.label), ''), 'Injured'))
      END AS detail,
      2 AS ord
    FROM public.competition_player_injury_fixtures iff
    JOIN public.competition_player_injuries i ON i.id = iff.injury_id
    WHERE iff.fixture_id = p_fixture_id
      AND iff.served = false
      AND i.status = 'active'
      AND i.player_id = p_player_id
  ) x
  ORDER BY ord
  LIMIT 1;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_active_suspensions(text, text[]) TO authenticated;
GRANT EXECUTE ON FUNCTION public.competition_active_suspensions(text, text[]) TO anon;
GRANT EXECUTE ON FUNCTION public.competition_fixture_unavailable_players(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.competition_player_unavailable_for_fixture(bigint, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.competition_player_unavailable_for_fixture(bigint, text) TO anon;

NOTIFY pgrst, 'reload schema';
