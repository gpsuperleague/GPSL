-- A cup tie finishes at the end of its round month plus one (May: none).
-- A new-owner catch-up does not push that deadline out.
-- Safe re-run.

DO $cup_window$
DECLARE
  v_def text;
  v_old text;
  v_new text;
BEGIN
  v_def := replace(pg_get_functiondef(
    'public.match_schedule_fixture_within_play_window(bigint,timestamptz)'::regprocedure
  ), E'\r\n', E'\n');
  IF position('cup window is not extended' IN v_def) = 0 THEN
    v_old := replace($old$  v_owner_through := public.match_schedule_fixture_new_owner_catchup_through_sort(p_fixture_id);
  IF v_owner_through IS NOT NULL AND v_active_sort <= v_owner_through THEN
    RETURN true;
  END IF;
$old$, E'\r\n', E'\n');
    v_new := replace($new$  -- cup window is not extended for a new owner
  IF lower(coalesce(v_f.competition_type, 'league')) <> 'cup' THEN
    v_owner_through := public.match_schedule_fixture_new_owner_catchup_through_sort(p_fixture_id);
    IF v_owner_through IS NOT NULL AND v_active_sort <= v_owner_through THEN
      RETURN true;
    END IF;
  END IF;
$new$, E'\r\n', E'\n');
    IF position(v_old IN v_def) = 0 THEN
      RAISE EXCEPTION 'within play window: new-owner extension not found';
    END IF;
    EXECUTE replace(v_def, v_old, v_new);
  END IF;

  v_def := replace(pg_get_functiondef(
    'public.match_schedule_fixture_play_window_expired(bigint,text)'::regprocedure
  ), E'\r\n', E'\n');
  IF position('cup window is not extended' IN v_def) = 0 THEN
    v_old := replace($old$  v_owner_through := public.match_schedule_fixture_new_owner_catchup_through_sort(p_fixture_id);
  IF v_owner_through IS NOT NULL AND v_closed_sort <= v_owner_through THEN
    RETURN false;
  END IF;
$old$, E'\r\n', E'\n');
    v_new := replace($new$  -- cup window is not extended for a new owner
  IF lower(coalesce(v_f.competition_type, 'league')) <> 'cup' THEN
    v_owner_through := public.match_schedule_fixture_new_owner_catchup_through_sort(p_fixture_id);
    IF v_owner_through IS NOT NULL AND v_closed_sort <= v_owner_through THEN
      RETURN false;
    END IF;
  END IF;
$new$, E'\r\n', E'\n');
    IF position(v_old IN v_def) = 0 THEN
      RAISE EXCEPTION 'play window expired: new-owner extension not found';
    END IF;
    EXECUTE replace(v_def, v_old, v_new);
  END IF;
END;
$cup_window$;

SELECT jsonb_build_object(
  'within', position('cup window is not extended' IN pg_get_functiondef(
    'public.match_schedule_fixture_within_play_window(bigint,timestamptz)'::regprocedure
  )) > 0,
  'expired', position('cup window is not extended' IN pg_get_functiondef(
    'public.match_schedule_fixture_play_window_expired(bigint,text)'::regprocedure
  )) > 0
);
