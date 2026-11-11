-- A quiz can start from the rounds that are fully filled.
-- Later rounds that are still empty are skipped. A half-filled round blocks the start.

CREATE OR REPLACE FUNCTION public.gpsl_pub_quiz_ready_summary(p_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_round record;
  v_ready int;
  v_blank int;
  v_total int;
  v_gap boolean := false;
  v_rounds int := 0;
  v_questions int := 0;
  v_block text := NULL;
BEGIN
  FOR v_round IN
    SELECT r.id, r.round_no, r.kind
    FROM public.gpsl_pub_quiz_round r
    WHERE r.quiz_id = p_id
    ORDER BY r.round_no
  LOOP
    SELECT
      count(*)::int,
      count(*) FILTER (
        WHERE btrim(qq.prompt) <> ''
          AND btrim(qq.option_a) <> ''
          AND btrim(qq.option_b) <> ''
          AND btrim(qq.option_c) <> ''
          AND (
            v_round.kind NOT IN ('picture', 'song')
            OR nullif(btrim(coalesce(qq.media_path, '')), '') IS NOT NULL
          )
      )::int,
      count(*) FILTER (
        WHERE btrim(qq.prompt) = ''
          AND btrim(qq.option_a) = ''
          AND btrim(qq.option_b) = ''
          AND btrim(qq.option_c) = ''
          AND nullif(btrim(coalesce(qq.media_path, '')), '') IS NULL
      )::int
    INTO v_total, v_ready, v_blank
    FROM public.gpsl_pub_quiz_question qq
    WHERE qq.round_id = v_round.id;

    IF v_ready = v_total AND v_total > 0 THEN
      IF v_gap THEN
        v_block := format('Round %s is filled after an empty round. Fill the rounds in order.', v_round.round_no);
        EXIT;
      END IF;
      v_rounds := v_rounds + 1;
      v_questions := v_questions + v_ready;
    ELSIF v_blank = v_total THEN
      v_gap := true;
    ELSE
      v_block := format(
        'Round %s still has %s question(s) to finish. A later round can stay empty.',
        v_round.round_no,
        v_total - v_ready
      );
      EXIT;
    END IF;
  END LOOP;

  IF v_block IS NULL AND v_rounds < 1 THEN
    v_block := 'Round 1 needs all 10 questions before this quiz can start.';
  END IF;

  RETURN jsonb_build_object(
    'ok', v_block IS NULL,
    'rounds', v_rounds,
    'questions', v_questions,
    'reason', v_block
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.gpsl_pub_quiz_ready_summary(bigint) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.gpsl_pub_quiz_schedule(
  p_id bigint,
  p_starts_at timestamptz
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_status text;
  v_ready jsonb;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;
  IF p_starts_at IS NULL THEN
    RAISE EXCEPTION 'Pick a start time';
  END IF;
  SELECT status INTO v_status FROM public.gpsl_pub_quiz WHERE id = p_id;
  IF v_status IS NULL THEN
    RAISE EXCEPTION 'Quiz not found';
  END IF;
  IF v_status NOT IN ('draft', 'scheduled') THEN
    RAISE EXCEPTION 'This quiz has already started';
  END IF;
  IF EXISTS (
    SELECT 1 FROM public.gpsl_pub_quiz
    WHERE status IN ('scheduled', 'live') AND id <> p_id
  ) THEN
    RAISE EXCEPTION 'Another quiz is already scheduled or live';
  END IF;

  v_ready := public.gpsl_pub_quiz_ready_summary(p_id);
  IF coalesce((v_ready->>'ok')::boolean, false) IS NOT TRUE THEN
    RAISE EXCEPTION '%', coalesce(v_ready->>'reason', 'This quiz is not ready');
  END IF;

  UPDATE public.gpsl_pub_quiz
  SET status = 'scheduled',
      starts_at = p_starts_at,
      phase = 'idle',
      updated_at = now()
  WHERE id = p_id;
  RETURN jsonb_build_object('ok', true, 'rounds', (v_ready->>'rounds')::int, 'questions', (v_ready->>'questions')::int);
END;
$function$;

-- Skip empty questions when picking the next one, and count only filled rounds.
DO $patch$
DECLARE
  v_def text;
  v_old text;
  v_new text;
BEGIN
  v_def := replace(pg_get_functiondef('public.gpsl_pub_quiz_open_question(bigint)'::regprocedure), E'\r\n', E'\n');
  v_old := replace($old$  WHERE r.quiz_id = p_id
    AND qq.status = 'pending'$old$, E'\r\n', E'\n');
  v_new := replace($new$  WHERE r.quiz_id = p_id
    AND qq.status = 'pending'
    AND btrim(qq.prompt) <> ''
    AND btrim(qq.option_a) <> ''
    AND btrim(qq.option_b) <> ''
    AND btrim(qq.option_c) <> ''
    AND (
      r.kind NOT IN ('picture', 'song')
      OR nullif(btrim(coalesce(qq.media_path, '')), '') IS NOT NULL
    )$new$, E'\r\n', E'\n');
  IF position('r.kind NOT IN' IN v_def) = 0 THEN
    IF position(v_old IN v_def) = 0 THEN
      RAISE EXCEPTION 'open_question filter not found';
    END IF;
    v_def := replace(v_def, v_old, v_new);
  END IF;

  v_old := replace($old$    'round_count', (SELECT count(*)::int FROM public.gpsl_pub_quiz_round rr WHERE rr.quiz_id = p_id),
    'question_count', (SELECT count(*)::int FROM public.gpsl_pub_quiz_question qc WHERE qc.round_id = v_row.round_id),$old$, E'\r\n', E'\n');
  v_new := replace($new$    'round_count', (
      SELECT count(DISTINCT rr.round_no)::int
      FROM public.gpsl_pub_quiz_round rr
      JOIN public.gpsl_pub_quiz_question qc ON qc.round_id = rr.id
      WHERE rr.quiz_id = p_id
        AND btrim(qc.prompt) <> ''
        AND btrim(qc.option_a) <> ''
        AND btrim(qc.option_b) <> ''
        AND btrim(qc.option_c) <> ''
        AND (
          rr.kind NOT IN ('picture', 'song')
          OR nullif(btrim(coalesce(qc.media_path, '')), '') IS NOT NULL
        )
    ),
    'question_count', (
      SELECT count(*)::int
      FROM public.gpsl_pub_quiz_question qc
      JOIN public.gpsl_pub_quiz_round rr ON rr.id = qc.round_id
      WHERE qc.round_id = v_row.round_id
        AND btrim(qc.prompt) <> ''
        AND btrim(qc.option_a) <> ''
        AND btrim(qc.option_b) <> ''
        AND btrim(qc.option_c) <> ''
        AND (
          rr.kind NOT IN ('picture', 'song')
          OR nullif(btrim(coalesce(qc.media_path, '')), '') IS NOT NULL
        )
    ),$new$, E'\r\n', E'\n');
  IF position('count(DISTINCT rr.round_no)' IN v_def) = 0 THEN
    IF position(v_old IN v_def) = 0 THEN
      RAISE EXCEPTION 'open_question counts not found';
    END IF;
    v_def := replace(v_def, v_old, v_new);
  END IF;
  EXECUTE v_def;

  v_def := replace(pg_get_functiondef('public.gpsl_pub_quiz_close_question(bigint)'::regprocedure), E'\r\n', E'\n');
  v_old := replace($old$  SELECT EXISTS (
    SELECT 1 FROM public.gpsl_pub_quiz_question qq
    WHERE qq.round_id = v_round.id AND qq.status = 'pending'
  ) INTO v_more_in_round;

  SELECT EXISTS (
    SELECT 1
    FROM public.gpsl_pub_quiz_question qq
    JOIN public.gpsl_pub_quiz_round r ON r.id = qq.round_id
    WHERE r.quiz_id = p_id AND r.round_no > v_round.round_no AND qq.status = 'pending'
  ) INTO v_more_rounds;$old$, E'\r\n', E'\n');
  v_new := replace($new$  SELECT EXISTS (
    SELECT 1
    FROM public.gpsl_pub_quiz_question qq
    JOIN public.gpsl_pub_quiz_round rr ON rr.id = qq.round_id
    WHERE qq.round_id = v_round.id
      AND qq.status = 'pending'
      AND btrim(qq.prompt) <> ''
      AND btrim(qq.option_a) <> ''
      AND btrim(qq.option_b) <> ''
      AND btrim(qq.option_c) <> ''
      AND (
        rr.kind NOT IN ('picture', 'song')
        OR nullif(btrim(coalesce(qq.media_path, '')), '') IS NOT NULL
      )
  ) INTO v_more_in_round;

  SELECT EXISTS (
    SELECT 1
    FROM public.gpsl_pub_quiz_question qq
    JOIN public.gpsl_pub_quiz_round r ON r.id = qq.round_id
    WHERE r.quiz_id = p_id
      AND r.round_no > v_round.round_no
      AND qq.status = 'pending'
      AND btrim(qq.prompt) <> ''
      AND btrim(qq.option_a) <> ''
      AND btrim(qq.option_b) <> ''
      AND btrim(qq.option_c) <> ''
      AND (
        r.kind NOT IN ('picture', 'song')
        OR nullif(btrim(coalesce(qq.media_path, '')), '') IS NOT NULL
      )
  ) INTO v_more_rounds;$new$, E'\r\n', E'\n');
  IF position('v_more_in_round' IN v_def) > 0 AND position('rr.kind NOT IN' IN v_def) = 0 THEN
    IF position(v_old IN v_def) = 0 THEN
      RAISE EXCEPTION 'close_question pending checks not found';
    END IF;
    EXECUTE replace(v_def, v_old, v_new);
  END IF;
END
$patch$;
