-- Pub quiz clock is 10–14 seconds from the length of the question.
-- Picture and song rounds start two seconds higher, still capped at 14.
-- Safe re-run.

CREATE OR REPLACE FUNCTION public.gpsl_pub_quiz_answer_seconds(
  p_prompt text,
  p_a text,
  p_b text,
  p_c text,
  p_kind text
)
RETURNS integer
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT least(
    14,
    greatest(
      10,
      10
      + CASE
          WHEN length(btrim(coalesce(p_prompt, '')))
             + length(btrim(coalesce(p_a, '')))
             + length(btrim(coalesce(p_b, '')))
             + length(btrim(coalesce(p_c, ''))) <= 80 THEN 0
          WHEN length(btrim(coalesce(p_prompt, '')))
             + length(btrim(coalesce(p_a, '')))
             + length(btrim(coalesce(p_b, '')))
             + length(btrim(coalesce(p_c, ''))) <= 130 THEN 1
          WHEN length(btrim(coalesce(p_prompt, '')))
             + length(btrim(coalesce(p_a, '')))
             + length(btrim(coalesce(p_b, '')))
             + length(btrim(coalesce(p_c, ''))) <= 190 THEN 2
          WHEN length(btrim(coalesce(p_prompt, '')))
             + length(btrim(coalesce(p_a, '')))
             + length(btrim(coalesce(p_b, '')))
             + length(btrim(coalesce(p_c, ''))) <= 250 THEN 3
          ELSE 4
        END
      + CASE WHEN lower(coalesce(p_kind, '')) IN ('picture', 'song') THEN 2 ELSE 0 END
    )
  );
$$;

DO $clock$
DECLARE
  v_def text;
  v_old text;
  v_new text;
BEGIN
  v_def := replace(pg_get_functiondef('public.gpsl_pub_quiz_open_question(bigint)'::regprocedure), E'\r\n', E'\n');
  IF position('gpsl_pub_quiz_answer_seconds' IN v_def) > 0 THEN
    RAISE NOTICE 'open_question already uses the short clock';
  ELSE
    v_old := replace($old$  v_closes := now() + make_interval(secs => v_row.answer_seconds);$old$, E'\r\n', E'\n');
    v_new := replace($new$  v_closes := now() + make_interval(secs => public.gpsl_pub_quiz_answer_seconds(
    v_row.prompt, v_row.option_a, v_row.option_b, v_row.option_c, v_row.kind
  ));$new$, E'\r\n', E'\n');
    IF position(v_old IN v_def) = 0 THEN
      RAISE EXCEPTION 'open_question clock not found';
    END IF;
    v_def := replace(v_def, v_old, v_new);
    v_old := replace($old$    'answer_seconds', v_row.answer_seconds,$old$, E'\r\n', E'\n');
    v_new := replace($new$    'answer_seconds', public.gpsl_pub_quiz_answer_seconds(
      v_row.prompt, v_row.option_a, v_row.option_b, v_row.option_c, v_row.kind
    ),$new$, E'\r\n', E'\n');
    IF position(v_old IN v_def) = 0 THEN
      RAISE EXCEPTION 'open_question answer_seconds return not found';
    END IF;
    EXECUTE replace(v_def, v_old, v_new);
  END IF;

  v_def := replace(pg_get_functiondef('public.gpsl_pub_quiz_mark_question_message(bigint,text,text)'::regprocedure), E'\r\n', E'\n');
  IF position('header_message_id = NULL' IN v_def) = 0 THEN
    v_old := replace($old$      header_message_id = coalesce(nullif(btrim(p_header_message_id), ''), z.header_message_id),$old$, E'\r\n', E'\n');
    v_new := replace($new$      header_message_id = NULL,$new$, E'\r\n', E'\n');
    IF position(v_old IN v_def) = 0 THEN
      RAISE EXCEPTION 'question message header assignment not found';
    END IF;
    EXECUTE replace(v_def, v_old, v_new);
  END IF;
END;
$clock$;

SELECT
  public.gpsl_pub_quiz_answer_seconds('Short one?', 'Yes', 'No', 'Maybe', 'text') AS short_text,
  public.gpsl_pub_quiz_answer_seconds(
    'Which of these long questions about a football final needs the full clock so the owner can read every word before the buttons lock?',
    'The first very long answer option',
    'The second very long answer option',
    'The third very long answer option',
    'text'
  ) AS long_text,
  public.gpsl_pub_quiz_answer_seconds('Who is this?', 'A', 'B', 'C', 'picture') AS short_picture,
  position(
    'gpsl_pub_quiz_answer_seconds' IN replace(
      pg_get_functiondef('public.gpsl_pub_quiz_open_question(bigint)'::regprocedure),
      E'\r\n',
      E'\n'
    )
  ) > 0 AS open_uses_clock;
