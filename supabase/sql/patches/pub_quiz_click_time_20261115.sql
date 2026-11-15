-- Count a pub-quiz click from the moment the button was pressed.
-- Safe re-run.

CREATE OR REPLACE FUNCTION public.gpsl_pub_quiz_lock_answer(
  p_discord_user_id text,
  p_question_id bigint,
  p_choice text,
  p_clicked_at timestamptz
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_user text := nullif(btrim(coalesce(p_discord_user_id, '')), '');
  v_choice char(1);
  v_owner uuid;
  v_tag text;
  v_q public.gpsl_pub_quiz_question%rowtype;
  v_click timestamptz := coalesce(p_clicked_at, now());
  v_inserted int := 0;
BEGIN
  v_choice := lower(left(btrim(coalesce(p_choice, '')), 1))::char(1);
  IF v_user IS NULL OR v_choice NOT IN ('a', 'b', 'c') THEN
    RETURN jsonb_build_object('ok', false, 'message', 'That answer was not recognised.');
  END IF;
  IF v_click > now() + interval '5 seconds' THEN
    v_click := now();
  END IF;

  SELECT r.owner_id, r.owner_tag INTO v_owner, v_tag
  FROM public.gpsl_owner_registry r
  WHERE r.discord_user_id = v_user
  LIMIT 1;
  IF v_owner IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Owners only. Link your Discord account on GPSL first.');
  END IF;

  SELECT * INTO v_q FROM public.gpsl_pub_quiz_question WHERE id = p_question_id;
  IF NOT FOUND OR v_q.closes_at IS NULL OR v_q.status NOT IN ('live', 'closed') THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Too late. That question has closed.');
  END IF;
  IF v_q.opens_at IS NOT NULL AND v_click < v_q.opens_at - interval '2 seconds' THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Too late. That question has closed.');
  END IF;
  IF v_click >= v_q.closes_at THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Too late. That question has closed.');
  END IF;

  INSERT INTO public.gpsl_pub_quiz_answer (
    question_id, owner_id, owner_tag, discord_user_id, choice, answered_at
  )
  VALUES (p_question_id, v_owner, v_tag, v_user, v_choice, v_click)
  ON CONFLICT (question_id, owner_id) DO NOTHING;
  GET DIAGNOSTICS v_inserted = ROW_COUNT;
  IF v_inserted = 0 THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Already answered.');
  END IF;
  RETURN jsonb_build_object(
    'ok', true,
    'message', format('Locked in: %s', upper(v_choice::text))
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.gpsl_pub_quiz_lock_answer(text, bigint, text, timestamptz) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.gpsl_pub_quiz_lock_answer(text, bigint, text, timestamptz) TO service_role;

CREATE OR REPLACE FUNCTION public.gpsl_pub_quiz_lock_answer(
  p_discord_user_id text,
  p_question_id bigint,
  p_choice text
)
RETURNS jsonb
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $function$
  SELECT public.gpsl_pub_quiz_lock_answer(p_discord_user_id, p_question_id, p_choice, now());
$function$;

REVOKE ALL ON FUNCTION public.gpsl_pub_quiz_lock_answer(text, bigint, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.gpsl_pub_quiz_lock_answer(text, bigint, text) TO service_role;

SELECT proname, pg_get_function_identity_arguments(p.oid) AS args
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public'
  AND proname = 'gpsl_pub_quiz_lock_answer'
ORDER BY 2;
