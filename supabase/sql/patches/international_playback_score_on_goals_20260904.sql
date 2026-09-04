-- =============================================================================
-- Intl playback: include running score_home / score_away on goal events
-- (UI already increments by side when these are missing; this keeps parity
-- with club match sim playback.)
-- Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.match_sim_build_intl_playback(
  p_home_name text,
  p_away_name text,
  p_home_goals int,
  p_away_goals int,
  p_duration_sec int DEFAULT 20
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
AS $function$
DECLARE
  v_dur numeric := greatest(8, least(60, coalesce(p_duration_sec, 20)))::numeric;
  v_events jsonb := '[]'::jsonb;
  v_i int;
  v_t numeric;
  v_hg int := 0;
  v_ag int := 0;
  r record;
BEGIN
  v_events := v_events || jsonb_build_array(jsonb_build_object(
    't', 0, 'type', 'kickoff', 'side', null, 'text', 'Kick-off', 'minute', 1
  ));

  -- Build goal moments, then emit in time order with running score
  CREATE TEMP TABLE IF NOT EXISTS _intl_pb_goals (
    t numeric,
    side text,
    minute int
  ) ON COMMIT DROP;
  DELETE FROM _intl_pb_goals;

  FOR v_i IN 1..greatest(coalesce(p_home_goals, 0), 0) LOOP
    v_t := round((v_dur * (0.12 + 0.7 * v_i / greatest(p_home_goals + p_away_goals, 1)))::numeric, 2);
    INSERT INTO _intl_pb_goals (t, side, minute)
    VALUES (v_t, 'home', least(90, 8 + v_i * 11));
  END LOOP;

  FOR v_i IN 1..greatest(coalesce(p_away_goals, 0), 0) LOOP
    v_t := round((v_dur * (0.18 + 0.7 * v_i / greatest(p_home_goals + p_away_goals, 1)))::numeric, 2);
    INSERT INTO _intl_pb_goals (t, side, minute)
    VALUES (v_t, 'away', least(90, 10 + v_i * 12));
  END LOOP;

  FOR r IN
    SELECT g.t, g.side, g.minute
    FROM _intl_pb_goals g
    ORDER BY g.t, g.side
  LOOP
    IF r.side = 'home' THEN
      v_hg := v_hg + 1;
    ELSE
      v_ag := v_ag + 1;
    END IF;
    v_events := v_events || jsonb_build_array(jsonb_build_object(
      't', r.t,
      'type', 'goal',
      'side', r.side,
      'text', CASE
        WHEN r.side = 'home' THEN coalesce(p_home_name, 'Home') || ' score!'
        ELSE coalesce(p_away_name, 'Away') || ' score!'
      END,
      'minute', r.minute,
      'score_home', v_hg,
      'score_away', v_ag
    ));
  END LOOP;

  v_events := v_events || jsonb_build_array(jsonb_build_object(
    't', v_dur, 'type', 'fulltime', 'side', null,
    'text', format('FT %s–%s', coalesce(p_home_goals, 0), coalesce(p_away_goals, 0)),
    'minute', 90,
    'score_home', coalesce(p_home_goals, 0),
    'score_away', coalesce(p_away_goals, 0)
  ));

  RETURN jsonb_build_object(
    'duration_sec', v_dur,
    'events', v_events,
    'home_name', p_home_name,
    'away_name', p_away_name
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.match_sim_build_intl_playback(text, text, int, int, int) TO authenticated;

NOTIFY pgrst, 'reload schema';
