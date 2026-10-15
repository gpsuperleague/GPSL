-- =============================================================================
-- GPSL months stay at Thursday 19:00 UK across the clock change (BST <-> GMT).
--
-- The calendar setter added 7 x 24h to the anchor in UTC, so after the clocks
-- go back every later month boundary landed at 18:00 UK (and 20:00 UK after
-- they go forward in spring).
--
--   1. competition_admin_set_season_calendar: weeks are added in UK local time.
--   2. One-off repair: future unlock_at / lock_at in the current season that sit
--      exactly 1 hour off the season's anchor time (UK) are moved back onto it.
--      Past boundaries and anything deliberately moved to another time are left.
--
-- Safe re-run.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. Calendar setter: add weeks in UK local time
-- ---------------------------------------------------------------------------
DO $fix_setter$
DECLARE
  v_oid oid := to_regprocedure('public.competition_admin_set_season_calendar(bigint,text,boolean)');
  v_src text;
  v_new text;
BEGIN
  IF v_oid IS NULL THEN
    RAISE WARNING 'competition_admin_set_season_calendar(bigint,text,boolean) missing — setter not patched';
    RETURN;
  END IF;

  v_src := pg_get_functiondef(v_oid);
  IF position('v_unlock := (v_uk + ((v_i - 1)' IN v_src) > 0 THEN
    RAISE NOTICE 'Calendar setter already uses UK local time';
    RETURN;
  END IF;

  v_new := v_src;
  v_new := replace(v_new,
    $o$v_unlock := v_anchor + ((v_i - 1) * interval '7 days');$o$,
    $n$v_unlock := (v_uk + ((v_i - 1) * interval '7 days')) AT TIME ZONE 'Europe/London';$n$);
  v_new := replace(v_new,
    $o$v_lock := v_unlock + interval '7 days';$o$,
    $n$v_lock := (v_uk + (v_i * interval '7 days')) AT TIME ZONE 'Europe/London';$n$);
  v_new := replace(v_new,
    $o$v_august := v_anchor + interval '14 days';$o$,
    $n$v_august := (v_uk + interval '14 days') AT TIME ZONE 'Europe/London';$n$);
  v_new := replace(v_new,
    $o$(v_anchor + interval '7 days') AT TIME ZONE 'Europe/London'$o$,
    $n$(v_uk + interval '7 days')$n$);
  v_new := replace(v_new,
    $o$(v_anchor + interval '91 days') AT TIME ZONE 'Europe/London'$o$,
    $n$(v_uk + interval '91 days')$n$);

  IF position('v_unlock := (v_uk + ((v_i - 1)' IN v_new) = 0 THEN
    RAISE WARNING 'Calendar setter: week loop needle not found — patch manually';
    RETURN;
  END IF;

  EXECUTE v_new;
END
$fix_setter$;

-- ---------------------------------------------------------------------------
-- 2. Repair the current season's future boundaries
-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS _cal_dst_before;
CREATE TEMP TABLE _cal_dst_before AS
SELECT cal.season_id, cal.gpsl_month, cal.sort_order, cal.unlock_at, cal.lock_at
FROM public.competition_season_calendar cal
JOIN public.competition_seasons s ON s.id = cal.season_id AND s.is_current = true;

WITH anchor AS (
  SELECT cfg.season_id,
         (cfg.anchor_unlock_at AT TIME ZONE 'Europe/London')::time AS uk_time
  FROM public.competition_season_calendar_config cfg
  JOIN public.competition_seasons s ON s.id = cfg.season_id AND s.is_current = true
)
UPDATE public.competition_season_calendar cal
SET
  unlock_at = CASE
    WHEN cal.unlock_at > now()
     AND abs(extract(epoch FROM ((cal.unlock_at AT TIME ZONE 'Europe/London')::time - a.uk_time))) = 3600
    THEN ((cal.unlock_at AT TIME ZONE 'Europe/London')::date + a.uk_time) AT TIME ZONE 'Europe/London'
    ELSE cal.unlock_at
  END,
  lock_at = CASE
    WHEN cal.lock_at > now()
     AND abs(extract(epoch FROM ((cal.lock_at AT TIME ZONE 'Europe/London')::time - a.uk_time))) = 3600
    THEN ((cal.lock_at AT TIME ZONE 'Europe/London')::date + a.uk_time) AT TIME ZONE 'Europe/London'
    ELSE cal.lock_at
  END
FROM anchor a
WHERE cal.season_id = a.season_id
  AND (
    (cal.unlock_at > now()
     AND abs(extract(epoch FROM ((cal.unlock_at AT TIME ZONE 'Europe/London')::time - a.uk_time))) = 3600)
    OR
    (cal.lock_at > now()
     AND abs(extract(epoch FROM ((cal.lock_at AT TIME ZONE 'Europe/London')::time - a.uk_time))) = 3600)
  );

NOTIFY pgrst, 'reload schema';

-- Report: current season calendar in UK time, before → after
SELECT
  cal.sort_order,
  cal.gpsl_month,
  to_char(b.unlock_at AT TIME ZONE 'Europe/London', 'Dy DD Mon HH24:MI') AS unlock_uk_before,
  to_char(cal.unlock_at AT TIME ZONE 'Europe/London', 'Dy DD Mon HH24:MI') AS unlock_uk_now,
  to_char(b.lock_at AT TIME ZONE 'Europe/London', 'Dy DD Mon HH24:MI') AS lock_uk_before,
  to_char(cal.lock_at AT TIME ZONE 'Europe/London', 'Dy DD Mon HH24:MI') AS lock_uk_now,
  (b.unlock_at IS DISTINCT FROM cal.unlock_at OR b.lock_at IS DISTINCT FROM cal.lock_at) AS changed
FROM public.competition_season_calendar cal
JOIN public.competition_seasons s ON s.id = cal.season_id AND s.is_current = true
LEFT JOIN _cal_dst_before b ON b.season_id = cal.season_id AND b.gpsl_month = cal.gpsl_month
ORDER BY cal.sort_order;
