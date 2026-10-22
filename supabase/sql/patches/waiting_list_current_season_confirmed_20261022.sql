-- =============================================================================
-- Waiting list panels (corrected)
--
-- Confirmed for current season = club owners only (Clubs.owner_id set),
--   excluding archived registry accounts.
-- Invited                 = live season invite awaiting accept/decline.
-- Waiting list            = non-owners on the registry who are not archived
--   and not holding a live invite.
-- Archived accounts never appear on this page.
--
-- Safe re-run. Replaces waiting_list_public().
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
  v_confirmed jsonb;
  v_confirmed_total int;
  v_self_confirmed_pos int;
  v_use_admin boolean;
  v_debug jsonb;
BEGIN
  v_on_board_mode := 'invited';

  SELECT jsonb_build_object(
    'registry_non_archived', count(*) FILTER (
      WHERE coalesce(r.status, '') IS DISTINCT FROM 'archived'
    ),
    'registry_archived', count(*) FILTER (
      WHERE coalesce(r.status, '') = 'archived'
    ),
    'club_owners', (
      SELECT count(DISTINCT c.owner_id)
      FROM public."Clubs" c
      WHERE c.owner_id IS NOT NULL
    ),
    'club_owners_non_archived', (
      SELECT count(DISTINCT c.owner_id)
      FROM public."Clubs" c
      LEFT JOIN public.gpsl_owner_registry r ON r.owner_id = c.owner_id
      WHERE c.owner_id IS NOT NULL
        AND coalesce(r.status, '') IS DISTINCT FROM 'archived'
    ),
    'registry_offered_live', count(*) FILTER (
      WHERE coalesce(r.status, '') IS DISTINCT FROM 'archived'
        AND coalesce(r.season1_invite_status, '') = 'offered'
        AND r.season1_invite_response IS NULL
        AND (r.season1_invite_deadline_at IS NULL OR r.season1_invite_deadline_at > now())
    )
  )
  INTO v_debug
  FROM public.gpsl_owner_registry r;

  -- Admin sort only among true waiting-list candidates
  SELECT coalesce(bool_and(
    r.waiting_list_use_admin_sort AND r.waiting_list_admin_sort IS NOT NULL
  ), false)
  INTO v_use_admin
  FROM public.gpsl_owner_registry r
  WHERE coalesce(r.status, '') IS DISTINCT FROM 'archived'
    AND NOT EXISTS (SELECT 1 FROM public."Clubs" c WHERE c.owner_id = r.owner_id)
    AND NOT (
      r.season1_invite_status = 'offered'
      AND r.season1_invite_response IS NULL
      AND (
        r.season1_invite_deadline_at IS NULL
        OR r.season1_invite_deadline_at > now()
      )
    );

  -- Middle: live invites awaiting reply (never archived)
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
      -- If they already own a club, they belong in Confirmed, not Invited
      AND NOT EXISTS (SELECT 1 FROM public."Clubs" c WHERE c.owner_id = r.owner_id)
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

  -- Left: confirmed = current club owners (not archived)
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
    SELECT DISTINCT ON (c.owner_id)
      c.owner_id,
      coalesce(nullif(btrim(public.owner_registry_resolve_tag(c.owner_id)), ''), '—') AS owner_tag,
      r.season1_invite_queue_num AS queue_num,
      r.season1_invite_responded_at AS responded_at,
      true AS has_club,
      'club_owner'::text AS list_kind,
      lc.country_code,
      lt.timezone_name AS origin_timezone,
      coalesce(
        nullif(btrim(coalesce(r.owner_timezone, '')), ''),
        nullif(btrim(coalesce(c.owner_timezone, '')), '')
      ) AS owner_timezone,
      (
        SELECT min(c2."ShortName")
        FROM public."Clubs" c2
        WHERE c2.owner_id = c.owner_id
      ) AS club_sort
    FROM public."Clubs" c
    LEFT JOIN public.gpsl_owner_registry r ON r.owner_id = c.owner_id
    LEFT JOIN latest_country lc ON lc.owner_id = c.owner_id
    LEFT JOIN latest_timezone lt ON lt.owner_id = c.owner_id
    WHERE c.owner_id IS NOT NULL
      AND coalesce(r.status, '') IS DISTINCT FROM 'archived'
    ORDER BY c.owner_id, c."ShortName"
  ),
  confirmed_ranked AS (
    SELECT
      conf.*,
      row_number() OVER (
        ORDER BY
          conf.club_sort NULLS LAST,
          conf.owner_tag,
          conf.owner_id
      )::int AS position
    FROM confirmed conf
  )
  SELECT
    coalesce(jsonb_agg(
      jsonb_build_object(
        'position', confirmed_ranked.position,
        'owner_id', confirmed_ranked.owner_id,
        'owner_tag', confirmed_ranked.owner_tag,
        'queue_num', confirmed_ranked.queue_num,
        'has_club', confirmed_ranked.has_club,
        'list_kind', confirmed_ranked.list_kind,
        'country_code', confirmed_ranked.country_code,
        'origin_timezone', confirmed_ranked.origin_timezone,
        'owner_timezone', confirmed_ranked.owner_timezone
      )
      ORDER BY confirmed_ranked.position
    ), '[]'::jsonb),
    count(*)::int,
    max(CASE WHEN confirmed_ranked.owner_id = auth.uid() THEN confirmed_ranked.position END)
  INTO v_confirmed, v_confirmed_total, v_self_confirmed_pos
  FROM confirmed_ranked;

  -- Right: waiting list = non-owners, not archived, not live invited
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
      coalesce(r.status, 'active') AS registry_status,
      coalesce(
        public.waiting_list_account_created_at(r.owner_id),
        r.status_changed_at,
        r.returned_to_list_at
      ) AS account_created_at,
      r.waiting_list_admin_sort AS admin_sort,
      coalesce(r.confirmed_test_season, false) AS confirmed_test_season,
      false AS has_club,
      'waiting'::text AS list_kind,
      lc.country_code,
      lt.timezone_name AS origin_timezone,
      nullif(btrim(coalesce(r.owner_timezone, '')), '') AS owner_timezone,
      (r.season1_invite_response = 'declined') AS season1_rejected
    FROM public.gpsl_owner_registry r
    LEFT JOIN latest_country lc ON lc.owner_id = r.owner_id
    LEFT JOIN latest_timezone lt ON lt.owner_id = r.owner_id
    WHERE coalesce(r.status, '') IS DISTINCT FROM 'archived'
      -- Not a club owner
      AND NOT EXISTS (SELECT 1 FROM public."Clubs" c WHERE c.owner_id = r.owner_id)
      -- Not on the Invited panel
      AND NOT (
        coalesce(r.season1_invite_status, '') = 'offered'
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
          CASE WHEN b.season1_rejected THEN 1 ELSE 0 END,
          CASE WHEN v_use_admin THEN b.admin_sort END NULLS LAST,
          b.account_created_at NULLS LAST,
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
    'season1_confirmed', coalesce(v_confirmed, '[]'::jsonb),
    'season1_confirmed_total', coalesce(v_confirmed_total, 0),
    'my_season1_confirmed_position', v_self_confirmed_pos,
    'current_season_confirmed', coalesce(v_confirmed, '[]'::jsonb),
    'current_season_confirmed_total', coalesce(v_confirmed_total, 0),
    'my_current_season_confirmed_position', v_self_confirmed_pos,
    'debug', v_debug
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.waiting_list_public() TO authenticated;

NOTIFY pgrst, 'reload schema';
