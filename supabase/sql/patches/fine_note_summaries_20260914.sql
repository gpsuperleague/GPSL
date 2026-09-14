-- =============================================================================
-- Compact fine notes for match management + missing match video (2026-09-14)
-- Display still trims in finance_ui.js; notes keep MD / side / opponent for ledger.
-- Safe re-run.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Missing match video note: MD + home/away + opponent
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
  v_r record;
  v_apply jsonb;
  v_fined int := 0;
  v_skipped int := 0;
  v_already int := 0;
  v_no_owner int := 0;
  v_deadline timestamptz;
  v_note text;
  v_opponent text;
BEGIN
  IF coalesce(auth.role(), '') <> 'service_role' AND NOT public.is_gpsl_admin() THEN
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

  IF v_fine <= 0 THEN
    RETURN jsonb_build_object(
      'ok', true,
      'skipped', true,
      'reason', 'missing_fine_amount is 0 (fines off)',
      'fined', 0
    );
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

    INSERT INTO public.fixture_match_video_failures (
      season_id, fixture_id, side, club_short_name, gpsl_month,
      assessed_at, deadline_at, fine_amount, ledger_id, fine_applied_id
    ) VALUES (
      v_season_id,
      v_r.fixture_id,
      v_r.side,
      v_r.club_short_name,
      v_r.gpsl_month,
      now(),
      v_deadline,
      v_fine,
      nullif(v_apply->>'ledger_id', '')::bigint,
      nullif(v_apply->>'applied_id', '')::bigint
    )
    ON CONFLICT (fixture_id, side) DO NOTHING;

    v_fined := v_fined + 1;
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true,
    'season_id', v_season_id,
    'fine_amount', v_fine,
    'grace_hours', v_grace,
    'fined', v_fined,
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
-- Response lock fines: include home/away reply + MD vs opponent
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
  v_count int := 0;
  v_skipped int := 0;
  v_side text;
  v_opponent text;
  v_reason text;
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
      f.gpsl_month,
      f.matchday,
      f.home_club_short_name,
      f.away_club_short_name
    FROM public.competition_fixture_schedule s
    JOIN public.competition_fixtures f ON f.id = s.fixture_id
    WHERE f.season_id = p_season_id
      AND f.competition_type IN ('league', 'cup')
      AND f.status = 'scheduled'
      AND f.gpsl_month = p_closed_gpsl_month
      AND s.status = 'negotiating'
      AND s.pending_proposal_id IS NOT NULL
      AND s.response_required_club_short_name IS NOT NULL
      AND (
        coalesce(s.response_miss_count, 0) > 0
        OR (
          s.response_due_at IS NOT NULL
          AND s.response_due_at < v_lock
        )
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
      '%s|%s · MD%s vs %s',
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
    'skipped', v_skipped,
    'fined', v_fined
  );
END;
$function$;
