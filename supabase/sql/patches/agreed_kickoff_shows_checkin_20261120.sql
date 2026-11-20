-- An agreed kick-off is a match they are playing.
-- New-owner grace still hides proposal and reply deadlines.
-- It no longer hides check-in once a kick-off is agreed.

DO $show$
DECLARE
  v_def text;
  v_old text;
  v_new text;
BEGIN
  v_def := replace(
    pg_get_functiondef('public.match_schedule_fixture_deadlines_suppressed_for_club(bigint,text)'::regprocedure),
    E'\r\n', E'\n'
  );
  IF position('agreed kick-off shows check-in' IN v_def) > 0 THEN
    RETURN;
  END IF;

  v_old := replace($old$  SELECT c.owner_assigned_at
  INTO v_assigned
  FROM public."Clubs" c
  WHERE upper(btrim(c."ShortName")) = v_opp
  LIMIT 1;$old$, E'\r\n', E'\n');
  v_new := replace($new$  -- agreed kick-off shows check-in
  IF EXISTS (
    SELECT 1
    FROM public.competition_fixture_schedule s
    WHERE s.fixture_id = p_fixture_id
      AND s.status = 'agreed'
      AND s.agreed_kickoff_at IS NOT NULL
  ) THEN
    RETURN false;
  END IF;

  SELECT c.owner_assigned_at
  INTO v_assigned
  FROM public."Clubs" c
  WHERE upper(btrim(c."ShortName")) = v_opp
  LIMIT 1;$new$, E'\r\n', E'\n');

  IF position(v_old IN v_def) = 0 THEN
    RAISE EXCEPTION 'grace suppress: owner lookup not found';
  END IF;
  IF (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 THEN
    RAISE EXCEPTION 'grace suppress: owner lookup is not unique';
  END IF;
  EXECUTE replace(v_def, v_old, v_new);
END;
$show$;

SELECT jsonb_build_object(
  'wired', position(
    'agreed kick-off shows check-in' IN pg_get_functiondef(
      'public.match_schedule_fixture_deadlines_suppressed_for_club(bigint,text)'::regprocedure
    )
  ) > 0,
  'jub_hidden', public.match_schedule_fixture_deadlines_suppressed_for_club(9081, 'JUB'),
  'cvi_hidden', public.match_schedule_fixture_deadlines_suppressed_for_club(9081, 'CVI'),
  'now_showing', (
    SELECT coalesce(jsonb_agg(jsonb_build_object(
      'id', f.id,
      'md', f.matchday,
      'month', f.gpsl_month,
      'home', f.home_club_short_name,
      'away', f.away_club_short_name,
      'ko_uk', to_char(s.agreed_kickoff_at AT TIME ZONE 'Europe/London', 'Dy DD Mon HH24:MI')
    ) ORDER BY s.agreed_kickoff_at, f.id), '[]'::jsonb)
    FROM public.competition_fixtures f
    JOIN public.competition_fixture_schedule s ON s.fixture_id = f.id
    JOIN public.competition_seasons sea ON sea.id = f.season_id AND sea.is_current
    WHERE f.status = 'scheduled'
      AND s.status = 'agreed'
      AND s.agreed_kickoff_at IS NOT NULL
      AND s.agreed_kickoff_at > now() - interval '6 hours'
      AND EXISTS (
        SELECT 1
        FROM public."Clubs" opp
        JOIN public.competition_season_calendar cal
          ON cal.season_id = f.season_id
         AND lower(btrim(cal.gpsl_month)) = lower(btrim(f.gpsl_month))
        WHERE opp."ShortName" IN (f.home_club_short_name, f.away_club_short_name)
          AND opp.owner_assigned_at IS NOT NULL
          AND opp.owner_assigned_at >= cal.unlock_at
          AND (cal.lock_at IS NULL OR opp.owner_assigned_at <= cal.lock_at)
      )
  )
);
