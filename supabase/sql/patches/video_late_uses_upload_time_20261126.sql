-- =============================================================================
-- V late uses the Discord upload time, not when the result was confirmed.
--
-- fixture_match_videos.matched_at is rewritten to now() when a held upload is
-- promoted after the GPSL result is confirmed. That made on-time posts look
-- late. The Discord message id is a snowflake: its timestamp is the upload.
-- Rows with no Discord id (admin / manual) fall back to created_at.
--
-- The deadline is match_video_due_lock_at: the lock of the month the fixture
-- was played in, or the fixture month when that is later (early holiday).
--
-- Depends on match_video_due_month_catchup_20261105.sql.
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
              public.match_video_due_lock_at(v.fixture_id) AS due_lock
          ) t
          WHERE v.season_id = v_season_id
            AND t.due_lock IS NOT NULL
            AND t.uploaded_at > t.due_lock
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
        clubs AS (
          SELECT club FROM late
          UNION
          SELECT club FROM failed
        )
        SELECT jsonb_object_agg(
          c.club,
          jsonb_build_object(
            'video_late_count', coalesce(l.video_late_count, 0),
            'video_failed_count', coalesce(f.video_failed_count, 0)
          )
        )
        FROM clubs c
        LEFT JOIN late l ON l.club = c.club
        LEFT JOIN failed f ON f.club = c.club
      ),
      '{}'::jsonb
    )
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.admin_match_video_owner_metrics(bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_match_video_owner_metrics(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_match_video_owner_metrics(bigint) TO service_role;

NOTIFY pgrst, 'reload schema';
