-- Awarded matches do not need a video, same as a match against a vacant
-- or departed club. Deadline warnings were still listing the awarded ones.
-- Safe re-run.

CREATE OR REPLACE FUNCTION public.competition_fixture_skips_match_video(p_fixture_id bigint)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT coalesce((
    SELECT
      coalesce(f.is_forfeit, false)
      OR EXISTS (
        SELECT 1
        FROM public."Clubs" c
        WHERE upper(btrim(c."ShortName")) IN (
          upper(btrim(f.home_club_short_name)),
          upper(btrim(f.away_club_short_name))
        )
          AND (
            c.owner_id IS NULL
            OR coalesce(c.is_archived, false)
          )
      )
    FROM public.competition_fixtures f
    WHERE f.id = p_fixture_id
  ), false);
$$;

DO $deadlines$
DECLARE
  v_def text;
  v_old text;
  v_new text;
BEGIN
  v_def := replace(
    pg_get_functiondef('public.owner_personal_deadlines(text)'::regprocedure),
    E'\r\n', E'\n'
  );
  v_old := replace($old$        AND f.status = 'played'
        AND coalesce(f.is_void, false) = false
        AND coalesce(f.competition_type, 'league') IN ('league', 'cup')
        AND cal.lock_at IS NOT NULL
        AND v_club IN (upper(btrim(f.home_club_short_name)), upper(btrim(f.away_club_short_name)))
        AND NOT EXISTS (
          SELECT 1
          FROM public.fixture_match_videos v$old$, E'\r\n', E'\n');
  v_new := replace($new$        AND f.status = 'played'
        AND NOT public.competition_fixture_skips_match_video(f.id)
        AND coalesce(f.is_void, false) = false
        AND coalesce(f.competition_type, 'league') IN ('league', 'cup')
        AND cal.lock_at IS NOT NULL
        AND v_club IN (upper(btrim(f.home_club_short_name)), upper(btrim(f.away_club_short_name)))
        AND NOT EXISTS (
          SELECT 1
          FROM public.fixture_match_videos v$new$, E'\r\n', E'\n');
  IF position(v_new IN v_def) > 0 THEN
    RETURN;
  END IF;
  IF (length(v_def) - length(replace(v_def, v_old, ''))) / nullif(length(v_old), 0) <> 1 THEN
    RAISE EXCEPTION 'video deadline needle not unique';
  END IF;
  EXECUTE replace(v_def, v_old, v_new);
END;
$deadlines$;

DO $detail$
DECLARE
  v_def text;
  v_old text := 'The other club is vacant or has left the league';
  v_new text := 'Awarded matches, and matches against a vacant or departed club, do not need a video';
BEGIN
  v_def := replace(
    pg_get_functiondef('public.matchday_checklist_for_club(text,boolean)'::regprocedure),
    E'\r\n', E'\n'
  );
  IF position(v_new IN v_def) > 0 OR position(v_old IN v_def) = 0 THEN
    RETURN;
  END IF;
  EXECUTE replace(v_def, v_old, v_new);
END;
$detail$;

UPDATE public.fixture_match_video_failures fail
SET pts_status = 'cleared',
    pts_cleared_at = coalesce(fail.pts_cleared_at, now())
WHERE fail.pts_status = 'suspended'
  AND public.competition_fixture_skips_match_video(fail.fixture_id);

UPDATE public.competition_inbox i
SET archived_at = coalesce(i.archived_at, now()),
    read_at = coalesce(i.read_at, now())
WHERE i.archived_at IS NULL
  AND i.fixture_id IS NOT NULL
  AND public.competition_fixture_skips_match_video(i.fixture_id)
  AND (
    i.message_type = 'owner_deadline_warning'
    OR i.title ILIKE 'Upload match video%'
    OR i.title ILIKE 'Upload video%'
    OR coalesce(i.body, '') ILIKE '%match video%'
  );

SELECT jsonb_build_object(
  'deadlines_skip', position(
    'competition_fixture_skips_match_video'
    IN pg_get_functiondef('public.owner_personal_deadlines(text)'::regprocedure)
  ) > 0,
  'awarded_skips', public.competition_fixture_skips_match_video(9030),
  'open_video_warnings', (
    SELECT count(*)
    FROM public.competition_inbox i
    WHERE i.archived_at IS NULL
      AND i.fixture_id IS NOT NULL
      AND public.competition_fixture_skips_match_video(i.fixture_id)
      AND (
        i.message_type = 'owner_deadline_warning'
        OR i.title ILIKE 'Upload match video%'
        OR i.title ILIKE 'Upload video%'
      )
  )
);
