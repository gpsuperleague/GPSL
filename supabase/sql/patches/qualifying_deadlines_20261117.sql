-- Qualifying clocks.
-- Five friendlies: 7 days from account creation (or from the last restart).
-- Short of five, the results clear and a new 7 days starts.
-- The film of those five is due 72 hours after that day-7 deadline.
-- Miss the film and the five clear and the 7 days start again.
-- A film already with staff, or an approved film, is left in place.
-- An account is not on the waiting list until that film is approved.

CREATE TABLE IF NOT EXISTS public.gpsl_qualifying_window (
  owner_id uuid PRIMARY KEY REFERENCES auth.users (id) ON DELETE CASCADE,
  started_at timestamptz NOT NULL,
  reset_count int NOT NULL DEFAULT 0
);

CREATE OR REPLACE FUNCTION public.qualifying_window_started_at(p_owner uuid)
RETURNS timestamptz
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
  SELECT coalesce(
    (SELECT w.started_at FROM public.gpsl_qualifying_window w WHERE w.owner_id = p_owner),
    (SELECT u.created_at FROM auth.users u WHERE u.id = p_owner)
  );
$function$;

CREATE OR REPLACE FUNCTION public.qualifying_enforce_deadlines(p_owner uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_start timestamptz;
  v_count int;
  v_tag text;
BEGIN
  IF p_owner IS NULL OR NOT public.owner_qualifying_is_subject(p_owner) THEN
    RETURN;
  END IF;
  IF EXISTS (
    SELECT 1 FROM public.gpsl_qualifying_video v
    WHERE v.owner_id = p_owner AND v.status IN ('submitted', 'approved')
  ) THEN
    RETURN;
  END IF;

  v_start := public.qualifying_window_started_at(p_owner);
  IF v_start IS NULL THEN
    RETURN;
  END IF;

  SELECT count(*)::int INTO v_count
  FROM public.gpsl_qualifying_friendly f
  WHERE f.owner_id = p_owner;

  IF coalesce(v_count, 0) < 5 AND now() <= v_start + interval '7 days' THEN
    RETURN;
  END IF;
  IF coalesce(v_count, 0) >= 5
     AND now() <= v_start + interval '7 days' + interval '72 hours' THEN
    RETURN;
  END IF;

  v_tag := nullif(upper(btrim(coalesce(public.owner_registry_resolve_tag(p_owner), ''))), '');

  DELETE FROM public.gpsl_qualifying_friendly f
  WHERE f.owner_id = p_owner;

  UPDATE public.gpsl_qualifying_friendly_reports r
  SET status = 'expired',
      note = 'Qualifying window restarted'
  WHERE r.status = 'pending'
    AND (
      r.reporter_owner_id = p_owner
      OR (v_tag IS NOT NULL AND (upper(r.canon_tag_a) = v_tag OR upper(r.canon_tag_b) = v_tag))
    );

  INSERT INTO public.gpsl_qualifying_window (owner_id, started_at, reset_count)
  VALUES (p_owner, now(), 1)
  ON CONFLICT (owner_id) DO UPDATE
  SET started_at = now(),
      reset_count = public.gpsl_qualifying_window.reset_count + 1;
END;
$function$;

REVOKE ALL ON FUNCTION public.qualifying_window_started_at(uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.qualifying_enforce_deadlines(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.qualifying_window_started_at(uuid) TO service_role;
GRANT EXECUTE ON FUNCTION public.qualifying_enforce_deadlines(uuid) TO service_role;

CREATE OR REPLACE FUNCTION public.qualifying_friendlies_credit(
  p_owner_id uuid,
  p_opponent text,
  p_played_on date,
  p_match_key text,
  p_scoreline text
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_tag text;
  v_slots int;
BEGIN
  IF p_owner_id IS NULL OR p_match_key IS NULL THEN
    RETURN false;
  END IF;
  IF NOT public.owner_qualifying_is_subject(p_owner_id) THEN
    RETURN false;
  END IF;
  IF EXISTS (
    SELECT 1 FROM public.gpsl_qualifying_video v
    WHERE v.owner_id = p_owner_id AND v.status = 'approved'
  ) THEN
    RETURN false;
  END IF;

  PERFORM public.qualifying_enforce_deadlines(p_owner_id);

  v_tag := nullif(btrim(coalesce(public.owner_registry_resolve_tag(p_owner_id), '')), '');
  SELECT count(*)::int INTO v_slots
  FROM public.gpsl_owner_registry_availability_slot s
  WHERE s.owner_id = p_owner_id;
  IF v_tag IS NULL OR coalesce(v_slots, 0) = 0 THEN
    RETURN false;
  END IF;

  INSERT INTO public.gpsl_qualifying_friendly (
    owner_id, played_on, opponent, match_key, scoreline
  )
  VALUES (
    p_owner_id,
    coalesce(p_played_on, CURRENT_DATE),
    left(btrim(p_opponent), 80),
    p_match_key,
    left(btrim(p_scoreline), 80)
  )
  ON CONFLICT (owner_id, match_key) WHERE match_key IS NOT NULL DO NOTHING;

  RETURN true;
END;
$function$;

DO $video_clock$
DECLARE
  v_def text;
  v_old text := $old$  IF EXISTS (
    SELECT 1 FROM public.gpsl_qualifying_video v
    WHERE v.owner_id = v_owner AND v.status = 'submitted'
  ) THEN
    RETURN jsonb_build_object('ok', false, 'status', 'ignored', 'reason', 'A recording is already with staff');
  END IF;

  SELECT count(*)::int INTO v_friendlies$old$;
  v_new text := $new$  IF EXISTS (
    SELECT 1 FROM public.gpsl_qualifying_video v
    WHERE v.owner_id = v_owner AND v.status = 'submitted'
  ) THEN
    RETURN jsonb_build_object('ok', false, 'status', 'ignored', 'reason', 'A recording is already with staff');
  END IF;

  IF now() > public.qualifying_window_started_at(v_owner) + interval '7 days' + interval '72 hours' THEN
    PERFORM public.qualifying_enforce_deadlines(v_owner);
    RETURN jsonb_build_object(
      'ok', false,
      'status', 'ignored',
      'reason', 'The 72 hours after day 7 have passed. The five friendlies start again.'
    );
  END IF;

  PERFORM public.qualifying_enforce_deadlines(v_owner);

  SELECT count(*)::int INTO v_friendlies$new$;
BEGIN
  v_def := replace(
    pg_get_functiondef('public.qualifying_videos_ingest_post(text,text,text,text,timestamptz)'::regprocedure),
    E'\r\n', E'\n'
  );
  v_old := replace(v_old, E'\r\n', E'\n');
  v_new := replace(v_new, E'\r\n', E'\n');
  IF position('qualifying_enforce_deadlines' IN v_def) > 0 THEN
    RETURN;
  END IF;
  IF position(v_old IN v_def) = 0 THEN
    RAISE EXCEPTION 'qualifying video ingest hook not found';
  END IF;
  EXECUTE replace(v_def, v_old, v_new);
END;
$video_clock$;

CREATE OR REPLACE FUNCTION public.owner_qualifying_state()
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_subject boolean;
  v_tag text;
  v_slots int;
  v_friendlies jsonb;
  v_friendly_count int;
  v_pending jsonb;
  v_video jsonb;
  v_approved boolean;
  v_grant_club text;
  v_grant_due timestamptz;
  v_window timestamptz;
  v_resets int;
BEGIN
  IF v_uid IS NULL THEN
    RETURN jsonb_build_object('authenticated', false);
  END IF;

  PERFORM public.qualifying_enforce_deadlines(v_uid);

  v_subject := public.owner_qualifying_is_subject(v_uid);
  v_tag := nullif(btrim(coalesce(public.owner_registry_resolve_tag(v_uid), '')), '');
  v_window := public.qualifying_window_started_at(v_uid);

  SELECT w.reset_count INTO v_resets
  FROM public.gpsl_qualifying_window w
  WHERE w.owner_id = v_uid;

  SELECT count(*)::int INTO v_slots
  FROM public.gpsl_owner_registry_availability_slot s
  WHERE s.owner_id = v_uid;

  SELECT coalesce(jsonb_agg(
    jsonb_build_object(
      'id', f.id,
      'played_on', f.played_on,
      'opponent', f.opponent,
      'scoreline', f.scoreline
    )
    ORDER BY f.played_on, f.id
  ), '[]'::jsonb), count(*)::int
  INTO v_friendlies, v_friendly_count
  FROM public.gpsl_qualifying_friendly f
  WHERE f.owner_id = v_uid;

  SELECT coalesce(jsonb_agg(
    jsonb_build_object(
      'scoreline', format('%s %s - %s %s', r.tag_left, r.score_left, r.score_right, r.tag_right),
      'posted_at', r.posted_at
    )
    ORDER BY r.posted_at DESC
  ), '[]'::jsonb)
  INTO v_pending
  FROM public.gpsl_qualifying_friendly_reports r
  WHERE r.status = 'pending'
    AND r.reporter_owner_id = v_uid
    AND r.posted_at >= now() - interval '48 hours';

  SELECT jsonb_build_object(
    'id', v.id,
    'status', v.status,
    'upload_code', v.upload_code,
    'video_url', v.video_url,
    'review_note', v.review_note,
    'checklist', v.checklist,
    'created_at', v.created_at
  )
  INTO v_video
  FROM public.gpsl_qualifying_video v
  WHERE v.owner_id = v_uid
  ORDER BY v.created_at DESC
  LIMIT 1;

  v_approved := coalesce(v_video->>'status', '') = 'approved';

  SELECT upper(btrim(g.handpick_club)), g.handpick_due_at
  INTO v_grant_club, v_grant_due
  FROM public.gpsl_qualifying_grant g
  WHERE g.owner_id = v_uid
    AND (g.handpick_due_at IS NULL OR g.handpick_due_at >= now());

  RETURN jsonb_build_object(
    'authenticated', true,
    'subject', v_subject,
    'tag_done', v_tag IS NOT NULL,
    'owner_tag', v_tag,
    'availability_done', coalesce(v_slots, 0) > 0,
    'availability_slots', coalesce(v_slots, 0),
    'step1_done', v_tag IS NOT NULL AND coalesce(v_slots, 0) > 0,
    'friendlies', v_friendlies,
    'friendly_count', coalesce(v_friendly_count, 0),
    'friendlies_done', coalesce(v_friendly_count, 0) >= 5,
    'pending', coalesce(v_pending, '[]'::jsonb),
    'upload_code', public.owner_qualifying_upload_code(v_uid),
    'video', v_video,
    'video_open', coalesce(v_video->>'status', '') = 'submitted',
    'video_approved', v_approved,
    'handpick_club', NULLIF(v_grant_club, ''),
    'handpick_due_at', v_grant_due,
    'window_started_at', v_window,
    'friendly_deadline', v_window + interval '7 days',
    'video_deadline', v_window + interval '7 days' + interval '72 hours',
    'qualifying_resets', coalesce(v_resets, 0),
    'friendly_channel', '［𝐆𝐏𝐒𝐋］𝐐𝐮𝐚𝐥𝐢𝐟𝐲𝐢𝐧𝐠-𝐅𝐫𝐢𝐞𝐧𝐝𝐥𝐢𝐞𝐬',
    'video_channel', '𝐐𝐮𝐚𝐥𝐢𝐟𝐲𝐢𝐧𝐠-𝐕𝐢𝐝𝐞𝐨𝐬'
  );
END;
$function$;

DO $list_hide$
DECLARE
  v_def text;
  v_old text := $old$      AND NOT (
        coalesce(r.season1_invite_status, '') = 'offered'
        AND r.season1_invite_response IS NULL
        AND (
          r.season1_invite_deadline_at IS NULL
          OR r.season1_invite_deadline_at > now()
        )
      )
  ),$old$;
  v_new text := $new$      AND NOT (
        coalesce(r.season1_invite_status, '') = 'offered'
        AND r.season1_invite_response IS NULL
        AND (
          r.season1_invite_deadline_at IS NULL
          OR r.season1_invite_deadline_at > now()
        )
      )
      AND NOT (
        public.owner_qualifying_is_subject(r.owner_id)
        AND NOT EXISTS (
          SELECT 1 FROM public.gpsl_qualifying_video qv
          WHERE qv.owner_id = r.owner_id
            AND qv.status = 'approved'
        )
      )
  ),$new$;
BEGIN
  v_def := replace(
    pg_get_functiondef('public.waiting_list_public()'::regprocedure),
    E'\r\n', E'\n'
  );
  v_old := replace(v_old, E'\r\n', E'\n');
  v_new := replace(v_new, E'\r\n', E'\n');
  IF position('owner_qualifying_is_subject' IN v_def) > 0 THEN
    RETURN;
  END IF;
  IF position(v_old IN v_def) = 0 THEN
    RAISE EXCEPTION 'waiting list board filter not found';
  END IF;
  EXECUTE replace(v_def, v_old, v_new);
END;
$list_hide$;

NOTIFY pgrst, 'reload schema';

SELECT jsonb_build_object(
  'window_table', to_regclass('public.gpsl_qualifying_window') IS NOT NULL,
  'enforce', to_regprocedure('public.qualifying_enforce_deadlines(uuid)') IS NOT NULL,
  'state_deadline', position('friendly_deadline' IN pg_get_functiondef('public.owner_qualifying_state()'::regprocedure)) > 0,
  'list_hides_qualifying', position('owner_qualifying_is_subject' IN pg_get_functiondef('public.waiting_list_public()'::regprocedure)) > 0,
  'credit_enforces', position('qualifying_enforce_deadlines' IN pg_get_functiondef('public.qualifying_friendlies_credit(uuid,text,date,text,text)'::regprocedure)) > 0,
  'video_enforces', position('qualifying_enforce_deadlines' IN pg_get_functiondef('public.qualifying_videos_ingest_post(text,text,text,text,timestamptz)'::regprocedure)) > 0,
  'subjects_inside_7_days', (
    SELECT count(*) FROM auth.users u
    JOIN public.gpsl_qualifying_settings s ON s.id = 1
    WHERE u.created_at >= s.required_from
      AND u.created_at + interval '7 days' > now()
  ),
  'subjects_past_7_days', (
    SELECT count(*) FROM auth.users u
    JOIN public.gpsl_qualifying_settings s ON s.id = 1
    WHERE u.created_at >= s.required_from
      AND u.created_at + interval '7 days' <= now()
  )
) AS info;
