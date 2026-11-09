-- =============================================================================
-- No match-video fine or points note for a match against an empty club
--
-- A walkover is stored as played, so the video check treated the owned club
-- as missing a video. Ease-in waived the money and the points, but the owner
-- still got the inbox notes (MD4 vs Atletico Madrid, MD7 vs Danubio).
--
-- Skip those fixtures from now on. Clear the assessments already stored so
-- they cannot become a real fine or a point when the switches turn on.
-- Archive the inbox notes already sent for them.
--
-- Run once in the Supabase SQL editor. Safe re-run.
-- =============================================================================

DO $gate$
DECLARE
  v_oid oid;
  v_def text;
  v_new text;
  v_pos int;
BEGIN
  v_oid := to_regprocedure('public.match_video_process_missing_fines(bigint)');
  IF v_oid IS NULL THEN
    RAISE EXCEPTION 'match_video_process_missing_fines missing';
  END IF;

  v_def := pg_get_functiondef(v_oid);
  IF position('competition_fixture_involves_vacant_club' IN v_def) > 0 THEN
    RAISE NOTICE 'video fines already skip vacant fixtures';
    RETURN;
  END IF;

  -- Live body whitespace varies (indent, CRLF). Match the played test only.
  IF v_def !~ 'f\.status[[:space:]]*=[[:space:]]*''played''' THEN
    v_pos := position('played' IN lower(v_def));
    RAISE EXCEPTION 'Could not find f.status = played. Nearby: %',
      substring(v_def FROM greatest(v_pos - 60, 1) FOR 180);
  END IF;

  v_new := regexp_replace(
    v_def,
    'f\.status[[:space:]]*=[[:space:]]*''played''',
    E'f.status = ''played''\n'
      || E'      AND coalesce(f.is_forfeit, false) = false\n'
      || E'      AND NOT public.competition_fixture_involves_vacant_club(f.id)'
  );

  IF v_new = v_def THEN
    RAISE EXCEPTION 'Video-fine filter was not changed';
  END IF;

  EXECUTE v_new;
  RAISE NOTICE 'video fines skip forfeits and vacant-club matches';
END;
$gate$;

-- Drop assessments that would charge later. No money was taken during ease-in.
DELETE FROM public.fixture_match_video_failures fail
WHERE EXISTS (
  SELECT 1
  FROM public.competition_fixtures f
  WHERE f.id = fail.fixture_id
    AND (
      coalesce(f.is_forfeit, false)
      OR public.competition_fixture_involves_vacant_club(f.id)
    )
);

-- Take those notes out of the inbox.
UPDATE public.competition_inbox i
SET
  archived_at = coalesce(i.archived_at, now()),
  read_at = coalesce(i.read_at, now())
WHERE i.archived_at IS NULL
  AND (
    i.dedupe_key LIKE 'mv_pts_suspend:%'
    OR i.message_type IN ('fine_applied', 'points_deduction')
    OR coalesce(i.title, '') ILIKE '%match video%'
    OR coalesce(i.body, '') ILIKE '%match video%'
  )
  AND EXISTS (
    SELECT 1
    FROM public.competition_fixtures f
    WHERE f.id = i.fixture_id
      AND (
        coalesce(f.is_forfeit, false)
        OR public.competition_fixture_involves_vacant_club(f.id)
      )
  );

NOTIFY pgrst, 'reload schema';
