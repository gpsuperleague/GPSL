-- Admin delete for a pub quiz. Rounds, questions, and answers cascade.
-- A quiz that is mid-post waits until the runner lock drops.

CREATE OR REPLACE FUNCTION public.gpsl_pub_quiz_delete(p_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_busy timestamptz;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  SELECT runner_busy_until INTO v_busy
  FROM public.gpsl_pub_quiz
  WHERE id = p_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Quiz not found';
  END IF;

  IF v_busy IS NOT NULL AND v_busy > now() THEN
    RAISE EXCEPTION 'This quiz is posting to Discord. Wait a minute, then delete it.';
  END IF;

  DELETE FROM public.gpsl_pub_quiz WHERE id = p_id;
  RETURN jsonb_build_object('ok', true);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.gpsl_pub_quiz_delete(bigint) TO authenticated;
