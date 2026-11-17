-- Admin video-report list: include the cup round so a cup report can name the round.

DO $cup_round$
DECLARE
  v_def text;
  v_old text := '        f.cup_code,';
  v_new text := E'        f.cup_code,\n        f.cup_round,';
BEGIN
  v_def := replace(
    pg_get_functiondef('public.admin_match_video_list_breach_reports(text,int)'::regprocedure),
    E'\r\n',
    E'\n'
  );
  v_old := replace(v_old, E'\r\n', E'\n');
  v_new := replace(v_new, E'\r\n', E'\n');
  IF position('f.cup_round' IN v_def) > 0 THEN
    RETURN;
  END IF;
  IF position(v_old IN v_def) = 0 THEN
    RAISE EXCEPTION 'cup_code select not found';
  END IF;
  IF (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 THEN
    RAISE EXCEPTION 'cup_code select matched more than once';
  END IF;
  EXECUTE replace(v_def, v_old, v_new);
END;
$cup_round$;

NOTIFY pgrst, 'reload schema';

SELECT position(
  'f.cup_round' IN pg_get_functiondef(
    'public.admin_match_video_list_breach_reports(text,int)'::regprocedure
  )
) > 0 AS has_cup_round;
