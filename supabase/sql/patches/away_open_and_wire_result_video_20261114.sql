-- Away can open a kick-off once the arrange month has locked and nothing
-- is currently proposed. The schedule page was still home-only, so the
-- button stayed off after a holiday even though the save would accept it.
-- A cleared arrangement no longer counts as home having proposed.
--
-- Club Wire: one card for the result deadline, and the video on that same
-- card when it is still missing. A played match whose score is already in
-- keeps its own video card, and that card stays up longer than two days.

CREATE OR REPLACE FUNCTION public.match_schedule_away_may_open_proposal(p_fixture_id bigint)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_f public.competition_fixtures;
  v_play int;
  v_lock timestamptz;
BEGIN
  SELECT * INTO v_f FROM public.competition_fixtures WHERE id = p_fixture_id;
  IF NOT FOUND OR v_f.status IS DISTINCT FROM 'scheduled' THEN
    RETURN false;
  END IF;
  IF to_regprocedure('public.fixture_is_manual_black_box(bigint)') IS NOT NULL
     AND public.fixture_is_manual_black_box(p_fixture_id) THEN
    RETURN false;
  END IF;
  IF to_regprocedure('public.competition_fixture_involves_vacant_club(bigint)') IS NOT NULL
     AND public.competition_fixture_involves_vacant_club(p_fixture_id) THEN
    RETURN false;
  END IF;
  -- A live proposal is home's. An old accepted or superseded one, after the
  -- kick-off was cleared, does not keep away from opening the match again.
  IF EXISTS (
    SELECT 1
    FROM public.competition_fixture_schedule_proposal p
    WHERE p.fixture_id = p_fixture_id
      AND p.proposed_by_club_short_name = v_f.home_club_short_name
      AND p.status = 'pending'
  ) THEN
    RETURN false;
  END IF;

  v_play := public.competition_gpsl_month_sort(v_f.gpsl_month);

  IF lower(coalesce(v_f.competition_type, 'league')) = 'cup' THEN
    SELECT c.lock_at INTO v_lock
    FROM public.competition_season_calendar c
    WHERE c.season_id = v_f.season_id
      AND public.competition_gpsl_month_sort(c.gpsl_month) = v_play
    ORDER BY c.lock_at
    LIMIT 1;
    RETURN v_lock IS NOT NULL AND v_lock <= now();
  END IF;

  SELECT c.lock_at INTO v_lock
  FROM public.competition_season_calendar c
  WHERE c.season_id = v_f.season_id
    AND public.competition_gpsl_month_sort(c.gpsl_month) = v_play - 1
  ORDER BY c.lock_at
  LIMIT 1;

  RETURN v_lock IS NOT NULL AND v_lock <= now();
END;
$function$;

DO $ctx$
DECLARE
  v_def text;
  v_old text;
  v_new text;
BEGIN
  v_def := replace(pg_get_functiondef(
    'public.match_schedule_fixture_context(bigint)'::regprocedure
  ), E'\r\n', E'\n');

  IF position('v_role = ''away''' IN substring(v_def FROM position('can_propose_first' IN v_def) FOR 500)) > 0 THEN
    RAISE NOTICE 'context already lets away open';
    RETURN;
  END IF;

  v_old := replace($old$(v_role = 'home' OR public.match_schedule_club_opened_reschedule(p_fixture_id, v_club))
      AND v_status = 'unscheduled' AND v_fixture.status = 'scheduled' AND v_has_mgr$old$, E'\r\n', E'\n');
  v_new := replace($new$(
        v_role = 'home'
        OR public.match_schedule_club_opened_reschedule(p_fixture_id, v_club)
        OR (
          v_role = 'away'
          AND public.match_schedule_away_may_open_proposal(p_fixture_id)
        )
      )
      AND v_status = 'unscheduled' AND v_fixture.status = 'scheduled' AND v_has_mgr$new$, E'\r\n', E'\n');

  IF position(v_old IN v_def) = 0 THEN
    RAISE EXCEPTION 'context: can_propose_first gate not found';
  END IF;
  EXECUTE replace(v_def, v_old, v_new);
END;
$ctx$;

DO $wire$
DECLARE
  v_def text;
  v_old text;
  v_new text;
BEGIN
  v_def := replace(pg_get_functiondef(
    'public.club_wire_cutoffs()'::regprocedure
  ), E'\r\n', E'\n');

  IF position('Result and video, one card' IN v_def) = 0 THEN
    v_old := replace($old$  -- ---------------------------------------------------------------------------
  -- Match video upload deadlines (month lock + grace hours)
  -- ---------------------------------------------------------------------------
  FOR r IN$old$, E'\r\n', E'\n');
    v_new := replace($new$  -- Result and video, one card. Kick-off has passed and the score is still open.
  -- The video sits on that same card when this club has not uploaded it.
  FOR r IN
    SELECT
      f.id,
      f.status AS fx_status,
      CASE
        WHEN upper(btrim(f.home_club_short_name)) = v_club
          THEN coalesce(public.club_display_name(f.away_club_short_name), f.away_club_short_name)
        ELSE coalesce(public.club_display_name(f.home_club_short_name), f.home_club_short_name)
      END AS opp,
      public.match_video_play_at(f.id) AS play_at,
      public.match_video_due_lock_at(f.id) AS due_lock,
      public.match_result_is_confirmed(f.id) AS confirmed,
      (
        SELECT upper(btrim(s.submitted_by_club))
        FROM public.competition_result_submissions s
        WHERE s.fixture_id = f.id
          AND s.status = 'pending'
        ORDER BY s.id DESC
        LIMIT 1
      ) AS entered_by,
      EXISTS (
        SELECT 1
        FROM public.fixture_match_videos v
        WHERE v.fixture_id = f.id
          AND v.side = CASE
            WHEN upper(btrim(f.home_club_short_name)) = v_club THEN 'home'
            ELSE 'away'
          END
      ) AS has_video
    FROM public.competition_fixtures f
    WHERE f.season_id = v_season
      AND f.status IN ('scheduled', 'played')
      AND coalesce(f.is_forfeit, false) = false
      AND coalesce(f.is_void, false) = false
      AND coalesce(f.competition_type, 'league') IN ('league', 'cup')
      AND v_club IN (
        upper(btrim(f.home_club_short_name)),
        upper(btrim(f.away_club_short_name))
      )
  LOOP
    IF r.play_at IS NULL OR r.due_lock IS NULL OR r.play_at > now() THEN
      CONTINUE;
    END IF;

    v_at := r.due_lock + make_interval(hours => v_video_grace);
    v_closes := v_at + interval '24 hours';

    IF r.confirmed OR r.entered_by = v_club THEN
      IF r.has_video OR r.fx_status = 'played' OR r.confirmed THEN
        CONTINUE;
      END IF;
      v_kind := 'video';
      v_title := format('Upload match video vs %s', r.opp);
      v_detail := 'Your score is in. Upload the match video by this time. The upload credit is ₿200,000.';
    ELSIF r.has_video THEN
      v_kind := 'result_enter';
      IF r.entered_by IS NOT NULL THEN
        v_title := format('Confirm result vs %s', r.opp);
        v_detail := 'Your opponent has entered a score. Confirm it by this time or it is ₿500,000, then 24 hours.';
      ELSE
        v_title := format('Enter result vs %s', r.opp);
        v_detail := 'Enter the score by this time. ₿500,000 if it is still not in, then 24 hours to finish it.';
      END IF;
    ELSE
      v_kind := 'result_enter';
      IF r.entered_by IS NOT NULL THEN
        v_title := format('Confirm result and video vs %s', r.opp);
        v_detail := 'Your opponent has entered a score. Confirm it and upload your match video by this time. A missing confirmation is ₿500,000. The video credit is ₿200,000.';
      ELSE
        v_title := format('Result and video vs %s', r.opp);
        v_detail := 'Enter the score and upload your match video by this time. A missing result is ₿500,000, then 24 hours to finish it. The video is due at the same time (₿200,000 for the upload).';
      END IF;
    END IF;

    IF now() >= v_at AND now() < v_closes THEN
      v_at := v_closes;
      v_detail := 'The first deadline has passed. ' || v_detail;
      v_sev := 'urgent';
    ELSIF now() >= v_closes THEN
      IF v_closes < now() - interval '21 days' THEN
        CONTINUE;
      END IF;
      v_at := v_closes;
      v_detail := 'Overdue. ' || v_detail;
      v_sev := 'urgent';
    ELSIF v_at > now() + interval '90 days' THEN
      CONTINUE;
    ELSE
      v_sev := CASE
        WHEN v_at <= now() + interval '48 hours' THEN 'warn'
        ELSE 'info'
      END;
    END IF;

    v_href := 'matchday.html?fixture=' || r.id::text;
    v_out := v_out || jsonb_build_array(jsonb_build_object(
      'id', v_kind || ':' || r.id::text,
      'kind', v_kind,
      'at', v_at,
      'title', v_title,
      'detail', v_detail,
      'severity', v_sev,
      'href', v_href,
      'fixture_id', r.id
    ));
  END LOOP;

  -- ---------------------------------------------------------------------------
  -- Match video upload deadlines (month lock + grace hours)
  -- ---------------------------------------------------------------------------
  FOR r IN$new$, E'\r\n', E'\n');

    IF position(v_old IN v_def) = 0 THEN
      RAISE EXCEPTION 'club wire: video section not found';
    END IF;
    v_def := replace(v_def, v_old, v_new);
  END IF;

  v_old := replace($old$      AND f.status = 'played'
      AND coalesce(f.competition_type, 'league') IN ('league', 'cup')$old$, E'\r\n', E'\n');
  v_new := replace($new$      AND f.status = 'played'
      AND public.match_result_is_confirmed(f.id)
      AND coalesce(f.competition_type, 'league') IN ('league', 'cup')$new$, E'\r\n', E'\n');
  IF position('match_result_is_confirmed(f.id)' IN v_def) = 0 THEN
    IF position(v_old IN v_def) = 0 THEN
      RAISE EXCEPTION 'club wire: played-video filter not found';
    END IF;
    v_def := replace(v_def, v_old, v_new);
  END IF;

  v_def := replace(
    v_def,
    'make_interval(hours => v_video_grace)' || E'\n' || '                <= now() + interval ''14 days''',
    'make_interval(hours => v_video_grace)' || E'\n' || '                <= now() + interval ''45 days'''
  );
  v_def := replace(
    v_def,
    'make_interval(hours => v_video_grace)' || E'\n' || '                > now() - interval ''2 days''',
    'make_interval(hours => v_video_grace)' || E'\n' || '                > now() - interval ''21 days'''
  );

  EXECUTE v_def;
END;
$wire$;

SELECT jsonb_build_object(
  'away_pending_only', position('p.status = ''pending''' IN replace(pg_get_functiondef(
    'public.match_schedule_away_may_open_proposal(bigint)'::regprocedure
  ), E'\r\n', E'\n')) > 0,
  'context_away', position('v_role = ''away''' IN substring(replace(pg_get_functiondef(
    'public.match_schedule_fixture_context(bigint)'::regprocedure
  ), E'\r\n', E'\n') FROM position('can_propose_first' IN replace(pg_get_functiondef(
    'public.match_schedule_fixture_context(bigint)'::regprocedure
  ), E'\r\n', E'\n')) FOR 600)) > 0,
  'wire_combined', position('Result and video, one card' IN replace(pg_get_functiondef(
    'public.club_wire_cutoffs()'::regprocedure
  ), E'\r\n', E'\n')) > 0,
  'jub_may_open_9017', public.match_schedule_away_may_open_proposal(9017),
  'lev_may_open_9378', public.match_schedule_away_may_open_proposal(9378)
);
