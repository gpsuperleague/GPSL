-- A qualifying member can restart their own attempt.
-- Friendlies logged so far are deleted and the 7 days start again.
-- Tag and availability stay. A film with staff, or an approved film, cannot be reset.

CREATE OR REPLACE FUNCTION public.owner_qualifying_reset_attempt()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_tag text;
  v_n int;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not signed in';
  END IF;
  IF NOT public.owner_qualifying_is_subject(v_uid) THEN
    RAISE EXCEPTION 'Qualifying does not apply to this account';
  END IF;
  IF EXISTS (
    SELECT 1
    FROM public.gpsl_qualifying_video v
    WHERE v.owner_id = v_uid
      AND v.status = 'approved'
  ) THEN
    RAISE EXCEPTION 'The recording is already approved. This attempt cannot be reset.';
  END IF;
  IF EXISTS (
    SELECT 1
    FROM public.gpsl_qualifying_video v
    WHERE v.owner_id = v_uid
      AND v.status = 'submitted'
  ) THEN
    RAISE EXCEPTION 'A film is with staff. Wait for that decision before resetting.';
  END IF;

  v_tag := nullif(upper(btrim(coalesce(public.owner_registry_resolve_tag(v_uid), ''))), '');

  DELETE FROM public.gpsl_qualifying_friendly f
  WHERE f.owner_id = v_uid;
  GET DIAGNOSTICS v_n = ROW_COUNT;

  UPDATE public.gpsl_qualifying_friendly_reports r
  SET status = 'expired',
      note = 'Owner restarted the qualifying attempt'
  WHERE r.status = 'pending'
    AND (
      r.reporter_owner_id = v_uid
      OR (v_tag IS NOT NULL AND (upper(r.canon_tag_a) = v_tag OR upper(r.canon_tag_b) = v_tag))
    );

  INSERT INTO public.gpsl_qualifying_window (owner_id, started_at, reset_count)
  VALUES (v_uid, now(), 1)
  ON CONFLICT (owner_id) DO UPDATE
  SET started_at = now(),
      reset_count = public.gpsl_qualifying_window.reset_count + 1;

  RETURN jsonb_build_object('ok', true, 'friendlies_cleared', v_n);
END;
$function$;

REVOKE ALL ON FUNCTION public.owner_qualifying_reset_attempt() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.owner_qualifying_reset_attempt() TO authenticated;

SELECT jsonb_build_object(
  'ready', to_regprocedure('public.owner_qualifying_reset_attempt()') IS NOT NULL
) AS result;
