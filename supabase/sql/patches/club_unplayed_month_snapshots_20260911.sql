-- =============================================================================
-- Club unplayed month snapshots (owner board / test-season activity)
--
-- Problem: after admin sims leftover fixtures, status becomes 'played' and the
-- live unplayed counts on the season owner board go to zero — so inactivity
-- history is lost.
--
-- Solution:
--   • Snapshot unplayed counts per club per GPSL month (first write wins)
--   • Soft-wire into month-lock jobs for the month being locked
--   • Admin RPC to record now / backfill closed months before you sim leftovers
--   • admin_owner_last_logins exposes unplayed_missed_total (running total)
--
-- Safe re-run.
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.club_unplayed_month_snapshots (
  season_id bigint NOT NULL
    REFERENCES public.competition_seasons (id) ON DELETE CASCADE,
  gpsl_month text NOT NULL,
  club_short_name text NOT NULL,
  owner_id uuid NULL,
  unplayed_count int NOT NULL DEFAULT 0
    CHECK (unplayed_count >= 0),
  fixture_ids jsonb NOT NULL DEFAULT '[]'::jsonb,
  snapped_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (season_id, gpsl_month, club_short_name)
);

CREATE INDEX IF NOT EXISTS club_unplayed_month_snapshots_owner_idx
  ON public.club_unplayed_month_snapshots (season_id, owner_id);

CREATE INDEX IF NOT EXISTS club_unplayed_month_snapshots_month_idx
  ON public.club_unplayed_month_snapshots (season_id, gpsl_month);

COMMENT ON TABLE public.club_unplayed_month_snapshots IS
  'Frozen unplayed fixture counts per club at month lock / admin record — survives later catch-up sims.';

ALTER TABLE public.club_unplayed_month_snapshots ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS club_unplayed_month_snapshots_admin_select
  ON public.club_unplayed_month_snapshots;
CREATE POLICY club_unplayed_month_snapshots_admin_select
  ON public.club_unplayed_month_snapshots
  FOR SELECT TO authenticated
  USING (public.is_gpsl_admin());

GRANT SELECT ON public.club_unplayed_month_snapshots TO authenticated;
GRANT ALL ON public.club_unplayed_month_snapshots TO service_role;

-- ---------------------------------------------------------------------------
-- Snapshot one GPSL month (first write wins unless p_force)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_snapshot_unplayed_gpsl_month(
  p_season_id bigint,
  p_gpsl_month text,
  p_force boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_month text := lower(btrim(coalesce(p_gpsl_month, '')));
  v_inserted int := 0;
  v_skipped int := 0;
  v_updated int := 0;
  v_clubs int := 0;
  v_total int := 0;
  r record;
BEGIN
  IF auth.uid() IS NOT NULL
     AND coalesce(auth.role(), '') IS DISTINCT FROM 'service_role'
     AND NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF p_season_id IS NULL THEN
    RAISE EXCEPTION 'season_id required';
  END IF;
  IF v_month = '' THEN
    RAISE EXCEPTION 'gpsl_month required';
  END IF;

  FOR r IN
    WITH month_clubs AS (
      SELECT DISTINCT x.club_short
      FROM (
        SELECT home_club_short_name AS club_short
        FROM public.competition_fixtures
        WHERE season_id = p_season_id
          AND lower(btrim(gpsl_month)) = v_month
          AND coalesce(home_club_short_name, '') <> ''
        UNION
        SELECT away_club_short_name
        FROM public.competition_fixtures
        WHERE season_id = p_season_id
          AND lower(btrim(gpsl_month)) = v_month
          AND coalesce(away_club_short_name, '') <> ''
      ) x
    ),
    sides AS (
      SELECT f.id AS fixture_id, f.home_club_short_name AS club_short
      FROM public.competition_fixtures f
      WHERE f.season_id = p_season_id
        AND lower(btrim(f.gpsl_month)) = v_month
        AND coalesce(f.status, '') NOT IN ('played', 'cancelled')
        AND coalesce(f.home_club_short_name, '') <> ''
      UNION ALL
      SELECT f.id, f.away_club_short_name
      FROM public.competition_fixtures f
      WHERE f.season_id = p_season_id
        AND lower(btrim(f.gpsl_month)) = v_month
        AND coalesce(f.status, '') NOT IN ('played', 'cancelled')
        AND coalesce(f.away_club_short_name, '') <> ''
    ),
    per_club AS (
      SELECT
        s.club_short,
        count(*)::int AS unplayed_count,
        coalesce(
          jsonb_agg(DISTINCT s.fixture_id ORDER BY s.fixture_id),
          '[]'::jsonb
        ) AS fixture_ids
      FROM sides s
      GROUP BY s.club_short
    )
    SELECT
      mc.club_short,
      coalesce(pc.unplayed_count, 0) AS unplayed_count,
      coalesce(pc.fixture_ids, '[]'::jsonb) AS fixture_ids,
      c.owner_id
    FROM month_clubs mc
    LEFT JOIN per_club pc ON pc.club_short = mc.club_short
    LEFT JOIN public."Clubs" c ON c."ShortName" = mc.club_short
  LOOP
    IF p_force THEN
      INSERT INTO public.club_unplayed_month_snapshots (
        season_id, gpsl_month, club_short_name, owner_id,
        unplayed_count, fixture_ids, snapped_at
      ) VALUES (
        p_season_id, v_month, r.club_short, r.owner_id,
        r.unplayed_count, r.fixture_ids, now()
      )
      ON CONFLICT (season_id, gpsl_month, club_short_name) DO UPDATE
        SET owner_id = EXCLUDED.owner_id,
            unplayed_count = EXCLUDED.unplayed_count,
            fixture_ids = EXCLUDED.fixture_ids,
            snapped_at = now();
      v_updated := v_updated + 1;
    ELSE
      INSERT INTO public.club_unplayed_month_snapshots (
        season_id, gpsl_month, club_short_name, owner_id,
        unplayed_count, fixture_ids, snapped_at
      ) VALUES (
        p_season_id, v_month, r.club_short, r.owner_id,
        r.unplayed_count, r.fixture_ids, now()
      )
      ON CONFLICT (season_id, gpsl_month, club_short_name) DO NOTHING;
      IF FOUND THEN
        v_inserted := v_inserted + 1;
      ELSE
        v_skipped := v_skipped + 1;
      END IF;
    END IF;
  END LOOP;

  SELECT count(*), coalesce(sum(unplayed_count), 0)
  INTO v_clubs, v_total
  FROM public.club_unplayed_month_snapshots
  WHERE season_id = p_season_id
    AND gpsl_month = v_month;

  RETURN jsonb_build_object(
    'ok', true,
    'season_id', p_season_id,
    'gpsl_month', v_month,
    'force', coalesce(p_force, false),
    'clubs', v_clubs,
    'unplayed_total_sides', v_total,
    'inserted', v_inserted,
    'updated', v_updated,
    'skipped_existing', v_skipped
  );
END;
$function$;

-- Record locked months (+ optional current) for current/active season
CREATE OR REPLACE FUNCTION public.admin_record_unplayed_snapshots(
  p_include_current_month boolean DEFAULT true,
  p_force boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season_id bigint;
  v_cur text;
  v_months text[] := ARRAY[]::text[];
  v_m text;
  v_results jsonb := '[]'::jsonb;
  v_one jsonb;
BEGIN
  IF auth.uid() IS NOT NULL
     AND coalesce(auth.role(), '') IS DISTINCT FROM 'service_role'
     AND NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  SELECT s.id INTO v_season_id
  FROM public.competition_seasons s
  WHERE s.is_current = true
    AND s.status IN ('active', 'preseason')
  ORDER BY CASE s.status WHEN 'active' THEN 0 ELSE 1 END, s.id DESC
  LIMIT 1;

  IF v_season_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'No current season');
  END IF;

  v_cur := public.competition_active_gpsl_month(v_season_id, now());

  SELECT coalesce(array_agg(lower(btrim(m.gpsl_month)) ORDER BY public.competition_gpsl_month_sort(m.gpsl_month)), ARRAY[]::text[])
  INTO v_months
  FROM public.competition_season_calendar m
  WHERE m.season_id = v_season_id
    AND (
      (m.lock_at IS NOT NULL AND m.lock_at <= now())
      OR (
        p_include_current_month
        AND v_cur IS NOT NULL
        AND lower(btrim(m.gpsl_month)) = lower(btrim(v_cur))
      )
    );

  FOREACH v_m IN ARRAY v_months
  LOOP
    v_one := public.admin_snapshot_unplayed_gpsl_month(v_season_id, v_m, p_force);
    v_results := v_results || jsonb_build_array(v_one);
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true,
    'season_id', v_season_id,
    'current_gpsl_month', v_cur,
    'months', to_jsonb(v_months),
    'results', v_results
  );
END;
$function$;

-- Called from month-lock jobs (service role / SECURITY DEFINER chain)
CREATE OR REPLACE FUNCTION public.club_unplayed_on_gpsl_month_lock(
  p_season_id bigint,
  p_gpsl_month text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF p_season_id IS NULL OR btrim(coalesce(p_gpsl_month, '')) = '' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'season_id and gpsl_month required');
  END IF;
  -- Freeze before any later catch-up sims; do not overwrite an earlier snap
  RETURN public.admin_snapshot_unplayed_gpsl_month(p_season_id, p_gpsl_month, false);
END;
$function$;

REVOKE ALL ON FUNCTION public.admin_snapshot_unplayed_gpsl_month(bigint, text, boolean) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.admin_record_unplayed_snapshots(boolean, boolean) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.club_unplayed_on_gpsl_month_lock(bigint, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_snapshot_unplayed_gpsl_month(bigint, text, boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_snapshot_unplayed_gpsl_month(bigint, text, boolean) TO service_role;
GRANT EXECUTE ON FUNCTION public.admin_record_unplayed_snapshots(boolean, boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_record_unplayed_snapshots(boolean, boolean) TO service_role;
GRANT EXECUTE ON FUNCTION public.club_unplayed_on_gpsl_month_lock(bigint, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.club_unplayed_on_gpsl_month_lock(bigint, text) TO service_role;

-- Soft-wire into month-lock jobs
DO $wire$
DECLARE
  v_def text;
  v_marker text := 'club_unplayed_on_gpsl_month_lock';
  v_old text := E'  RETURN v_out;\nEND;';
  v_new text;
BEGIN
  IF to_regprocedure('public.competition_run_month_lock_jobs(bigint,boolean,text,text)') IS NULL THEN
    RAISE NOTICE 'competition_run_month_lock_jobs(4-arg) missing — unplayed snapshot wire skipped';
    RETURN;
  END IF;

  SELECT pg_get_functiondef(
    'public.competition_run_month_lock_jobs(bigint,boolean,text,text)'::regprocedure
  ) INTO v_def;

  IF v_def IS NULL THEN
    RETURN;
  END IF;

  IF position(v_marker IN v_def) > 0 THEN
    RAISE NOTICE 'Unplayed snapshots already wired into month-lock jobs';
    RETURN;
  END IF;

  IF position(v_old IN v_def) = 0 THEN
    RAISE NOTICE 'Could not locate RETURN v_out in month-lock jobs — unplayed snapshot wire skipped';
    RETURN;
  END IF;

  v_new :=
    E'  -- Freeze unplayed counts for owner-board missed totals (before catch-up sims)\n'
    || E'  BEGIN\n'
    || E'    IF to_regprocedure(''public.club_unplayed_on_gpsl_month_lock(bigint,text)'') IS NOT NULL THEN\n'
    || E'      v_out := v_out || jsonb_build_object(\n'
    || E'        ''unplayed_snapshots'',\n'
    || E'        public.club_unplayed_on_gpsl_month_lock(p_season_id, v_month)\n'
    || E'      );\n'
    || E'    END IF;\n'
    || E'  EXCEPTION\n'
    || E'    WHEN OTHERS THEN\n'
    || E'      v_out := v_out || jsonb_build_object(\n'
    || E'        ''unplayed_snapshots'',\n'
    || E'        jsonb_build_object(''ok'', false, ''error'', SQLERRM)\n'
    || E'      );\n'
    || E'  END;\n'
    || E'\n'
    || E'  RETURN v_out;\n'
    || E'END;';

  EXECUTE 'CREATE OR REPLACE ' || replace(v_def, v_old, v_new);
  RAISE NOTICE 'Wired unplayed snapshots into competition_run_month_lock_jobs';
EXCEPTION
  WHEN OTHERS THEN
    RAISE NOTICE 'Unplayed snapshot month-lock wire failed (%); call admin_record_unplayed_snapshots manually', SQLERRM;
END;
$wire$;

-- ---------------------------------------------------------------------------
-- Extend owner board activity with missed running total
-- ---------------------------------------------------------------------------
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
  v_snap_months int := 0;
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

    SELECT count(DISTINCT gpsl_month)::int
    INTO v_snap_months
    FROM public.club_unplayed_month_snapshots
    WHERE season_id = v_season_id;
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
    'unplayed_snapshot_months', coalesce(v_snap_months, 0),
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
        ),
        missed_snap AS (
          SELECT
            s.club_short_name AS club_short,
            coalesce(sum(s.unplayed_count), 0)::int AS unplayed_missed_total,
            count(*)::int AS snap_month_count
          FROM public.club_unplayed_month_snapshots s
          WHERE v_season_id IS NOT NULL
            AND s.season_id = v_season_id
          GROUP BY s.club_short_name
        ),
        -- For closed months with no snapshot yet, best-effort live remainder
        closed_months AS (
          SELECT lower(btrim(m.gpsl_month)) AS gpsl_month
          FROM public.competition_season_calendar m
          WHERE v_season_id IS NOT NULL
            AND m.season_id = v_season_id
            AND m.lock_at IS NOT NULL
            AND m.lock_at <= now()
            AND (
              v_cur IS NULL
              OR lower(btrim(m.gpsl_month)) IS DISTINCT FROM lower(btrim(v_cur))
            )
        ),
        snapped_months AS (
          SELECT DISTINCT lower(btrim(s.gpsl_month)) AS gpsl_month
          FROM public.club_unplayed_month_snapshots s
          WHERE v_season_id IS NOT NULL
            AND s.season_id = v_season_id
        ),
        live_closed_missed AS (
          SELECT
            u.club_short,
            count(*)::int AS live_closed_unplayed
          FROM unplayed_sides u
          JOIN closed_months cm ON cm.gpsl_month = u.gpsl_month
          LEFT JOIN snapped_months sm ON sm.gpsl_month = u.gpsl_month
          WHERE sm.gpsl_month IS NULL
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
            END AS unplayed_season,
            CASE
              WHEN c."ShortName" IS NULL THEN NULL
              ELSE
                coalesce(ms.unplayed_missed_total, 0)
                + coalesce(lcm.live_closed_unplayed, 0)
                + CASE
                    WHEN v_cur IS NOT NULL
                      AND NOT EXISTS (
                        SELECT 1
                        FROM public.club_unplayed_month_snapshots s2
                        WHERE s2.season_id = v_season_id
                          AND s2.club_short_name = c."ShortName"
                          AND lower(btrim(s2.gpsl_month)) = lower(btrim(v_cur))
                      )
                    THEN coalesce(uc.unplayed_current_month, 0)
                    ELSE 0
                  END
            END AS unplayed_missed_total
          FROM owner_ids o
          JOIN auth.users u ON u.id = o.owner_id
          LEFT JOIN public."Clubs" c ON c.owner_id = o.owner_id
          LEFT JOIN public.gpsl_owner_registry reg ON reg.owner_id = o.owner_id
          LEFT JOIN ticket_join tj ON tj.discord_user_id = reg.discord_user_id
          LEFT JOIN login_counts lc ON lc.owner_id = o.owner_id
          LEFT JOIN unplayed_counts uc ON uc.club_short = c."ShortName"
          LEFT JOIN missed_snap ms ON ms.club_short = c."ShortName"
          LEFT JOIN live_closed_missed lcm ON lcm.club_short = c."ShortName"
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
