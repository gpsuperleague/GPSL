-- Between seasons, an approved qualifying member joins the next club auction.
-- Mid-season they stay on the waiting list so they can pick an empty division club.

DO $auction_enroll$
DECLARE
  v_def text;
  v_old text := $old$  v_approved := coalesce(v_video->>'status', '') = 'approved';

  SELECT upper(btrim(g.handpick_club)), g.handpick_due_at$old$;
  v_new text := $new$  v_approved := coalesce(v_video->>'status', '') = 'approved';

  IF v_approved
     AND public.gpsl_owner_intake_mode() IS DISTINCT FROM 'mid_season'
     AND NOT EXISTS (
       SELECT 1 FROM public."Clubs" c
       WHERE c.owner_id = v_uid
         AND upper(c."ShortName") <> 'FOREIGN'
         AND coalesce(c.is_archived, false) = false
     )
  THEN
    UPDATE public.gpsl_owner_registry r
    SET status = 'awaiting_club_auction',
        status_changed_at = now()
    WHERE r.owner_id = v_uid
      AND r.status = 'member';
  END IF;

  SELECT upper(btrim(g.handpick_club)), g.handpick_due_at$new$;
BEGIN
  v_def := replace(
    pg_get_functiondef('public.owner_qualifying_state()'::regprocedure),
    E'\r\n', E'\n'
  );
  v_old := replace(v_old, E'\r\n', E'\n');
  v_new := replace(v_new, E'\r\n', E'\n');
  IF position('awaiting_club_auction' IN v_def) > 0
     AND position('gpsl_owner_intake_mode()' IN v_def) > 0 THEN
    RETURN;
  END IF;
  IF position(v_old IN v_def) = 0 THEN
    RAISE EXCEPTION 'qualifying state approval hook not found';
  END IF;
  EXECUTE replace(v_def, v_old, v_new);
END;
$auction_enroll$;

NOTIFY pgrst, 'reload schema';

SELECT jsonb_build_object(
  'enrolls', position(
    'awaiting_club_auction' IN pg_get_functiondef('public.owner_qualifying_state()'::regprocedure)
  ) > 0
) AS info;
