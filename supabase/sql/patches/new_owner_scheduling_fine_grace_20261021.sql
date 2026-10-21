-- =============================================================================
-- New-owner scheduling fine grace (next full GPSL month)
--
-- Newly appointed owners are not fined for arrangement / reply issues at locks
-- for months that were already underway when they took over.
--
-- Rule: if Clubs.owner_assigned_at > unlock_at of the closed GPSL month,
--       skip match_mgmt_no_proposal / match_late_arrangement / response
--       fines (and response warnings) for that club at that lock.
--
-- Example: appointed Wednesday before Thursday July lock → July lock pass;
--          liable from the August lock onward (first full month after appoint).
--
-- Also:
--   • Clubs.owner_assigned_at stamped on every owner change
--   • Season owner board F lock forecast respects the same grace
--   • ACM (Makxx) backfill if recently assigned without a timestamp
--
-- Safe re-run.
-- =============================================================================

ALTER TABLE public."Clubs"
  ADD COLUMN IF NOT EXISTS owner_assigned_at timestamptz;

COMMENT ON COLUMN public."Clubs".owner_assigned_at IS
  'When the current owner_id was assigned. Scheduling fines start after they have owned through a full GPSL month (exempt while assigned_at > closed month unlock_at).';

-- ---------------------------------------------------------------------------
-- Helper
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.club_scheduling_fines_in_new_owner_grace(
  p_season_id bigint,
  p_club_short_name text,
  p_closed_gpsl_month text
)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := upper(btrim(coalesce(p_club_short_name, '')));
  v_assigned timestamptz;
  v_unlock timestamptz;
BEGIN
  IF v_club = '' OR p_season_id IS NULL OR nullif(btrim(p_closed_gpsl_month), '') IS NULL THEN
    RETURN false;
  END IF;

  SELECT c.owner_assigned_at
  INTO v_assigned
  FROM public."Clubs" c
  WHERE c."ShortName" = v_club
     OR upper(c."ShortName") = v_club
  LIMIT 1;

  IF v_assigned IS NULL THEN
    RETURN false;
  END IF;

  SELECT cal.unlock_at
  INTO v_unlock
  FROM public.competition_season_calendar cal
  WHERE cal.season_id = p_season_id
    AND lower(btrim(cal.gpsl_month)) = lower(btrim(p_closed_gpsl_month))
  LIMIT 1;

  IF v_unlock IS NULL THEN
    RETURN false;
  END IF;

  -- Appointed after this GPSL month opened → no full month yet → grace
  RETURN v_assigned > v_unlock;
END;
$function$;

REVOKE ALL ON FUNCTION public.club_scheduling_fines_in_new_owner_grace(bigint, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.club_scheduling_fines_in_new_owner_grace(bigint, text, text)
  TO authenticated, service_role, anon;

COMMENT ON FUNCTION public.club_scheduling_fines_in_new_owner_grace(bigint, text, text) IS
  'True when the current owner was appointed after the closed GPSL month unlocked — skip scheduling fines at that lock.';

-- ---------------------------------------------------------------------------
-- Stamp owner_assigned_at on tenure mark + owner_id trigger
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.club_mark_new_owner_tenure(
  p_club_short text,
  p_season_id bigint DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text;
  v_season_id bigint := p_season_id;
BEGIN
  SELECT c."ShortName" INTO v_club
  FROM public."Clubs" c
  WHERE upper(c."ShortName") = upper(btrim(coalesce(p_club_short, '')))
  LIMIT 1;

  IF v_club IS NULL THEN
    RETURN;
  END IF;

  IF v_season_id IS NULL THEN
    SELECT id INTO v_season_id
    FROM public.competition_seasons
    WHERE is_current = true
    ORDER BY id DESC
    LIMIT 1;
  END IF;

  UPDATE public."Clubs" c
  SET owner_assigned_season_id = v_season_id,
      new_owner_releases_remaining = 3,
      owner_assigned_at = now()
  WHERE c."ShortName" = v_club;
END;
$function$;

CREATE OR REPLACE FUNCTION public.trg_clubs_owner_change_new_owner_tenure()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season_id bigint;
BEGIN
  IF NEW.owner_id IS NULL AND OLD.owner_id IS NOT NULL THEN
    NEW.owner_assigned_season_id := NULL;
    NEW.new_owner_releases_remaining := 0;
    NEW.owner_assigned_at := NULL;
    RETURN NEW;
  END IF;

  IF NEW.owner_id IS NOT NULL
    AND NEW.owner_id IS DISTINCT FROM OLD.owner_id THEN
    SELECT id INTO v_season_id
    FROM public.competition_seasons
    WHERE is_current = true
    ORDER BY id DESC
    LIMIT 1;

    NEW.owner_assigned_season_id := v_season_id;
    NEW.new_owner_releases_remaining := 3;
    NEW.owner_assigned_at := now();
  END IF;

  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS clubs_owner_change_new_owner_tenure ON public."Clubs";
CREATE TRIGGER clubs_owner_change_new_owner_tenure
  BEFORE UPDATE OF owner_id ON public."Clubs"
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_clubs_owner_change_new_owner_tenure();

-- ---------------------------------------------------------------------------
-- Arrangement fines — grace skip
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.competition_enforce_scheduling_arrangement_fines(
  p_season_id bigint,
  p_closed_gpsl_month text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_closed_sort smallint;
  v_closed_lock timestamptz;
  v_f record;
  v_first_at timestamptz;
  v_deadline timestamptz;
  v_is_arrangement_deadline boolean;
  v_tariff_code text;
  v_note_key text;
  v_note_body text;
  v_opponent text;
  v_apply jsonb;
  v_fined jsonb := '[]'::jsonb;
  v_skipped int := 0;
  v_holiday int := 0;
  v_grace int := 0;
  v_play_label text;
  v_closed_label text;
BEGIN
  v_closed_sort := public.competition_gpsl_month_sort(p_closed_gpsl_month);
  IF v_closed_sort IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_closed_month');
  END IF;

  SELECT c.lock_at INTO v_closed_lock
  FROM public.competition_season_calendar c
  WHERE c.season_id = p_season_id
    AND c.gpsl_month = p_closed_gpsl_month;

  IF v_closed_lock IS NULL OR v_closed_lock > now() THEN
    RETURN jsonb_build_object(
      'ok', false,
      'reason', 'month_not_closed',
      'closed_gpsl_month', p_closed_gpsl_month
    );
  END IF;

  v_closed_label := public.competition_gpsl_month_label(p_closed_gpsl_month);

  FOR v_f IN
    SELECT
      f.id,
      f.matchday,
      f.gpsl_month,
      f.home_club_short_name,
      f.away_club_short_name,
      public.competition_gpsl_month_sort(f.gpsl_month) AS play_sort,
      cal_play.unlock_at AS play_unlock_at
    FROM public.competition_fixtures f
    JOIN public.competition_season_calendar cal_play
      ON cal_play.season_id = f.season_id
     AND cal_play.gpsl_month = f.gpsl_month
    WHERE f.season_id = p_season_id
      AND f.competition_type IN ('league', 'cup')
      AND f.status = 'scheduled'
      AND public.competition_gpsl_month_sort(f.gpsl_month) <= v_closed_sort + 1
      AND EXISTS (
        SELECT 1 FROM public."Clubs" c
        WHERE c."ShortName" = f.home_club_short_name
          AND c.owner_id IS NOT NULL
      )
  LOOP
    IF EXISTS (
      SELECT 1 FROM public.competition_fixture_schedule s
      WHERE s.fixture_id = v_f.id AND s.status = 'agreed'
    ) THEN
      v_skipped := v_skipped + 1;
      CONTINUE;
    END IF;

    IF public.match_schedule_club_on_holiday_for_month(
      p_season_id, v_f.home_club_short_name, p_closed_gpsl_month
    ) THEN
      v_holiday := v_holiday + 1;
      CONTINUE;
    END IF;

    IF public.club_scheduling_fines_in_new_owner_grace(
      p_season_id, v_f.home_club_short_name, p_closed_gpsl_month
    ) THEN
      v_grace := v_grace + 1;
      CONTINUE;
    END IF;

    v_first_at := public.match_schedule_home_first_proposal_at(v_f.id, v_closed_lock);
    v_deadline := v_f.play_unlock_at;
    v_play_label := public.competition_gpsl_month_label(v_f.gpsl_month);

    v_is_arrangement_deadline := (v_f.play_sort = v_closed_sort + 1);

    v_tariff_code := NULL;

    IF v_is_arrangement_deadline THEN
      IF v_first_at IS NULL THEN
        v_tariff_code := 'match_mgmt_no_proposal';
      ELSIF v_deadline IS NOT NULL
        AND v_first_at >= v_deadline - interval '48 hours'
        AND v_first_at < v_deadline
      THEN
        v_tariff_code := 'match_late_arrangement';
      END IF;
    ELSIF v_closed_sort >= v_f.play_sort THEN
      IF v_first_at IS NULL THEN
        v_tariff_code := 'match_mgmt_no_proposal';
      END IF;
    END IF;

    IF v_tariff_code IS NULL THEN
      v_skipped := v_skipped + 1;
      CONTINUE;
    END IF;

    v_note_key := format(
      'sched_arrangement:%s:%s:%s',
      p_closed_gpsl_month, v_f.id, v_tariff_code
    );

    IF EXISTS (
      SELECT 1 FROM public.competition_fine_applied fa
      WHERE fa.fixture_id = v_f.id
        AND fa.tariff_code = v_tariff_code
        AND fa.note LIKE v_note_key || '%'
    ) THEN
      v_skipped := v_skipped + 1;
      CONTINUE;
    END IF;

    v_opponent := coalesce(
      public.club_display_name(v_f.away_club_short_name),
      v_f.away_club_short_name
    );

    v_note_body := format(
      '%s|GPSL %s closed · %s fixture · MD%s vs %s · %s',
      v_note_key,
      v_closed_label,
      v_play_label,
      v_f.matchday,
      v_opponent,
      CASE v_tariff_code
        WHEN 'match_late_arrangement' THEN 'Late arrangement (last 48h)'
        ELSE 'No home proposal'
      END
    );

    v_apply := public.competition_apply_club_fine_tariff(
      v_f.home_club_short_name,
      v_tariff_code,
      NULL,
      v_note_body,
      v_f.id,
      p_season_id
    );

    v_fined := v_fined || jsonb_build_array(
      jsonb_build_object(
        'fixture_id', v_f.id,
        'club', v_f.home_club_short_name,
        'tariff', v_tariff_code,
        'apply', v_apply
      )
    );
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true,
    'closed_gpsl_month', p_closed_gpsl_month,
    'fined', v_fined,
    'skipped', v_skipped,
    'holiday_suppressed', v_holiday,
    'new_owner_grace_suppressed', v_grace
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_enforce_scheduling_arrangement_fines(bigint, text)
  TO service_role;

-- ---------------------------------------------------------------------------
-- Response fines — grace skip (warnings + fines)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.competition_enforce_scheduling_response_fines(
  p_season_id bigint,
  p_closed_gpsl_month text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_row record;
  v_lock timestamptz;
  v_note_key text;
  v_note_body text;
  v_apply jsonb;
  v_fined jsonb := '[]'::jsonb;
  v_warned jsonb := '[]'::jsonb;
  v_count int := 0;
  v_warn_count int := 0;
  v_skipped int := 0;
  v_holiday int := 0;
  v_grace int := 0;
  v_side text;
  v_opponent text;
  v_reason text;
  v_href text;
  v_warn_body text;
BEGIN
  SELECT c.lock_at
  INTO v_lock
  FROM public.competition_season_calendar c
  WHERE c.season_id = p_season_id
    AND c.gpsl_month = p_closed_gpsl_month;

  IF v_lock IS NULL OR v_lock > now() THEN
    RETURN jsonb_build_object(
      'ok', false,
      'reason', 'month_not_closed',
      'closed_gpsl_month', p_closed_gpsl_month
    );
  END IF;

  FOR v_row IN
    SELECT
      s.fixture_id,
      s.pending_proposal_id,
      s.response_required_club_short_name,
      s.response_miss_count,
      s.response_due_at,
      s.response_deadline_warned_at,
      f.gpsl_month,
      f.matchday,
      f.home_club_short_name,
      f.away_club_short_name
    FROM public.competition_fixture_schedule s
    JOIN public.competition_fixtures f ON f.id = s.fixture_id
    WHERE f.season_id = p_season_id
      AND f.competition_type IN ('league', 'cup')
      AND f.status = 'scheduled'
      AND s.status = 'negotiating'
      AND s.pending_proposal_id IS NOT NULL
      AND s.response_required_club_short_name IS NOT NULL
      AND s.response_due_at IS NOT NULL
      AND s.response_due_at < v_lock
      AND (
        f.gpsl_month = p_closed_gpsl_month
        OR public.match_schedule_fixture_is_catch_up(f.id)
      )
      AND (
        to_regprocedure('public.match_schedule_fixture_within_play_window(bigint,timestamptz)') IS NULL
        OR public.match_schedule_fixture_within_play_window(f.id, v_lock)
      )
      AND EXISTS (
        SELECT 1
        FROM public.competition_fixture_schedule_proposal p
        WHERE p.id = s.pending_proposal_id
          AND p.status = 'pending'
      )
      AND EXISTS (
        SELECT 1
        FROM public."Clubs" c
        WHERE c."ShortName" = s.response_required_club_short_name
          AND c.owner_id IS NOT NULL
      )
  LOOP
    IF to_regprocedure('public.match_schedule_club_on_holiday_for_month(bigint,text,text)') IS NOT NULL
       AND public.match_schedule_club_on_holiday_for_month(
         p_season_id, v_row.response_required_club_short_name, p_closed_gpsl_month
       ) THEN
      v_holiday := v_holiday + 1;
      CONTINUE;
    END IF;

    IF public.club_scheduling_fines_in_new_owner_grace(
      p_season_id, v_row.response_required_club_short_name, p_closed_gpsl_month
    ) THEN
      v_grace := v_grace + 1;
      CONTINUE;
    END IF;

    v_href := 'fixture_schedule.html?fixture=' || v_row.fixture_id::text;

    IF v_row.response_deadline_warned_at IS NULL THEN
      v_note_key := format(
        'sched_response_warn:%s:%s',
        p_closed_gpsl_month,
        v_row.fixture_id
      );

      UPDATE public.competition_fixture_schedule
      SET
        response_deadline_warned_at = coalesce(response_deadline_warned_at, now()),
        updated_at = now()
      WHERE fixture_id = v_row.fixture_id;

      v_warn_body :=
        'Your scheduling reply was still overdue when '
        || public.competition_gpsl_month_label(p_closed_gpsl_month)
        || E' locked.\nThis is a warning only — no fine this lock. '
        || E'Reply on Schedule / Inbox. If you are still overdue at a later month lock, you will be fined ₿2.5m.';

      PERFORM public.owner_inbox_send(
        'match_response_deadline_warning',
        'Scheduling reply overdue — warning',
        v_warn_body,
        v_row.response_required_club_short_name,
        NULL,
        v_row.fixture_id,
        NULL, NULL, NULL,
        v_href,
        v_note_key || ':' || v_row.response_required_club_short_name,
        p_closed_gpsl_month,
        p_season_id,
        NULL
      );

      v_warn_count := v_warn_count + 1;
      v_warned := v_warned || jsonb_build_array(
        jsonb_build_object(
          'fixture_id', v_row.fixture_id,
          'club', v_row.response_required_club_short_name
        )
      );
      CONTINUE;
    END IF;

    IF v_row.response_deadline_warned_at >= v_lock THEN
      v_skipped := v_skipped + 1;
      CONTINUE;
    END IF;

    v_note_key := format(
      'sched_response_lock:%s:%s',
      p_closed_gpsl_month,
      v_row.fixture_id
    );

    IF EXISTS (
      SELECT 1
      FROM public.competition_fine_applied fa
      WHERE fa.fixture_id = v_row.fixture_id
        AND fa.tariff_code = 'match_response_deadline'
        AND fa.note LIKE v_note_key || '%'
    ) THEN
      v_skipped := v_skipped + 1;
      CONTINUE;
    END IF;

    IF upper(btrim(v_row.response_required_club_short_name))
         = upper(btrim(v_row.home_club_short_name)) THEN
      v_side := 'home';
      v_reason := 'home reply fail';
      v_opponent := coalesce(
        public.club_display_name(v_row.away_club_short_name),
        v_row.away_club_short_name
      );
    ELSE
      v_side := 'away';
      v_reason := 'Away reply fail';
      v_opponent := coalesce(
        public.club_display_name(v_row.home_club_short_name),
        v_row.home_club_short_name
      );
    END IF;

    v_note_body := format(
      '%s|%s · MD%s vs %s · after prior warning',
      v_note_key,
      v_reason,
      v_row.matchday,
      coalesce(v_opponent, '?')
    );

    v_apply := public.competition_apply_club_fine_tariff(
      v_row.response_required_club_short_name,
      'match_response_deadline',
      NULL,
      v_note_body,
      v_row.fixture_id,
      p_season_id
    );

    v_count := v_count + 1;
    v_fined := v_fined || jsonb_build_array(
      jsonb_build_object(
        'fixture_id', v_row.fixture_id,
        'club', v_row.response_required_club_short_name,
        'side', v_side,
        'apply', v_apply
      )
    );
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true,
    'closed_gpsl_month', p_closed_gpsl_month,
    'fines_applied', v_count,
    'warnings_sent', v_warn_count,
    'skipped', v_skipped,
    'holiday_suppressed', v_holiday,
    'new_owner_grace_suppressed', v_grace,
    'fined', v_fined,
    'warned', v_warned
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_enforce_scheduling_response_fines(bigint, text)
  TO service_role;

-- ---------------------------------------------------------------------------
-- Forecast — same grace (rebuild from admin_owner_board_fine_forecast_20261021)
-- ---------------------------------------------------------------------------
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
          WHEN public.club_scheduling_fines_in_new_owner_grace(
                 v_season, f.home_club_short_name, v_lock_month
               )
            THEN NULL
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
        AND NOT public.club_scheduling_fines_in_new_owner_grace(
          v_season, s.response_required_club_short_name, v_lock_month
        )
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
        AND NOT public.club_scheduling_fines_in_new_owner_grace(
          v_season, s.response_required_club_short_name, v_lock_month
        )
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

-- ---------------------------------------------------------------------------
-- Backfill: only recent takeovers (last 14 days), never season-wide.
-- Prefer registry status_changed_at; ACM forced if still null.
-- ---------------------------------------------------------------------------
UPDATE public."Clubs" c
SET owner_assigned_at = r.status_changed_at
FROM public.gpsl_owner_registry r
WHERE r.owner_id = c.owner_id
  AND r.status = 'active'
  AND upper(btrim(coalesce(r.last_club_short_name, ''))) = upper(c."ShortName")
  AND r.status_changed_at IS NOT NULL
  AND r.status_changed_at > now() - interval '14 days'
  AND c.owner_id IS NOT NULL
  AND c.owner_assigned_at IS NULL;

UPDATE public."Clubs" c
SET owner_assigned_at = coalesce(c.owner_assigned_at, now())
WHERE c."ShortName" = 'ACM'
  AND c.owner_id IS NOT NULL;

NOTIFY pgrst, 'reload schema';

-- Sample: is ACM in grace for the next lock month?
SELECT
  c."ShortName",
  c.owner,
  c.owner_assigned_at,
  cal.gpsl_month AS next_lock_month,
  cal.unlock_at,
  public.club_scheduling_fines_in_new_owner_grace(
    cal.season_id, c."ShortName", cal.gpsl_month
  ) AS in_grace_for_next_lock
FROM public."Clubs" c
CROSS JOIN LATERAL (
  SELECT m.season_id, m.gpsl_month, m.unlock_at, m.lock_at
  FROM public.competition_season_calendar m
  JOIN public.competition_seasons s ON s.id = m.season_id AND s.is_current
  WHERE m.lock_at > now() - interval '1 hour'
  ORDER BY m.lock_at
  LIMIT 1
) cal
WHERE c."ShortName" = 'ACM';
