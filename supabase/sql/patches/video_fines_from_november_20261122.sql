-- Missing-video money fines and the 1-point deduction start with November.
-- August, September, and October matches stay outside both.
-- Does not refund charges already on the ledger. Does not turn auto-fines on.
-- Safe re-run.

DO $fines$
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
      AND coalesce(f.competition_type, 'league') IN ('league', 'cup')$old$, E'\r\n', E'\n');
  v_new := replace($new$      AND NOT public.competition_fixture_skips_match_video(f.id)
      AND public.competition_gpsl_month_sort(f.gpsl_month) >= public.competition_gpsl_month_sort('november')
      AND coalesce(f.competition_type, 'league') IN ('league', 'cup')$new$, E'\r\n', E'\n');
  IF position(v_new IN v_def) > 0 THEN
    RAISE NOTICE 'missing-video fines already start in November';
    RETURN;
  END IF;
  IF (length(v_def) - length(replace(v_def, v_old, ''))) / nullif(length(v_old), 0) <> 1 THEN
    RAISE EXCEPTION 'missing-video fine month needle not unique';
  END IF;
  EXECUTE replace(v_def, v_old, v_new);
END;
$fines$;

DO $points$
DECLARE
  v_def text;
  v_old text;
  v_new text;
BEGIN
  v_def := replace(
    pg_get_functiondef('public.match_video_process_suspended_points(bigint)'::regprocedure),
    E'\r\n', E'\n'
  );
  v_old := replace($old$      AND fail.pts_status = 'suspended'
      AND fail.pts_suspend_until IS NOT NULL
      AND fail.pts_suspend_until <= now()
      AND NOT EXISTS (
        SELECT 1
        FROM public.fixture_match_videos v
        WHERE v.fixture_id = fail.fixture_id
          AND v.side = fail.side
      )$old$, E'\r\n', E'\n');
  v_new := replace($new$      AND fail.pts_status = 'suspended'
      AND fail.pts_suspend_until IS NOT NULL
      AND fail.pts_suspend_until <= now()
      AND public.competition_gpsl_month_sort(coalesce(nullif(btrim(fail.gpsl_month), ''), f.gpsl_month))
            >= public.competition_gpsl_month_sort('november')
      AND NOT EXISTS (
        SELECT 1
        FROM public.fixture_match_videos v
        WHERE v.fixture_id = fail.fixture_id
          AND v.side = fail.side
      )$new$, E'\r\n', E'\n');
  IF position(v_new IN v_def) > 0 THEN
    RAISE NOTICE 'suspended video points already start in November';
    RETURN;
  END IF;
  IF (length(v_def) - length(replace(v_def, v_old, ''))) / nullif(length(v_old), 0) <> 1 THEN
    RAISE EXCEPTION 'suspended video points month needle not unique';
  END IF;
  EXECUTE replace(v_def, v_old, v_new);
END;
$points$;

SELECT
  position(
    'competition_gpsl_month_sort(''november'')' IN
    replace(pg_get_functiondef('public.match_video_process_missing_fines(bigint)'::regprocedure), E'\r\n', E'\n')
  ) > 0 AS fines_from_november,
  position(
    'competition_gpsl_month_sort(''november'')' IN
    replace(pg_get_functiondef('public.match_video_process_suspended_points(bigint)'::regprocedure), E'\r\n', E'\n')
  ) > 0 AS points_from_november;
