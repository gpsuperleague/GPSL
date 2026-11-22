-- August, September, and October matches: the missing-video fine and the strike still count.
-- The 1-point deduction does not, and the checklist must not warn about one.
-- November onwards is unchanged. Does not turn auto-fines on. Safe re-run.

DO $ungate$
DECLARE
  v_def text;
  v_old text;
  v_new text;
BEGIN
  v_def := replace(
    pg_get_functiondef('public.match_video_process_missing_fines(bigint)'::regprocedure),
    E'\r\n', E'\n'
  );
  v_old := replace($old$      AND NOT public.competition_fixture_skips_match_video(f.id)
      AND public.competition_gpsl_month_sort(f.gpsl_month) >= public.competition_gpsl_month_sort('november')
      AND coalesce(f.competition_type, 'league') IN ('league', 'cup')$old$, E'\r\n', E'\n');
  v_new := replace($new$      AND NOT public.competition_fixture_skips_match_video(f.id)
      AND coalesce(f.competition_type, 'league') IN ('league', 'cup')$new$, E'\r\n', E'\n');
  IF position(v_old IN v_def) = 0 THEN
    RAISE NOTICE 'missing-video fines already apply before November';
    RETURN;
  END IF;
  IF (length(v_def) - length(replace(v_def, v_old, ''))) / nullif(length(v_old), 0) <> 1 THEN
    RAISE EXCEPTION 'missing-video fine gate needle not unique';
  END IF;
  EXECUTE replace(v_def, v_old, v_new);
END;
$ungate$;

DO $inbox$
DECLARE
  v_def text;
  v_old text;
  v_new text;
BEGIN
  v_def := replace(
    pg_get_functiondef('public.match_video_process_missing_fines(bigint)'::regprocedure),
    E'\r\n', E'\n'
  );
  v_old := replace($old$        'Match video — 1 point suspended',
        format(
          E'Missing match video after the %s-hour upload window (MD%s %s vs %s).\n'
          || 'A 1 point deduction is SUSPENDED for %s hours. Upload the video before then to avoid the point.\n'
          || 'Money fine (if any) has already been applied and will not be rescinded.',$old$, E'\r\n', E'\n');
  v_new := replace($new$        CASE
          WHEN public.competition_gpsl_month_sort((
            SELECT fx.gpsl_month FROM public.competition_fixtures fx WHERE fx.id = v_r.fixture_id
          )) >= public.competition_gpsl_month_sort('november')
          THEN 'Match video — 1 point suspended'
          ELSE 'Match video — fine applied'
        END,
        format(
          E'Missing match video after the %s-hour upload window (MD%s %s vs %s).\n'
          || CASE
               WHEN public.competition_gpsl_month_sort((
                 SELECT fx.gpsl_month FROM public.competition_fixtures fx WHERE fx.id = v_r.fixture_id
               )) >= public.competition_gpsl_month_sort('november')
               THEN 'A 1 point deduction is SUSPENDED for %s hours. Upload the video before then to avoid the point.\n'
               ELSE 'The fine is applied. Upload before the deadline to avoid the strike. No league point is deducted.\n'
             END
          || 'Money fine (if any) has already been applied and will not be rescinded.',$new$, E'\r\n', E'\n');
  IF position(v_new IN v_def) > 0 THEN
    RAISE NOTICE 'missing-video inbox already splits the point warning';
    RETURN;
  END IF;
  IF (length(v_def) - length(replace(v_def, v_old, ''))) / nullif(length(v_old), 0) <> 1 THEN
    RAISE EXCEPTION 'missing-video inbox needle not unique';
  END IF;
  EXECUTE replace(v_def, v_old, v_new);
END;
$inbox$;

DO $convert$
DECLARE
  v_def text;
  v_old text;
  v_new text;
BEGIN
  v_def := replace(
    pg_get_functiondef('public.match_video_process_suspended_points(bigint)'::regprocedure),
    E'\r\n', E'\n'
  );
  v_old := replace($old$      AND fail.pts_suspend_until <= now()
      AND public.competition_gpsl_month_sort(coalesce(nullif(btrim(fail.gpsl_month), ''), f.gpsl_month))
            >= public.competition_gpsl_month_sort('november')
      AND NOT EXISTS ($old$, E'\r\n', E'\n');
  v_new := replace($new$      AND fail.pts_suspend_until <= now()
      AND NOT EXISTS ($new$, E'\r\n', E'\n');
  IF position(v_old IN v_def) > 0 THEN
    IF (length(v_def) - length(replace(v_def, v_old, ''))) / nullif(length(v_old), 0) <> 1 THEN
      RAISE EXCEPTION 'suspended-point month skip needle not unique';
    END IF;
    v_def := replace(v_def, v_old, v_new);
  END IF;

  v_old := replace($old$    v_adj_id := public.match_video_apply_league_points(
      v_fail.club_short_name,
      (-1)::smallint,
      format(
        'Missing match video — full 1 pt after suspended window (MD%s %s vs %s)',
        v_md,
        v_fail.side,
        coalesce(v_opponent, '?')
      ),
      v_season_id
    );$old$, E'\r\n', E'\n');
  v_new := replace($new$    IF public.competition_gpsl_month_sort((
         SELECT fx.gpsl_month FROM public.competition_fixtures fx WHERE fx.id = v_fail.fixture_id
       )) >= public.competition_gpsl_month_sort('november') THEN
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
    ELSE
      v_adj_id := NULL;
    END IF;$new$, E'\r\n', E'\n');
  IF position(v_new IN v_def) = 0 THEN
    IF (length(v_def) - length(replace(v_def, v_old, ''))) / nullif(length(v_old), 0) <> 1 THEN
      RAISE EXCEPTION 'suspended-point apply needle not unique';
    END IF;
    v_def := replace(v_def, v_old, v_new);
  END IF;

  v_old := replace($old$    IF v_full_count >= 3
       AND NOT EXISTS ($old$, E'\r\n', E'\n');
  v_new := replace($new$    IF v_full_count >= 3
       AND public.competition_gpsl_month_sort((
             SELECT fx.gpsl_month FROM public.competition_fixtures fx WHERE fx.id = v_fail.fixture_id
           )) >= public.competition_gpsl_month_sort('november')
       AND NOT EXISTS ($new$, E'\r\n', E'\n');
  IF position(v_new IN v_def) = 0 THEN
    IF (length(v_def) - length(replace(v_def, v_old, ''))) / nullif(length(v_old), 0) <> 1 THEN
      RAISE EXCEPTION 'third-strike point needle not unique';
    END IF;
    v_def := replace(v_def, v_old, v_new);
  END IF;

  v_old := replace($old$'Your match video was uploaded within the suspended-point window. The 1 point deduction will not be applied.'$old$, E'\r\n', E'\n');
  v_new := replace($new$CASE
          WHEN public.competition_gpsl_month_sort((
            SELECT fx.gpsl_month FROM public.competition_fixtures fx WHERE fx.id = v_fail.fixture_id
          )) >= public.competition_gpsl_month_sort('november')
          THEN 'Your match video was uploaded within the suspended-point window. The 1 point deduction will not be applied.'
          ELSE 'Your match video was uploaded in time. The fine stands. It will not count as a strike, and no point is deducted.'
        END$new$, E'\r\n', E'\n');
  IF position(v_new IN v_def) = 0 AND position(v_old IN v_def) > 0 THEN
    v_def := replace(v_def, v_old, v_new);
  END IF;

  EXECUTE v_def;
END;
$convert$;

DO $checklist$
DECLARE
  v_def text;
  v_old text;
  v_new text;
BEGIN
  v_def := replace(
    pg_get_functiondef('public.matchday_checklist_for_club(text,boolean)'::regprocedure),
    E'\r\n', E'\n'
  );
  v_old := replace($old$      IF v_fail_found AND v_fail.pts_status = 'suspended' THEN
        v_step := jsonb_build_object('key', 'video', 'label', 'Upload video — 1 point suspended', 'state', 'overdue',
          'due_at', v_fail.pts_suspend_until, 'filename', v_filename, 'href', 'discord', 'action', 'Upload',
          'detail', 'Upload before the deadline to avoid the point deduction');
      ELSIF v_fail_found AND v_fail.pts_status = 'cleared' AND coalesce(v_fail.fine_amount, 0) = 0 THEN$old$, E'\r\n', E'\n');
  v_new := replace($new$      IF v_fail_found AND v_fail.pts_status = 'suspended'
         AND public.competition_gpsl_month_sort(r.gpsl_month) < public.competition_gpsl_month_sort('november') THEN
        v_step := jsonb_build_object('key', 'video', 'label', 'Upload video', 'state', 'overdue',
          'due_at', v_fail.pts_suspend_until, 'filename', v_filename, 'href', 'discord', 'action', 'Upload',
          'detail', 'Fine applied. Upload before the deadline to avoid the strike.');
      ELSIF v_fail_found AND v_fail.pts_status = 'suspended' THEN
        v_step := jsonb_build_object('key', 'video', 'label', 'Upload video — 1 point suspended', 'state', 'overdue',
          'due_at', v_fail.pts_suspend_until, 'filename', v_filename, 'href', 'discord', 'action', 'Upload',
          'detail', 'Upload before the deadline to avoid the point deduction');
      ELSIF v_fail_found AND v_fail.pts_status = 'cleared' AND coalesce(v_fail.fine_amount, 0) = 0 THEN$new$, E'\r\n', E'\n');
  IF position(v_new IN v_def) = 0 THEN
    IF (length(v_def) - length(replace(v_def, v_old, ''))) / nullif(length(v_old), 0) <> 1 THEN
      RAISE EXCEPTION 'checklist point-warning needle not unique';
    END IF;
    v_def := replace(v_def, v_old, v_new);
  END IF;

  v_old := replace($old$          'detail', 'Fine' || CASE WHEN v_fail.pts_status = 'full' THEN ' and point deduction applied' ELSE ' applied' END);$old$, E'\r\n', E'\n');
  v_new := replace($new$          'detail', CASE
            WHEN v_fail.pts_status = 'full' AND v_fail.pts_adjustment_id IS NOT NULL THEN 'Fine and point deduction applied'
            WHEN v_fail.pts_status = 'full' THEN 'Fine applied. Counts as a strike.'
            ELSE 'Fine applied'
          END);$new$, E'\r\n', E'\n');
  IF position(v_new IN v_def) = 0 THEN
    IF (length(v_def) - length(replace(v_def, v_old, ''))) / nullif(length(v_old), 0) <> 1 THEN
      RAISE EXCEPTION 'checklist missed-video detail needle not unique';
    END IF;
    v_def := replace(v_def, v_old, v_new);
  END IF;
  EXECUTE v_def;
END;
$checklist$;

DO $wire$
DECLARE
  v_def text;
  v_old text;
  v_new text;
BEGIN
  v_def := replace(
    pg_get_functiondef('public.club_wire_cutoffs()'::regprocedure),
    E'\r\n', E'\n'
  );
  v_old := replace($old$      END AS opp,
      cal.lock_at,$old$, E'\r\n', E'\n');
  v_new := replace($new$      END AS opp,
      f.gpsl_month AS fixture_month,
      cal.lock_at,$new$, E'\r\n', E'\n');
  IF position('f.gpsl_month AS fixture_month' IN v_def) = 0 THEN
    IF (length(v_def) - length(replace(v_def, v_old, ''))) / nullif(length(v_old), 0) <> 1 THEN
      RAISE EXCEPTION 'club wire video select needle not unique';
    END IF;
    v_def := replace(v_def, v_old, v_new);
  END IF;

  v_old := replace($old$    IF r.pts_status = 'suspended' THEN
      v_kind := 'video_suspend';
      v_at := r.pts_suspend_until;
      v_title := format('Upload video vs %s (clear suspended pt)', r.opp);
      v_detail := format(
        '1 point suspended — upload before %s UK to avoid the deduction (+₿200k credit).',
        to_char(r.pts_suspend_until AT TIME ZONE 'Europe/London', 'Dy DD Mon HH24:MI')
      );$old$, E'\r\n', E'\n');
  v_new := replace($new$    IF r.pts_status = 'suspended'
       AND public.competition_gpsl_month_sort(r.fixture_month) < public.competition_gpsl_month_sort('november') THEN
      v_kind := 'video_suspend';
      v_at := r.pts_suspend_until;
      v_title := format('Upload video vs %s', r.opp);
      v_detail := format(
        'Fine applied. Upload before %s UK to avoid the strike. No point deduction.',
        to_char(r.pts_suspend_until AT TIME ZONE 'Europe/London', 'Dy DD Mon HH24:MI')
      );
    ELSIF r.pts_status = 'suspended' THEN
      v_kind := 'video_suspend';
      v_at := r.pts_suspend_until;
      v_title := format('Upload video vs %s (clear suspended pt)', r.opp);
      v_detail := format(
        '1 point suspended — upload before %s UK to avoid the deduction (+₿200k credit).',
        to_char(r.pts_suspend_until AT TIME ZONE 'Europe/London', 'Dy DD Mon HH24:MI')
      );$new$, E'\r\n', E'\n');
  IF position('No point deduction.' IN v_def) = 0 THEN
    IF (length(v_def) - length(replace(v_def, v_old, ''))) / nullif(length(v_old), 0) <> 1 THEN
      RAISE EXCEPTION 'club wire point-warning needle not unique';
    END IF;
    v_def := replace(v_def, v_old, v_new);
  END IF;
  EXECUTE v_def;
END;
$wire$;

INSERT INTO public.competition_league_points_adjustments (
  season_id, club_short_name, points_delta, reason, applied_by
)
SELECT
  a.season_id,
  a.club_short_name,
  (-a.points_delta)::smallint,
  'Reversed missing-video point ' || a.id::text || ' — August to October matches are not deducted a point.',
  'MATCH_VIDEO'
FROM public.fixture_match_video_failures fail
JOIN public.competition_fixtures fx ON fx.id = fail.fixture_id
JOIN public.competition_league_points_adjustments a ON a.id = fail.pts_adjustment_id
WHERE public.competition_gpsl_month_sort(fx.gpsl_month) < public.competition_gpsl_month_sort('november')
  AND a.points_delta < 0
  AND NOT EXISTS (
    SELECT 1
    FROM public.competition_league_points_adjustments rev
    WHERE rev.reason = 'Reversed missing-video point ' || a.id::text || ' — August to October matches are not deducted a point.'
  );

INSERT INTO public.competition_league_points_adjustments (
  season_id, club_short_name, points_delta, reason, applied_by
)
SELECT
  a.season_id,
  a.club_short_name,
  (-a.points_delta)::smallint,
  'Reversed missing-video strike points ' || a.id::text || ' — August to October matches are not deducted a point.',
  'MATCH_VIDEO'
FROM public.match_video_strike_escalations e
JOIN public.competition_league_points_adjustments a ON a.id = e.season_adjustment_id
JOIN public.fixture_match_video_failures fail ON fail.id = e.third_failure_id
JOIN public.competition_fixtures fx ON fx.id = fail.fixture_id
WHERE public.competition_gpsl_month_sort(fx.gpsl_month) < public.competition_gpsl_month_sort('november')
  AND a.points_delta < 0
  AND NOT EXISTS (
    SELECT 1
    FROM public.competition_league_points_adjustments rev
    WHERE rev.reason = 'Reversed missing-video strike points ' || a.id::text || ' — August to October matches are not deducted a point.'
  );

UPDATE public.match_video_points_carry c
SET points_delta = 0,
    reason = c.reason || ' (no point — pre-November strike)'
FROM public.match_video_strike_escalations e
JOIN public.fixture_match_video_failures fail ON fail.id = e.third_failure_id
JOIN public.competition_fixtures fx ON fx.id = fail.fixture_id
WHERE c.escalation_id = e.id
  AND c.applied_at IS NULL
  AND c.points_delta <> 0
  AND public.competition_gpsl_month_sort(fx.gpsl_month) < public.competition_gpsl_month_sort('november');

UPDATE public.fixture_match_video_failures fail
SET pts_adjustment_id = NULL
FROM public.competition_fixtures fx
WHERE fx.id = fail.fixture_id
  AND fail.pts_adjustment_id IS NOT NULL
  AND public.competition_gpsl_month_sort(fx.gpsl_month) < public.competition_gpsl_month_sort('november')
  AND EXISTS (
    SELECT 1
    FROM public.competition_league_points_adjustments rev
    WHERE rev.reason LIKE 'Reversed missing-video point ' || fail.pts_adjustment_id::text || ' —%'
       OR rev.reason LIKE 'Reversed missing-video strike points ' || fail.pts_adjustment_id::text || ' —%'
  );

SELECT jsonb_build_object(
  'fines_still_gated', position(
    'competition_gpsl_month_sort(f.gpsl_month) >= public.competition_gpsl_month_sort(''november'')' IN
    replace(pg_get_functiondef('public.match_video_process_missing_fines(bigint)'::regprocedure), E'\r\n', E'\n')
  ) > 0,
  'strike_without_point', position(
    'v_adj_id := NULL' IN
    replace(pg_get_functiondef('public.match_video_process_suspended_points(bigint)'::regprocedure), E'\r\n', E'\n')
  ) > 0,
  'checklist', (
    SELECT jsonb_build_object(
      'month', item->>'gpsl_month',
      'label', step->>'label',
      'detail', step->>'detail'
    )
    FROM public.matchday_checklist_for_club('MON', true) AS c
    CROSS JOIN LATERAL jsonb_array_elements(c->'fixtures') AS item
    CROSS JOIN LATERAL jsonb_array_elements(item->'steps') AS step
    WHERE item->>'fixture_id' = '9044'
      AND step->>'key' = 'video'
  ),
  'pre_nov_points_still_linked', (
    SELECT count(*)
    FROM public.fixture_match_video_failures fail
    JOIN public.competition_fixtures fx ON fx.id = fail.fixture_id
    WHERE fail.pts_adjustment_id IS NOT NULL
      AND public.competition_gpsl_month_sort(fx.gpsl_month) < public.competition_gpsl_month_sort('november')
  )
) AS check;
