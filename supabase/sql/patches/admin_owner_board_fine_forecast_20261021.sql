-- =============================================================================
-- Season owner board — month-lock fine forecast + season fine totals
--
-- admin_owner_board_fine_forecast():
--   by_club[SHORT] = {
--     month_lock_amount, month_lock_count, month_lock_detail,
--     season_total, season_count
--   }
--
-- Month-lock projection mirrors competition_enforce_scheduling_arrangement_fines
-- + response fines (as things stand before the next lock):
--   • Next-month home fixtures (play month = lock month + 1):
--       no home proposal yet → match_mgmt_no_proposal
--       first proposal in last 48h before that month’s unlock → match_late_arrangement
--   • Lock-month / earlier homes still with no proposal → recurring no_proposal
--   • Overdue reply after prior warning → match_response_deadline
--   • First overdue reply (no warning yet) → detail only (warn, £0)
-- Video failures stay on V fail.
--
-- Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.admin_owner_board_fine_forecast()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season bigint;
  v_lock_month text;
  v_lock_at timestamptz;
  v_lock_label text;
  v_lock_sort smallint;
  v_no_prop numeric := 2500000;
  v_late numeric := 1000000;
  v_response numeric := 2500000;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  SELECT id INTO v_season
  FROM public.competition_seasons
  WHERE is_current = true
  ORDER BY id DESC
  LIMIT 1;

  IF v_season IS NULL THEN
    RETURN jsonb_build_object(
      'ok', true,
      'season_id', NULL,
      'lock_month', NULL,
      'by_club', '{}'::jsonb
    );
  END IF;

  SELECT t.amount INTO v_no_prop
  FROM public.competition_fine_tariff t WHERE t.code = 'match_mgmt_no_proposal';
  SELECT t.amount INTO v_late
  FROM public.competition_fine_tariff t WHERE t.code = 'match_late_arrangement';
  SELECT t.amount INTO v_response
  FROM public.competition_fine_tariff t WHERE t.code = 'match_response_deadline';
  v_no_prop := coalesce(v_no_prop, 2500000);
  v_late := coalesce(v_late, 1000000);
  v_response := coalesce(v_response, 2500000);

  SELECT c.gpsl_month, c.lock_at
  INTO v_lock_month, v_lock_at
  FROM public.competition_season_calendar c
  WHERE c.season_id = v_season
    AND c.lock_at IS NOT NULL
    AND c.lock_at > now() - interval '1 hour'
  ORDER BY c.lock_at
  LIMIT 1;

  IF v_lock_month IS NOT NULL THEN
    v_lock_sort := public.competition_gpsl_month_sort(v_lock_month);
    BEGIN
      v_lock_label := public.competition_gpsl_month_label(v_lock_month);
    EXCEPTION WHEN OTHERS THEN
      v_lock_label := v_lock_month;
    END;
  END IF;

  RETURN (
    WITH season_tot AS (
      SELECT
        upper(btrim(a.club_short_name)) AS club,
        coalesce(sum(a.amount), 0) AS season_amt,
        count(*)::int AS season_n
      FROM public.competition_fine_applied a
      WHERE a.season_id = v_season
        AND NOT coalesce(a.waived, false)
        AND coalesce(a.amount, 0) > 0
        AND nullif(btrim(a.club_short_name), '') IS NOT NULL
      GROUP BY 1
    ),
    -- Same fixture set / tariffs as competition_enforce_scheduling_arrangement_fines
    arrangement_rows AS (
      SELECT
        upper(btrim(f.home_club_short_name)) AS club,
        CASE
          WHEN EXISTS (
            SELECT 1
            FROM public.competition_fixture_schedule s
            WHERE s.fixture_id = f.id
              AND s.status = 'agreed'
          ) THEN NULL
          WHEN to_regprocedure(
                 'public.match_schedule_club_on_holiday_for_month(bigint,text,text)'
               ) IS NOT NULL
            AND public.match_schedule_club_on_holiday_for_month(
                  v_season, f.home_club_short_name, v_lock_month
                )
            THEN NULL
          WHEN public.competition_gpsl_month_sort(f.gpsl_month) = v_lock_sort + 1 THEN
            CASE
              WHEN public.match_schedule_home_first_proposal_at(f.id, now()) IS NULL
                THEN 'match_mgmt_no_proposal'
              WHEN cal_play.unlock_at IS NOT NULL
                AND public.match_schedule_home_first_proposal_at(f.id, now())
                    >= cal_play.unlock_at - interval '48 hours'
                AND public.match_schedule_home_first_proposal_at(f.id, now())
                    < cal_play.unlock_at
                THEN 'match_late_arrangement'
              ELSE NULL
            END
          WHEN public.competition_gpsl_month_sort(f.gpsl_month) <= v_lock_sort
            AND public.match_schedule_home_first_proposal_at(f.id, now()) IS NULL
            THEN 'match_mgmt_no_proposal'
          ELSE NULL
        END AS tariff
      FROM public.competition_fixtures f
      JOIN public."Clubs" c ON c."ShortName" = f.home_club_short_name
      JOIN public.competition_season_calendar cal_play
        ON cal_play.season_id = f.season_id
       AND cal_play.gpsl_month = f.gpsl_month
      WHERE v_lock_month IS NOT NULL
        AND v_lock_sort IS NOT NULL
        AND f.season_id = v_season
        AND f.status = 'scheduled'
        AND coalesce(f.competition_type, 'league') IN ('league', 'cup')
        AND public.competition_gpsl_month_sort(f.gpsl_month) <= v_lock_sort + 1
        AND c.owner_id IS NOT NULL
    ),
    arrangement AS (
      SELECT
        club,
        count(*) FILTER (WHERE tariff = 'match_mgmt_no_proposal')::int AS n_none,
        count(*) FILTER (WHERE tariff = 'match_late_arrangement')::int AS n_late,
        (
          count(*) FILTER (WHERE tariff = 'match_mgmt_no_proposal')::numeric * v_no_prop
          + count(*) FILTER (WHERE tariff = 'match_late_arrangement')::numeric * v_late
        ) AS amt,
        nullif(
          concat_ws(
            ' · ',
            CASE
              WHEN count(*) FILTER (WHERE tariff = 'match_mgmt_no_proposal') > 0
                THEN format(
                  'no proposal×%s',
                  count(*) FILTER (WHERE tariff = 'match_mgmt_no_proposal')
                )
              ELSE NULL
            END,
            CASE
              WHEN count(*) FILTER (WHERE tariff = 'match_late_arrangement') > 0
                THEN format(
                  'late arrange×%s',
                  count(*) FILTER (WHERE tariff = 'match_late_arrangement')
                )
              ELSE NULL
            END
          ),
          ''
        ) AS detail
      FROM arrangement_rows
      WHERE tariff IS NOT NULL
      GROUP BY club
    ),
    reply_fine AS (
      SELECT
        upper(btrim(s.response_required_club_short_name)) AS club,
        count(*)::int AS n,
        count(*)::numeric * v_response AS amt,
        format('reply overdue×%s', count(*)) AS detail
      FROM public.competition_fixture_schedule s
      JOIN public.competition_fixtures f ON f.id = s.fixture_id
      JOIN public."Clubs" c ON c."ShortName" = s.response_required_club_short_name
      WHERE v_lock_month IS NOT NULL
        AND f.season_id = v_season
        AND f.status = 'scheduled'
        AND coalesce(f.competition_type, 'league') IN ('league', 'cup')
        AND s.status = 'negotiating'
        AND s.pending_proposal_id IS NOT NULL
        AND s.response_required_club_short_name IS NOT NULL
        AND s.response_due_at IS NOT NULL
        AND s.response_due_at < coalesce(v_lock_at, now())
        AND s.response_deadline_warned_at IS NOT NULL
        AND s.response_deadline_warned_at < coalesce(v_lock_at, now())
        AND (
          lower(btrim(f.gpsl_month)) = lower(btrim(v_lock_month))
          OR (
            to_regprocedure('public.match_schedule_fixture_is_catch_up(bigint)') IS NOT NULL
            AND public.match_schedule_fixture_is_catch_up(f.id)
          )
        )
        AND c.owner_id IS NOT NULL
        AND EXISTS (
          SELECT 1 FROM public.competition_fixture_schedule_proposal p
          WHERE p.id = s.pending_proposal_id AND p.status = 'pending'
        )
        AND (
          to_regprocedure('public.match_schedule_club_on_holiday_for_month(bigint,text,text)') IS NULL
          OR NOT public.match_schedule_club_on_holiday_for_month(
            v_season, s.response_required_club_short_name, v_lock_month
          )
        )
      GROUP BY 1
    ),
    reply_warn AS (
      SELECT
        upper(btrim(s.response_required_club_short_name)) AS club,
        format('reply warn×%s', count(*)) AS detail
      FROM public.competition_fixture_schedule s
      JOIN public.competition_fixtures f ON f.id = s.fixture_id
      JOIN public."Clubs" c ON c."ShortName" = s.response_required_club_short_name
      WHERE v_lock_month IS NOT NULL
        AND f.season_id = v_season
        AND f.status = 'scheduled'
        AND coalesce(f.competition_type, 'league') IN ('league', 'cup')
        AND s.status = 'negotiating'
        AND s.pending_proposal_id IS NOT NULL
        AND s.response_required_club_short_name IS NOT NULL
        AND s.response_due_at IS NOT NULL
        AND s.response_due_at < coalesce(v_lock_at, now())
        AND s.response_deadline_warned_at IS NULL
        AND (
          lower(btrim(f.gpsl_month)) = lower(btrim(v_lock_month))
          OR (
            to_regprocedure('public.match_schedule_fixture_is_catch_up(bigint)') IS NOT NULL
            AND public.match_schedule_fixture_is_catch_up(f.id)
          )
        )
        AND c.owner_id IS NOT NULL
        AND EXISTS (
          SELECT 1 FROM public.competition_fixture_schedule_proposal p
          WHERE p.id = s.pending_proposal_id AND p.status = 'pending'
        )
      GROUP BY 1
    ),
    clubs AS (
      SELECT club FROM season_tot
      UNION SELECT club FROM arrangement
      UNION SELECT club FROM reply_fine
      UNION SELECT club FROM reply_warn
    ),
    merged AS (
      SELECT
        c.club,
        coalesce(ar.amt, 0) + coalesce(rf.amt, 0) AS lock_amt,
        coalesce(ar.n_none, 0) + coalesce(ar.n_late, 0) + coalesce(rf.n, 0) AS lock_n,
        nullif(
          concat_ws(
            ' · ',
            nullif(ar.detail, ''),
            nullif(rf.detail, ''),
            nullif(rw.detail, '')
          ),
          ''
        ) AS detail,
        coalesce(st.season_amt, 0) AS season_amt,
        coalesce(st.season_n, 0) AS season_n
      FROM clubs c
      LEFT JOIN season_tot st ON st.club = c.club
      LEFT JOIN arrangement ar ON ar.club = c.club
      LEFT JOIN reply_fine rf ON rf.club = c.club
      LEFT JOIN reply_warn rw ON rw.club = c.club
    )
    SELECT jsonb_build_object(
      'ok', true,
      'season_id', v_season,
      'lock_month', v_lock_month,
      'lock_month_label', v_lock_label,
      'lock_at', v_lock_at,
      'by_club', coalesce(
        (
          SELECT jsonb_object_agg(
            m.club,
            jsonb_build_object(
              'month_lock_amount', m.lock_amt,
              'month_lock_count', m.lock_n,
              'month_lock_detail', m.detail,
              'season_total', m.season_amt,
              'season_count', m.season_n
            )
          )
          FROM merged m
          WHERE m.lock_amt > 0 OR m.lock_n > 0 OR m.season_amt > 0 OR m.detail IS NOT NULL
        ),
        '{}'::jsonb
      )
    )
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.admin_owner_board_fine_forecast() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_owner_board_fine_forecast() TO authenticated;

NOTIFY pgrst, 'reload schema';

SELECT public.admin_owner_board_fine_forecast() AS sample;
