-- =============================================================================
-- Match video: missing-upload points ladder + peer breach reports (2026-09-14)
--
-- Missing upload (automatic, separate from R reports):
--   At lock_at + grace (default 72h): money fine (unchanged) + 1 pt SUSPENDED (24h)
--   If still no video after 24h: convert to full −1 pt (strike)
--   On 3rd full −1 in a season: extra −9 pts now + −3 pts carry into next season
--
-- R reports: peer flags video content breaches (matchday/squad/manager tariffs).
--   Uphold → fine via tariff + ₿2,000 Building Society reward to reporter.
--
-- Run after match_video_amounts_fines_board + fine_note_summaries patches.
-- Safe re-run.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Settings: suspended-point window (hours after money-fine assess)
-- ---------------------------------------------------------------------------
ALTER TABLE public.gpsl_discord_match_videos_settings
  ADD COLUMN IF NOT EXISTS missing_pts_suspend_hours int NOT NULL DEFAULT 24;

COMMENT ON COLUMN public.gpsl_discord_match_videos_settings.missing_pts_suspend_hours IS
  'Hours after missing-video money fine before suspended −1 pt becomes a full deduction.';

-- ---------------------------------------------------------------------------
-- Failure row: points ladder state
-- ---------------------------------------------------------------------------
ALTER TABLE public.fixture_match_video_failures
  ADD COLUMN IF NOT EXISTS pts_status text NOT NULL DEFAULT 'none';

ALTER TABLE public.fixture_match_video_failures
  DROP CONSTRAINT IF EXISTS fixture_match_video_failures_pts_status_chk;

ALTER TABLE public.fixture_match_video_failures
  ADD CONSTRAINT fixture_match_video_failures_pts_status_chk
  CHECK (pts_status IN ('none', 'suspended', 'full', 'cleared'));

ALTER TABLE public.fixture_match_video_failures
  ADD COLUMN IF NOT EXISTS pts_suspend_until timestamptz;

ALTER TABLE public.fixture_match_video_failures
  ADD COLUMN IF NOT EXISTS pts_cleared_at timestamptz;

ALTER TABLE public.fixture_match_video_failures
  ADD COLUMN IF NOT EXISTS pts_adjustment_id bigint;

ALTER TABLE public.fixture_match_video_failures
  ADD COLUMN IF NOT EXISTS pts_converted_at timestamptz;

CREATE INDEX IF NOT EXISTS fixture_match_video_failures_pts_suspend_idx
  ON public.fixture_match_video_failures (pts_status, pts_suspend_until)
  WHERE pts_status = 'suspended';

-- ---------------------------------------------------------------------------
-- 3-strike escalation (once per club per season) + next-season carry
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.match_video_strike_escalations (
  id bigserial PRIMARY KEY,
  season_id bigint NOT NULL REFERENCES public.competition_seasons(id) ON DELETE CASCADE,
  club_short_name text NOT NULL,
  third_failure_id bigint REFERENCES public.fixture_match_video_failures(id) ON DELETE SET NULL,
  season_points_delta smallint NOT NULL DEFAULT -9,
  season_adjustment_id bigint,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT match_video_strike_escalations_season_club_uidx UNIQUE (season_id, club_short_name)
);

CREATE TABLE IF NOT EXISTS public.match_video_points_carry (
  id bigserial PRIMARY KEY,
  from_season_id bigint NOT NULL REFERENCES public.competition_seasons(id) ON DELETE CASCADE,
  club_short_name text NOT NULL,
  points_delta smallint NOT NULL DEFAULT -3,
  reason text NOT NULL,
  escalation_id bigint REFERENCES public.match_video_strike_escalations(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  applied_season_id bigint REFERENCES public.competition_seasons(id) ON DELETE SET NULL,
  applied_at timestamptz,
  applied_adjustment_id bigint
);

CREATE INDEX IF NOT EXISTS match_video_points_carry_pending_idx
  ON public.match_video_points_carry (from_season_id)
  WHERE applied_at IS NULL;

ALTER TABLE public.match_video_strike_escalations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.match_video_points_carry ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS match_video_strike_escalations_staff ON public.match_video_strike_escalations;
CREATE POLICY match_video_strike_escalations_staff
  ON public.match_video_strike_escalations
  FOR ALL TO authenticated
  USING (public.is_gpsl_admin_or_mod())
  WITH CHECK (public.is_gpsl_admin_or_mod());

DROP POLICY IF EXISTS match_video_points_carry_staff ON public.match_video_points_carry;
CREATE POLICY match_video_points_carry_staff
  ON public.match_video_points_carry
  FOR ALL TO authenticated
  USING (public.is_gpsl_admin_or_mod())
  WITH CHECK (public.is_gpsl_admin_or_mod());

GRANT SELECT ON public.match_video_strike_escalations TO authenticated;
GRANT SELECT ON public.match_video_points_carry TO authenticated;
GRANT ALL ON public.match_video_strike_escalations TO service_role;
GRANT ALL ON public.match_video_points_carry TO service_role;
GRANT USAGE, SELECT ON SEQUENCE public.match_video_strike_escalations_id_seq TO service_role;
GRANT USAGE, SELECT ON SEQUENCE public.match_video_points_carry_id_seq TO service_role;

-- ---------------------------------------------------------------------------
-- Peer breach reports
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.match_video_breach_reports (
  id bigserial PRIMARY KEY,
  season_id bigint NOT NULL REFERENCES public.competition_seasons(id) ON DELETE CASCADE,
  fixture_id bigint NOT NULL REFERENCES public.competition_fixtures(id) ON DELETE CASCADE,
  side text NOT NULL CHECK (side IN ('home', 'away')),
  accused_club_short_name text NOT NULL,
  reporter_owner_id uuid NOT NULL REFERENCES auth.users(id),
  reporter_club_short_name text,
  breach_tariff_code text NOT NULL REFERENCES public.competition_fine_tariff(code),
  note text,
  status text NOT NULL DEFAULT 'open'
    CHECK (status IN ('open', 'upheld', 'dismissed')),
  created_at timestamptz NOT NULL DEFAULT now(),
  reviewed_at timestamptz,
  reviewed_by uuid REFERENCES auth.users(id),
  review_note text,
  upheld_tariff_code text REFERENCES public.competition_fine_tariff(code),
  fine_applied_id bigint,
  fine_ledger_id bigint,
  reward_ledger_id bigint
);

-- One open report per reporter / fixture side / breach
CREATE UNIQUE INDEX IF NOT EXISTS match_video_breach_reports_open_uidx
  ON public.match_video_breach_reports (fixture_id, side, reporter_owner_id, breach_tariff_code)
  WHERE status = 'open';

CREATE INDEX IF NOT EXISTS match_video_breach_reports_status_idx
  ON public.match_video_breach_reports (status, created_at DESC);

CREATE INDEX IF NOT EXISTS match_video_breach_reports_season_idx
  ON public.match_video_breach_reports (season_id, status);

ALTER TABLE public.match_video_breach_reports ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS match_video_breach_reports_select ON public.match_video_breach_reports;
CREATE POLICY match_video_breach_reports_select
  ON public.match_video_breach_reports
  FOR SELECT TO authenticated
  USING (
    public.is_gpsl_admin_or_mod()
    OR reporter_owner_id = auth.uid()
  );

DROP POLICY IF EXISTS match_video_breach_reports_staff ON public.match_video_breach_reports;
CREATE POLICY match_video_breach_reports_staff
  ON public.match_video_breach_reports
  FOR ALL TO authenticated
  USING (public.is_gpsl_admin_or_mod())
  WITH CHECK (public.is_gpsl_admin_or_mod());

GRANT SELECT ON public.match_video_breach_reports TO authenticated;
GRANT ALL ON public.match_video_breach_reports TO service_role;
GRANT USAGE, SELECT ON SEQUENCE public.match_video_breach_reports_id_seq TO authenticated;
GRANT USAGE, SELECT ON SEQUENCE public.match_video_breach_reports_id_seq TO service_role;

-- ---------------------------------------------------------------------------
-- Internal: apply league points (system / staff)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.match_video_apply_league_points(
  p_club_short_name text,
  p_points_delta smallint,
  p_reason text,
  p_season_id bigint DEFAULT NULL
)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season_id bigint := p_season_id;
  v_club text := upper(btrim(p_club_short_name));
  v_adj_id bigint;
BEGIN
  IF p_points_delta IS NULL OR p_points_delta = 0 THEN
    RAISE EXCEPTION 'points_delta must be non-zero';
  END IF;
  IF nullif(btrim(coalesce(p_reason, '')), '') IS NULL THEN
    RAISE EXCEPTION 'reason is required';
  END IF;
  IF nullif(v_club, '') IS NULL THEN
    RAISE EXCEPTION 'club required';
  END IF;

  IF v_season_id IS NULL THEN
    SELECT id INTO v_season_id
    FROM public.competition_seasons
    WHERE is_current = true
    ORDER BY id DESC
    LIMIT 1;
  END IF;

  INSERT INTO public.competition_league_points_adjustments (
    season_id, club_short_name, points_delta, reason, applied_by
  )
  VALUES (
    v_season_id,
    v_club,
    p_points_delta,
    btrim(p_reason),
    'MATCH_VIDEO'
  )
  RETURNING id INTO v_adj_id;

  BEGIN
    PERFORM public.owner_inbox_send(
      'points_deduction',
      CASE WHEN p_points_delta < 0 THEN 'League points deduction' ELSE 'League points adjustment' END,
      format(
        E'%s point(s) %s.\nReason: %s',
        abs(p_points_delta),
        CASE WHEN p_points_delta < 0 THEN 'deducted' ELSE 'added' END,
        btrim(p_reason)
      ),
      v_club,
      NULL,
      NULL, NULL, NULL, NULL,
      'progress.html',
      'points_adj:' || v_adj_id::text,
      NULL,
      v_season_id
    );
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;

  RETURN v_adj_id;
END;
$function$;

REVOKE ALL ON FUNCTION public.match_video_apply_league_points(text, smallint, text, bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.match_video_apply_league_points(text, smallint, text, bigint) TO service_role;

-- ---------------------------------------------------------------------------
-- Assess money fine + start suspended −1 (lock + grace)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.match_video_process_missing_fines(
  p_season_id bigint DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season_id bigint := p_season_id;
  v_fine numeric := public.match_video_missing_fine_amount();
  v_grace int := public.match_video_missing_fine_grace_hours();
  v_suspend_h int := 24;
  v_r record;
  v_apply jsonb;
  v_fined int := 0;
  v_skipped int := 0;
  v_already int := 0;
  v_no_owner int := 0;
  v_deadline timestamptz;
  v_note text;
  v_opponent text;
  v_suspend_until timestamptz;
BEGIN
  IF coalesce(auth.role(), '') <> 'service_role'
     AND NOT public.is_gpsl_admin_or_mod() THEN
    RAISE EXCEPTION 'Not allowed';
  END IF;

  IF v_season_id IS NULL THEN
    SELECT id INTO v_season_id
    FROM public.competition_seasons
    WHERE is_current = true AND status = 'active'
    ORDER BY id DESC
    LIMIT 1;
  END IF;

  IF v_season_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'No active season');
  END IF;

  SELECT coalesce(missing_pts_suspend_hours, 24)
  INTO v_suspend_h
  FROM public.gpsl_discord_match_videos_settings
  WHERE id = 1;

  IF v_suspend_h IS NULL OR v_suspend_h < 1 THEN
    v_suspend_h := 24;
  END IF;

  FOR v_r IN
    SELECT
      f.id AS fixture_id,
      f.gpsl_month,
      f.matchday,
      f.home_club_short_name,
      f.away_club_short_name,
      cal.lock_at,
      side.side,
      side.club_short_name
    FROM public.competition_fixtures f
    JOIN public.competition_season_calendar cal
      ON cal.season_id = f.season_id
     AND lower(btrim(cal.gpsl_month)) = lower(btrim(f.gpsl_month))
    CROSS JOIN LATERAL (
      VALUES
        ('home', upper(btrim(f.home_club_short_name))),
        ('away', upper(btrim(f.away_club_short_name)))
    ) AS side(side, club_short_name)
    WHERE f.season_id = v_season_id
      AND f.status = 'played'
      AND coalesce(f.competition_type, 'league') IN ('league', 'cup')
      AND nullif(btrim(f.gpsl_month), '') IS NOT NULL
      AND cal.lock_at IS NOT NULL
      AND cal.lock_at <= now()
      AND cal.lock_at + make_interval(hours => v_grace) <= now()
      AND side.club_short_name IS NOT NULL
      AND EXISTS (
        SELECT 1
        FROM public."Clubs" c
        WHERE upper(btrim(c."ShortName")) = side.club_short_name
          AND c.owner_id IS NOT NULL
      )
      AND NOT EXISTS (
        SELECT 1
        FROM public.fixture_match_videos v
        WHERE v.fixture_id = f.id
          AND v.side = side.side
      )
      AND NOT EXISTS (
        SELECT 1
        FROM public.fixture_match_video_failures fail
        WHERE fail.fixture_id = f.id
          AND fail.side = side.side
      )
  LOOP
    v_deadline := v_r.lock_at + make_interval(hours => v_grace);
    v_suspend_until := now() + make_interval(hours => v_suspend_h);
    v_opponent := CASE
      WHEN v_r.side = 'home' THEN coalesce(
        public.club_display_name(v_r.away_club_short_name),
        v_r.away_club_short_name
      )
      ELSE coalesce(
        public.club_display_name(v_r.home_club_short_name),
        v_r.home_club_short_name
      )
    END;

    v_note := format(
      'No match video within %sh of month lock, MD%s %s vs %s',
      v_grace,
      coalesce(v_r.matchday::text, '?'),
      v_r.side,
      coalesce(v_opponent, '?')
    );

    v_apply := NULL;
    IF v_fine > 0 THEN
      BEGIN
        v_apply := public.competition_apply_club_fine_tariff(
          v_r.club_short_name,
          'match_video_missing',
          v_fine,
          v_note,
          v_r.fixture_id,
          v_season_id
        );
      EXCEPTION WHEN OTHERS THEN
        v_skipped := v_skipped + 1;
        CONTINUE;
      END;
    END IF;

    INSERT INTO public.fixture_match_video_failures (
      season_id, fixture_id, side, club_short_name, gpsl_month,
      assessed_at, deadline_at, fine_amount, ledger_id, fine_applied_id,
      pts_status, pts_suspend_until
    ) VALUES (
      v_season_id,
      v_r.fixture_id,
      v_r.side,
      v_r.club_short_name,
      v_r.gpsl_month,
      now(),
      v_deadline,
      coalesce(v_fine, 0),
      nullif(v_apply->>'ledger_id', '')::bigint,
      nullif(v_apply->>'applied_id', '')::bigint,
      'suspended',
      v_suspend_until
    )
    ON CONFLICT (fixture_id, side) DO NOTHING;

    BEGIN
      PERFORM public.owner_inbox_send(
        'points_deduction',
        'Match video — 1 point suspended',
        format(
          E'Missing match video after the %s-hour upload window (MD%s %s vs %s).\n'
          || 'A 1 point deduction is SUSPENDED for %s hours. Upload the video before then to avoid the point.\n'
          || 'Money fine (if any) has already been applied and will not be rescinded.',
          v_grace,
          coalesce(v_r.matchday::text, '?'),
          v_r.side,
          coalesce(v_opponent, '?'),
          v_suspend_h
        ),
        v_r.club_short_name,
        NULL,
        NULL, NULL, NULL, NULL,
        'fixtures.html',
        'mv_pts_suspend:' || v_r.fixture_id::text || ':' || v_r.side,
        NULL,
        v_season_id
      );
    EXCEPTION WHEN OTHERS THEN
      NULL;
    END;

    v_fined := v_fined + 1;
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true,
    'season_id', v_season_id,
    'fine_amount', v_fine,
    'grace_hours', v_grace,
    'suspend_hours', v_suspend_h,
    'assessed', v_fined,
    'already', v_already,
    'skipped_errors', v_skipped,
    'no_owner_skipped_note', v_no_owner
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.match_video_process_missing_fines(bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.match_video_process_missing_fines(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.match_video_process_missing_fines(bigint) TO service_role;

-- ---------------------------------------------------------------------------
-- Clear suspended if video arrives; convert expired suspended → full −1 + escalate
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.match_video_process_suspended_points(
  p_season_id bigint DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season_id bigint := p_season_id;
  v_fail record;
  v_cleared int := 0;
  v_converted int := 0;
  v_escalated int := 0;
  v_full_count int;
  v_adj_id bigint;
  v_esc_id bigint;
  v_carry_id bigint;
  v_esc_adj bigint;
  v_opponent text;
  v_md text;
BEGIN
  IF coalesce(auth.role(), '') <> 'service_role'
     AND NOT public.is_gpsl_admin_or_mod() THEN
    RAISE EXCEPTION 'Not allowed';
  END IF;

  IF v_season_id IS NULL THEN
    SELECT id INTO v_season_id
    FROM public.competition_seasons
    WHERE is_current = true AND status = 'active'
    ORDER BY id DESC
    LIMIT 1;
  END IF;

  IF v_season_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'No active season');
  END IF;

  -- Clear if video uploaded during suspended window
  FOR v_fail IN
    SELECT fail.*
    FROM public.fixture_match_video_failures fail
    WHERE fail.season_id = v_season_id
      AND fail.pts_status = 'suspended'
      AND EXISTS (
        SELECT 1
        FROM public.fixture_match_videos v
        WHERE v.fixture_id = fail.fixture_id
          AND v.side = fail.side
      )
  LOOP
    UPDATE public.fixture_match_video_failures
    SET pts_status = 'cleared',
        pts_cleared_at = now()
    WHERE id = v_fail.id;

    BEGIN
      PERFORM public.owner_inbox_send(
        'points_deduction',
        'Match video — suspended point cleared',
        'Your match video was uploaded within the suspended-point window. The 1 point deduction will not be applied.',
        v_fail.club_short_name,
        NULL,
        NULL, NULL, NULL, NULL,
        'fixtures.html',
        'mv_pts_clear:' || v_fail.id::text,
        NULL,
        v_season_id
      );
    EXCEPTION WHEN OTHERS THEN
      NULL;
    END;

    v_cleared := v_cleared + 1;
  END LOOP;

  -- Convert expired suspensions
  FOR v_fail IN
    SELECT fail.*, f.matchday, f.home_club_short_name, f.away_club_short_name
    FROM public.fixture_match_video_failures fail
    JOIN public.competition_fixtures f ON f.id = fail.fixture_id
    WHERE fail.season_id = v_season_id
      AND fail.pts_status = 'suspended'
      AND fail.pts_suspend_until IS NOT NULL
      AND fail.pts_suspend_until <= now()
      AND NOT EXISTS (
        SELECT 1
        FROM public.fixture_match_videos v
        WHERE v.fixture_id = fail.fixture_id
          AND v.side = fail.side
      )
  LOOP
    v_opponent := CASE
      WHEN v_fail.side = 'home' THEN coalesce(
        public.club_display_name(v_fail.away_club_short_name),
        v_fail.away_club_short_name
      )
      ELSE coalesce(
        public.club_display_name(v_fail.home_club_short_name),
        v_fail.home_club_short_name
      )
    END;
    v_md := coalesce(v_fail.matchday::text, '?');

    v_adj_id := public.match_video_apply_league_points(
      v_fail.club_short_name,
      (-1)::smallint,
      format(
        'Missing match video — full 1 pt after suspended window (MD%s %s vs %s)',
        v_md,
        v_fail.side,
        coalesce(v_opponent, '?')
      ),
      v_season_id
    );

    UPDATE public.fixture_match_video_failures
    SET pts_status = 'full',
        pts_converted_at = now(),
        pts_adjustment_id = v_adj_id
    WHERE id = v_fail.id;

    v_converted := v_converted + 1;

    SELECT count(*)::int INTO v_full_count
    FROM public.fixture_match_video_failures
    WHERE season_id = v_season_id
      AND upper(btrim(club_short_name)) = upper(btrim(v_fail.club_short_name))
      AND pts_status = 'full';

    IF v_full_count >= 3
       AND NOT EXISTS (
         SELECT 1
         FROM public.match_video_strike_escalations e
         WHERE e.season_id = v_season_id
           AND upper(btrim(e.club_short_name)) = upper(btrim(v_fail.club_short_name))
       )
    THEN
      v_esc_adj := public.match_video_apply_league_points(
        v_fail.club_short_name,
        (-9)::smallint,
        format(
          'Missing match video — 3rd full strike this season (extra −9 pts; MD%s %s vs %s)',
          v_md,
          v_fail.side,
          coalesce(v_opponent, '?')
        ),
        v_season_id
      );

      INSERT INTO public.match_video_strike_escalations (
        season_id, club_short_name, third_failure_id,
        season_points_delta, season_adjustment_id
      ) VALUES (
        v_season_id,
        upper(btrim(v_fail.club_short_name)),
        v_fail.id,
        -9,
        v_esc_adj
      )
      RETURNING id INTO v_esc_id;

      INSERT INTO public.match_video_points_carry (
        from_season_id, club_short_name, points_delta, reason, escalation_id
      ) VALUES (
        v_season_id,
        upper(btrim(v_fail.club_short_name)),
        -3,
        'Missing match video — 3-strike carry (−3 pts next season)',
        v_esc_id
      )
      RETURNING id INTO v_carry_id;

      v_escalated := v_escalated + 1;
    END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true,
    'season_id', v_season_id,
    'cleared', v_cleared,
    'converted', v_converted,
    'escalated', v_escalated
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.match_video_process_suspended_points(bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.match_video_process_suspended_points(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.match_video_process_suspended_points(bigint) TO service_role;

-- ---------------------------------------------------------------------------
-- Apply next-season carry (−3) once a newer season is current
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.match_video_apply_points_carry(
  p_season_id bigint DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season_id bigint := p_season_id;
  v_row record;
  v_applied int := 0;
  v_adj_id bigint;
BEGIN
  IF coalesce(auth.role(), '') <> 'service_role'
     AND NOT public.is_gpsl_admin_or_mod() THEN
    RAISE EXCEPTION 'Not allowed';
  END IF;

  IF v_season_id IS NULL THEN
    SELECT id INTO v_season_id
    FROM public.competition_seasons
    WHERE is_current = true
    ORDER BY id DESC
    LIMIT 1;
  END IF;

  IF v_season_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'No active season');
  END IF;

  FOR v_row IN
    SELECT c.*
    FROM public.match_video_points_carry c
    WHERE c.applied_at IS NULL
      AND c.from_season_id <> v_season_id
      AND EXISTS (
        SELECT 1
        FROM public.competition_club_seasons ccs
        WHERE ccs.season_id = v_season_id
          AND upper(btrim(ccs.club_short_name)) = upper(btrim(c.club_short_name))
      )
  LOOP
    v_adj_id := public.match_video_apply_league_points(
      v_row.club_short_name,
      v_row.points_delta,
      coalesce(v_row.reason, 'Missing match video — carried points from prior season'),
      v_season_id
    );

    UPDATE public.match_video_points_carry
    SET applied_season_id = v_season_id,
        applied_at = now(),
        applied_adjustment_id = v_adj_id
    WHERE id = v_row.id;

    v_applied := v_applied + 1;
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true,
    'season_id', v_season_id,
    'applied', v_applied
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.match_video_apply_points_carry(bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.match_video_apply_points_carry(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.match_video_apply_points_carry(bigint) TO service_role;

-- ---------------------------------------------------------------------------
-- Orchestrator used by cron + admin "Assess now"
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.match_video_process_all_penalties(
  p_season_id bigint DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_fines jsonb;
  v_pts jsonb;
  v_carry jsonb;
BEGIN
  IF coalesce(auth.role(), '') <> 'service_role'
     AND NOT public.is_gpsl_admin_or_mod() THEN
    RAISE EXCEPTION 'Not allowed';
  END IF;

  v_fines := public.match_video_process_missing_fines(p_season_id);
  v_pts := public.match_video_process_suspended_points(p_season_id);
  v_carry := public.match_video_apply_points_carry(p_season_id);

  RETURN jsonb_build_object(
    'ok', true,
    'fines', v_fines,
    'suspended_points', v_pts,
    'carry', v_carry
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.match_video_process_all_penalties(bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.match_video_process_all_penalties(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.match_video_process_all_penalties(bigint) TO service_role;

-- ---------------------------------------------------------------------------
-- Report catalogue + submit / resolve
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.match_video_report_breach_codes()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  RETURN coalesce((
    SELECT jsonb_agg(
      jsonb_build_object(
        'code', t.code,
        'label', t.label,
        'category', t.category,
        'amount', t.amount
      )
      ORDER BY t.category, t.sort_order, t.label
    )
    FROM public.competition_fine_tariff t
    WHERE t.is_active = true
      AND t.direction = 'fine'
      AND t.category IN ('matchday', 'squad', 'manager')
      AND t.code <> 'match_video_missing'
  ), '[]'::jsonb);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.match_video_report_breach_codes() TO authenticated;

CREATE OR REPLACE FUNCTION public.match_video_submit_breach_report(
  p_fixture_id bigint,
  p_side text,
  p_breach_tariff_code text,
  p_note text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_side text := lower(btrim(p_side));
  v_code text := btrim(p_breach_tariff_code);
  v_f record;
  v_accused text;
  v_reporter_club text;
  v_id bigint;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;
  IF p_fixture_id IS NULL OR v_side NOT IN ('home', 'away') THEN
    RAISE EXCEPTION 'fixture_id and side (home|away) required';
  END IF;
  IF nullif(v_code, '') IS NULL THEN
    RAISE EXCEPTION 'breach_tariff_code required';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.competition_fine_tariff t
    WHERE t.code = v_code
      AND t.is_active
      AND t.direction = 'fine'
      AND t.category IN ('matchday', 'squad', 'manager')
      AND t.code <> 'match_video_missing'
  ) THEN
    RAISE EXCEPTION 'Invalid breach code';
  END IF;

  SELECT f.*
  INTO v_f
  FROM public.competition_fixtures f
  WHERE f.id = p_fixture_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Fixture not found';
  END IF;

  IF v_f.status <> 'played' THEN
    RAISE EXCEPTION 'Fixture must be played';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.fixture_match_videos v
    WHERE v.fixture_id = p_fixture_id AND v.side = v_side
  ) THEN
    RAISE EXCEPTION 'No uploaded video on that side to report';
  END IF;

  v_accused := CASE
    WHEN v_side = 'home' THEN upper(btrim(v_f.home_club_short_name))
    ELSE upper(btrim(v_f.away_club_short_name))
  END;

  SELECT upper(btrim(c."ShortName"))
  INTO v_reporter_club
  FROM public."Clubs" c
  WHERE c.owner_id = v_uid
  ORDER BY c."ShortName"
  LIMIT 1;

  IF v_reporter_club IS NULL THEN
    RAISE EXCEPTION 'You must own a club to submit a report';
  END IF;

  IF v_reporter_club = v_accused THEN
    RAISE EXCEPTION 'You cannot report your own club video';
  END IF;

  INSERT INTO public.match_video_breach_reports (
    season_id, fixture_id, side, accused_club_short_name,
    reporter_owner_id, reporter_club_short_name,
    breach_tariff_code, note, status
  ) VALUES (
    v_f.season_id,
    p_fixture_id,
    v_side,
    v_accused,
    v_uid,
    v_reporter_club,
    v_code,
    nullif(btrim(coalesce(p_note, '')), ''),
    'open'
  )
  RETURNING id INTO v_id;

  RETURN jsonb_build_object('ok', true, 'report_id', v_id);
EXCEPTION
  WHEN unique_violation THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'duplicate_open_report');
END;
$function$;

GRANT EXECUTE ON FUNCTION public.match_video_submit_breach_report(bigint, text, text, text) TO authenticated;

CREATE OR REPLACE FUNCTION public.admin_match_video_list_breach_reports(
  p_status text DEFAULT 'open',
  p_limit int DEFAULT 100
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_status text := lower(btrim(coalesce(p_status, 'open')));
  v_limit int := greatest(1, least(coalesce(p_limit, 100), 500));
BEGIN
  IF NOT public.is_gpsl_admin_or_mod() THEN
    RAISE EXCEPTION 'Staff only';
  END IF;

  RETURN coalesce((
    SELECT jsonb_agg(row_to_json(x)::jsonb ORDER BY x.created_at DESC)
    FROM (
      SELECT
        r.id,
        r.season_id,
        r.fixture_id,
        r.side,
        r.accused_club_short_name,
        r.reporter_club_short_name,
        r.reporter_owner_id,
        r.breach_tariff_code,
        t.label AS breach_label,
        t.amount AS breach_amount,
        r.note,
        r.status,
        r.created_at,
        r.reviewed_at,
        r.review_note,
        r.upheld_tariff_code,
        r.fine_applied_id,
        r.reward_ledger_id,
        f.matchday,
        f.gpsl_month,
        f.competition_type,
        f.division,
        f.home_club_short_name,
        f.away_club_short_name,
        f.home_goals,
        f.away_goals,
        v.video_url
      FROM public.match_video_breach_reports r
      JOIN public.competition_fixtures f ON f.id = r.fixture_id
      LEFT JOIN public.competition_fine_tariff t ON t.code = r.breach_tariff_code
      LEFT JOIN public.fixture_match_videos v
        ON v.fixture_id = r.fixture_id AND v.side = r.side
      WHERE (v_status = 'all' OR r.status = v_status)
      ORDER BY r.created_at DESC
      LIMIT v_limit
    ) x
  ), '[]'::jsonb);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.admin_match_video_list_breach_reports(text, int) TO authenticated;

CREATE OR REPLACE FUNCTION public.admin_match_video_resolve_breach_report(
  p_report_id bigint,
  p_action text,
  p_tariff_code text DEFAULT NULL,
  p_review_note text DEFAULT NULL,
  p_amount_override numeric DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_action text := lower(btrim(p_action));
  v_uid uuid := auth.uid();
  v_r public.match_video_breach_reports%ROWTYPE;
  v_tariff text;
  v_apply jsonb;
  v_reward_id bigint;
  v_reward numeric := 2000;
BEGIN
  IF NOT public.is_gpsl_admin_or_mod() THEN
    RAISE EXCEPTION 'Staff only';
  END IF;
  IF v_action NOT IN ('uphold', 'dismiss') THEN
    RAISE EXCEPTION 'action must be uphold or dismiss';
  END IF;

  SELECT * INTO v_r
  FROM public.match_video_breach_reports
  WHERE id = p_report_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Report not found';
  END IF;
  IF v_r.status <> 'open' THEN
    RAISE EXCEPTION 'Report already resolved';
  END IF;

  IF v_action = 'dismiss' THEN
    UPDATE public.match_video_breach_reports
    SET status = 'dismissed',
        reviewed_at = now(),
        reviewed_by = v_uid,
        review_note = nullif(btrim(coalesce(p_review_note, '')), '')
    WHERE id = p_report_id;

    RETURN jsonb_build_object('ok', true, 'status', 'dismissed', 'report_id', p_report_id);
  END IF;

  v_tariff := coalesce(nullif(btrim(coalesce(p_tariff_code, '')), ''), v_r.breach_tariff_code);

  IF NOT EXISTS (
    SELECT 1 FROM public.competition_fine_tariff t
    WHERE t.code = v_tariff AND t.is_active AND t.direction = 'fine'
  ) THEN
    RAISE EXCEPTION 'Invalid fine tariff';
  END IF;

  v_apply := public.competition_apply_club_fine_tariff(
    v_r.accused_club_short_name,
    v_tariff,
    p_amount_override,
    coalesce(
      nullif(btrim(coalesce(p_review_note, '')), ''),
      format('Match video breach report #%s', p_report_id)
    ),
    v_r.fixture_id,
    v_r.season_id
  );

  BEGIN
    PERFORM public.owner_wallet_ensure(v_r.reporter_owner_id);
    v_reward_id := public._post_owner_ledger_internal(
      v_r.reporter_owner_id,
      'match_video_report_reward',
      v_reward,
      format('Match video report upheld (#%s)', p_report_id),
      jsonb_build_object(
        'source', 'match_video_breach_report',
        'report_id', p_report_id,
        'fixture_id', v_r.fixture_id
      ),
      v_r.season_id,
      true
    );
  EXCEPTION WHEN OTHERS THEN
    v_reward_id := NULL;
  END;

  UPDATE public.match_video_breach_reports
  SET status = 'upheld',
      reviewed_at = now(),
      reviewed_by = v_uid,
      review_note = nullif(btrim(coalesce(p_review_note, '')), ''),
      upheld_tariff_code = v_tariff,
      fine_applied_id = nullif(v_apply->>'applied_id', '')::bigint,
      fine_ledger_id = nullif(v_apply->>'ledger_id', '')::bigint,
      reward_ledger_id = v_reward_id
  WHERE id = p_report_id;

  RETURN jsonb_build_object(
    'ok', true,
    'status', 'upheld',
    'report_id', p_report_id,
    'fine', v_apply,
    'reward_ledger_id', v_reward_id,
    'reward_amount', v_reward
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.admin_match_video_resolve_breach_report(bigint, text, text, text, numeric)
  TO authenticated;

-- ---------------------------------------------------------------------------
-- Cron: run full penalty stack after Discord poll
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.gpsl_discord_match_videos_request_poll()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions, net
AS $function$
DECLARE
  v_enabled boolean;
  v_url text;
  v_key text;
BEGIN
  SELECT auto_poll_enabled, edge_function_url, invoke_key
  INTO v_enabled, v_url, v_key
  FROM public.gpsl_discord_match_videos_settings
  WHERE id = 1;

  IF NOT coalesce(v_enabled, false) THEN
    RETURN;
  END IF;
  IF nullif(btrim(coalesce(v_url, '')), '') IS NULL THEN
    RETURN;
  END IF;
  IF nullif(btrim(coalesce(v_key, '')), '') IS NULL THEN
    RETURN;
  END IF;

  BEGIN
    PERFORM net.http_post(
      url := v_url,
      headers := jsonb_build_object(
        'Content-Type', 'application/json',
        'Authorization', 'Bearer ' || v_key
      ),
      body := jsonb_build_object('limit', 40, 'poll', true),
      timeout_milliseconds := 55000
    );
  EXCEPTION
    WHEN undefined_function THEN
      RAISE WARNING 'gpsl_discord_match_videos_request_poll: pg_net missing';
    WHEN OTHERS THEN
      RAISE WARNING 'gpsl_discord_match_videos_request_poll failed: %', SQLERRM;
  END;

  BEGIN
    PERFORM public.match_video_process_all_penalties(NULL);
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'match_video_process_all_penalties: %', SQLERRM;
  END;
END;
$function$;

NOTIFY pgrst, 'reload schema';
