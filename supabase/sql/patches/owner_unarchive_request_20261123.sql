-- Archived members ask to be unarchived. Staff approve or reject.
-- News channel ping and a Discord DM on request, approval, and rejection.
-- Safe re-run.

CREATE TABLE IF NOT EXISTS public.owner_unarchive_requests (
  id bigserial PRIMARY KEY,
  owner_id uuid NOT NULL,
  status text NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending', 'approved', 'rejected')),
  requested_at timestamptz NOT NULL DEFAULT now(),
  resolved_at timestamptz,
  staff_alert_id bigint
);

CREATE UNIQUE INDEX IF NOT EXISTS owner_unarchive_requests_one_pending
  ON public.owner_unarchive_requests (owner_id)
  WHERE status = 'pending';

ALTER TABLE public.owner_unarchive_requests ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.owner_unarchive_requests FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.owner_unarchive_discord_notice(
  p_owner_id uuid,
  p_kind text,
  p_request_id bigint
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_tag text;
  v_discord text;
  v_headline text;
  v_body text;
  v_color int;
BEGIN
  SELECT
    coalesce(nullif(btrim(r.owner_tag), ''), 'member'),
    nullif(btrim(r.discord_user_id), '')
  INTO v_tag, v_discord
  FROM public.gpsl_owner_registry r
  WHERE r.owner_id = p_owner_id;

  v_tag := coalesce(v_tag, 'member');

  IF p_kind = 'approved' THEN
    v_headline := format('Unarchive approved — %s', v_tag);
    v_body := format(
      '%s, your unarchive request is approved. You are back on the waiting list as a returning member.',
      v_tag
    );
    v_color := 5763719;
  ELSIF p_kind = 'rejected' THEN
    v_headline := format('Unarchive request declined — %s', v_tag);
    v_body := format(
      '%s, your unarchive request was declined. Your account stays archived.',
      v_tag
    );
    v_color := 15548997;
  ELSE
    v_headline := format('Unarchive request — %s', v_tag);
    v_body := format(
      '%s asked to unarchive their GPSL account. Staff are reviewing it. You will hear here when it is approved or declined.',
      v_tag
    );
    v_color := 16753920;
  END IF;

  IF to_regprocedure('public.gpsl_discord_feed_enqueue(text,text,text,integer,text,jsonb)') IS NULL THEN
    RETURN;
  END IF;

  PERFORM public.gpsl_discord_feed_enqueue(
    'unarchive_request',
    v_headline,
    v_body,
    v_color,
    format('unarchive:%s:%s', p_request_id, p_kind),
    jsonb_build_object(
      'channel', 'news',
      'ping', true,
      'try_dm', true,
      'owner_tag', v_tag,
      'discord_user_id', v_discord,
      'request_id', p_request_id,
      'kind', p_kind
    )
  );

  IF to_regprocedure('public.gpsl_discord_feed_request_flush()') IS NOT NULL THEN
    BEGIN
      PERFORM public.gpsl_discord_feed_request_flush();
    EXCEPTION WHEN OTHERS THEN
      NULL;
    END;
  END IF;
END;
$function$;

REVOKE ALL ON FUNCTION public.owner_unarchive_discord_notice(uuid, text, bigint)
  FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.owner_unarchive_request()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
SET statement_timeout = '25s'
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_row public.gpsl_owner_registry%ROWTYPE;
  v_has_club boolean := false;
  v_id bigint;
  v_existing bigint;
  v_alert bigint;
  v_tag text;
  v_body text;
BEGIN
  IF v_uid IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_authenticated');
  END IF;

  SELECT * INTO v_row
  FROM public.gpsl_owner_registry r
  WHERE r.owner_id = v_uid
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_on_registry');
  END IF;

  IF coalesce(v_row.status, '') IS DISTINCT FROM 'archived' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_archived', 'status', v_row.status);
  END IF;

  SELECT EXISTS (
    SELECT 1
    FROM public."Clubs" c
    WHERE c.owner_id = v_uid
      AND c."ShortName" IS DISTINCT FROM 'FOREIGN'
      AND coalesce(c.is_archived, false) = false
  ) INTO v_has_club;

  IF v_has_club THEN
    RETURN jsonb_build_object(
      'ok', false,
      'reason', 'still_has_club',
      'detail', 'Your account still has a club. Contact staff before asking to be unarchived.'
    );
  END IF;

  SELECT r.id INTO v_existing
  FROM public.owner_unarchive_requests r
  WHERE r.owner_id = v_uid
    AND r.status = 'pending'
  LIMIT 1;

  IF v_existing IS NOT NULL THEN
    RETURN jsonb_build_object(
      'ok', true,
      'status', 'pending',
      'request_id', v_existing,
      'already', true
    );
  END IF;

  INSERT INTO public.owner_unarchive_requests (owner_id)
  VALUES (v_uid)
  RETURNING id INTO v_id;

  v_tag := coalesce(nullif(btrim(v_row.owner_tag), ''), 'member');
  v_body := format(
    E'%s asked to unarchive their account.\nLast club: %s.\nApprove puts them back on the waiting list as a returning member. Reject leaves the account archived.',
    v_tag,
    coalesce(nullif(btrim(v_row.last_club_short_name), ''), 'none')
  );

  IF to_regprocedure('public.gpsl_staff_alert_create(text,text,text,text,jsonb,text)') IS NOT NULL THEN
    BEGIN
      v_alert := public.gpsl_staff_alert_create(
        'unarchive_request',
        format('Unarchive requested: %s', v_tag),
        v_body,
        'admin_staff_hub.html#alerts',
        jsonb_build_object(
          'request_id', v_id,
          'owner_id', v_uid,
          'owner_tag', v_tag,
          'last_club', v_row.last_club_short_name
        ),
        format('unarchive_request:%s', v_id)
      );
      UPDATE public.owner_unarchive_requests
      SET staff_alert_id = v_alert
      WHERE id = v_id;
    EXCEPTION WHEN OTHERS THEN
      v_alert := NULL;
    END;
  END IF;

  PERFORM public.owner_unarchive_discord_notice(v_uid, 'requested', v_id);

  RETURN jsonb_build_object(
    'ok', true,
    'status', 'pending',
    'request_id', v_id,
    'staff_alert_id', v_alert
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.owner_unarchive_request() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.owner_unarchive_request() TO authenticated;

CREATE OR REPLACE FUNCTION public.owner_unarchive_request_mine()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_row public.owner_unarchive_requests%ROWTYPE;
BEGIN
  IF v_uid IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_authenticated');
  END IF;

  SELECT * INTO v_row
  FROM public.owner_unarchive_requests r
  WHERE r.owner_id = v_uid
  ORDER BY r.requested_at DESC, r.id DESC
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', true, 'status', 'none');
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'status', v_row.status,
    'request_id', v_row.id,
    'requested_at', v_row.requested_at,
    'resolved_at', v_row.resolved_at
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.owner_unarchive_request_mine() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.owner_unarchive_request_mine() TO authenticated;

CREATE OR REPLACE FUNCTION public.waiting_list_self_unarchive_to_list()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
SET statement_timeout = '25s'
AS $function$
DECLARE
  v_res jsonb;
BEGIN
  v_res := public.owner_unarchive_request();
  IF coalesce((v_res->>'ok')::boolean, false)
     AND coalesce(v_res->>'status', '') = 'pending' THEN
    RETURN jsonb_build_object(
      'ok', false,
      'reason', 'pending_review',
      'detail', 'Your unarchive request is being reviewed. Refresh this page.'
    );
  END IF;
  RETURN v_res;
END;
$function$;

CREATE OR REPLACE FUNCTION public.owner_unarchive_request_after_restore()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_req public.owner_unarchive_requests%ROWTYPE;
BEGIN
  IF OLD.status IS DISTINCT FROM 'archived'
     OR NEW.status IS NOT DISTINCT FROM 'archived' THEN
    RETURN NEW;
  END IF;

  SELECT * INTO v_req
  FROM public.owner_unarchive_requests r
  WHERE r.owner_id = NEW.owner_id
    AND r.status = 'pending'
  ORDER BY r.id DESC
  LIMIT 1
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN NEW;
  END IF;

  UPDATE public.owner_unarchive_requests
  SET status = 'approved',
      resolved_at = now()
  WHERE id = v_req.id;

  IF v_req.staff_alert_id IS NOT NULL THEN
    UPDATE public.gpsl_staff_alerts
    SET body = coalesce(body, '') || E'\n\nApproved. They are back on the waiting list.',
        metadata = coalesce(metadata, '{}'::jsonb) || jsonb_build_object('resolved', 'approved')
    WHERE id = v_req.staff_alert_id;
  END IF;

  PERFORM public.owner_unarchive_discord_notice(NEW.owner_id, 'approved', v_req.id);
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS owner_unarchive_request_after_restore ON public.gpsl_owner_registry;
CREATE TRIGGER owner_unarchive_request_after_restore
  AFTER UPDATE OF status ON public.gpsl_owner_registry
  FOR EACH ROW
  EXECUTE FUNCTION public.owner_unarchive_request_after_restore();

CREATE OR REPLACE FUNCTION public.admin_owner_unarchive_request_resolve(
  p_request_id bigint,
  p_approve boolean
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
SET statement_timeout = '25s'
AS $function$
DECLARE
  v_req public.owner_unarchive_requests%ROWTYPE;
  v_tag text;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  SELECT * INTO v_req
  FROM public.owner_unarchive_requests
  WHERE id = p_request_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Request not found';
  END IF;

  IF v_req.status IS DISTINCT FROM 'pending' THEN
    RETURN jsonb_build_object('ok', true, 'status', v_req.status, 'already', true);
  END IF;

  IF coalesce(p_approve, false) THEN
    IF EXISTS (
      SELECT 1 FROM public."Clubs" c
      WHERE c.owner_id = v_req.owner_id
        AND c."ShortName" IS DISTINCT FROM 'FOREIGN'
        AND coalesce(c.is_archived, false) = false
    ) THEN
      RAISE EXCEPTION 'That account still has a club';
    END IF;

    PERFORM public.waiting_list_enqueue_returning(v_req.owner_id);
    RETURN jsonb_build_object('ok', true, 'status', 'approved', 'request_id', v_req.id);
  END IF;

  UPDATE public.owner_unarchive_requests
  SET status = 'rejected',
      resolved_at = now()
  WHERE id = v_req.id;

  SELECT coalesce(nullif(btrim(r.owner_tag), ''), 'member')
  INTO v_tag
  FROM public.gpsl_owner_registry r
  WHERE r.owner_id = v_req.owner_id;

  IF v_req.staff_alert_id IS NOT NULL THEN
    UPDATE public.gpsl_staff_alerts
    SET body = coalesce(body, '') || E'\n\nDeclined. The account stays archived.',
        metadata = coalesce(metadata, '{}'::jsonb) || jsonb_build_object('resolved', 'rejected')
    WHERE id = v_req.staff_alert_id;
  END IF;

  PERFORM public.owner_unarchive_discord_notice(v_req.owner_id, 'rejected', v_req.id);

  RETURN jsonb_build_object(
    'ok', true,
    'status', 'rejected',
    'request_id', v_req.id,
    'owner_tag', v_tag
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.admin_owner_unarchive_request_resolve(bigint, boolean)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_owner_unarchive_request_resolve(bigint, boolean)
  TO authenticated;

SELECT jsonb_build_object(
  'request', to_regprocedure('public.owner_unarchive_request()') IS NOT NULL,
  'resolve', to_regprocedure('public.admin_owner_unarchive_request_resolve(bigint,boolean)') IS NOT NULL
) AS ready;
