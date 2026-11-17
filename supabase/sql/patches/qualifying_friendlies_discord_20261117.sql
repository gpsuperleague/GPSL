-- Qualifying friendlies: same dual-post confirm as league friendlies,
-- but the scoreline is owner tag vs owner tag. No club cash, stats, or fines.

ALTER TABLE public.gpsl_qualifying_settings
  ADD COLUMN IF NOT EXISTS last_ingested_message_id text;

ALTER TABLE public.gpsl_qualifying_friendly
  ADD COLUMN IF NOT EXISTS match_key text,
  ADD COLUMN IF NOT EXISTS scoreline text;

CREATE UNIQUE INDEX IF NOT EXISTS gpsl_qualifying_friendly_owner_match_uidx
  ON public.gpsl_qualifying_friendly (owner_id, match_key)
  WHERE match_key IS NOT NULL;

CREATE TABLE IF NOT EXISTS public.gpsl_qualifying_friendly_reports (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  discord_message_id text NOT NULL UNIQUE,
  discord_user_id text,
  reporter_owner_id uuid NOT NULL,
  reporter_tag text NOT NULL,
  tag_left text NOT NULL,
  score_left int NOT NULL,
  tag_right text NOT NULL,
  score_right int NOT NULL,
  canon_tag_a text NOT NULL,
  canon_score_a int NOT NULL,
  canon_tag_b text NOT NULL,
  canon_score_b int NOT NULL,
  status text NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending', 'matched', 'ignored', 'expired')),
  matched_key text,
  note text,
  posted_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS gpsl_qualifying_friendly_reports_pending_idx
  ON public.gpsl_qualifying_friendly_reports (canon_tag_a, canon_tag_b, canon_score_a, canon_score_b, posted_at)
  WHERE status = 'pending';

ALTER TABLE public.gpsl_qualifying_friendly_reports ENABLE ROW LEVEL SECURITY;

CREATE OR REPLACE FUNCTION public.qualifying_friendlies_parse_scoreline(p_content text)
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE
AS $function$
DECLARE
  v_raw text := btrim(coalesce(p_content, ''));
  v_m text[];
  v_l text;
  v_r text;
  v_sl int;
  v_sr int;
BEGIN
  v_raw := regexp_replace(v_raw, E'[\\u2013\\u2014\\u2212\\u2010\\u2011]', '-', 'g');
  v_raw := regexp_replace(v_raw, E'[\\u200B-\\u200D\\uFEFF]', '', 'g');
  v_raw := btrim(v_raw);

  v_m := regexp_match(
    v_raw,
    '^([A-Za-z0-9]{2,32})\s+(\d{1,2})\s*-\s*(\d{1,2})\s+([A-Za-z0-9]{2,32})$'
  );
  IF v_m IS NOT NULL THEN
    v_l := upper(v_m[1]);
    v_sl := v_m[2]::int;
    v_sr := v_m[3]::int;
    v_r := upper(v_m[4]);
  ELSE
    v_m := regexp_match(
      v_raw,
      '^([A-Za-z0-9]{2,32})\s+(\d{1,2})\s*-\s*([A-Za-z0-9]{2,32})\s+(\d{1,2})$'
    );
    IF v_m IS NULL THEN
      RETURN NULL;
    END IF;
    v_l := upper(v_m[1]);
    v_sl := v_m[2]::int;
    v_r := upper(v_m[3]);
    v_sr := v_m[4]::int;
  END IF;

  IF v_l IS NULL OR v_r IS NULL OR v_l = v_r THEN
    RETURN NULL;
  END IF;

  RETURN jsonb_build_object(
    'tag_left', v_l,
    'score_left', v_sl,
    'tag_right', v_r,
    'score_right', v_sr
  );
END;
$function$;

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

CREATE OR REPLACE FUNCTION public.qualifying_friendlies_ingest_post(
  p_discord_message_id text,
  p_discord_user_id text,
  p_reporter_owner_id uuid,
  p_content text,
  p_posted_at timestamptz DEFAULT now()
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_msg_id text := nullif(btrim(coalesce(p_discord_message_id, '')), '');
  v_parsed jsonb;
  v_tag_l text;
  v_tag_r text;
  v_score_l int;
  v_score_r int;
  v_left_id uuid;
  v_right_id uuid;
  v_left_tag text;
  v_right_tag text;
  v_left_n int;
  v_right_n int;
  v_canon_a text;
  v_canon_b text;
  v_score_a int;
  v_score_b int;
  v_report public.gpsl_qualifying_friendly_reports%ROWTYPE;
  v_match public.gpsl_qualifying_friendly_reports%ROWTYPE;
  v_key text;
  v_scoreline text;
  v_played date;
  v_exists boolean;
BEGIN
  IF coalesce(auth.role(), '') <> 'service_role' AND NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Not allowed';
  END IF;

  IF v_msg_id IS NULL OR p_reporter_owner_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'status', 'ignored', 'reason', 'Missing message or owner');
  END IF;

  SELECT EXISTS (
    SELECT 1 FROM public.gpsl_qualifying_friendly_reports r
    WHERE r.discord_message_id = v_msg_id
  ) INTO v_exists;
  IF v_exists THEN
    RETURN jsonb_build_object('ok', true, 'status', 'duplicate', 'reason', 'Already ingested');
  END IF;

  v_parsed := public.qualifying_friendlies_parse_scoreline(p_content);
  IF v_parsed IS NULL THEN
    RETURN jsonb_build_object(
      'ok', false,
      'status', 'ignored',
      'reason', 'Bad format — use TAG score - score TAG (e.g. ROT 2 - 1 BEN)'
    );
  END IF;

  v_tag_l := v_parsed ->> 'tag_left';
  v_tag_r := v_parsed ->> 'tag_right';
  v_score_l := (v_parsed ->> 'score_left')::int;
  v_score_r := (v_parsed ->> 'score_right')::int;

  SELECT count(*)::int INTO v_left_n
  FROM public.gpsl_owner_registry r
  WHERE upper(btrim(r.owner_tag)) = v_tag_l;
  SELECT count(*)::int INTO v_right_n
  FROM public.gpsl_owner_registry r
  WHERE upper(btrim(r.owner_tag)) = v_tag_r;

  IF v_left_n <> 1 OR v_right_n <> 1 THEN
    RETURN jsonb_build_object(
      'ok', false,
      'status', 'ignored',
      'reason', 'Both tags must match exactly one owner'
    );
  END IF;

  SELECT r.owner_id, btrim(r.owner_tag)
  INTO v_left_id, v_left_tag
  FROM public.gpsl_owner_registry r
  WHERE upper(btrim(r.owner_tag)) = v_tag_l;

  SELECT r.owner_id, btrim(r.owner_tag)
  INTO v_right_id, v_right_tag
  FROM public.gpsl_owner_registry r
  WHERE upper(btrim(r.owner_tag)) = v_tag_r;

  IF v_left_id = v_right_id THEN
    RETURN jsonb_build_object('ok', false, 'status', 'ignored', 'reason', 'The two tags are the same owner');
  END IF;

  IF p_reporter_owner_id IS DISTINCT FROM v_left_id
     AND p_reporter_owner_id IS DISTINCT FROM v_right_id THEN
    RETURN jsonb_build_object(
      'ok', false,
      'status', 'ignored',
      'reason', 'Your tag is not in this scoreline'
    );
  END IF;

  IF v_tag_l < v_tag_r THEN
    v_canon_a := v_tag_l;
    v_score_a := v_score_l;
    v_canon_b := v_tag_r;
    v_score_b := v_score_r;
  ELSE
    v_canon_a := v_tag_r;
    v_score_a := v_score_r;
    v_canon_b := v_tag_l;
    v_score_b := v_score_l;
  END IF;

  UPDATE public.gpsl_qualifying_friendly_reports
  SET status = 'expired',
      note = 'Expired — no matching owner post'
  WHERE status = 'pending'
    AND posted_at < now() - interval '48 hours';

  IF EXISTS (
    SELECT 1
    FROM public.gpsl_qualifying_friendly_reports r
    WHERE r.status = 'pending'
      AND r.canon_tag_a = v_canon_a
      AND r.canon_tag_b = v_canon_b
      AND r.canon_score_a = v_score_a
      AND r.canon_score_b = v_score_b
      AND r.reporter_owner_id = p_reporter_owner_id
      AND r.posted_at >= now() - interval '48 hours'
  ) THEN
    INSERT INTO public.gpsl_qualifying_friendly_reports (
      discord_message_id, discord_user_id, reporter_owner_id, reporter_tag,
      tag_left, score_left, tag_right, score_right,
      canon_tag_a, canon_score_a, canon_tag_b, canon_score_b,
      status, note, posted_at
    )
    VALUES (
      v_msg_id, nullif(btrim(coalesce(p_discord_user_id, '')), ''),
      p_reporter_owner_id,
      CASE WHEN p_reporter_owner_id = v_left_id THEN v_left_tag ELSE v_right_tag END,
      v_tag_l, v_score_l, v_tag_r, v_score_r,
      v_canon_a, v_score_a, v_canon_b, v_score_b,
      'ignored',
      'Duplicate pending post from same owner',
      coalesce(p_posted_at, now())
    );
    RETURN jsonb_build_object(
      'ok', true,
      'status', 'duplicate',
      'reason', 'You already have a pending post for this scoreline'
    );
  END IF;

  SELECT r.* INTO v_match
  FROM public.gpsl_qualifying_friendly_reports r
  WHERE r.status = 'pending'
    AND r.canon_tag_a = v_canon_a
    AND r.canon_tag_b = v_canon_b
    AND r.canon_score_a = v_score_a
    AND r.canon_score_b = v_score_b
    AND r.reporter_owner_id <> p_reporter_owner_id
    AND r.reporter_owner_id IN (v_left_id, v_right_id)
    AND r.posted_at >= now() - interval '48 hours'
  ORDER BY r.posted_at ASC
  LIMIT 1
  FOR UPDATE SKIP LOCKED;

  INSERT INTO public.gpsl_qualifying_friendly_reports (
    discord_message_id, discord_user_id, reporter_owner_id, reporter_tag,
    tag_left, score_left, tag_right, score_right,
    canon_tag_a, canon_score_a, canon_tag_b, canon_score_b,
    status, posted_at
  )
  VALUES (
    v_msg_id, nullif(btrim(coalesce(p_discord_user_id, '')), ''),
    p_reporter_owner_id,
    CASE WHEN p_reporter_owner_id = v_left_id THEN v_left_tag ELSE v_right_tag END,
    v_tag_l, v_score_l, v_tag_r, v_score_r,
    v_canon_a, v_score_a, v_canon_b, v_score_b,
    CASE WHEN v_match.id IS NULL THEN 'pending' ELSE 'matched' END,
    coalesce(p_posted_at, now())
  )
  RETURNING * INTO v_report;

  IF v_match.id IS NULL THEN
    RETURN jsonb_build_object(
      'ok', true,
      'status', 'pending',
      'report_id', v_report.id,
      'scoreline', format('%s %s - %s %s', v_left_tag, v_score_l, v_score_r, v_right_tag),
      'reason', 'Waiting for the other owner to post the matching result'
    );
  END IF;

  IF v_match.discord_message_id::numeric <= v_report.discord_message_id::numeric THEN
    v_key := v_match.discord_message_id || ':' || v_report.discord_message_id;
  ELSE
    v_key := v_report.discord_message_id || ':' || v_match.discord_message_id;
  END IF;

  v_scoreline := format('%s %s - %s %s', v_left_tag, v_score_l, v_score_r, v_right_tag);
  v_played := (coalesce(p_posted_at, now()) AT TIME ZONE 'Europe/London')::date;

  UPDATE public.gpsl_qualifying_friendly_reports
  SET status = 'matched',
      matched_key = v_key
  WHERE id IN (v_match.id, v_report.id);

  PERFORM public.qualifying_friendlies_credit(
    v_left_id, v_right_tag, v_played, v_key, v_scoreline
  );
  PERFORM public.qualifying_friendlies_credit(
    v_right_id, v_left_tag, v_played, v_key, v_scoreline
  );

  RETURN jsonb_build_object(
    'ok', true,
    'status', 'matched',
    'scoreline', v_scoreline,
    'match_key', v_key,
    'discord_message_ids', jsonb_build_array(
      v_match.discord_message_id,
      v_report.discord_message_id
    )
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.qualifying_friendlies_ingest_post(text, text, uuid, text, timestamptz)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.qualifying_friendlies_ingest_post(text, text, uuid, text, timestamptz)
  TO service_role, authenticated;

CREATE OR REPLACE FUNCTION public.owner_qualifying_state()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
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
$$;

CREATE OR REPLACE FUNCTION public.gpsl_discord_friendlies_request_poll()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions, net
AS $function$
DECLARE
  v_url text;
  v_key text;
  v_enabled boolean;
BEGIN
  SELECT s.edge_function_url, s.invoke_key, s.auto_poll_enabled
  INTO v_url, v_key, v_enabled
  FROM public.gpsl_discord_friendlies_settings s
  WHERE s.id = 1;

  IF NOT coalesce(v_enabled, false) THEN
    RETURN;
  END IF;
  IF v_url IS NULL OR v_key IS NULL THEN
    RETURN;
  END IF;

  PERFORM net.http_post(
    url := v_url,
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || v_key
    ),
    body := jsonb_build_object('limit', 40),
    timeout_milliseconds := 30000
  );
EXCEPTION
  WHEN undefined_function THEN
    RAISE WARNING 'gpsl_discord_friendlies_request_poll: pg_net missing';
  WHEN OTHERS THEN
    RAISE WARNING 'gpsl_discord_friendlies_request_poll failed: %', SQLERRM;
END;
$function$;

SELECT
  to_regclass('public.gpsl_qualifying_friendly_reports') IS NOT NULL AS reports,
  EXISTS (
    SELECT 1 FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = 'qualifying_friendlies_ingest_post'
  ) AS ingest,
  EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'gpsl_qualifying_friendly'
      AND column_name = 'match_key'
  ) AS match_key;
