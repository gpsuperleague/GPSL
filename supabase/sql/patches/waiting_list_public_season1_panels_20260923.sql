-- =============================================================================
-- Waiting list public: Season 1 confirmed / Invited / Owner waiting list
--
-- Layout for waiting_list.html (exclusive — each owner in at most one panel):
--   Left:  Confirmed for Season 1  (accepted) — highest priority
--   Middle: Invited               (offer pending) — next
--   Right: Owner waiting list     (everyone else who is NOT archived)
--
-- Depends on: season1_league_invite_queue_20260923.sql
-- Safe re-run.
-- =============================================================================

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
  v_on_board_mode text;
  v_on_board jsonb;
  v_on_board_total int;
  v_self_on_board_pos int;
  v_s1_confirmed jsonb;
  v_s1_confirmed_total int;
  v_self_s1_confirmed_pos int;
  v_use_admin boolean;
BEGIN
  v_on_board_mode := 'invited';

  -- Admin sort only when every non-archived, non-S1-panel owner has a sort key
  SELECT coalesce(bool_and(
    r.waiting_list_use_admin_sort AND r.waiting_list_admin_sort IS NOT NULL
  ), false)
  INTO v_use_admin
  FROM public.gpsl_owner_registry r
  WHERE coalesce(r.status, '') IS DISTINCT FROM 'archived'
    AND coalesce(r.season1_invite_response, '') IS DISTINCT FROM 'accepted'
    AND NOT (
      r.season1_invite_status = 'offered'
      AND r.season1_invite_response IS NULL
      AND (
        r.season1_invite_deadline_at IS NULL
        OR r.season1_invite_deadline_at > now()
      )
    );

  -- Middle panel: Season 1 invites awaiting a reply
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
      lt.timezone_name AS origin_timezone,
      coalesce(
        nullif(btrim(coalesce(r.owner_timezone, '')), ''),
        (
          SELECT nullif(btrim(coalesce(c.owner_timezone, '')), '')
          FROM public."Clubs" c
          WHERE c.owner_id = r.owner_id
          ORDER BY c."ShortName"
          LIMIT 1
        )
      ) AS owner_timezone
    FROM public.gpsl_owner_registry r
    LEFT JOIN latest_country lc ON lc.owner_id = r.owner_id
    LEFT JOIN latest_timezone lt ON lt.owner_id = r.owner_id
    WHERE coalesce(r.status, '') IS DISTINCT FROM 'archived'
      AND r.season1_invite_status = 'offered'
      AND r.season1_invite_response IS NULL
      AND (
        r.season1_invite_deadline_at IS NULL
        OR r.season1_invite_deadline_at > now()
      )
  ),
  invited_ranked AS (
    SELECT
      i.*,
      row_number() OVER (
        ORDER BY
          i.queue_num NULLS LAST,
          i.invited_at NULLS LAST,
          i.owner_tag,
          i.owner_id
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
        'owner_timezone', invited_ranked.owner_timezone,
        'deadline_at', invited_ranked.deadline_at
      )
      ORDER BY invited_ranked.position
    ), '[]'::jsonb),
    count(*)::int,
    max(CASE WHEN invited_ranked.owner_id = auth.uid() THEN invited_ranked.position END)
  INTO v_on_board, v_on_board_total, v_self_on_board_pos
  FROM invited_ranked;

  -- Left panel: accepted Season 1
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
      lt.timezone_name AS origin_timezone,
      coalesce(
        nullif(btrim(coalesce(r.owner_timezone, '')), ''),
        (
          SELECT nullif(btrim(coalesce(c.owner_timezone, '')), '')
          FROM public."Clubs" c
          WHERE c.owner_id = r.owner_id
          ORDER BY c."ShortName"
          LIMIT 1
        )
      ) AS owner_timezone
    FROM public.gpsl_owner_registry r
    LEFT JOIN latest_country lc ON lc.owner_id = r.owner_id
    LEFT JOIN latest_timezone lt ON lt.owner_id = r.owner_id
    WHERE coalesce(r.status, '') IS DISTINCT FROM 'archived'
      AND r.season1_invite_response = 'accepted'
  ),
  confirmed_ranked AS (
    SELECT
      c.*,
      row_number() OVER (
        ORDER BY
          c.queue_num NULLS LAST,
          c.responded_at NULLS LAST,
          c.owner_tag,
          c.owner_id
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
        'origin_timezone', confirmed_ranked.origin_timezone,
        'owner_timezone', confirmed_ranked.owner_timezone
      )
      ORDER BY confirmed_ranked.position
    ), '[]'::jsonb),
    count(*)::int,
    max(CASE WHEN confirmed_ranked.owner_id = auth.uid() THEN confirmed_ranked.position END)
  INTO v_s1_confirmed, v_s1_confirmed_total, v_self_s1_confirmed_pos
  FROM confirmed_ranked;

  -- Right panel: ALL non-archived owners who are not Confirmed and not Invited
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
      EXISTS (SELECT 1 FROM public."Clubs" c WHERE c.owner_id = r.owner_id) AS has_club,
      CASE
        WHEN EXISTS (SELECT 1 FROM public."Clubs" c WHERE c.owner_id = r.owner_id)
          THEN 'club_owner'::text
        ELSE 'waiting'::text
      END AS list_kind,
      lc.country_code,
      lt.timezone_name AS origin_timezone,
      coalesce(
        nullif(btrim(coalesce(r.owner_timezone, '')), ''),
        (
          SELECT nullif(btrim(coalesce(c.owner_timezone, '')), '')
          FROM public."Clubs" c
          WHERE c.owner_id = r.owner_id
          ORDER BY c."ShortName"
          LIMIT 1
        )
      ) AS owner_timezone,
      (r.season1_invite_response = 'declined') AS season1_rejected
    FROM public.gpsl_owner_registry r
    JOIN auth.users u ON u.id = r.owner_id
    LEFT JOIN latest_country lc ON lc.owner_id = r.owner_id
    LEFT JOIN latest_timezone lt ON lt.owner_id = r.owner_id
    WHERE coalesce(r.status, '') IS DISTINCT FROM 'archived'
      -- Exclusive panels: Confirmed > Invited > this board
      AND coalesce(r.season1_invite_response, '') IS DISTINCT FROM 'accepted'
      AND NOT (
        r.season1_invite_status = 'offered'
        AND r.season1_invite_response IS NULL
        AND (
          r.season1_invite_deadline_at IS NULL
          OR r.season1_invite_deadline_at > now()
        )
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
        'owner_timezone', ranked.owner_timezone,
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

NOTIFY pgrst, 'reload schema';
