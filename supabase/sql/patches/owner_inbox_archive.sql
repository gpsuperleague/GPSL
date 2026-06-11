-- =============================================================================
-- Inbox: mark all read + archive messages
-- =============================================================================

ALTER TABLE public.competition_inbox
  ADD COLUMN IF NOT EXISTS archived_at timestamptz,
  ADD COLUMN IF NOT EXISTS is_favourite boolean NOT NULL DEFAULT false;

CREATE INDEX IF NOT EXISTS competition_inbox_active_idx
  ON public.competition_inbox (recipient_club_short_name, created_at DESC)
  WHERE archived_at IS NULL;

CREATE INDEX IF NOT EXISTS competition_inbox_owner_active_idx
  ON public.competition_inbox (owner_id, created_at DESC)
  WHERE archived_at IS NULL AND owner_id IS NOT NULL;

CREATE OR REPLACE FUNCTION public.competition_inbox_mark_all_read()
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := public.my_club_shortname();
  v_count int;
BEGIN
  UPDATE public.competition_inbox
  SET read_at = now()
  WHERE archived_at IS NULL
    AND read_at IS NULL
    AND (
      (v_club IS NOT NULL AND recipient_club_short_name = v_club)
      OR owner_id = auth.uid()
    );

  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$function$;

CREATE OR REPLACE FUNCTION public.competition_inbox_archive_messages(p_inbox_ids bigint[])
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := public.my_club_shortname();
  v_count int;
BEGIN
  IF p_inbox_ids IS NULL OR coalesce(array_length(p_inbox_ids, 1), 0) = 0 THEN
    RETURN 0;
  END IF;

  UPDATE public.competition_inbox
  SET archived_at = now(),
      read_at = coalesce(read_at, now())
  WHERE id = ANY (p_inbox_ids)
    AND archived_at IS NULL
    AND (
      (v_club IS NOT NULL AND recipient_club_short_name = v_club)
      OR owner_id = auth.uid()
    );

  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$function$;

CREATE OR REPLACE FUNCTION public.competition_inbox_toggle_favourite(p_inbox_id bigint)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := public.my_club_shortname();
  v_fav boolean;
BEGIN
  UPDATE public.competition_inbox
  SET is_favourite = NOT coalesce(is_favourite, false)
  WHERE id = p_inbox_id
    AND (
      (v_club IS NOT NULL AND recipient_club_short_name = v_club)
      OR owner_id = auth.uid()
    )
  RETURNING is_favourite INTO v_fav;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Message not found';
  END IF;

  RETURN coalesce(v_fav, false);
END;
$function$;

CREATE OR REPLACE FUNCTION public.competition_inbox_restore_messages(p_inbox_ids bigint[])
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := public.my_club_shortname();
  v_count int;
BEGIN
  IF p_inbox_ids IS NULL OR coalesce(array_length(p_inbox_ids, 1), 0) = 0 THEN
    RETURN 0;
  END IF;

  UPDATE public.competition_inbox
  SET archived_at = NULL
  WHERE id = ANY (p_inbox_ids)
    AND archived_at IS NOT NULL
    AND (
      (v_club IS NOT NULL AND recipient_club_short_name = v_club)
      OR owner_id = auth.uid()
    );

  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$function$;

CREATE OR REPLACE FUNCTION public.competition_inbox_restore_all_archived()
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := public.my_club_shortname();
  v_count int;
BEGIN
  UPDATE public.competition_inbox
  SET archived_at = NULL
  WHERE archived_at IS NOT NULL
    AND (
      (v_club IS NOT NULL AND recipient_club_short_name = v_club)
      OR owner_id = auth.uid()
    );

  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_inbox_mark_all_read() TO authenticated;
GRANT EXECUTE ON FUNCTION public.competition_inbox_archive_messages(bigint[]) TO authenticated;
GRANT EXECUTE ON FUNCTION public.competition_inbox_toggle_favourite(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.competition_inbox_restore_messages(bigint[]) TO authenticated;
GRANT EXECUTE ON FUNCTION public.competition_inbox_restore_all_archived() TO authenticated;

NOTIFY pgrst, 'reload schema';
