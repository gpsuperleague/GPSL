-- Once a league month is open and home never proposed, the away club
-- can propose. Club Wire was only saying the match was still unplayed.

DO $wire$
DECLARE
  v_def text;
  v_old text;
  v_new text;
BEGIN
  v_def := replace(pg_get_functiondef(
    'public.club_wire_cutoffs()'::regprocedure
  ), E'\r\n', E'\n');

  IF position('You can propose one now.' IN v_def) > 0 THEN
    RAISE NOTICE 'away propose wire copy already present';
    RETURN;
  END IF;

  v_old := replace($old$        'kind', CASE WHEN v_state = 'propose' THEN 'propose' ELSE 'play_window' END,
        'at', coalesce(r.response_due_at, now()),
        'title', CASE
          WHEN v_state = 'propose' THEN format('Propose vs %s', v_opp)
          WHEN v_state = 'waiting' THEN format('Reply pending vs %s', v_opp)
          ELSE format('Still unplayed vs %s', v_opp)
        END,
        'detail', CASE
          WHEN v_state = 'propose' THEN 'This GPSL month has opened and the match has not been played or awarded. ' || CASE WHEN lower(coalesce(r.competition_type, '')) = 'cup' THEN 'Either club can propose the kick-off. If nobody does, the strike stays with the home club.' ELSE 'Home still has to propose.' END
          WHEN v_state = 'waiting' THEN 'This GPSL month has opened and the match has not been played or awarded. Waiting on the other club to reply.'
          ELSE 'This GPSL month has opened and the match has not been played or awarded.'
        END,$old$, E'\r\n', E'\n');

  v_new := replace($new$        'kind', CASE
          WHEN v_state = 'propose' THEN 'propose'
          WHEN v_state = 'waiting_home'
               AND v_side = 'away'
               AND lower(coalesce(r.competition_type, 'league')) <> 'cup'
               AND NOT v_home_proposed
            THEN 'propose'
          ELSE 'play_window'
        END,
        'at', coalesce(r.response_due_at, now()),
        'title', CASE
          WHEN v_state = 'propose' THEN format('Propose vs %s', v_opp)
          WHEN v_state = 'waiting' THEN format('Reply pending vs %s', v_opp)
          WHEN v_state = 'waiting_home'
               AND v_side = 'away'
               AND lower(coalesce(r.competition_type, 'league')) <> 'cup'
               AND NOT v_home_proposed
            THEN format('You can propose vs %s', v_opp)
          ELSE format('Still unplayed vs %s', v_opp)
        END,
        'detail', CASE
          WHEN v_state = 'propose' THEN 'This GPSL month has opened and the match has not been played or awarded. ' || CASE WHEN lower(coalesce(r.competition_type, '')) = 'cup' THEN 'Either club can propose the kick-off. If nobody does, the strike stays with the home club.' ELSE 'Home still has to propose.' END
          WHEN v_state = 'waiting' THEN 'This GPSL month has opened and the match has not been played or awarded. Waiting on the other club to reply.'
          WHEN v_state = 'waiting_home'
               AND v_side = 'away'
               AND lower(coalesce(r.competition_type, 'league')) <> 'cup'
               AND NOT v_home_proposed
            THEN 'Home did not propose a kick-off before this month. You can propose one now.'
          ELSE 'This GPSL month has opened and the match has not been played or awarded.'
        END,$new$, E'\r\n', E'\n');

  IF (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 THEN
    RAISE EXCEPTION 'club wire: open-month card not unique';
  END IF;

  EXECUTE replace(v_def, v_old, v_new);
END;
$wire$;

SELECT
  position(
    'You can propose one now.' IN replace(pg_get_functiondef('public.club_wire_cutoffs()'::regprocedure), E'\r\n', E'\n')
  ) > 0 AS away_line;
