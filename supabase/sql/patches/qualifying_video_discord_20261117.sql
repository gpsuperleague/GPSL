-- Qualifying recordings arrive as a Discord link in Qualifying-Videos:
--   [QUAL-878597A8-1](https://youtu.be/…)
-- A second closing bracket is accepted, because league lines end with ]].

ALTER TABLE public.gpsl_qualifying_settings
  ADD COLUMN IF NOT EXISTS last_video_message_id text;

ALTER TABLE public.gpsl_qualifying_video
  ADD COLUMN IF NOT EXISTS video_url text,
  ADD COLUMN IF NOT EXISTS discord_message_id text,
  ADD COLUMN IF NOT EXISTS discord_user_id text;

CREATE UNIQUE INDEX IF NOT EXISTS gpsl_qualifying_video_discord_msg_uidx
  ON public.gpsl_qualifying_video (discord_message_id)
  WHERE discord_message_id IS NOT NULL;

CREATE OR REPLACE FUNCTION public.qualifying_videos_ingest_post(
  p_discord_message_id text,
  p_discord_user_id text,
  p_upload_code text,
  p_video_url text,
  p_posted_at timestamptz DEFAULT now()
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_msg text := nullif(btrim(coalesce(p_discord_message_id, '')), '');
  v_discord text := nullif(btrim(coalesce(p_discord_user_id, '')), '');
  v_code text := upper(btrim(coalesce(p_upload_code, '')));
  v_url text := btrim(coalesce(p_video_url, ''));
  v_host text;
  v_hits int;
  v_owner uuid;
  v_linked text;
  v_tag text;
  v_friendlies int;
  v_id bigint;
  v_body text;
BEGIN
  IF coalesce(auth.role(), '') <> 'service_role' AND NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Not allowed';
  END IF;

  IF v_msg IS NULL OR v_discord IS NULL OR v_code IS NULL OR v_url = '' THEN
    RETURN jsonb_build_object('ok', false, 'status', 'ignored', 'reason', 'Missing link');
  END IF;

  IF v_code !~ '^QUAL-[A-F0-9]{8}-[0-9]+$' THEN
    RETURN jsonb_build_object('ok', false, 'status', 'ignored', 'reason', 'Use the code from the qualifying page');
  END IF;

  IF v_url !~ '^https://' OR v_url ~ '\s' OR position('@' IN v_url) > 0 THEN
    RETURN jsonb_build_object('ok', false, 'status', 'ignored', 'reason', 'Use an https YouTube or MEGA link');
  END IF;

  v_host := lower(substring(v_url from '^https://([^/]+)'));
  v_host := regexp_replace(v_host, '^www\.', '');
  IF v_host NOT IN (
    'youtu.be', 'youtube.com', 'm.youtube.com', 'youtube-nocookie.com',
    'mega.nz', 'mega.co.nz'
  ) THEN
    RETURN jsonb_build_object('ok', false, 'status', 'ignored', 'reason', 'Use a YouTube or MEGA link');
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.gpsl_qualifying_video v
    WHERE v.discord_message_id = v_msg
  ) THEN
    RETURN jsonb_build_object('ok', true, 'status', 'duplicate', 'reason', 'Already ingested');
  END IF;

  SELECT count(*)::int,
         (array_agg(c.owner_id))[1],
         (array_agg(c.discord_user_id))[1]
  INTO v_hits, v_owner, v_linked
  FROM (
    SELECT r.owner_id, nullif(btrim(r.discord_user_id), '') AS discord_user_id
    FROM public.gpsl_owner_registry r
    JOIN auth.users u ON u.id = r.owner_id
    JOIN public.gpsl_qualifying_settings s ON s.id = 1
    WHERE u.created_at >= s.required_from
      AND (
        'QUAL-' || upper(substr(replace(r.owner_id::text, '-', ''), 1, 8))
        || '-' || (
          1 + coalesce((
            SELECT count(*)::int
            FROM public.gpsl_qualifying_video v
            WHERE v.owner_id = r.owner_id
              AND v.status = 'rejected'
          ), 0)
        )::text
      ) = v_code
  ) c;

  IF coalesce(v_hits, 0) = 0 THEN
    RETURN jsonb_build_object('ok', false, 'status', 'ignored', 'reason', 'That code is not the current one for a qualifying member');
  END IF;
  IF v_hits > 1 THEN
    RETURN jsonb_build_object('ok', false, 'status', 'ignored', 'reason', 'That code matches more than one member');
  END IF;

  IF v_linked IS NULL OR v_linked IS DISTINCT FROM v_discord THEN
    RETURN jsonb_build_object(
      'ok', false,
      'status', 'ignored',
      'reason', 'Post this from the Discord account linked to that GPSL profile'
    );
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.gpsl_qualifying_video v
    WHERE v.owner_id = v_owner AND v.status = 'approved'
  ) THEN
    RETURN jsonb_build_object('ok', false, 'status', 'ignored', 'reason', 'That recording is already approved');
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.gpsl_qualifying_video v
    WHERE v.owner_id = v_owner AND v.status = 'submitted'
  ) THEN
    RETURN jsonb_build_object('ok', false, 'status', 'ignored', 'reason', 'A recording is already with staff');
  END IF;

  SELECT count(*)::int INTO v_friendlies
  FROM public.gpsl_qualifying_friendly f
  WHERE f.owner_id = v_owner;
  IF coalesce(v_friendlies, 0) < 5 THEN
    RETURN jsonb_build_object('ok', false, 'status', 'ignored', 'reason', 'Five friendlies have to be registered first');
  END IF;

  v_tag := coalesce(public.owner_registry_resolve_tag(v_owner), 'New member');

  INSERT INTO public.gpsl_qualifying_video (
    owner_id, upload_code, status, video_url, discord_message_id, discord_user_id, created_at
  )
  VALUES (
    v_owner, v_code, 'submitted', left(v_url, 500), v_msg, v_discord, coalesce(p_posted_at, now())
  )
  RETURNING id INTO v_id;

  v_body := format(
    E'%s posted a qualifying recording.\nCode: %s\nLink: %s\nFriendlies logged: %s\n\nTick the matchday card on Qualifying videos.',
    v_tag,
    v_code,
    v_url,
    v_friendlies
  );

  IF to_regprocedure('public.gpsl_staff_alert_create(text,text,text,text,jsonb,text)') IS NOT NULL THEN
    PERFORM public.gpsl_staff_alert_create(
      'qualifying_video',
      format('Qualifying video: %s', v_tag),
      v_body,
      'admin_qualifying.html',
      jsonb_build_object('video_id', v_id, 'owner_id', v_owner, 'upload_code', v_code, 'video_url', v_url),
      format('qualifying_video:%s', v_id)
    );
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'status', 'accepted',
    'video_id', v_id,
    'upload_code', v_code,
    'video_url', v_url
  );
EXCEPTION
  WHEN unique_violation THEN
    RETURN jsonb_build_object('ok', true, 'status', 'duplicate', 'reason', 'Already ingested');
END;
$function$;

REVOKE ALL ON FUNCTION public.qualifying_videos_ingest_post(text, text, text, text, timestamptz)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.qualifying_videos_ingest_post(text, text, text, text, timestamptz)
  TO service_role;

CREATE OR REPLACE FUNCTION public.owner_qualifying_state()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
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
BEGIN
  IF v_uid IS NULL THEN
    RETURN jsonb_build_object('authenticated', false);
  END IF;

  v_subject := public.owner_qualifying_is_subject(v_uid);
  v_tag := nullif(btrim(coalesce(public.owner_registry_resolve_tag(v_uid), '')), '');

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
    'friendly_channel', '［𝐆𝐏𝐒𝐋］𝐐𝐮𝐚𝐥𝐢𝐟𝐲𝐢𝐧𝐠-𝐅𝐫𝐢𝐞𝐧𝐝𝐥𝐢𝐞𝐬',
    'video_channel', '𝐐𝐮𝐚𝐥𝐢𝐟𝐲𝐢𝐧𝐠-𝐕𝐢𝐝𝐞𝐨𝐬'
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_qualifying_queue()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF NOT public.is_gpsl_admin_or_mod() THEN
    RAISE EXCEPTION 'Staff only';
  END IF;

  RETURN coalesce((
    SELECT jsonb_agg(row_to_json(x)::jsonb ORDER BY x.created_at)
    FROM (
      SELECT
        v.id,
        v.owner_id,
        v.upload_code,
        v.video_url,
        v.status,
        v.created_at,
        v.review_note,
        v.checklist,
        public.owner_registry_resolve_tag(v.owner_id) AS owner_tag,
        (
          SELECT count(*)::int
          FROM public.gpsl_qualifying_friendly f
          WHERE f.owner_id = v.owner_id
        ) AS friendly_count,
        g.handpick_club,
        g.handpick_due_at
      FROM public.gpsl_qualifying_video v
      LEFT JOIN public.gpsl_qualifying_grant g ON g.owner_id = v.owner_id
      WHERE v.status = 'submitted'
         OR (
           v.status = 'approved'
           AND v.created_at = (
             SELECT max(v2.created_at)
             FROM public.gpsl_qualifying_video v2
             WHERE v2.owner_id = v.owner_id
           )
           AND NOT EXISTS (
             SELECT 1 FROM public."Clubs" c WHERE c.owner_id = v.owner_id
           )
         )
    ) x
  ), '[]'::jsonb);
END;
$function$;

NOTIFY pgrst, 'reload schema';

SELECT jsonb_build_object(
  'ingest', EXISTS (
    SELECT 1 FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = 'qualifying_videos_ingest_post'
  ),
  'video_url', EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'gpsl_qualifying_video'
      AND column_name = 'video_url'
  ),
  'watermark', EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'gpsl_qualifying_settings'
      AND column_name = 'last_video_message_id'
  )
) AS info;
