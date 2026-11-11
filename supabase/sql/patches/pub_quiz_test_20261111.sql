-- Test quiz from saved questions, and round counts on the live runner.
-- Safe re-run.

ALTER TABLE public.gpsl_pub_quiz
  ADD COLUMN IF NOT EXISTS is_test boolean NOT NULL DEFAULT false;

CREATE OR REPLACE FUNCTION public.gpsl_pub_quiz_start_test(p_source_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_kind text;
  v_q public.gpsl_pub_quiz_question%rowtype;
  v_title text;
  v_id bigint;
  v_round bigint;
  v_n int := 0;
  v_missing text := '';
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.gpsl_pub_quiz WHERE id = p_source_id) THEN
    RAISE EXCEPTION 'Quiz not found';
  END IF;
  IF EXISTS (
    SELECT 1 FROM public.gpsl_pub_quiz WHERE status IN ('scheduled', 'live')
  ) THEN
    RAISE EXCEPTION 'A quiz is already scheduled or running. Wait until it finishes.';
  END IF;

  INSERT INTO public.gpsl_pub_quiz (
    title, status, starts_at, phase, is_test,
    prize_1, prize_2, prize_3, prize_rest
  )
  VALUES ('Pub quiz test', 'scheduled', now(), 'idle', true, 0, 0, 0, 0)
  RETURNING id INTO v_id;

  FOREACH v_kind IN ARRAY ARRAY['text', 'picture', 'song'] LOOP
    SELECT qq.* INTO v_q
    FROM public.gpsl_pub_quiz_question qq
    JOIN public.gpsl_pub_quiz_round r ON r.id = qq.round_id
    WHERE r.quiz_id = p_source_id
      AND r.kind = v_kind
      AND btrim(qq.prompt) <> ''
      AND btrim(qq.option_a) <> ''
      AND btrim(qq.option_b) <> ''
      AND btrim(qq.option_c) <> ''
      AND (v_kind = 'text' OR nullif(btrim(coalesce(qq.media_path, '')), '') IS NOT NULL)
    ORDER BY r.round_no, qq.q_no
    LIMIT 1;
    IF NOT FOUND THEN
      v_missing := v_missing || v_kind || ' ';
      CONTINUE;
    END IF;
    v_n := v_n + 1;
    v_title := CASE v_kind
      WHEN 'picture' THEN 'Picture round'
      WHEN 'song' THEN 'Songs'
      ELSE 'Text'
    END;
    INSERT INTO public.gpsl_pub_quiz_round (quiz_id, round_no, title, kind, answer_seconds)
    VALUES (v_id, v_n, v_title, v_kind, 8)
    RETURNING id INTO v_round;
    INSERT INTO public.gpsl_pub_quiz_question (
      round_id, q_no, prompt, option_a, option_b, option_c, correct, media_path
    )
    VALUES (
      v_round, 1, v_q.prompt, v_q.option_a, v_q.option_b, v_q.option_c, v_q.correct, v_q.media_path
    );
  END LOOP;

  IF v_n < 3 THEN
    DELETE FROM public.gpsl_pub_quiz WHERE id = v_id;
    RAISE EXCEPTION 'Need one filled text question, one picture with an image, and one song with an audio file. Missing: %', btrim(v_missing);
  END IF;

  RETURN jsonb_build_object('ok', true, 'id', v_id);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.gpsl_pub_quiz_start_test(bigint) TO authenticated;

DO $patch$
DECLARE
  v_def text;
  v_old text;
  v_new text;
BEGIN
  v_def := replace(pg_get_functiondef('public.gpsl_pub_quiz_open_question(bigint)'::regprocedure), E'\r\n', E'\n');
  v_old := replace($old$    'answer_seconds', v_row.answer_seconds,
    'closes_at', v_closes$old$, E'\r\n', E'\n');
  v_new := replace($new$    'answer_seconds', v_row.answer_seconds,
    'round_count', (SELECT count(*)::int FROM public.gpsl_pub_quiz_round rr WHERE rr.quiz_id = p_id),
    'question_count', (SELECT count(*)::int FROM public.gpsl_pub_quiz_question qc WHERE qc.round_id = v_row.round_id),
    'is_test', coalesce((SELECT z.is_test FROM public.gpsl_pub_quiz z WHERE z.id = p_id), false),
    'closes_at', v_closes$new$, E'\r\n', E'\n');
  IF position('round_count' IN v_def) = 0 THEN
    IF position(v_old IN v_def) = 0 THEN
      RAISE EXCEPTION 'open_question return block not found';
    END IF;
    EXECUTE replace(v_def, v_old, v_new);
  END IF;

  v_def := replace(pg_get_functiondef('public.gpsl_pub_quiz_close_question(bigint)'::regprocedure), E'\r\n', E'\n');
  v_old := replace($old$  v_gap := CASE
    WHEN v_more_in_round THEN 10
    WHEN v_more_rounds THEN 60
    ELSE 10
  END;$old$, E'\r\n', E'\n');
  v_new := replace($new$  v_gap := CASE
    WHEN EXISTS (SELECT 1 FROM public.gpsl_pub_quiz z WHERE z.id = p_id AND z.is_test) THEN 10
    WHEN v_more_in_round THEN 10
    WHEN v_more_rounds THEN 60
    ELSE 10
  END;$new$, E'\r\n', E'\n');
  IF position('z.is_test' IN v_def) = 0 THEN
    IF position(v_old IN v_def) = 0 THEN
      RAISE EXCEPTION 'close_question gap block not found';
    END IF;
    EXECUTE replace(v_def, v_old, v_new);
  END IF;

  v_def := replace(pg_get_functiondef('public.gpsl_pub_quiz_pay(bigint)'::regprocedure), E'\r\n', E'\n');
  v_old := replace($old$    'prize_rest', v_q.prize_rest
  );$old$, E'\r\n', E'\n');
  v_new := replace($new$    'prize_rest', v_q.prize_rest,
    'is_test', coalesce(v_q.is_test, false)
  );$new$, E'\r\n', E'\n');
  IF position('''is_test'', coalesce(v_q.is_test' IN v_def) = 0 THEN
    IF position(v_old IN v_def) = 0 THEN
      RAISE EXCEPTION 'pay return block not found';
    END IF;
    EXECUTE replace(v_def, v_old, v_new);
  END IF;

  v_def := replace(pg_get_functiondef('public.gpsl_pub_quiz_public_board(bigint)'::regprocedure), E'\r\n', E'\n');
  v_old := replace($old$    WHERE status IN ('live', 'finished', 'scheduled')$old$, E'\r\n', E'\n');
  v_new := replace($new$    WHERE status IN ('live', 'finished', 'scheduled')
      AND NOT coalesce(is_test, false)$new$, E'\r\n', E'\n');
  IF position('NOT coalesce(is_test, false)' IN v_def) = 0 THEN
    IF position(v_old IN v_def) = 0 THEN
      RAISE EXCEPTION 'public board filter not found';
    END IF;
    EXECUTE replace(v_def, v_old, v_new);
  END IF;
END
$patch$;
