-- =============================================================================
-- V late uses the Discord upload time, not when the result was confirmed.
--
-- fixture_match_videos.matched_at is rewritten to now() when a held upload is
-- promoted after the GPSL result is confirmed. That made on-time posts look
-- late. The Discord message id is a snowflake: its timestamp is the upload.
-- Rows with no Discord id (admin / manual) fall back to created_at.
--
-- The deadline is match_video_due_at: that month's lock plus the video grace
-- (72 hours). The same instant is the result-entry / confirm cutoff.
--
-- R ent: this club had not entered a result when that cutoff passed.
-- R con: the other club had entered on time, and this club had not confirmed.
-- The extra 24 hours that closes a one-sided score is not part of either count.
--
-- match_result_deadline_tick uses match_video_due_at for that same instant.
--
-- Depends on match_video_due_month_catchup_20261105.sql
-- and match_result_deadline_20261109.sql.
-- Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.discord_snowflake_timestamptz(p_id text)
RETURNS timestamptz
LANGUAGE plpgsql
IMMUTABLE
AS $function$
DECLARE
  v_id bigint;
BEGIN
  IF p_id IS NULL OR btrim(p_id) !~ '^[0-9]{15,22}$' THEN
    RETURN NULL;
  END IF;

  v_id := btrim(p_id)::bigint;
  -- Discord epoch is 2015-01-01 UTC. The timestamp is the top 42 bits.
  RETURN to_timestamp(
    ((v_id >> 22) + 1420070400000)::double precision / 1000.0
  );
EXCEPTION
  WHEN OTHERS THEN
    RETURN NULL;
END;
$function$;

COMMENT ON FUNCTION public.discord_snowflake_timestamptz(text) IS
  'UTC time encoded in a Discord snowflake. NULL when the text is not a snowflake.';

REVOKE ALL ON FUNCTION public.discord_snowflake_timestamptz(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.discord_snowflake_timestamptz(text) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.admin_match_video_owner_metrics(
  p_season_id bigint DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season_id bigint := p_season_id;
BEGIN
  IF NOT public.is_gpsl_admin()
     AND coalesce(auth.role(), '') <> 'service_role' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'admin_only');
  END IF;

  IF v_season_id IS NULL THEN
    SELECT id INTO v_season_id
    FROM public.competition_seasons
    WHERE is_current = true
    ORDER BY id DESC
    LIMIT 1;
  END IF;

  IF v_season_id IS NULL THEN
    RETURN jsonb_build_object('ok', true, 'season_id', null, 'by_club', '{}'::jsonb);
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'season_id', v_season_id,
    'by_club', coalesce(
      (
        WITH late AS (
          SELECT
            upper(btrim(v.club_short_name)) AS club,
            count(*)::int AS video_late_count
          FROM public.fixture_match_videos v
          CROSS JOIN LATERAL (
            SELECT
              coalesce(
                public.discord_snowflake_timestamptz(v.discord_message_id),
                v.created_at
              ) AS uploaded_at,
              public.match_video_due_at(v.fixture_id) AS due_at
          ) t
          WHERE v.season_id = v_season_id
            AND t.due_at IS NOT NULL
            AND t.uploaded_at > t.due_at
          GROUP BY 1
        ),
        failed AS (
          SELECT
            upper(btrim(fail.club_short_name)) AS club,
            count(*)::int AS video_failed_count
          FROM public.fixture_match_video_failures fail
          WHERE fail.season_id = v_season_id
          GROUP BY 1
        ),
        result_scope AS (
          SELECT
            f.id AS fixture_id,
            upper(btrim(f.home_club_short_name)) AS home_club,
            upper(btrim(f.away_club_short_name)) AS away_club,
            public.match_video_due_at(f.id) AS due_at
          FROM public.competition_fixtures f
          WHERE f.season_id = v_season_id
            AND coalesce(f.competition_type, 'league') IN ('league', 'cup')
            AND coalesce(f.is_forfeit, false) = false
            AND nullif(btrim(f.home_club_short_name), '') IS NOT NULL
            AND nullif(btrim(f.away_club_short_name), '') IS NOT NULL
            AND public.match_video_play_at(f.id) IS NOT NULL
            AND public.match_video_play_at(f.id) <= now()
            AND public.match_video_due_at(f.id) IS NOT NULL
            AND public.match_video_due_at(f.id) <= now()
        ),
        result_sub AS (
          SELECT DISTINCT ON (s.fixture_id)
            s.fixture_id,
            upper(btrim(s.submitted_by_club)) AS entered_by,
            s.submitted_at,
            upper(btrim(s.responded_by_club)) AS responded_by,
            s.responded_at,
            s.status
          FROM public.competition_result_submissions s
          JOIN result_scope r ON r.fixture_id = s.fixture_id
          WHERE s.status IN ('pending', 'confirmed')
          ORDER BY s.fixture_id, s.id DESC
        ),
        result_sides AS (
          SELECT
            r.fixture_id,
            r.due_at,
            r.home_club AS club,
            r.away_club AS other_club,
            sub.entered_by,
            sub.submitted_at,
            sub.responded_by,
            sub.responded_at,
            sub.status
          FROM result_scope r
          LEFT JOIN result_sub sub ON sub.fixture_id = r.fixture_id
          UNION ALL
          SELECT
            r.fixture_id,
            r.due_at,
            r.away_club,
            r.home_club,
            sub.entered_by,
            sub.submitted_at,
            sub.responded_by,
            sub.responded_at,
            sub.status
          FROM result_scope r
          LEFT JOIN result_sub sub ON sub.fixture_id = r.fixture_id
        ),
        result_marks AS (
          SELECT
            s.club,
            CASE
              WHEN s.entered_by IS NOT NULL
               AND s.submitted_at <= s.due_at
              THEN 0
              ELSE 1
            END AS enter_late,
            CASE
              WHEN s.entered_by IS NOT NULL
               AND s.entered_by = s.other_club
               AND s.submitted_at <= s.due_at
               AND NOT (
                 s.status = 'confirmed'
                 AND s.responded_at IS NOT NULL
                 AND s.responded_at <= s.due_at
                 AND (s.responded_by IS NULL OR s.responded_by = s.club)
               )
              THEN 1
              ELSE 0
            END AS confirm_late
          FROM result_sides s
          WHERE nullif(s.club, '') IS NOT NULL
        ),
        results AS (
          SELECT
            club,
            sum(enter_late)::int AS result_enter_late_count,
            sum(confirm_late)::int AS result_confirm_late_count
          FROM result_marks
          GROUP BY club
        ),
        clubs AS (
          SELECT club FROM late
          UNION
          SELECT club FROM failed
          UNION
          SELECT club FROM results
        )
        SELECT jsonb_object_agg(
          c.club,
          jsonb_build_object(
            'video_late_count', coalesce(l.video_late_count, 0),
            'video_failed_count', coalesce(f.video_failed_count, 0),
            'result_enter_late_count', coalesce(r.result_enter_late_count, 0),
            'result_confirm_late_count', coalesce(r.result_confirm_late_count, 0)
          )
        )
        FROM clubs c
        LEFT JOIN late l ON l.club = c.club
        LEFT JOIN failed f ON f.club = c.club
        LEFT JOIN results r ON r.club = c.club
      ),
      '{}'::jsonb
    )
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.admin_match_video_owner_metrics(bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_match_video_owner_metrics(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_match_video_owner_metrics(bigint) TO service_role;

-- Result deadline uses the same cutoff as the video upload timer.
DO $result_cutoff$
DECLARE
  v_def text := pg_get_functiondef('public.match_result_deadline_tick()'::regprocedure);
  v_old text := 'v_remind_at := v_lock + make_interval(hours => v_grace);';
  v_new text := 'v_remind_at := public.match_video_due_at(v_r.id);';
BEGIN
  v_def := replace(v_def, E'\r\n', E'\n');
  IF position(v_new IN v_def) > 0 THEN
    RETURN;
  END IF;
  IF position(v_old IN v_def) = 0 THEN
    RAISE EXCEPTION 'result deadline cutoff assignment not found';
  END IF;
  EXECUTE replace(v_def, v_old, v_new);
END;
$result_cutoff$;

NOTIFY pgrst, 'reload schema';
