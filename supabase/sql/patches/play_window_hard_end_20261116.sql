-- The play month plus its grace is the award point.
-- A new-owner catch-up must not push that into a further month.
-- Holiday still names the loser. It does not move the lock.
-- Safe re-run. Then award the matches the October lock should have closed.

DO $window$
DECLARE
  v_def text;
  v_old text;
BEGIN
  v_def := replace(
    pg_get_functiondef('public.match_schedule_fixture_within_play_window(bigint,timestamptz)'::regprocedure),
    E'\r\n', E'\n'
  );
  IF position('play window is the hard end' IN v_def) = 0 THEN
    v_old := replace($old$  -- cup window is not extended for a new owner
  IF lower(coalesce(v_f.competition_type, 'league')) <> 'cup' THEN
    v_owner_through := public.match_schedule_fixture_new_owner_catchup_through_sort(p_fixture_id);
    IF v_owner_through IS NOT NULL AND v_active_sort <= v_owner_through THEN
      RETURN true;
    END IF;
  END IF;
$old$, E'\r\n', E'\n');
    IF position(v_old IN v_def) = 0 THEN
      RAISE EXCEPTION 'within play window: new-owner block not found';
    END IF;
    EXECUTE replace(v_def, v_old, E'  -- play window is the hard end\n');
  END IF;

  v_def := replace(
    pg_get_functiondef('public.match_schedule_fixture_play_window_expired(bigint,text)'::regprocedure),
    E'\r\n', E'\n'
  );
  IF position('play window is the hard end' IN v_def) = 0 THEN
    v_old := replace($old$  -- cup window is not extended for a new owner
  IF lower(coalesce(v_f.competition_type, 'league')) <> 'cup' THEN
    v_owner_through := public.match_schedule_fixture_new_owner_catchup_through_sort(p_fixture_id);
    IF v_owner_through IS NOT NULL AND v_closed_sort <= v_owner_through THEN
      RETURN false;
    END IF;
  END IF;
$old$, E'\r\n', E'\n');
    IF position(v_old IN v_def) = 0 THEN
      RAISE EXCEPTION 'play window expired: new-owner block not found';
    END IF;
    EXECUTE replace(v_def, v_old, E'  -- play window is the hard end\n');
  END IF;
END;
$window$;

DO $award$
DECLARE
  v_f record;
  v_loser text;
  v_note text;
BEGIN
  FOR v_f IN
    SELECT f.id, f.gpsl_month, f.matchday, f.season_id
    FROM public.competition_fixtures f
    WHERE f.season_id = 1
      AND f.status = 'scheduled'
      AND coalesce(f.competition_type, 'league') IN ('league', 'cup')
      AND public.competition_gpsl_month_sort('october')
          >= public.competition_gpsl_month_sort(f.gpsl_month)
             + public.match_schedule_play_grace_months(f.competition_type, f.gpsl_month)
    ORDER BY f.id
  LOOP
    v_loser := public.match_schedule_pick_window_loser(v_f.season_id, v_f.id, 'october');
    v_note := format(
      'Unplayed after play window · %s MD%s · %s',
      public.competition_gpsl_month_label(v_f.gpsl_month),
      v_f.matchday,
      CASE WHEN v_loser IS NULL THEN 'activity tied → 0–0' ELSE 'awarded on activity' END
    );
    IF v_loser IS NULL THEN
      PERFORM public.fixture_apply_score_draw_0_0(v_f.id, v_note);
    ELSE
      PERFORM public.fixture_apply_forfeit(
        v_f.id, v_loser, 'match_window_expiry', v_note
      );
    END IF;
  END LOOP;
END;
$award$;

SELECT jsonb_build_object(
  'within_hard', position(
    'play window is the hard end'
    IN pg_get_functiondef('public.match_schedule_fixture_within_play_window(bigint,timestamptz)'::regprocedure)
  ) > 0,
  'expired_hard', position(
    'play window is the hard end'
    IN pg_get_functiondef('public.match_schedule_fixture_play_window_expired(bigint,text)'::regprocedure)
  ) > 0,
  'owner_still_in_expired', position(
    'new_owner_catchup_through_sort'
    IN pg_get_functiondef('public.match_schedule_fixture_play_window_expired(bigint,text)'::regprocedure)
  ) > 0,
  'awarded', (
    SELECT coalesce(jsonb_agg(jsonb_build_object(
      'id', f.id,
      'md', f.matchday,
      'home', f.home_club_short_name,
      'away', f.away_club_short_name,
      'hg', f.home_goals,
      'ag', f.away_goals,
      'loser', f.forfeit_loser_club,
      'status', f.status
    ) ORDER BY f.id), '[]'::jsonb)
    FROM public.competition_fixtures f
    WHERE f.id IN (8963, 8974)
  )
);
