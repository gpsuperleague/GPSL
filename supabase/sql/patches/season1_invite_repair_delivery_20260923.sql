-- =============================================================================
-- Season 1 invite REPAIR — inbox + Discord + Invited panel
--
-- Root causes this fixes:
--   • Inbox was skipped when owner_inbox_send signature check returned NULL
--   • Discord rows may never have been enqueued / never flushed
--   • Invited panel hid expired offers (deadline already passed)
--
-- Run in Supabase SQL Editor. Safe re-run.
-- Then: hard-refresh waiting_list.html; owners refresh Inbox;
--       Admin → Discord News → Push queue (if posts do not appear).
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1) Allow season1_invite inbox message type
-- ---------------------------------------------------------------------------
DO $inbox$
DECLARE
  v_list text;
BEGIN
  SELECT string_agg(quote_literal(t), ', ' ORDER BY t)
  INTO v_list
  FROM (
    SELECT DISTINCT message_type AS t
    FROM public.competition_inbox
    WHERE message_type IS NOT NULL
    UNION
    SELECT 'season1_invite'
  ) s;

  ALTER TABLE public.competition_inbox
    DROP CONSTRAINT IF EXISTS competition_inbox_message_type_check;

  EXECUTE format(
    'ALTER TABLE public.competition_inbox
       ADD CONSTRAINT competition_inbox_message_type_check
       CHECK (message_type IS NULL OR message_type IN (%s)) NOT VALID',
    v_list
  );

  BEGIN
    ALTER TABLE public.competition_inbox
      VALIDATE CONSTRAINT competition_inbox_message_type_check;
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'inbox type check left NOT VALID: %', SQLERRM;
  END;
END;
$inbox$;

-- ---------------------------------------------------------------------------
-- 2) Robust inbox sender (never silently skip)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.season1_invite_send_inbox(
  p_owner_id uuid,
  p_title text,
  p_body text,
  p_action_href text,
  p_dedupe_key text
)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_id bigint;
BEGIN
  IF p_owner_id IS NULL THEN
    RETURN NULL;
  END IF;

  IF p_dedupe_key IS NOT NULL THEN
    SELECT i.id INTO v_id
    FROM public.competition_inbox i
    WHERE i.dedupe_key = p_dedupe_key
    LIMIT 1;
    IF v_id IS NOT NULL THEN
      RETURN v_id;
    END IF;
  END IF;

  BEGIN
    v_id := public.owner_inbox_send(
      'season1_invite',
      p_title,
      p_body,
      NULL,
      p_owner_id,
      NULL, NULL, NULL, NULL,
      p_action_href,
      p_dedupe_key,
      NULL,
      NULL
    );
    IF v_id IS NOT NULL THEN
      RETURN v_id;
    END IF;
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'owner_inbox_send fallback for %: %', p_owner_id, SQLERRM;
  END;

  INSERT INTO public.competition_inbox (
    recipient_club_short_name, owner_id, message_type,
    title, body, action_href, dedupe_key
  ) VALUES (
    NULL, p_owner_id, 'season1_invite',
    p_title, p_body, p_action_href, p_dedupe_key
  )
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$fn$;

GRANT EXECUTE ON FUNCTION public.season1_invite_send_inbox(uuid, text, text, text, text)
  TO authenticated;

-- ---------------------------------------------------------------------------
-- 3) Discord news → live Admin Discord News queue
-- ---------------------------------------------------------------------------
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
  v_dedupe text :=
    'season1_invite:' || coalesce(p_owner_id::text, 'na') || ':'
    || coalesce(nullif(btrim(p_token), ''), 'na');
BEGIN
  v_offered_label := to_char(
    timezone('Europe/London', coalesce(
      (SELECT season1_invite_offered_at
         FROM public.gpsl_owner_registry
        WHERE owner_id = p_owner_id),
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

  IF to_regprocedure(
    'public.gpsl_discord_feed_enqueue(text,text,text,integer,text,jsonb)'
  ) IS NOT NULL THEN
    BEGIN
      v_id := public.gpsl_discord_feed_enqueue(
        'news',
        v_headline,
        v_body,
        16750848,
        v_dedupe,
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
      RAISE NOTICE 'gpsl_discord_feed_enqueue failed: %', SQLERRM;
      v_id := NULL;
    END;
  END IF;

  IF v_id IS NULL AND to_regclass('public.gpsl_discord_feed_queue') IS NOT NULL THEN
    BEGIN
      INSERT INTO public.gpsl_discord_feed_queue (
        event_type, headline, body, color, dedupe_key, metadata, status
      ) VALUES (
        'news',
        left(v_headline, 250),
        v_body,
        16750848,
        v_dedupe,
        jsonb_build_object(
          'channel', 'news',
          'kind', 'season1_invite',
          'ping', true,
          'owner_tag', v_tag,
          'owner_tags', jsonb_build_array(v_tag),
          'discord_user_id', nullif(btrim(coalesce(p_discord_user_id, '')), ''),
          'deadline_at', p_deadline,
          'deadline_label', v_deadline_label,
          'queue_num', p_queue_num
        ),
        'pending'
      )
      ON CONFLICT DO NOTHING
      RETURNING id INTO v_id;

      IF v_id IS NULL THEN
        SELECT q.id INTO v_id
        FROM public.gpsl_discord_feed_queue q
        WHERE q.dedupe_key = v_dedupe
        LIMIT 1;
      END IF;
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'Discord queue insert failed: %', SQLERRM;
    END;
  END IF;

  IF to_regprocedure('public.gpsl_discord_feed_request_flush()') IS NOT NULL THEN
    BEGIN
      PERFORM public.gpsl_discord_feed_request_flush();
    EXCEPTION WHEN OTHERS THEN
      NULL;
    END;
  END IF;

  RETURN v_id;
END;
$fn$;

GRANT EXECUTE ON FUNCTION public.season1_invite_enqueue_discord_news(
  uuid, text, timestamptz, text, integer, text, text
) TO authenticated;

-- ---------------------------------------------------------------------------
-- 4) Patch admin send — always deliver inbox + Discord
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_season1_invite_send(p_owner_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_row public.gpsl_owner_registry%ROWTYPE;
  v_email text;
  v_tag text;
  v_deadline timestamptz;
  v_token text;
  v_inbox_id bigint;
  v_email_id bigint;
  v_discord_qid bigint;
  v_deadline_label text;
  v_title text;
  v_body text;
  v_site text := 'https://gpsuperleague.github.io/GPSL';
  v_accept_url text;
  v_decline_url text;
  v_discord_user text;
BEGIN
  IF NOT public.is_gpsl_admin_or_mod() THEN
    RAISE EXCEPTION 'Admin or mod only';
  END IF;

  SELECT * INTO v_row
  FROM public.gpsl_owner_registry
  WHERE owner_id = p_owner_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'No registry row';
  END IF;

  IF v_row.season1_invite_queue_num IS NULL THEN
    RAISE EXCEPTION 'Assign a Season 1 queue number before inviting';
  END IF;

  IF v_row.season1_invite_response = 'accepted' THEN
    RAISE EXCEPTION 'Owner already accepted Season 1';
  END IF;

  IF v_row.season1_invite_status = 'offered'
     AND v_row.season1_invite_deadline_at IS NOT NULL
     AND v_row.season1_invite_deadline_at > now()
     AND v_row.season1_invite_response IS NULL THEN
    RAISE EXCEPTION 'Invite already pending until %',
      public.season1_invite_format_deadline_uk(v_row.season1_invite_deadline_at);
  END IF;

  SELECT u.email::text INTO v_email FROM auth.users u WHERE u.id = p_owner_id;
  IF nullif(btrim(coalesce(v_email, '')), '') IS NULL THEN
    RAISE EXCEPTION 'Owner has no email';
  END IF;

  v_tag := coalesce(
    nullif(btrim(public.owner_registry_resolve_tag(p_owner_id)), ''),
    nullif(btrim(v_row.owner_tag), ''),
    'owner'
  );
  v_discord_user := nullif(btrim(coalesce(v_row.discord_user_id, '')), '');

  v_deadline := now() + interval '48 hours';
  v_token := coalesce(
    (
      SELECT encode(extensions.gen_random_bytes(24), 'hex')
      WHERE to_regprocedure('extensions.gen_random_bytes(integer)') IS NOT NULL
    ),
    replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '')
  );
  v_deadline_label := public.season1_invite_format_deadline_uk(v_deadline);
  v_accept_url := v_site || '/season1_invite.html?token=' || v_token || '&decision=accept';
  v_decline_url := v_site || '/season1_invite.html?token=' || v_token || '&decision=decline';

  v_title := 'You''re invited to GPSL Season 1';
  v_body :=
    'Congratulations ' || v_tag
    || ' — you have been invited to join GPSL Season 1 (club auction).'
    || E'\n\nYou have 48 hours to accept or decline.'
    || E'\nDeadline: ' || v_deadline_label || '.'
    || E'\nQueue position: #' || v_row.season1_invite_queue_num::text || '.'
    || E'\n\nRespond from Inbox, Waiting list, or your email links.';

  v_inbox_id := public.season1_invite_send_inbox(
    p_owner_id,
    v_title,
    v_body,
    'waiting_list.html#season1',
    'season1_invite:' || p_owner_id::text || ':' || v_token
  );

  UPDATE public.gpsl_owner_registry
  SET season1_invite_status = 'offered',
      season1_invite_offered_at = now(),
      season1_invite_deadline_at = v_deadline,
      season1_invite_token = v_token,
      season1_invite_inbox_id = v_inbox_id,
      season1_invite_offer_count = coalesce(season1_invite_offer_count, 0) + 1,
      season1_invite_responded_at = NULL,
      season1_invite_response = CASE
        WHEN season1_invite_response = 'declined' THEN NULL
        ELSE season1_invite_response
      END
  WHERE owner_id = p_owner_id
  RETURNING * INTO v_row;

  v_discord_qid := public.season1_invite_enqueue_discord_news(
    p_owner_id,
    v_tag,
    v_deadline,
    v_deadline_label,
    v_row.season1_invite_queue_num,
    v_token,
    v_discord_user
  );

  BEGIN
    INSERT INTO public.gpsl_email_outbox (
      kind, to_email, to_owner_id, subject, html_body, text_body, metadata
    ) VALUES (
      'season1_invite',
      v_email,
      p_owner_id,
      v_title,
      '<div style="font-family:Arial,Helvetica,sans-serif;line-height:1.5;color:#222">'
        || '<h2 style="color:#cc7a00;margin:0 0 12px">You''re invited to GPSL Season 1</h2>'
        || '<p>Hi <strong>'
        || replace(replace(v_tag, '&', '&amp;'), '<', '&lt;')
        || '</strong>,</p>'
        || '<p>You have been invited to join <strong>GPSL Season 1</strong>.</p>'
        || '<p>Deadline: <strong>' || v_deadline_label || '</strong></p>'
        || '<p style="margin:22px 0">'
        || '<a href="' || v_accept_url
        || '" style="background:#2a7;color:#fff;padding:10px 16px;border-radius:4px;text-decoration:none;margin-right:10px">Accept</a>'
        || '<a href="' || v_decline_url
        || '" style="background:#844;color:#fff;padding:10px 16px;border-radius:4px;text-decoration:none">Decline</a>'
        || '</p></div>',
      v_body || E'\n\nAccept: ' || v_accept_url || E'\nDecline: ' || v_decline_url,
      jsonb_build_object(
        'token', v_token,
        'deadline_at', v_deadline,
        'queue_num', v_row.season1_invite_queue_num,
        'accept_url', v_accept_url,
        'decline_url', v_decline_url
      )
    )
    RETURNING id INTO v_email_id;
  EXCEPTION WHEN undefined_table THEN
    v_email_id := NULL;
  END;

  PERFORM public.season1_invite_log_event(
    p_owner_id,
    'invite_sent',
    v_row.season1_invite_queue_num,
    jsonb_build_object(
      'deadline_at', v_deadline,
      'inbox_id', v_inbox_id,
      'discord_queue_id', v_discord_qid,
      'email_outbox_id', v_email_id
    )
  );

  RETURN jsonb_build_object(
    'ok', true,
    'owner_id', p_owner_id,
    'email', v_email,
    'owner_tag', v_tag,
    'queue_num', v_row.season1_invite_queue_num,
    'deadline_at', v_deadline,
    'deadline_label', v_deadline_label,
    'inbox_id', v_inbox_id,
    'discord_queue_id', v_discord_qid,
    'email_outbox_id', v_email_id,
    'season1', public.season1_invite_row_json(v_row)
  );
END;
$fn$;

GRANT EXECUTE ON FUNCTION public.admin_season1_invite_send(uuid) TO authenticated;

-- ---------------------------------------------------------------------------
-- 5) Invited panel = Season 1 offered (include expired until they reply)
--     Re-applies waiting_list_public from panels file logic with deadline filter removed.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.waiting_list_public()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_rows jsonb;
  v_total int;
  v_self_pos int;
  v_on_board_mode text := 'invited';
  v_on_board jsonb;
  v_on_board_total int;
  v_self_on_board_pos int;
  v_s1_confirmed jsonb;
  v_s1_confirmed_total int;
  v_self_s1_confirmed_pos int;
  v_use_admin boolean;
BEGIN
  SELECT coalesce(bool_and(
    r.waiting_list_use_admin_sort AND r.waiting_list_admin_sort IS NOT NULL
  ), false)
  INTO v_use_admin
  FROM public.gpsl_owner_registry r
  WHERE (
      public.waiting_list_on_list_status(r.status)
      AND NOT EXISTS (SELECT 1 FROM public."Clubs" c WHERE c.owner_id = r.owner_id)
    )
    OR EXISTS (SELECT 1 FROM public."Clubs" c WHERE c.owner_id = r.owner_id);

  -- Middle: Invited (Season 1 offered, awaiting reply — including expired)
  WITH latest_country AS (
    SELECT DISTINCT ON (e.owner_id)
      e.owner_id,
      upper(nullif(btrim(coalesce(e.country_code, '')), '')) AS country_code
    FROM public.owner_login_origin_events e
    WHERE nullif(btrim(coalesce(e.country_code, '')), '') IS NOT NULL
    ORDER BY e.owner_id, e.logged_in_at DESC, e.id DESC
  ),
  latest_timezone AS (
    SELECT DISTINCT ON (e.owner_id)
      e.owner_id,
      nullif(btrim(coalesce(e.timezone_name, '')), '') AS timezone_name
    FROM public.owner_login_origin_events e
    WHERE nullif(btrim(coalesce(e.timezone_name, '')), '') IS NOT NULL
    ORDER BY e.owner_id, e.logged_in_at DESC, e.id DESC
  ),
  invited AS (
    SELECT
      r.owner_id,
      public.owner_registry_resolve_tag(r.owner_id) AS owner_tag,
      r.season1_invite_queue_num AS queue_num,
      r.season1_invite_offered_at AS invited_at,
      r.season1_invite_deadline_at AS deadline_at,
      lc.country_code,
      coalesce(
        nullif(btrim(coalesce(r.owner_timezone, '')), ''),
        (
          SELECT nullif(btrim(coalesce(c.owner_timezone, '')), '')
          FROM public."Clubs" c
          WHERE c.owner_id = r.owner_id
          ORDER BY c."ShortName"
          LIMIT 1
        ),
        lt.timezone_name
      ) AS origin_timezone
    FROM public.gpsl_owner_registry r
    LEFT JOIN latest_country lc ON lc.owner_id = r.owner_id
    LEFT JOIN latest_timezone lt ON lt.owner_id = r.owner_id
    WHERE r.season1_invite_status = 'offered'
      AND r.season1_invite_response IS NULL
  ),
  invited_ranked AS (
    SELECT
      i.*,
      row_number() OVER (
        ORDER BY i.queue_num NULLS LAST, i.invited_at NULLS LAST, i.owner_tag, i.owner_id
      )::int AS position
    FROM invited i
  )
  SELECT
    coalesce(jsonb_agg(
      jsonb_build_object(
        'position', invited_ranked.position,
        'owner_id', invited_ranked.owner_id,
        'owner_tag', invited_ranked.owner_tag,
        'queue_num', invited_ranked.queue_num,
        'country_code', invited_ranked.country_code,
        'origin_timezone', invited_ranked.origin_timezone,
        'deadline_at', invited_ranked.deadline_at
      )
      ORDER BY invited_ranked.position
    ), '[]'::jsonb),
    count(*)::int,
    max(CASE WHEN invited_ranked.owner_id = auth.uid() THEN invited_ranked.position END)
  INTO v_on_board, v_on_board_total, v_self_on_board_pos
  FROM invited_ranked;

  -- Left: Confirmed for Season 1
  WITH latest_country AS (
    SELECT DISTINCT ON (e.owner_id)
      e.owner_id,
      upper(nullif(btrim(coalesce(e.country_code, '')), '')) AS country_code
    FROM public.owner_login_origin_events e
    WHERE nullif(btrim(coalesce(e.country_code, '')), '') IS NOT NULL
    ORDER BY e.owner_id, e.logged_in_at DESC, e.id DESC
  ),
  latest_timezone AS (
    SELECT DISTINCT ON (e.owner_id)
      e.owner_id,
      nullif(btrim(coalesce(e.timezone_name, '')), '') AS timezone_name
    FROM public.owner_login_origin_events e
    WHERE nullif(btrim(coalesce(e.timezone_name, '')), '') IS NOT NULL
    ORDER BY e.owner_id, e.logged_in_at DESC, e.id DESC
  ),
  confirmed AS (
    SELECT
      r.owner_id,
      public.owner_registry_resolve_tag(r.owner_id) AS owner_tag,
      r.season1_invite_queue_num AS queue_num,
      r.season1_invite_responded_at AS responded_at,
      lc.country_code,
      coalesce(
        nullif(btrim(coalesce(r.owner_timezone, '')), ''),
        (
          SELECT nullif(btrim(coalesce(c.owner_timezone, '')), '')
          FROM public."Clubs" c
          WHERE c.owner_id = r.owner_id
          ORDER BY c."ShortName"
          LIMIT 1
        ),
        lt.timezone_name
      ) AS origin_timezone
    FROM public.gpsl_owner_registry r
    LEFT JOIN latest_country lc ON lc.owner_id = r.owner_id
    LEFT JOIN latest_timezone lt ON lt.owner_id = r.owner_id
    WHERE r.season1_invite_response = 'accepted'
  ),
  confirmed_ranked AS (
    SELECT
      c.*,
      row_number() OVER (
        ORDER BY c.queue_num NULLS LAST, c.responded_at NULLS LAST, c.owner_tag, c.owner_id
      )::int AS position
    FROM confirmed c
  )
  SELECT
    coalesce(jsonb_agg(
      jsonb_build_object(
        'position', confirmed_ranked.position,
        'owner_id', confirmed_ranked.owner_id,
        'owner_tag', confirmed_ranked.owner_tag,
        'queue_num', confirmed_ranked.queue_num,
        'country_code', confirmed_ranked.country_code,
        'origin_timezone', confirmed_ranked.origin_timezone
      )
      ORDER BY confirmed_ranked.position
    ), '[]'::jsonb),
    count(*)::int,
    max(CASE WHEN confirmed_ranked.owner_id = auth.uid() THEN confirmed_ranked.position END)
  INTO v_s1_confirmed, v_s1_confirmed_total, v_self_s1_confirmed_pos
  FROM confirmed_ranked;

  -- Right: waiting board (rejectors last; offered pending excluded)
  WITH latest_country AS (
    SELECT DISTINCT ON (e.owner_id)
      e.owner_id,
      upper(nullif(btrim(coalesce(e.country_code, '')), '')) AS country_code
    FROM public.owner_login_origin_events e
    WHERE nullif(btrim(coalesce(e.country_code, '')), '') IS NOT NULL
    ORDER BY e.owner_id, e.logged_in_at DESC, e.id DESC
  ),
  latest_timezone AS (
    SELECT DISTINCT ON (e.owner_id)
      e.owner_id,
      nullif(btrim(coalesce(e.timezone_name, '')), '') AS timezone_name
    FROM public.owner_login_origin_events e
    WHERE nullif(btrim(coalesce(e.timezone_name, '')), '') IS NOT NULL
    ORDER BY e.owner_id, e.logged_in_at DESC, e.id DESC
  ),
  board AS (
    SELECT
      r.owner_id,
      coalesce(nullif(btrim(public.owner_registry_resolve_tag(r.owner_id)), ''), '—') AS owner_tag,
      r.status AS registry_status,
      u.created_at AS account_created_at,
      r.waiting_list_admin_sort AS admin_sort,
      coalesce(r.confirmed_test_season, false) AS confirmed_test_season,
      true AS has_club,
      'club_owner'::text AS list_kind,
      lc.country_code,
      coalesce(
        nullif(btrim(coalesce(r.owner_timezone, '')), ''),
        (
          SELECT nullif(btrim(coalesce(c.owner_timezone, '')), '')
          FROM public."Clubs" c
          WHERE c.owner_id = r.owner_id
          ORDER BY c."ShortName"
          LIMIT 1
        ),
        lt.timezone_name
      ) AS origin_timezone,
      (r.season1_invite_response = 'declined') AS season1_rejected
    FROM public.gpsl_owner_registry r
    JOIN auth.users u ON u.id = r.owner_id
    LEFT JOIN latest_country lc ON lc.owner_id = r.owner_id
    LEFT JOIN latest_timezone lt ON lt.owner_id = r.owner_id
    WHERE EXISTS (SELECT 1 FROM public."Clubs" c WHERE c.owner_id = r.owner_id)

    UNION ALL

    SELECT
      r.owner_id,
      coalesce(nullif(btrim(public.owner_registry_resolve_tag(r.owner_id)), ''), '—') AS owner_tag,
      r.status AS registry_status,
      u.created_at AS account_created_at,
      r.waiting_list_admin_sort AS admin_sort,
      coalesce(r.confirmed_test_season, false) AS confirmed_test_season,
      false AS has_club,
      'waiting'::text AS list_kind,
      lc.country_code,
      coalesce(
        nullif(btrim(coalesce(r.owner_timezone, '')), ''),
        (
          SELECT nullif(btrim(coalesce(c.owner_timezone, '')), '')
          FROM public."Clubs" c
          WHERE c.owner_id = r.owner_id
          ORDER BY c."ShortName"
          LIMIT 1
        ),
        lt.timezone_name
      ) AS origin_timezone,
      (r.season1_invite_response = 'declined') AS season1_rejected
    FROM public.gpsl_owner_registry r
    JOIN auth.users u ON u.id = r.owner_id
    LEFT JOIN latest_country lc ON lc.owner_id = r.owner_id
    LEFT JOIN latest_timezone lt ON lt.owner_id = r.owner_id
    WHERE public.waiting_list_on_list_status(r.status)
      AND NOT EXISTS (SELECT 1 FROM public."Clubs" c WHERE c.owner_id = r.owner_id)
      AND coalesce(r.season1_invite_response, '') IS DISTINCT FROM 'accepted'
      AND NOT (
        r.season1_invite_status = 'offered'
        AND r.season1_invite_response IS NULL
      )
  ),
  ranked AS (
    SELECT
      b.*,
      row_number() OVER (
        ORDER BY
          CASE WHEN b.has_club THEN 0 ELSE 1 END,
          CASE WHEN b.season1_rejected THEN 1 ELSE 0 END,
          CASE WHEN v_use_admin THEN b.admin_sort END NULLS LAST,
          b.account_created_at,
          b.owner_id
      )::int AS position
    FROM board b
  )
  SELECT
    coalesce(jsonb_agg(
      jsonb_build_object(
        'position', ranked.position,
        'owner_id', ranked.owner_id,
        'owner_tag', ranked.owner_tag,
        'status', ranked.registry_status,
        'list_kind', ranked.list_kind,
        'has_club', ranked.has_club,
        'confirmed_test_season', ranked.confirmed_test_season,
        'country_code', ranked.country_code,
        'origin_timezone', ranked.origin_timezone,
        'season1_rejected', ranked.season1_rejected
      )
      ORDER BY ranked.position
    ), '[]'::jsonb),
    count(*)::int,
    max(CASE WHEN ranked.owner_id = auth.uid() THEN ranked.position END)
  INTO v_rows, v_total, v_self_pos
  FROM ranked;

  RETURN jsonb_build_object(
    'total', coalesce(v_total, 0),
    'rows', coalesce(v_rows, '[]'::jsonb),
    'my_position', v_self_pos,
    'on_board_mode', v_on_board_mode,
    'on_board', coalesce(v_on_board, '[]'::jsonb),
    'on_board_total', coalesce(v_on_board_total, 0),
    'my_on_board_position', v_self_on_board_pos,
    'season1_confirmed', coalesce(v_s1_confirmed, '[]'::jsonb),
    'season1_confirmed_total', coalesce(v_s1_confirmed_total, 0),
    'my_season1_confirmed_position', v_self_s1_confirmed_pos
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.waiting_list_public() TO authenticated;

-- ---------------------------------------------------------------------------
-- 6) Backfill inbox + Discord for already-offered owners
-- ---------------------------------------------------------------------------
DO $backfill$
DECLARE
  r record;
  v_tag text;
  v_deadline_label text;
  v_title text;
  v_body text;
  v_inbox_id bigint;
  v_discord_id bigint;
  v_token text;
  v_inbox_n int := 0;
  v_discord_n int := 0;
  v_offered_n int := 0;
BEGIN
  FOR r IN
    SELECT *
    FROM public.gpsl_owner_registry o
    WHERE o.season1_invite_status = 'offered'
      AND o.season1_invite_response IS NULL
  LOOP
    v_offered_n := v_offered_n + 1;

    v_tag := coalesce(
      nullif(btrim(public.owner_registry_resolve_tag(r.owner_id)), ''),
      nullif(btrim(r.owner_tag), ''),
      'owner'
    );

    v_token := coalesce(
      nullif(btrim(r.season1_invite_token), ''),
      (
        SELECT encode(extensions.gen_random_bytes(12), 'hex')
        WHERE to_regprocedure('extensions.gen_random_bytes(integer)') IS NOT NULL
      ),
      replace(gen_random_uuid()::text, '-', '')
    );
    IF r.season1_invite_token IS NULL THEN
      UPDATE public.gpsl_owner_registry
      SET season1_invite_token = v_token
      WHERE owner_id = r.owner_id;
    END IF;

    v_deadline_label := CASE
      WHEN r.season1_invite_deadline_at IS NULL THEN '48 hours'
      ELSE public.season1_invite_format_deadline_uk(r.season1_invite_deadline_at)
    END;

    v_title := 'You''re invited to GPSL Season 1';
    v_body :=
      'Congratulations ' || v_tag
      || ' — you have been invited to join GPSL Season 1 (club auction).'
      || E'\n\nYou have 48 hours to accept or decline.'
      || E'\nDeadline: ' || v_deadline_label || '.'
      || E'\nQueue position: #' || coalesce(r.season1_invite_queue_num::text, '—') || '.'
      || E'\n\nRespond from Inbox, Waiting list, or your email links.';

    v_inbox_id := public.season1_invite_send_inbox(
      r.owner_id,
      v_title,
      v_body,
      'waiting_list.html#season1',
      'season1_invite:' || r.owner_id::text || ':' || v_token
    );
    IF v_inbox_id IS NOT NULL THEN
      v_inbox_n := v_inbox_n + 1;
      UPDATE public.gpsl_owner_registry
      SET season1_invite_inbox_id = coalesce(season1_invite_inbox_id, v_inbox_id)
      WHERE owner_id = r.owner_id;
    END IF;

    v_discord_id := public.season1_invite_enqueue_discord_news(
      r.owner_id,
      v_tag,
      r.season1_invite_deadline_at,
      v_deadline_label,
      r.season1_invite_queue_num,
      v_token,
      r.discord_user_id
    );
    IF v_discord_id IS NOT NULL THEN
      v_discord_n := v_discord_n + 1;
    END IF;
  END LOOP;

  RAISE NOTICE
    'Season 1 repair: offered=% inbox=% discord_queued=% — Push Discord News if posts do not appear.',
    v_offered_n, v_inbox_n, v_discord_n;
END;
$backfill$;

NOTIFY pgrst, 'reload schema';
