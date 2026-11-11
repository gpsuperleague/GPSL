-- 20 seconds to read and answer. Applies to the quiz already running
-- and to quizzes created from here on.

UPDATE public.gpsl_pub_quiz_round r
SET answer_seconds = 20
FROM public.gpsl_pub_quiz q
WHERE q.id = r.quiz_id
  AND q.status IN ('draft', 'scheduled', 'live')
  AND NOT q.is_test
  AND r.answer_seconds < 20;

DO $patch$
DECLARE
  v_def text;
  v_old text;
  v_new text;
BEGIN
  v_def := replace(pg_get_functiondef('public.gpsl_pub_quiz_create()'::regprocedure), E'\r\n', E'\n');
  v_old := replace($old$      (1, 'World Cup football', 'text', 5),
      (2, 'Picture round', 'picture', 8),
      (3, 'English football', 'text', 5),
      (4, 'Songs', 'song', 8),
      (5, 'General knowledge', 'text', 5)$old$, E'\r\n', E'\n');
  v_new := replace($new$      (1, 'World Cup football', 'text', 20),
      (2, 'Picture round', 'picture', 20),
      (3, 'English football', 'text', 20),
      (4, 'Songs', 'song', 20),
      (5, 'General knowledge', 'text', 20)$new$, E'\r\n', E'\n');
  IF position('picture'', 20)' IN v_def) = 0 THEN
    IF position(v_old IN v_def) = 0 THEN
      RAISE EXCEPTION 'quiz create timings not found';
    END IF;
    EXECUTE replace(v_def, v_old, v_new);
  END IF;
END
$patch$;
