-- =============================================================================
-- Suspension resync: keep pending bans on the nearest upcoming club fixtures
--
-- Fixes cases where a red card/yellow ban got pinned to odd far-future fixtures
-- because only a sparse set of matches was scheduled when the suspension was
-- first issued. Active suspensions are re-packed onto the next real club
-- fixtures after the source match.
--
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
      f.matchday,
      public.match_schedule_agreed_kickoff(f.id) AS kickoff_at
    FROM public.competition_fixtures f
    WHERE f.id = p_after_fixture_id
  ),
  upcoming AS (
    SELECT
      f.id,
      row_number() OVER (
        ORDER BY
          CASE
            WHEN to_regprocedure('public.match_schedule_agreed_kickoff(bigint)') IS NOT NULL
            THEN coalesce(
              public.match_schedule_agreed_kickoff(f.id),
              'infinity'::timestamptz
            )
            ELSE 'infinity'::timestamptz
          END,
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
        OR (
          s.kickoff_at IS NOT NULL
          AND (
            coalesce(public.match_schedule_agreed_kickoff(f.id), 'infinity'::timestamptz) > s.kickoff_at
            OR (
              coalesce(public.match_schedule_agreed_kickoff(f.id), 'infinity'::timestamptz) = s.kickoff_at
              AND f.id > s.id
            )
          )
        )
        OR (
          s.kickoff_at IS NULL
          AND (
            coalesce(f.matchday, 9999) > coalesce(s.matchday, -1)
            OR (
              coalesce(f.matchday, 9999) = coalesce(s.matchday, -1)
              AND f.id > s.id
            )
          )
        )
      )
  )
  SELECT u.id, u.seq
  FROM upcoming u
  WHERE u.seq <= greatest(p_limit, 1);
$function$;

CREATE OR REPLACE FUNCTION public.competition_resync_pending_suspensions(
  p_season_id bigint DEFAULT NULL,
  p_club text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_row record;
  v_fx record;
  v_done int := 0;
  v_season_id bigint := p_season_id;
  v_club text := nullif(btrim(coalesce(p_club, '')), '');
BEGIN
  IF v_season_id IS NULL THEN
    SELECT s.id
    INTO v_season_id
    FROM public.competition_seasons s
    WHERE coalesce(s.is_current, false) = true
       OR s.status = 'active'
    ORDER BY coalesce(s.is_current, false) DESC, s.id DESC
    LIMIT 1;
  END IF;

  IF v_season_id IS NULL THEN
    RETURN jsonb_build_object('ok', true, 'updated', 0, 'reason', 'no_active_season');
  END IF;

  FOR v_row IN
    SELECT s.id, s.season_id, s.club_short_name, s.source_fixture_id, s.ban_matches
    FROM public.competition_player_suspensions s
    WHERE s.status = 'active'
      AND s.season_id = v_season_id
      AND (v_club IS NULL OR s.club_short_name = v_club)
  LOOP
    DELETE FROM public.competition_player_suspension_matches sm
    WHERE sm.suspension_id = v_row.id
      AND sm.served = false;

    FOR v_fx IN
      SELECT *
      FROM public.competition_next_club_fixtures(
        v_row.season_id,
        v_row.club_short_name,
        v_row.source_fixture_id,
        v_row.ban_matches
      )
    LOOP
      INSERT INTO public.competition_player_suspension_matches (
        suspension_id, fixture_id, sequence_no, served
      )
      VALUES (v_row.id, v_fx.fixture_id, v_fx.seq, false)
      ON CONFLICT (suspension_id, fixture_id) DO NOTHING;
    END LOOP;

    UPDATE public.competition_player_suspensions s
    SET status = CASE
      WHEN EXISTS (
        SELECT 1
        FROM public.competition_player_suspension_matches sm
        WHERE sm.suspension_id = v_row.id
          AND sm.served = false
      ) THEN 'active'
      ELSE 'completed'
    END
    WHERE s.id = v_row.id;

    v_done := v_done + 1;
  END LOOP;

  RETURN jsonb_build_object('ok', true, 'updated', v_done);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_resync_pending_suspensions(bigint, text)
  TO authenticated, service_role;

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
  BEGIN
    PERFORM public.competition_resync_pending_suspensions(NULL, v_club);
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;

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

  BEGIN
    PERFORM public.competition_resync_pending_suspensions(v_fixture.season_id, v_fixture.home_club_short_name);
    PERFORM public.competition_resync_pending_suspensions(v_fixture.season_id, v_fixture.away_club_short_name);
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;

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
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_fixture public.competition_fixtures%rowtype;
  v_detail text;
BEGIN
  SELECT * INTO v_fixture
  FROM public.competition_fixtures
  WHERE id = p_fixture_id;

  IF FOUND THEN
    BEGIN
      PERFORM public.competition_resync_pending_suspensions(v_fixture.season_id, v_fixture.home_club_short_name);
      PERFORM public.competition_resync_pending_suspensions(v_fixture.season_id, v_fixture.away_club_short_name);
    EXCEPTION WHEN OTHERS THEN
      NULL;
    END;
  END IF;

  SELECT detail
  INTO v_detail
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

  RETURN v_detail;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_active_suspensions(text, text[]) TO authenticated;
GRANT EXECUTE ON FUNCTION public.competition_active_suspensions(text, text[]) TO anon;
GRANT EXECUTE ON FUNCTION public.competition_fixture_unavailable_players(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.competition_player_unavailable_for_fixture(bigint, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.competition_player_unavailable_for_fixture(bigint, text) TO anon;

NOTIFY pgrst, 'reload schema';
