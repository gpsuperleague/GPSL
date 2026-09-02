-- =============================================================================
-- Season owner board: unplayed fixtures under Activity
-- Extends admin_owner_last_logins() with per-club unplayed counts:
--   • previous GPSL month
--   • current GPSL month
--   • season total (all months, still not played)
--
-- Unplayed = fixture status not played/cancelled (league + cup + etc.).
-- Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.admin_owner_last_logins()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season_id bigint;
  v_cur text;
  v_prev text;
  v_cur_unlock timestamptz;
  v_cur_lock timestamptz;
  v_prev_unlock timestamptz;
  v_prev_lock timestamptz;
  v_cur_end timestamptz;
  v_prev_end timestamptz;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Not signed in';
  END IF;

  SELECT s.id INTO v_season_id
  FROM public.competition_seasons s
  WHERE s.is_current = true
    AND s.status IN ('active', 'preseason')
  ORDER BY CASE s.status WHEN 'active' THEN 0 ELSE 1 END, s.id DESC
  LIMIT 1;

  IF v_season_id IS NOT NULL THEN
    v_cur := public.competition_active_gpsl_month(v_season_id, now());

    IF v_cur IS NOT NULL THEN
      SELECT m.unlock_at, m.lock_at
      INTO v_cur_unlock, v_cur_lock
      FROM public.competition_season_calendar m
      WHERE m.season_id = v_season_id
        AND lower(btrim(m.gpsl_month)) = lower(btrim(v_cur))
      LIMIT 1;

      SELECT m.gpsl_month, m.unlock_at, m.lock_at
      INTO v_prev, v_prev_unlock, v_prev_lock
      FROM public.competition_season_calendar m
      WHERE m.season_id = v_season_id
        AND public.competition_gpsl_month_sort(m.gpsl_month)
          < public.competition_gpsl_month_sort(v_cur)
      ORDER BY public.competition_gpsl_month_sort(m.gpsl_month) DESC
      LIMIT 1;
    END IF;
  END IF;

  v_cur_end := now();
  v_prev_end := coalesce(v_prev_lock, v_cur_unlock, now());

  IF v_cur IS NOT NULL AND v_cur_unlock IS NULL THEN
    v_cur_unlock := now() - interval '45 days';
  END IF;

  RETURN jsonb_build_object(
    'current_gpsl_month', v_cur,
    'current_gpsl_month_label', public.competition_gpsl_month_label(v_cur),
    'previous_gpsl_month', v_prev,
    'previous_gpsl_month_label', public.competition_gpsl_month_label(v_prev),
    'season_id', v_season_id,
    'owners', coalesce(
      (
        WITH owner_ids AS (
          SELECT r.owner_id FROM public.gpsl_owner_registry r
          UNION
          SELECT cl.owner_id FROM public."Clubs" cl WHERE cl.owner_id IS NOT NULL
        ),
        event_counts AS (
          SELECT
            e.owner_id,
            count(*)::int AS total_n,
            count(*) FILTER (
              WHERE v_cur_unlock IS NOT NULL
                AND e.logged_in_at >= v_cur_unlock
                AND e.logged_in_at <= v_cur_end
            )::int AS cur_n,
            count(*) FILTER (
              WHERE v_prev_unlock IS NOT NULL
                AND e.logged_in_at >= v_prev_unlock
                AND e.logged_in_at < v_prev_end
            )::int AS prev_n,
            max(e.logged_in_at) AS last_event_at
          FROM public.owner_site_login_events e
          GROUP BY e.owner_id
        ),
        session_counts AS (
          SELECT
            s.user_id AS owner_id,
            count(*)::int AS total_n,
            count(*) FILTER (
              WHERE v_cur_unlock IS NOT NULL
                AND s.created_at >= v_cur_unlock
                AND s.created_at <= v_cur_end
            )::int AS cur_n,
            count(*) FILTER (
              WHERE v_prev_unlock IS NOT NULL
                AND s.created_at >= v_prev_unlock
                AND s.created_at < v_prev_end
            )::int AS prev_n
          FROM auth.sessions s
          GROUP BY s.user_id
        ),
        login_counts AS (
          SELECT
            o.owner_id,
            greatest(coalesce(ec.total_n, 0), coalesce(sc.total_n, 0)) AS logins_total,
            greatest(coalesce(ec.cur_n, 0), coalesce(sc.cur_n, 0)) AS logins_current_month,
            greatest(coalesce(ec.prev_n, 0), coalesce(sc.prev_n, 0)) AS logins_previous_month,
            ec.last_event_at
          FROM owner_ids o
          LEFT JOIN event_counts ec ON ec.owner_id = o.owner_id
          LEFT JOIN session_counts sc ON sc.owner_id = o.owner_id
        ),
        ticket_join AS (
          SELECT DISTINCT ON (t.discord_user_id)
            t.discord_user_id,
            t.discord_joined_at
          FROM public.discord_join_tickets t
          WHERE t.discord_user_id IS NOT NULL
            AND t.discord_joined_at IS NOT NULL
          ORDER BY t.discord_user_id, t.created_at DESC
        ),
        unplayed_sides AS (
          SELECT
            f.home_club_short_name AS club_short,
            lower(btrim(f.gpsl_month)) AS gpsl_month
          FROM public.competition_fixtures f
          WHERE v_season_id IS NOT NULL
            AND f.season_id = v_season_id
            AND coalesce(f.status, '') NOT IN ('played', 'cancelled')
            AND coalesce(f.home_club_short_name, '') <> ''
          UNION ALL
          SELECT
            f.away_club_short_name AS club_short,
            lower(btrim(f.gpsl_month)) AS gpsl_month
          FROM public.competition_fixtures f
          WHERE v_season_id IS NOT NULL
            AND f.season_id = v_season_id
            AND coalesce(f.status, '') NOT IN ('played', 'cancelled')
            AND coalesce(f.away_club_short_name, '') <> ''
        ),
        unplayed_counts AS (
          SELECT
            u.club_short,
            count(*) FILTER (
              WHERE v_cur IS NOT NULL
                AND u.gpsl_month = lower(btrim(v_cur))
            )::int AS unplayed_current_month,
            count(*) FILTER (
              WHERE v_prev IS NOT NULL
                AND u.gpsl_month = lower(btrim(v_prev))
            )::int AS unplayed_previous_month,
            count(*)::int AS unplayed_season
          FROM unplayed_sides u
          GROUP BY u.club_short
        )
        SELECT jsonb_agg(
          row_to_json(x)::jsonb
          ORDER BY x.sort_ts DESC NULLS LAST,
                   x.owner_tag ASC NULLS LAST,
                   x.club_short_name ASC NULLS LAST
        )
        FROM (
          SELECT
            o.owner_id,
            public.owner_registry_resolve_tag(o.owner_id) AS owner_tag,
            coalesce(
              reg.status,
              CASE WHEN c.owner_id IS NOT NULL THEN 'active' ELSE 'member' END
            )::text AS registry_status,
            c."ShortName"::text AS club_short_name,
            c."Club"::text AS club_name,
            greatest(lc.last_event_at, u.last_sign_in_at) AS last_sign_in_at,
            u.created_at AS account_created_at,
            coalesce(reg.discord_joined_at, tj.discord_joined_at) AS discord_joined_at,
            CASE
              WHEN reg.discord_joined_at IS NOT NULL OR tj.discord_joined_at IS NOT NULL
                THEN 'discord'
              ELSE 'account'
            END AS discord_join_source,
            coalesce(greatest(lc.last_event_at, u.last_sign_in_at), u.created_at) AS sort_ts,
            coalesce(lc.logins_total, 0) AS logins_total,
            coalesce(lc.logins_current_month, 0) AS logins_current_month,
            coalesce(lc.logins_previous_month, 0) AS logins_previous_month,
            CASE
              WHEN c."ShortName" IS NULL THEN NULL
              ELSE coalesce(uc.unplayed_previous_month, 0)
            END AS unplayed_previous_month,
            CASE
              WHEN c."ShortName" IS NULL THEN NULL
              ELSE coalesce(uc.unplayed_current_month, 0)
            END AS unplayed_current_month,
            CASE
              WHEN c."ShortName" IS NULL THEN NULL
              ELSE coalesce(uc.unplayed_season, 0)
            END AS unplayed_season
          FROM owner_ids o
          JOIN auth.users u ON u.id = o.owner_id
          LEFT JOIN public."Clubs" c ON c.owner_id = o.owner_id
          LEFT JOIN public.gpsl_owner_registry reg ON reg.owner_id = o.owner_id
          LEFT JOIN ticket_join tj ON tj.discord_user_id = reg.discord_user_id
          LEFT JOIN login_counts lc ON lc.owner_id = o.owner_id
          LEFT JOIN unplayed_counts uc ON uc.club_short = c."ShortName"
          WHERE coalesce(reg.status, '') IS DISTINCT FROM 'archived'
        ) x
      ),
      '[]'::jsonb
    )
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.admin_owner_last_logins() TO authenticated;

NOTIFY pgrst, 'reload schema';
