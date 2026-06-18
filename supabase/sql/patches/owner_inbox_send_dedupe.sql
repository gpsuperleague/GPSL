-- =============================================================================
-- owner_inbox_send — drop duplicate overloads (13 vs 14 param after scheduling)
-- Run once if you see: function public.owner_inbox_send(...) is not unique
-- e.g. when admin_testing_assign_manager → season expectations inbox fails.
-- =============================================================================

DO $$
DECLARE
  r record;
BEGIN
  FOR r IN
    SELECT pg_get_function_identity_arguments(p.oid) AS args
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname = 'owner_inbox_send'
  LOOP
    EXECUTE format('DROP FUNCTION IF EXISTS public.owner_inbox_send(%s)', r.args);
  END LOOP;
END $$;

CREATE OR REPLACE FUNCTION public.owner_inbox_send(
  p_message_type text,
  p_title text,
  p_body text,
  p_recipient_club text DEFAULT NULL,
  p_owner_id uuid DEFAULT NULL,
  p_fixture_id bigint DEFAULT NULL,
  p_submission_id bigint DEFAULT NULL,
  p_transfer_history_id bigint DEFAULT NULL,
  p_transfer_listing_id bigint DEFAULT NULL,
  p_action_href text DEFAULT NULL,
  p_dedupe_key text DEFAULT NULL,
  p_gpsl_month text DEFAULT NULL,
  p_season_id bigint DEFAULT NULL,
  p_schedule_proposal_id bigint DEFAULT NULL
)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_id bigint;
  v_club text := nullif(btrim(p_recipient_club), '');
BEGIN
  IF v_club IS NULL AND p_owner_id IS NULL THEN
    RETURN NULL;
  END IF;
  IF v_club = 'FOREIGN' THEN
    RETURN NULL;
  END IF;

  IF p_dedupe_key IS NOT NULL AND EXISTS (
    SELECT 1 FROM public.competition_inbox i WHERE i.dedupe_key = p_dedupe_key
  ) THEN
    RETURN NULL;
  END IF;

  INSERT INTO public.competition_inbox (
    recipient_club_short_name, owner_id, message_type,
    fixture_id, submission_id, transfer_history_id, transfer_listing_id,
    title, body, action_href, dedupe_key, gpsl_month, season_id,
    schedule_proposal_id
  )
  VALUES (
    v_club, p_owner_id, p_message_type,
    p_fixture_id, p_submission_id, p_transfer_history_id, p_transfer_listing_id,
    p_title, p_body, p_action_href, p_dedupe_key, p_gpsl_month, p_season_id,
    p_schedule_proposal_id
  )
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.owner_inbox_send(
  text, text, text, text, uuid, bigint, bigint, bigint, bigint, text, text, text, bigint, bigint
) TO authenticated;

NOTIFY pgrst, 'reload schema';
