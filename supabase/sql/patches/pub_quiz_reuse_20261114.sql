-- Copy a finished or draft pub quiz into a new draft.
-- Questions, answers and picture/song files are copied by reference.
-- Scores, prizes and Discord posts stay on the original.

CREATE OR REPLACE FUNCTION public.gpsl_pub_quiz_reuse(p_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_src public.gpsl_pub_quiz%ROWTYPE;
  v_id bigint;
  v_round bigint;
  r record;
  q record;
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  SELECT * INTO v_src FROM public.gpsl_pub_quiz WHERE id = p_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Quiz not found';
  END IF;
  IF v_src.status = 'live' THEN
    RAISE EXCEPTION 'That quiz is running. Wait until it finishes, then reuse it.';
  END IF;

  INSERT INTO public.gpsl_pub_quiz (title)
  VALUES (v_src.title)
  RETURNING id INTO v_id;

  FOR r IN
    SELECT *
    FROM public.gpsl_pub_quiz_round
    WHERE quiz_id = p_id
    ORDER BY round_no
  LOOP
    INSERT INTO public.gpsl_pub_quiz_round (quiz_id, round_no, title, kind, answer_seconds)
    VALUES (v_id, r.round_no, r.title, r.kind, r.answer_seconds)
    RETURNING id INTO v_round;

    FOR q IN
      SELECT *
      FROM public.gpsl_pub_quiz_question
      WHERE round_id = r.id
      ORDER BY q_no
    LOOP
      INSERT INTO public.gpsl_pub_quiz_question (
        round_id, q_no, prompt, option_a, option_b, option_c, correct, media_path
      )
      VALUES (
        v_round, q.q_no, q.prompt, q.option_a, q.option_b, q.option_c, q.correct, q.media_path
      );
    END LOOP;
  END LOOP;

  RETURN jsonb_build_object('ok', true, 'id', v_id);
END;
$function$;

REVOKE ALL ON FUNCTION public.gpsl_pub_quiz_reuse(bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.gpsl_pub_quiz_reuse(bigint) TO authenticated, service_role;

SELECT position(
  'gpsl_pub_quiz_reuse' IN pg_get_functiondef('public.gpsl_pub_quiz_reuse(bigint)'::regprocedure)
) > 0 AS reuse_ready;
