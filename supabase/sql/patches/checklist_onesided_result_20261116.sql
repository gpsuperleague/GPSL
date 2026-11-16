-- Match Day checklist only offered "Enter the result" after both clubs
-- checked in. A club who checked in, after the window, had no button.
-- Safe re-run.

DO $checklist_result$
DECLARE
  v_def text;
  v_old text;
  v_new text;
BEGIN
  v_def := replace(
    pg_get_functiondef('public.matchday_checklist_for_club(text,boolean)'::regprocedure),
    E'\r\n', E'\n'
  );
  IF position('opponent missed check-in' IN v_def) > 0 THEN
    RETURN;
  END IF;

  v_old := replace($old$    ELSIF v_my_in AND v_opp_in THEN
      v_step := jsonb_build_object('key', 'result', 'label', 'Enter the result', 'state', 'todo',
        'href', v_matchday_href, 'action', 'Enter result');
    ELSE
      v_step := jsonb_build_object('key', 'result', 'label', 'Submit result', 'state', 'upcoming');
    END IF;$old$, E'\r\n', E'\n');
  v_new := replace($new$    ELSIF v_my_in AND v_opp_in THEN
      v_step := jsonb_build_object('key', 'result', 'label', 'Enter the result', 'state', 'todo',
        'href', v_matchday_href, 'action', 'Enter result');
    ELSIF v_closes IS NOT NULL AND v_now >= v_closes AND v_my_in AND NOT v_opp_in THEN
      v_step := jsonb_build_object('key', 'result', 'label', 'Enter the result', 'state', 'todo',
        'detail', 'Opponent missed check-in',
        'href', v_matchday_href, 'action', 'Enter result');
    ELSIF v_closes IS NOT NULL AND v_now >= v_closes AND NOT v_my_in AND NOT v_opp_in THEN
      v_step := jsonb_build_object('key', 'result', 'label', 'Enter the result', 'state', 'todo',
        'detail', 'Neither club checked in',
        'href', v_matchday_href, 'action', 'Enter result');
    ELSE
      v_step := jsonb_build_object('key', 'result', 'label', 'Submit result', 'state', 'upcoming');
    END IF;$new$, E'\r\n', E'\n');
  IF position(v_old IN v_def) <> 1 AND position(v_old IN v_def) = 0 THEN
    RAISE EXCEPTION 'checklist result needle not found';
  END IF;
  IF (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 THEN
    RAISE EXCEPTION 'checklist result needle not unique';
  END IF;
  EXECUTE replace(v_def, v_old, v_new);
END;
$checklist_result$;

SELECT position(
  'opponent missed check-in'
  IN pg_get_functiondef('public.matchday_checklist_for_club(text,boolean)'::regprocedure)
) > 0 AS onesided_result;
