-- =============================================================================
-- Season 1 invite → Discord #gpsl-news (timestamp + tag + deadline)
-- Also backfill pending news for invites already offered with no reply.
-- Safe re-run. After apply: push pending via Admin → Discord News, or invite again
-- (admin UI now flushes discord-sky-feed after each invite).
-- =============================================================================

CREATE OR REPLACE FUNCTION public.season1_invite_enqueue_discord_news(
  p_owner_id uuid,
  p_owner_tag text,
  p_deadline timestamptz,
  p_deadline_label text,
  p_queue_num integer,
  p_token text,
  p_discord_user_id text DEFAULT NULL
)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_id bigint;
  v_tag text := coalesce(nullif(btrim(p_owner_tag), ''), 'owner');
  v_mention text := '@' || ltrim(v_tag, '@');
  v_offered_label text;
  v_deadline_label text := coalesce(nullif(btrim(p_deadline_label), ''), '48 hours');
  v_headline text;
  v_body text;
BEGIN
  IF to_regprocedure(
    'public.gpsl_discord_feed_enqueue(text,text,text,integer,text,jsonb)'
  ) IS NULL THEN
    RETURN NULL;
  END IF;

  v_offered_label := to_char(
    timezone('Europe/London', coalesce(
      (SELECT season1_invite_offered_at FROM public.gpsl_owner_registry WHERE owner_id = p_owner_id),
      now()
    )),
    'Dy DD Mon YYYY HH24:MI'
  ) || ' UK';

  v_headline := 'Season 1 invite — ' || v_mention;
  v_body :=
    v_mention || ' has been invited to GPSL Season 1.'
    || E'\nInvited: ' || v_offered_label
    || E'\nDeadline: ' || v_deadline_label
    || CASE
         WHEN p_queue_num IS NOT NULL THEN E'\nQueue: #' || p_queue_num::text
         ELSE ''
       END;

  BEGIN
    v_id := public.gpsl_discord_feed_enqueue(
      'news',
      v_headline,
      v_body,
      16750848,
      'season1_invite:' || p_owner_id::text || ':' || coalesce(nullif(btrim(p_token), ''), 'na'),
      jsonb_build_object(
        'channel', 'news',
        'kind', 'season1_invite',
        'ping', true,
        'owner_tag', v_tag,
        'owner_tags', jsonb_build_array(v_tag),
        'discord_user_id', nullif(btrim(coalesce(p_discord_user_id, '')), ''),
        'deadline_at', p_deadline,
        'deadline_label', v_deadline_label,
        'queue_num', p_queue_num,
        'offered_label_uk', v_offered_label
      )
    );
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'season1 Discord enqueue failed: %', SQLERRM;
    RETURN NULL;
  END;

  RETURN v_id;
END;
$fn$;

GRANT EXECUTE ON FUNCTION public.season1_invite_enqueue_discord_news(
  uuid, text, timestamptz, text, integer, text, text
) TO authenticated;

-- Patch send function: replace inline enqueue with helper (full function body kept in season1 patch;
-- here we only ensure currently-offered invites get news rows, then rely on updated send via
-- rewriting the enqueue call site by re-applying the send function from the main patch if needed).

-- Backfill Discord news for already-offered invites that never made it into the feed queue
DO $backfill$
DECLARE
  r record;
  v_tag text;
  v_deadline_label text;
BEGIN
  IF to_regprocedure(
    'public.gpsl_discord_feed_enqueue(text,text,text,integer,text,jsonb)'
  ) IS NULL THEN
    RAISE NOTICE 'gpsl_discord_feed_enqueue missing — skip Season 1 Discord backfill';
    RETURN;
  END IF;

  FOR r IN
    SELECT
      o.owner_id,
      o.season1_invite_token,
      o.season1_invite_deadline_at,
      o.season1_invite_queue_num,
      o.discord_user_id,
      o.owner_tag
    FROM public.gpsl_owner_registry o
    WHERE o.season1_invite_status = 'offered'
      AND o.season1_invite_response IS NULL
      AND o.season1_invite_token IS NOT NULL
      AND (
        o.season1_invite_deadline_at IS NULL
        OR o.season1_invite_deadline_at > now()
      )
  LOOP
    v_tag := coalesce(
      nullif(btrim(public.owner_registry_resolve_tag(r.owner_id)), ''),
      nullif(btrim(r.owner_tag), ''),
      'owner'
    );
    v_deadline_label := CASE
      WHEN r.season1_invite_deadline_at IS NULL THEN '48 hours'
      WHEN to_regprocedure('public.season1_invite_format_deadline_uk(timestamptz)') IS NOT NULL THEN
        public.season1_invite_format_deadline_uk(r.season1_invite_deadline_at)
      ELSE to_char(timezone('Europe/London', r.season1_invite_deadline_at), 'Dy DD Mon YYYY HH24:MI') || ' UK'
    END;

    PERFORM public.season1_invite_enqueue_discord_news(
      r.owner_id,
      v_tag,
      r.season1_invite_deadline_at,
      v_deadline_label,
      r.season1_invite_queue_num,
      r.season1_invite_token,
      r.discord_user_id
    );
  END LOOP;
END;
$backfill$;

NOTIFY pgrst, 'reload schema';
