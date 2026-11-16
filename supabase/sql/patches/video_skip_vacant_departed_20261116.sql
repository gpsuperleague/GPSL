-- A match against a vacant club, or a club whose owner has left, does not need a video.
-- Vacant and archived (owner removed) both qualify. The other club is not asked,
-- and Club Wire does not list a deadline.

CREATE OR REPLACE FUNCTION public.competition_fixture_skips_match_video(p_fixture_id bigint)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT coalesce((
    SELECT EXISTS (
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

REVOKE ALL ON FUNCTION public.competition_fixture_skips_match_video(bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.competition_fixture_skips_match_video(bigint)
  TO authenticated, service_role;

DO $checklist$
DECLARE
  v_def text;
  v_old_start text := $old$    -- 7. Match video
    v_filename := public.matchday_checklist_video_filename(r.id);$old$;
  v_new_start text := $new$    -- 7. Match video
    IF public.competition_fixture_skips_match_video(r.id) THEN
      v_step := jsonb_build_object(
        'key', 'video',
        'label', 'No video required',
        'state', 'na',
        'detail', 'The other club is vacant or has left the league'
      );
    ELSE
    v_filename := public.matchday_checklist_video_filename(r.id);$new$;
  v_old_end text := $old$    END IF;
    v_steps := v_steps || jsonb_build_array(v_step);

    -- Fixture flags$old$;
  v_new_end text := $new$    END IF;
    END IF;
    v_steps := v_steps || jsonb_build_array(v_step);

    -- Fixture flags$new$;
BEGIN
  v_def := replace(
    pg_get_functiondef('public.matchday_checklist_for_club(text,boolean)'::regprocedure),
    E'\r\n',
    E'\n'
  );
  v_old_start := replace(v_old_start, E'\r\n', E'\n');
  v_new_start := replace(v_new_start, E'\r\n', E'\n');
  v_old_end := replace(v_old_end, E'\r\n', E'\n');
  v_new_end := replace(v_new_end, E'\r\n', E'\n');
  IF position('competition_fixture_skips_match_video' IN v_def) > 0 THEN
    RETURN;
  END IF;
  IF position(v_old_start IN v_def) = 0 THEN
    RAISE EXCEPTION 'checklist video start not found';
  END IF;
  IF position(v_old_end IN v_def) = 0 THEN
    RAISE EXCEPTION 'checklist video end not found';
  END IF;
  v_def := replace(v_def, v_old_start, v_new_start);
  v_def := replace(v_def, v_old_end, v_new_end);
  EXECUTE v_def;
END;
$checklist$;

DO $wire$
DECLARE
  v_def text;
  v_old text := $old$      AND f.status = 'played'
      AND coalesce(f.competition_type, 'league') IN ('league', 'cup')
      AND nullif(btrim(f.gpsl_month), '') IS NOT NULL
      AND cal.lock_at IS NOT NULL
      AND v_club IN (upper(btrim(f.home_club_short_name)), upper(btrim(f.away_club_short_name)))
      AND NOT EXISTS (
        SELECT 1
        FROM public.fixture_match_videos v$old$;
  v_new text := $new$      AND f.status = 'played'
      AND NOT public.competition_fixture_skips_match_video(f.id)
      AND coalesce(f.competition_type, 'league') IN ('league', 'cup')
      AND nullif(btrim(f.gpsl_month), '') IS NOT NULL
      AND cal.lock_at IS NOT NULL
      AND v_club IN (upper(btrim(f.home_club_short_name)), upper(btrim(f.away_club_short_name)))
      AND NOT EXISTS (
        SELECT 1
        FROM public.fixture_match_videos v$new$;
BEGIN
  v_def := replace(pg_get_functiondef('public.club_wire_cutoffs()'::regprocedure), E'\r\n', E'\n');
  v_old := replace(v_old, E'\r\n', E'\n');
  v_new := replace(v_new, E'\r\n', E'\n');
  IF position('competition_fixture_skips_match_video' IN v_def) > 0 THEN
    RETURN;
  END IF;
  IF position(v_old IN v_def) = 0 THEN
    RAISE EXCEPTION 'club wire video filter not found';
  END IF;
  EXECUTE replace(v_def, v_old, v_new);
END;
$wire$;

DO $fines$
DECLARE
  v_def text;
  v_old text := 'AND NOT public.competition_fixture_involves_vacant_club(f.id)';
  v_new text := 'AND NOT public.competition_fixture_involves_vacant_club(f.id)'
    || E'\n      AND NOT public.competition_fixture_skips_match_video(f.id)';
BEGIN
  v_def := replace(
    pg_get_functiondef('public.match_video_process_missing_fines(bigint)'::regprocedure),
    E'\r\n',
    E'\n'
  );
  IF position('competition_fixture_skips_match_video' IN v_def) > 0 THEN
    RETURN;
  END IF;
  IF position(v_old IN v_def) = 0 THEN
    RAISE EXCEPTION 'missing-video vacant skip not found';
  END IF;
  EXECUTE replace(v_def, v_old, v_new);
END;
$fines$;

UPDATE public.fixture_match_video_failures fail
SET pts_status = 'cleared'
WHERE fail.pts_status = 'suspended'
  AND public.competition_fixture_skips_match_video(fail.fixture_id);

NOTIFY pgrst, 'reload schema';

SELECT
  to_regprocedure('public.competition_fixture_skips_match_video(bigint)') IS NOT NULL AS skip_fn,
  position(
    'competition_fixture_skips_match_video'
    IN pg_get_functiondef('public.matchday_checklist_for_club(text,boolean)'::regprocedure)
  ) > 0 AS checklist_skips,
  position(
    'competition_fixture_skips_match_video'
    IN pg_get_functiondef('public.club_wire_cutoffs()'::regprocedure)
  ) > 0 AS wire_skips,
  position(
    'competition_fixture_skips_match_video'
    IN pg_get_functiondef('public.match_video_process_missing_fines(bigint)'::regprocedure)
  ) > 0 AS fines_skip;
