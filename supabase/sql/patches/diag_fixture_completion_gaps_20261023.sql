-- =============================================================================
-- DIAGNOSTIC: fixture completion / gaps — league + cups (repeatable)
-- =============================================================================
-- Read-only report RPCs for schedule, check-in, result, match video (matched +
-- Discord pending hold). Spot matches that should already have been played.
--
-- Apply once, then re-run the SELECT examples below any time.
-- Safe re-run.
--
-- League:
--   SELECT * FROM public.diag_league_fixture_gaps('superleague', 'october');
--   SELECT * FROM public.diag_league_fixture_gaps(NULL, 'october');  -- all divisions
--   SELECT gap, count(*) FROM public.diag_league_fixture_gaps('championship_a', 'october')
--     GROUP BY 1 ORDER BY 2 DESC;
--
-- Cups:
--   SELECT * FROM public.diag_cup_fixture_gaps();                    -- all cups, due only
--   SELECT * FROM public.diag_cup_fixture_gaps('league_cup', 'october');
--   SELECT cup_code, gap, count(*) FROM public.diag_cup_fixture_gaps()
--     GROUP BY 1, 2 ORDER BY 1, 3 DESC;
--
-- due_only (default true): KO past, month locked, or already played (video gaps).
-- Set false to see every fixture in the filter (including future KOs).
-- =============================================================================

CREATE OR REPLACE FUNCTION public.diag_league_fixture_gaps(
  p_division text DEFAULT NULL,
  p_gpsl_month text DEFAULT NULL,
  p_season_id bigint DEFAULT NULL,
  p_due_only boolean DEFAULT true
)
RETURNS TABLE (
  fixture_id bigint,
  season_id bigint,
  division text,
  matchday smallint,
  gpsl_month text,
  week_in_month smallint,
  matchup text,
  fixture_status text,
  score text,
  is_forfeit boolean,
  manual_black_box boolean,
  schedule_status text,
  ko timestamptz,
  home_checked_in boolean,
  away_checked_in boolean,
  both_checked_in boolean,
  submission_status text,
  pending_by_club text,
  home_video boolean,
  away_video boolean,
  home_video_pending boolean,
  away_video_pending boolean,
  both_videos boolean,
  should_have_played boolean,
  gap text,
  month_locked boolean,
  hours_since_ko int
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season bigint;
  v_month text;
  v_div text := nullif(lower(btrim(coalesce(p_division, ''))), '');
BEGIN
  v_season := coalesce(
    p_season_id,
    (
      SELECT s.id
      FROM public.competition_seasons s
      WHERE s.is_current = true
      ORDER BY s.id DESC
      LIMIT 1
    )
  );

  v_month := nullif(lower(btrim(coalesce(p_gpsl_month, ''))), '');
  IF v_month IS NULL THEN
    SELECT lower(btrim(m.gpsl_month)) INTO v_month
    FROM public.competition_season_calendar m
    WHERE m.season_id = v_season
      AND m.unlock_at <= now()
      AND m.lock_at > now()
    ORDER BY m.unlock_at DESC
    LIMIT 1;
  END IF;

  RETURN QUERY
  WITH base AS (
    SELECT
      f.id AS fixture_id,
      f.season_id,
      f.division,
      f.matchday,
      lower(btrim(f.gpsl_month)) AS gpsl_month,
      f.week_in_month,
      f.home_club_short_name AS home,
      f.away_club_short_name AS away,
      f.status AS fixture_status,
      f.home_goals,
      f.away_goals,
      coalesce(f.is_forfeit, false) AS is_forfeit,
      coalesce(s.status, 'unscheduled') AS schedule_status,
      s.agreed_kickoff_at AS ko,
      EXISTS (
        SELECT 1 FROM public.competition_fixture_checkin c
        WHERE c.fixture_id = f.id AND c.club_short_name = f.home_club_short_name
      ) AS home_checked_in,
      EXISTS (
        SELECT 1 FROM public.competition_fixture_checkin c
        WHERE c.fixture_id = f.id AND c.club_short_name = f.away_club_short_name
      ) AS away_checked_in,
      (
        SELECT rs.status
        FROM public.competition_result_submissions rs
        WHERE rs.fixture_id = f.id
        ORDER BY
          CASE rs.status WHEN 'pending' THEN 0 WHEN 'confirmed' THEN 1 ELSE 2 END,
          rs.submitted_at DESC
        LIMIT 1
      ) AS submission_status,
      (
        SELECT rs.submitted_by_club
        FROM public.competition_result_submissions rs
        WHERE rs.fixture_id = f.id AND rs.status = 'pending'
        ORDER BY rs.submitted_at DESC
        LIMIT 1
      ) AS pending_by_club,
      EXISTS (
        SELECT 1 FROM public.fixture_match_videos v
        WHERE v.fixture_id = f.id AND v.side = 'home'
      ) AS home_video,
      EXISTS (
        SELECT 1 FROM public.fixture_match_videos v
        WHERE v.fixture_id = f.id AND v.side = 'away'
      ) AS away_video,
      EXISTS (
        SELECT 1 FROM public.fixture_match_video_pending pv
        WHERE pv.fixture_id = f.id AND pv.side = 'home'
      ) AS home_video_pending,
      EXISTS (
        SELECT 1 FROM public.fixture_match_video_pending pv
        WHERE pv.fixture_id = f.id AND pv.side = 'away'
      ) AS away_video_pending,
      CASE
        WHEN to_regprocedure('public.fixture_is_manual_black_box(bigint)') IS NOT NULL
          THEN public.fixture_is_manual_black_box(f.id)
        ELSE false
      END AS manual_black_box,
      (cal.lock_at IS NOT NULL AND cal.lock_at <= now()) AS month_locked
    FROM public.competition_fixtures f
    LEFT JOIN public.competition_fixture_schedule s ON s.fixture_id = f.id
    LEFT JOIN public.competition_season_calendar cal
      ON cal.season_id = f.season_id
     AND lower(btrim(cal.gpsl_month)) = lower(btrim(f.gpsl_month))
    WHERE f.season_id = v_season
      AND coalesce(f.competition_type, 'league') = 'league'
      AND (v_div IS NULL OR lower(btrim(f.division)) = v_div)
      AND (v_month IS NULL OR lower(btrim(f.gpsl_month)) = v_month)
  ),
  enriched AS (
    SELECT
      b.*,
      (b.home_checked_in AND b.away_checked_in) AS both_checked_in,
      (b.home_video AND b.away_video) AS both_videos,
      (
        b.fixture_status = 'played'
        OR (b.ko IS NOT NULL AND b.ko < now())
        OR b.month_locked
      ) AS should_have_played,
      CASE
        WHEN b.fixture_status = 'cancelled' THEN 'cancelled'
        WHEN b.fixture_status = 'played' AND b.home_video AND b.away_video THEN 'complete'
        WHEN b.fixture_status = 'played'
             AND (b.home_video OR b.away_video OR b.home_video_pending OR b.away_video_pending)
          THEN 'played_missing_video'
        WHEN b.fixture_status = 'played' THEN 'played_no_video'
        WHEN b.submission_status = 'pending' THEN 'result_pending_confirm'
        WHEN b.ko IS NOT NULL AND b.ko < now()
             AND NOT (b.home_checked_in AND b.away_checked_in)
             AND NOT b.manual_black_box THEN 'ko_passed_missing_checkin'
        WHEN b.ko IS NOT NULL AND b.ko < now() THEN 'ko_passed_no_result'
        WHEN b.month_locked AND b.schedule_status <> 'agreed' THEN 'month_locked_unscheduled'
        WHEN b.month_locked THEN 'month_locked_no_result'
        WHEN b.schedule_status <> 'agreed' OR b.ko IS NULL THEN 'not_agreed'
        WHEN b.ko IS NOT NULL AND b.ko >= now() THEN 'scheduled_future'
        ELSE 'other'
      END AS gap
    FROM base b
  )
  SELECT
    e.fixture_id,
    e.season_id,
    e.division,
    e.matchday,
    e.gpsl_month,
    e.week_in_month,
    (e.home || ' vs ' || e.away)::text,
    e.fixture_status,
    CASE
      WHEN e.fixture_status = 'played'
        THEN (e.home_goals::text || '-' || e.away_goals::text)
      ELSE NULL
    END,
    e.is_forfeit,
    e.manual_black_box,
    e.schedule_status,
    e.ko,
    e.home_checked_in,
    e.away_checked_in,
    e.both_checked_in,
    e.submission_status,
    e.pending_by_club,
    e.home_video,
    e.away_video,
    e.home_video_pending,
    e.away_video_pending,
    e.both_videos,
    e.should_have_played,
    e.gap,
    e.month_locked,
    CASE
      WHEN e.ko IS NOT NULL AND e.ko < now()
        THEN floor(extract(epoch FROM (now() - e.ko)) / 3600.0)::int
      ELSE NULL
    END
  FROM enriched e
  WHERE (
    NOT coalesce(p_due_only, true)
    OR e.should_have_played
    OR e.gap IN ('month_locked_unscheduled', 'month_locked_no_result', 'not_agreed')
  )
  ORDER BY
    CASE e.gap
      WHEN 'ko_passed_no_result' THEN 0
      WHEN 'ko_passed_missing_checkin' THEN 1
      WHEN 'result_pending_confirm' THEN 2
      WHEN 'played_no_video' THEN 3
      WHEN 'played_missing_video' THEN 4
      WHEN 'month_locked_no_result' THEN 5
      WHEN 'month_locked_unscheduled' THEN 6
      WHEN 'not_agreed' THEN 7
      WHEN 'complete' THEN 8
      ELSE 9
    END,
    e.ko NULLS LAST,
    e.matchday,
    e.fixture_id;
END;
$function$;

CREATE OR REPLACE FUNCTION public.diag_cup_fixture_gaps(
  p_cup_code text DEFAULT NULL,
  p_gpsl_month text DEFAULT NULL,
  p_season_id bigint DEFAULT NULL,
  p_due_only boolean DEFAULT true
)
RETURNS TABLE (
  fixture_id bigint,
  season_id bigint,
  cup_code text,
  cup_label text,
  cup_round smallint,
  cup_leg smallint,
  gpsl_month text,
  matchup text,
  fixture_status text,
  score text,
  is_forfeit boolean,
  manual_black_box boolean,
  schedule_status text,
  ko timestamptz,
  home_checked_in boolean,
  away_checked_in boolean,
  both_checked_in boolean,
  submission_status text,
  pending_by_club text,
  home_video boolean,
  away_video boolean,
  home_video_pending boolean,
  away_video_pending boolean,
  both_videos boolean,
  should_have_played boolean,
  gap text,
  month_locked boolean,
  hours_since_ko int
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season bigint;
  v_month text := nullif(lower(btrim(coalesce(p_gpsl_month, ''))), '');
  v_cup text := nullif(lower(btrim(coalesce(p_cup_code, ''))), '');
BEGIN
  v_season := coalesce(
    p_season_id,
    (
      SELECT s.id
      FROM public.competition_seasons s
      WHERE s.is_current = true
      ORDER BY s.id DESC
      LIMIT 1
    )
  );

  RETURN QUERY
  WITH base AS (
    SELECT
      f.id AS fixture_id,
      f.season_id,
      f.cup_code,
      f.cup_round,
      coalesce(f.cup_leg, 1)::smallint AS cup_leg,
      lower(btrim(f.gpsl_month)) AS gpsl_month,
      f.home_club_short_name AS home,
      f.away_club_short_name AS away,
      f.status AS fixture_status,
      f.home_goals,
      f.away_goals,
      coalesce(f.is_forfeit, false) AS is_forfeit,
      coalesce(s.status, 'unscheduled') AS schedule_status,
      s.agreed_kickoff_at AS ko,
      EXISTS (
        SELECT 1 FROM public.competition_fixture_checkin c
        WHERE c.fixture_id = f.id AND c.club_short_name = f.home_club_short_name
      ) AS home_checked_in,
      EXISTS (
        SELECT 1 FROM public.competition_fixture_checkin c
        WHERE c.fixture_id = f.id AND c.club_short_name = f.away_club_short_name
      ) AS away_checked_in,
      (
        SELECT rs.status
        FROM public.competition_result_submissions rs
        WHERE rs.fixture_id = f.id
        ORDER BY
          CASE rs.status WHEN 'pending' THEN 0 WHEN 'confirmed' THEN 1 ELSE 2 END,
          rs.submitted_at DESC
        LIMIT 1
      ) AS submission_status,
      (
        SELECT rs.submitted_by_club
        FROM public.competition_result_submissions rs
        WHERE rs.fixture_id = f.id AND rs.status = 'pending'
        ORDER BY rs.submitted_at DESC
        LIMIT 1
      ) AS pending_by_club,
      EXISTS (
        SELECT 1 FROM public.fixture_match_videos v
        WHERE v.fixture_id = f.id AND v.side = 'home'
      ) AS home_video,
      EXISTS (
        SELECT 1 FROM public.fixture_match_videos v
        WHERE v.fixture_id = f.id AND v.side = 'away'
      ) AS away_video,
      EXISTS (
        SELECT 1 FROM public.fixture_match_video_pending pv
        WHERE pv.fixture_id = f.id AND pv.side = 'home'
      ) AS home_video_pending,
      EXISTS (
        SELECT 1 FROM public.fixture_match_video_pending pv
        WHERE pv.fixture_id = f.id AND pv.side = 'away'
      ) AS away_video_pending,
      CASE
        WHEN to_regprocedure('public.fixture_is_manual_black_box(bigint)') IS NOT NULL
          THEN public.fixture_is_manual_black_box(f.id)
        ELSE false
      END AS manual_black_box,
      (cal.lock_at IS NOT NULL AND cal.lock_at <= now()) AS month_locked,
      CASE
        WHEN to_regprocedure('public.competition_cup_fixture_label(public.competition_fixtures)') IS NOT NULL
          THEN public.competition_cup_fixture_label(f)
        ELSE coalesce(f.cup_code, 'cup') || ' R' || coalesce(f.cup_round::text, '?')
      END AS cup_label
    FROM public.competition_fixtures f
    LEFT JOIN public.competition_fixture_schedule s ON s.fixture_id = f.id
    LEFT JOIN public.competition_season_calendar cal
      ON cal.season_id = f.season_id
     AND lower(btrim(cal.gpsl_month)) = lower(btrim(f.gpsl_month))
    WHERE f.season_id = v_season
      AND coalesce(f.competition_type, 'league') = 'cup'
      AND (v_cup IS NULL OR lower(coalesce(f.cup_code, '')) = v_cup)
      AND (v_month IS NULL OR lower(btrim(f.gpsl_month)) = v_month)
  ),
  enriched AS (
    SELECT
      b.*,
      (b.home_checked_in AND b.away_checked_in) AS both_checked_in,
      (b.home_video AND b.away_video) AS both_videos,
      (
        b.fixture_status = 'played'
        OR (b.ko IS NOT NULL AND b.ko < now())
        OR b.month_locked
      ) AS should_have_played,
      CASE
        WHEN b.fixture_status = 'cancelled' THEN 'cancelled'
        WHEN b.fixture_status = 'played' AND b.home_video AND b.away_video THEN 'complete'
        WHEN b.fixture_status = 'played'
             AND (b.home_video OR b.away_video OR b.home_video_pending OR b.away_video_pending)
          THEN 'played_missing_video'
        WHEN b.fixture_status = 'played' THEN 'played_no_video'
        WHEN b.submission_status = 'pending' THEN 'result_pending_confirm'
        WHEN b.ko IS NOT NULL AND b.ko < now()
             AND NOT (b.home_checked_in AND b.away_checked_in)
             AND NOT b.manual_black_box THEN 'ko_passed_missing_checkin'
        WHEN b.ko IS NOT NULL AND b.ko < now() THEN 'ko_passed_no_result'
        WHEN b.month_locked AND b.schedule_status <> 'agreed' THEN 'month_locked_unscheduled'
        WHEN b.month_locked THEN 'month_locked_no_result'
        WHEN b.schedule_status <> 'agreed' OR b.ko IS NULL THEN 'not_agreed'
        WHEN b.ko IS NOT NULL AND b.ko >= now() THEN 'scheduled_future'
        ELSE 'other'
      END AS gap
    FROM base b
  )
  SELECT
    e.fixture_id,
    e.season_id,
    e.cup_code,
    e.cup_label,
    e.cup_round,
    e.cup_leg,
    e.gpsl_month,
    (e.home || ' vs ' || e.away)::text,
    e.fixture_status,
    CASE
      WHEN e.fixture_status = 'played'
        THEN (e.home_goals::text || '-' || e.away_goals::text)
      ELSE NULL
    END,
    e.is_forfeit,
    e.manual_black_box,
    e.schedule_status,
    e.ko,
    e.home_checked_in,
    e.away_checked_in,
    e.both_checked_in,
    e.submission_status,
    e.pending_by_club,
    e.home_video,
    e.away_video,
    e.home_video_pending,
    e.away_video_pending,
    e.both_videos,
    e.should_have_played,
    e.gap,
    e.month_locked,
    CASE
      WHEN e.ko IS NOT NULL AND e.ko < now()
        THEN floor(extract(epoch FROM (now() - e.ko)) / 3600.0)::int
      ELSE NULL
    END
  FROM enriched e
  WHERE (
    NOT coalesce(p_due_only, true)
    OR e.should_have_played
    OR e.gap IN ('month_locked_unscheduled', 'month_locked_no_result', 'not_agreed')
  )
  ORDER BY
    e.cup_code NULLS LAST,
    e.cup_round NULLS LAST,
    e.cup_leg,
    CASE e.gap
      WHEN 'ko_passed_no_result' THEN 0
      WHEN 'ko_passed_missing_checkin' THEN 1
      WHEN 'result_pending_confirm' THEN 2
      WHEN 'played_no_video' THEN 3
      WHEN 'played_missing_video' THEN 4
      WHEN 'month_locked_no_result' THEN 5
      WHEN 'month_locked_unscheduled' THEN 6
      WHEN 'not_agreed' THEN 7
      WHEN 'complete' THEN 8
      ELSE 9
    END,
    e.ko NULLS LAST,
    e.fixture_id;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.diag_league_fixture_gaps(text, text, bigint, boolean)
  TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.diag_cup_fixture_gaps(text, text, bigint, boolean)
  TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';

-- ---------------------------------------------------------------------------
-- Quick runs (uncomment / edit after apply)
-- ---------------------------------------------------------------------------
-- SELECT * FROM public.diag_league_fixture_gaps('superleague', 'october');
-- SELECT gap, count(*) AS n
-- FROM public.diag_league_fixture_gaps('superleague', 'october')
-- GROUP BY 1 ORDER BY n DESC;
--
-- SELECT * FROM public.diag_cup_fixture_gaps();
-- SELECT cup_code, gap, count(*) AS n
-- FROM public.diag_cup_fixture_gaps()
-- GROUP BY 1, 2 ORDER BY 1, n DESC;
--
-- Gaps only (hide complete):
-- SELECT * FROM public.diag_league_fixture_gaps('superleague', 'october')
-- WHERE gap <> 'complete';
-- SELECT * FROM public.diag_cup_fixture_gaps(NULL, 'october')
-- WHERE gap <> 'complete';
