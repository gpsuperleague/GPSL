-- =============================================================================
-- Public waiting_list.html display (admin board unchanged)
--
-- Left ("I'm on board"): owners invited to club auction
--   (gpsl_owner_registry.status = 'awaiting_club_auction')
-- Right (Owner waiting list): same people/sections as admin season board
--   1) current club owners (test-season board) in admin priority order
--   2) waiting-list members (no club) below them in admin priority order
--   Invited-to-auction stay on the left only (not duplicated on the right).
--
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
  v_use_admin boolean;
BEGIN
  -- Label kept for older clients; left panel is now auction invitees.
  v_on_board_mode := 'invited';

  SELECT coalesce(bool_and(
    r.waiting_list_use_admin_sort AND r.waiting_list_admin_sort IS NOT NULL
  ), false)
  INTO v_use_admin
  FROM public.gpsl_owner_registry r
  JOIN auth.users u ON u.id = r.owner_id
  WHERE (
      public.waiting_list_on_list_status(r.status)
      AND NOT EXISTS (SELECT 1 FROM public."Clubs" c WHERE c.owner_id = r.owner_id)
    )
    OR EXISTS (SELECT 1 FROM public."Clubs" c WHERE c.owner_id = r.owner_id);

  -- Left panel: invited to club auction (no club yet)
  WITH latest_origin AS (
    SELECT DISTINCT ON (e.owner_id)
      e.owner_id,
      upper(nullif(btrim(coalesce(e.country_code, '')), '')) AS country_code,
      nullif(btrim(coalesce(e.timezone_name, '')), '') AS timezone_name
    FROM public.owner_login_origin_events e
    WHERE nullif(
      btrim(coalesce(e.country_code, e.timezone_name, '')),
      ''
    ) IS NOT NULL
    ORDER BY e.owner_id, e.logged_in_at DESC, e.id DESC
  ),
  invited AS (
    SELECT
      r.owner_id,
      public.owner_registry_resolve_tag(r.owner_id) AS owner_tag,
      r.status_changed_at AS invited_at,
      lo.country_code,
      lo.timezone_name AS origin_timezone
    FROM public.gpsl_owner_registry r
    LEFT JOIN latest_origin lo
      ON lo.owner_id = r.owner_id
    WHERE r.status = 'awaiting_club_auction'
      AND NOT EXISTS (
        SELECT 1 FROM public."Clubs" c WHERE c.owner_id = r.owner_id
      )
  ),
  invited_ranked AS (
    SELECT
      i.*,
      row_number() OVER (
        ORDER BY i.invited_at NULLS LAST, i.owner_tag, i.owner_id
      )::int AS position
    FROM invited i
  )
  SELECT
    coalesce(jsonb_agg(
      jsonb_build_object(
        'position', invited_ranked.position,
        'owner_tag', invited_ranked.owner_tag,
        'country_code', invited_ranked.country_code,
        'origin_timezone', invited_ranked.origin_timezone
      )
      ORDER BY invited_ranked.position
    ), '[]'::jsonb),
    count(*)::int,
    max(CASE WHEN invited_ranked.owner_id = auth.uid() THEN invited_ranked.position END)
  INTO v_on_board, v_on_board_total, v_self_on_board_pos
  FROM invited_ranked;

  -- Right panel: club owners first, then waiting-list members (admin board order)
  WITH latest_origin AS (
    SELECT DISTINCT ON (e.owner_id)
      e.owner_id,
      upper(nullif(btrim(coalesce(e.country_code, '')), '')) AS country_code,
      nullif(btrim(coalesce(e.timezone_name, '')), '') AS timezone_name
    FROM public.owner_login_origin_events e
    WHERE nullif(
      btrim(coalesce(e.country_code, e.timezone_name, '')),
      ''
    ) IS NOT NULL
    ORDER BY e.owner_id, e.logged_in_at DESC, e.id DESC
  ),
  board AS (
    -- Current club owners (admin "Owners" section / test-season board)
    SELECT
      r.owner_id,
      coalesce(nullif(btrim(public.owner_registry_resolve_tag(r.owner_id)), ''), '—') AS owner_tag,
      r.status AS registry_status,
      u.created_at AS account_created_at,
      r.waiting_list_admin_sort AS admin_sort,
      coalesce(r.confirmed_test_season, false) AS confirmed_test_season,
      true AS has_club,
      'club_owner'::text AS list_kind,
      lo.country_code,
      lo.timezone_name AS origin_timezone
    FROM public.gpsl_owner_registry r
    JOIN auth.users u ON u.id = r.owner_id
    LEFT JOIN latest_origin lo ON lo.owner_id = r.owner_id
    WHERE EXISTS (SELECT 1 FROM public."Clubs" c WHERE c.owner_id = r.owner_id)

    UNION ALL

    -- Waiting-list members without a club (admin "Waiting list" section, excl. invited)
    SELECT
      r.owner_id,
      coalesce(nullif(btrim(public.owner_registry_resolve_tag(r.owner_id)), ''), '—') AS owner_tag,
      r.status AS registry_status,
      u.created_at AS account_created_at,
      r.waiting_list_admin_sort AS admin_sort,
      coalesce(r.confirmed_test_season, false) AS confirmed_test_season,
      false AS has_club,
      'waiting'::text AS list_kind,
      lo.country_code,
      lo.timezone_name AS origin_timezone
    FROM public.gpsl_owner_registry r
    JOIN auth.users u ON u.id = r.owner_id
    LEFT JOIN latest_origin lo ON lo.owner_id = r.owner_id
    WHERE public.waiting_list_on_list_status(r.status)
      AND NOT EXISTS (SELECT 1 FROM public."Clubs" c WHERE c.owner_id = r.owner_id)
  ),
  ranked AS (
    SELECT
      b.*,
      row_number() OVER (
        ORDER BY
          -- Owners block first, then waiting — same section layout as admin board
          CASE WHEN b.has_club THEN 0 ELSE 1 END,
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
        'owner_tag', ranked.owner_tag,
        'status', ranked.registry_status,
        'list_kind', ranked.list_kind,
        'has_club', ranked.has_club,
        'confirmed_test_season', ranked.confirmed_test_season,
        'country_code', ranked.country_code,
        'origin_timezone', ranked.origin_timezone
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
    'my_on_board_position', v_self_on_board_pos
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.waiting_list_public() TO authenticated;

NOTIFY pgrst, 'reload schema';
