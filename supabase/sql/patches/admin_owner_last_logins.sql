-- =============================================================================
-- Admin: owner last login + login counts for current & previous GPSL month
-- Counts use auth.audit_log_entries (action login / mfa_code_login).
-- Requires Auth audit logs written to Postgres (Dashboard → Auth → Audit Logs).
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
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
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

  RETURN jsonb_build_object(
    'current_gpsl_month', v_cur,
    'current_gpsl_month_label', public.competition_gpsl_month_label(v_cur),
    'previous_gpsl_month', v_prev,
    'previous_gpsl_month_label', public.competition_gpsl_month_label(v_prev),
    'owners', coalesce(
      (
        WITH owner_ids AS (
          SELECT r.owner_id FROM public.gpsl_owner_registry r
          UNION
          SELECT cl.owner_id FROM public."Clubs" cl WHERE cl.owner_id IS NOT NULL
        ),
        login_counts AS (
          SELECT
            (a.payload->>'actor_id')::uuid AS owner_id,
            count(*) FILTER (
              WHERE v_cur_unlock IS NOT NULL
                AND a.created_at >= v_cur_unlock
                AND a.created_at < coalesce(v_cur_lock, 'infinity'::timestamptz)
            )::int AS logins_current_month,
            count(*) FILTER (
              WHERE v_prev_unlock IS NOT NULL
                AND a.created_at >= v_prev_unlock
                AND a.created_at < coalesce(v_prev_lock, 'infinity'::timestamptz)
            )::int AS logins_previous_month
          FROM auth.audit_log_entries a
          WHERE a.payload->>'action' IN ('login', 'mfa_code_login')
            AND a.payload->>'actor_id' IS NOT NULL
            AND (
              (v_prev_unlock IS NOT NULL AND a.created_at >= v_prev_unlock)
              OR (v_cur_unlock IS NOT NULL AND a.created_at >= v_cur_unlock)
            )
            AND a.created_at < coalesce(
              greatest(v_cur_lock, v_prev_lock),
              'infinity'::timestamptz
            )
          GROUP BY 1
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
            u.last_sign_in_at AS last_sign_in_at,
            u.created_at AS account_created_at,
            coalesce(u.last_sign_in_at, u.created_at) AS sort_ts,
            coalesce(lc.logins_current_month, 0) AS logins_current_month,
            coalesce(lc.logins_previous_month, 0) AS logins_previous_month
          FROM owner_ids o
          JOIN auth.users u ON u.id = o.owner_id
          LEFT JOIN public."Clubs" c ON c.owner_id = o.owner_id
          LEFT JOIN public.gpsl_owner_registry reg ON reg.owner_id = o.owner_id
          LEFT JOIN login_counts lc ON lc.owner_id = o.owner_id
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
