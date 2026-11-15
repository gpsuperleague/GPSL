-- Private "Locked in" replies, so the quiz can delete them when the card changes.
-- Safe re-run.

CREATE TABLE IF NOT EXISTS public.gpsl_pub_quiz_ack (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  application_id text NOT NULL,
  interaction_token text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.gpsl_pub_quiz_ack ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.gpsl_pub_quiz_ack FROM PUBLIC, anon, authenticated;
GRANT ALL ON TABLE public.gpsl_pub_quiz_ack TO service_role;

CREATE OR REPLACE FUNCTION public.gpsl_pub_quiz_take_acks()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_rows jsonb;
BEGIN
  WITH picked AS (
    DELETE FROM public.gpsl_pub_quiz_ack
    RETURNING application_id, interaction_token, created_at
  )
  SELECT coalesce(jsonb_agg(jsonb_build_object(
    'application_id', application_id,
    'interaction_token', interaction_token
  )), '[]'::jsonb)
  INTO v_rows
  FROM picked
  WHERE created_at > now() - interval '15 minutes';
  RETURN v_rows;
END;
$function$;

REVOKE ALL ON FUNCTION public.gpsl_pub_quiz_take_acks() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.gpsl_pub_quiz_take_acks() TO service_role;

CREATE OR REPLACE FUNCTION public.gpsl_pub_quiz_save_ack(p_app text, p_token text)
RETURNS void
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $function$
  INSERT INTO public.gpsl_pub_quiz_ack (application_id, interaction_token)
  SELECT btrim(p_app), btrim(p_token)
  WHERE btrim(coalesce(p_app, '')) <> ''
    AND btrim(coalesce(p_token, '')) <> '';
$function$;

REVOKE ALL ON FUNCTION public.gpsl_pub_quiz_save_ack(text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.gpsl_pub_quiz_save_ack(text, text) TO service_role;

SELECT to_regclass('public.gpsl_pub_quiz_ack') AS ack_table;
