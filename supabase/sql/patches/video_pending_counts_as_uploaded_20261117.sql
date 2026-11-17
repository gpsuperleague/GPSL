-- A video parked until the result is confirmed is already uploaded.
-- Do not chase or fine that club. The club that has not confirmed the result
-- stays on the result chase.

CREATE OR REPLACE FUNCTION public.club_side_video_is_in(p_fixture_id bigint, p_side text)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.fixture_match_videos v
    WHERE v.fixture_id = p_fixture_id
      AND v.side = p_side
  )
  OR EXISTS (
    SELECT 1
    FROM public.fixture_match_video_pending p
    WHERE p.fixture_id = p_fixture_id
      AND p.side = p_side
  );
$$;

REVOKE ALL ON FUNCTION public.club_side_video_is_in(bigint, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.club_side_video_is_in(bigint, text) TO authenticated, service_role;

DO $wire$
DECLARE
  v_def text;
  v_old text;
  v_new text;
BEGIN
  v_def := replace(pg_get_functiondef('public.club_wire_cutoffs()'::regprocedure), E'\r\n', E'\n');

  v_old := replace($old$      EXISTS (
        SELECT 1
        FROM public.fixture_match_videos v
        WHERE v.fixture_id = f.id
          AND v.side = CASE
            WHEN upper(btrim(f.home_club_short_name)) = v_club THEN 'home'
            ELSE 'away'
          END
      ) AS has_video$old$, E'\r\n', E'\n');
  v_new := replace($new$      public.club_side_video_is_in(
        f.id,
        CASE
          WHEN upper(btrim(f.home_club_short_name)) = v_club THEN 'home'
          ELSE 'away'
        END
      ) AS has_video$new$, E'\r\n', E'\n');
  IF position(v_new IN v_def) = 0 THEN
    IF (length(v_def) - length(replace(v_def, v_old, ''))) / nullif(length(v_old), 0) <> 1 THEN
      RAISE EXCEPTION 'wire has_video needle not unique';
    END IF;
    v_def := replace(v_def, v_old, v_new);
  END IF;

  v_old := replace($old$      AND NOT EXISTS (
        SELECT 1
        FROM public.fixture_match_videos v
        WHERE v.fixture_id = f.id
          AND v.side = CASE
            WHEN upper(btrim(f.home_club_short_name)) = v_club THEN 'home'
            ELSE 'away'
          END
      )$old$, E'\r\n', E'\n');
  v_new := replace($new$      AND NOT public.club_side_video_is_in(
        f.id,
        CASE
          WHEN upper(btrim(f.home_club_short_name)) = v_club THEN 'home'
          ELSE 'away'
        END
      )$new$, E'\r\n', E'\n');
  IF position(v_new IN v_def) = 0 THEN
    IF (length(v_def) - length(replace(v_def, v_old, ''))) / nullif(length(v_old), 0) <> 1 THEN
      RAISE EXCEPTION 'wire played-video needle not unique';
    END IF;
    v_def := replace(v_def, v_old, v_new);
  END IF;

  EXECUTE v_def;
END;
$wire$;

DO $fine$
DECLARE
  v_def text;
  v_old text;
  v_new text;
BEGIN
  v_def := replace(pg_get_functiondef('public.match_video_process_missing_fines(bigint)'::regprocedure), E'\r\n', E'\n');
  v_old := replace($old$      AND NOT EXISTS (
        SELECT 1
        FROM public.fixture_match_videos v
        WHERE v.fixture_id = f.id
          AND v.side = side.side
      )$old$, E'\r\n', E'\n');
  v_new := replace($new$      AND NOT public.club_side_video_is_in(f.id, side.side)$new$, E'\r\n', E'\n');
  IF position(v_new IN v_def) > 0 THEN
    RETURN;
  END IF;
  IF (length(v_def) - length(replace(v_def, v_old, ''))) / nullif(length(v_old), 0) <> 1 THEN
    RAISE EXCEPTION 'video fine needle not unique';
  END IF;
  EXECUTE replace(v_def, v_old, v_new);
END;
$fine$;

DO $cal$
DECLARE
  v_def text;
  v_old text;
  v_new text;
BEGIN
  v_def := replace(pg_get_functiondef('public.owner_personal_deadlines(text)'::regprocedure), E'\r\n', E'\n');
  v_old := replace($old$        AND NOT EXISTS (
          SELECT 1
          FROM public.fixture_match_videos v
          WHERE v.fixture_id = f.id
            AND v.side = CASE
              WHEN upper(btrim(f.home_club_short_name)) = v_club THEN 'home'
              ELSE 'away'
            END
        )$old$, E'\r\n', E'\n');
  v_new := replace($new$        AND NOT public.club_side_video_is_in(
          f.id,
          CASE
            WHEN upper(btrim(f.home_club_short_name)) = v_club THEN 'home'
            ELSE 'away'
          END
        )$new$, E'\r\n', E'\n');
  IF position(v_new IN v_def) > 0 THEN
    RETURN;
  END IF;
  IF (length(v_def) - length(replace(v_def, v_old, ''))) / nullif(length(v_old), 0) <> 1 THEN
    RAISE EXCEPTION 'calendar video needle not unique';
  END IF;
  EXECUTE replace(v_def, v_old, v_new);
END;
$cal$;

DO $check$
DECLARE
  v_def text;
  v_old text;
  v_new text;
BEGIN
  v_def := replace(pg_get_functiondef('public.matchday_checklist_for_club(text,boolean)'::regprocedure), E'\r\n', E'\n');
  v_old := replace($old$    IF FOUND THEN
      v_step := jsonb_build_object('key', 'video', 'label', 'Match video uploaded', 'state', 'done',
        'detail', CASE WHEN coalesce(v_video.credited_amount, 0) > 0 THEN '+₿' || to_char(v_video.credited_amount, 'FM999,999,999') || ' credited' END);
    ELSE$old$, E'\r\n', E'\n');
  v_new := replace($new$    IF FOUND THEN
      v_step := jsonb_build_object('key', 'video', 'label', 'Match video uploaded', 'state', 'done',
        'detail', CASE WHEN coalesce(v_video.credited_amount, 0) > 0 THEN '+₿' || to_char(v_video.credited_amount, 'FM999,999,999') || ' credited' END);
    ELSIF EXISTS (
      SELECT 1
      FROM public.fixture_match_video_pending p
      WHERE p.fixture_id = r.id
        AND p.side = v_side
    ) THEN
      v_step := jsonb_build_object(
        'key', 'video',
        'label', 'Match video uploaded',
        'state', 'done',
        'detail', 'Waiting for the result to be confirmed'
      );
    ELSE$new$, E'\r\n', E'\n');
  IF position('Waiting for the result to be confirmed' IN v_def) = 0 THEN
    IF (length(v_def) - length(replace(v_def, v_old, ''))) / nullif(length(v_old), 0) <> 1 THEN
      RAISE EXCEPTION 'checklist video needle not unique';
    END IF;
    EXECUTE replace(v_def, v_old, v_new);
  END IF;
END;
$check$;

NOTIFY pgrst, 'reload schema';

SELECT jsonb_build_object(
  'juv_video_in', public.club_side_video_is_in(9029, 'away'),
  'cor_video_in', public.club_side_video_is_in(9029, 'home'),
  'wire', position('club_side_video_is_in' IN pg_get_functiondef('public.club_wire_cutoffs()'::regprocedure)) > 0,
  'fine', position('club_side_video_is_in' IN pg_get_functiondef('public.match_video_process_missing_fines(bigint)'::regprocedure)) > 0,
  'calendar', position('club_side_video_is_in' IN pg_get_functiondef('public.owner_personal_deadlines(text)'::regprocedure)) > 0,
  'checklist', position('Waiting for the result to be confirmed' IN pg_get_functiondef('public.matchday_checklist_for_club(text,boolean)'::regprocedure)) > 0
) AS info;
