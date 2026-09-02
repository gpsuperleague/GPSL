-- =============================================================================
-- Season owner board: surface on_break owners (Remove club limbo)
--
-- "Remove club" (not → Waiting) sets gpsl_owner_registry.status = 'on_break'.
-- That status was not on the board — owners looked deleted.
--
-- This patch:
--   1) waiting_list_admin() also returns on_break[]
--   2) admin_owner_return_to_waiting_list() for on_break → returning WL
--
-- Find anyone stuck now:
--   SELECT owner_id, owner_tag, status, last_club_short_name, status_note, status_changed_at
--   FROM public.gpsl_owner_registry WHERE status = 'on_break'
--   ORDER BY status_changed_at DESC NULLS LAST;
--
-- Put one back on waiting list:
--   SELECT public.admin_owner_return_to_waiting_list(NULL, '<email>');
-- =============================================================================

CREATE OR REPLACE FUNCTION public.admin_owner_return_to_waiting_list(
  p_owner_id uuid DEFAULT NULL,
  p_owner_email text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_user_id uuid;
  v_row public.gpsl_owner_registry%rowtype;
  v_email text;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  v_user_id := p_owner_id;
  IF v_user_id IS NULL AND nullif(btrim(coalesce(p_owner_email, '')), '') IS NOT NULL THEN
    SELECT u.id INTO v_user_id
    FROM auth.users u
    WHERE lower(u.email) = lower(btrim(p_owner_email))
    LIMIT 1;
  END IF;

  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Owner email or owner_id required';
  END IF;

  IF EXISTS (SELECT 1 FROM public."Clubs" c WHERE c.owner_id = v_user_id) THEN
    RAISE EXCEPTION 'Owner still has a club — remove club first, or use → Waiting from owners';
  END IF;

  SELECT * INTO v_row FROM public.gpsl_owner_registry WHERE owner_id = v_user_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'No registry row for owner';
  END IF;

  IF v_row.status = 'archived' THEN
    RAISE EXCEPTION 'Owner is archived — use Unarchive instead';
  END IF;

  IF public.waiting_list_on_list_status(v_row.status) THEN
    SELECT u.email INTO v_email FROM auth.users u WHERE u.id = v_user_id;
    RETURN jsonb_build_object(
      'ok', true,
      'already_on_waiting_list', true,
      'owner_id', v_user_id,
      'email', v_email,
      'owner_tag', public.owner_registry_resolve_tag(v_user_id),
      'status', v_row.status
    );
  END IF;

  PERFORM public.waiting_list_enqueue_returning(v_user_id);
  SELECT u.email INTO v_email FROM auth.users u WHERE u.id = v_user_id;

  RETURN jsonb_build_object(
    'ok', true,
    'already_on_waiting_list', false,
    'owner_id', v_user_id,
    'email', v_email,
    'owner_tag', public.owner_registry_resolve_tag(v_user_id),
    'status', 'member',
    'tier', 'returning'
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.waiting_list_admin()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_priority jsonb;
  v_waiting jsonb;
  v_other jsonb;
  v_on_break jsonb;
  v_use_admin boolean;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

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

  WITH board AS (
    SELECT
      r.owner_id,
      coalesce(nullif(btrim(public.owner_registry_resolve_tag(r.owner_id)), ''), '—') AS owner_tag,
      r.status AS registry_status,
      r.waiting_list_tier AS tier,
      u.created_at AS account_created_at,
      u.email::text AS email,
      r.last_club_short_name,
      r.absence_note,
      r.returned_to_list_at,
      r.pending_starting_balance,
      r.waiting_list_use_admin_sort AS use_admin_sort,
      r.waiting_list_admin_sort AS admin_sort,
      coalesce(r.confirmed_test_season, false) AS confirmed_test_season,
      coalesce(r.confirmed_live_season, false) AS confirmed_live_season,
      false AS has_club,
      NULL::text AS club_short_name,
      NULL::text AS club_name,
      'waiting'::text AS list_kind
    FROM public.gpsl_owner_registry r
    JOIN auth.users u ON u.id = r.owner_id
    WHERE public.waiting_list_on_list_status(r.status)
      AND NOT EXISTS (SELECT 1 FROM public."Clubs" c WHERE c.owner_id = r.owner_id)

    UNION ALL

    SELECT
      r.owner_id,
      coalesce(nullif(btrim(public.owner_registry_resolve_tag(r.owner_id)), ''), '—') AS owner_tag,
      r.status AS registry_status,
      r.waiting_list_tier AS tier,
      u.created_at AS account_created_at,
      u.email::text AS email,
      r.last_club_short_name,
      r.absence_note,
      r.returned_to_list_at,
      r.pending_starting_balance,
      r.waiting_list_use_admin_sort AS use_admin_sort,
      r.waiting_list_admin_sort AS admin_sort,
      coalesce(r.confirmed_test_season, false) AS confirmed_test_season,
      coalesce(r.confirmed_live_season, false) AS confirmed_live_season,
      true AS has_club,
      (
        SELECT string_agg(c."ShortName"::text, ', ' ORDER BY c."ShortName")
        FROM public."Clubs" c
        WHERE c.owner_id = r.owner_id
      ) AS club_short_name,
      (
        SELECT string_agg(c."Club"::text, ', ' ORDER BY c."ShortName")
        FROM public."Clubs" c
        WHERE c.owner_id = r.owner_id
      ) AS club_name,
      'club_owner'::text AS list_kind
    FROM public.gpsl_owner_registry r
    JOIN auth.users u ON u.id = r.owner_id
    WHERE EXISTS (SELECT 1 FROM public."Clubs" c WHERE c.owner_id = r.owner_id)
  ),
  ranked AS (
    SELECT
      b.*,
      row_number() OVER (
        ORDER BY
          CASE WHEN v_use_admin THEN b.admin_sort END NULLS LAST,
          b.account_created_at,
          b.owner_id
      )::int AS list_position
    FROM board b
  )
  SELECT coalesce(jsonb_agg(
    jsonb_build_object(
      'position', ranked.list_position,
      'owner_id', ranked.owner_id,
      'email', ranked.email,
      'owner_tag', ranked.owner_tag,
      'status', ranked.registry_status,
      'tier', ranked.tier,
      'account_created_at', ranked.account_created_at,
      'last_club_short_name', ranked.last_club_short_name,
      'absence_note', ranked.absence_note,
      'returned_to_list_at', ranked.returned_to_list_at,
      'pending_starting_balance', ranked.pending_starting_balance,
      'use_admin_sort', ranked.use_admin_sort,
      'confirmed_test_season', ranked.confirmed_test_season,
      'confirmed_live_season', ranked.confirmed_live_season,
      'has_club', ranked.has_club,
      'club_short_name', ranked.club_short_name,
      'club_name', ranked.club_name,
      'list_kind', ranked.list_kind
    )
    ORDER BY ranked.list_position
  ), '[]'::jsonb)
  INTO v_priority
  FROM ranked;

  SELECT coalesce(jsonb_agg(elem ORDER BY (elem->>'position')::int), '[]'::jsonb)
  INTO v_waiting
  FROM jsonb_array_elements(v_priority) elem
  WHERE elem->>'list_kind' = 'waiting';

  SELECT coalesce(jsonb_agg(
    (elem - 'position') || jsonb_build_object('position', ord::int)
    ORDER BY ord
  ), '[]'::jsonb)
  INTO v_waiting
  FROM jsonb_array_elements(v_waiting) WITH ORDINALITY AS t(elem, ord);

  SELECT coalesce(jsonb_agg(
    jsonb_build_object(
      'owner_id', r.owner_id,
      'email', u.email,
      'owner_tag', public.owner_registry_resolve_tag(r.owner_id),
      'status', r.status,
      'last_club_short_name', r.last_club_short_name,
      'confirmed_test_season', coalesce(r.confirmed_test_season, false),
      'confirmed_live_season', coalesce(r.confirmed_live_season, false)
    )
    ORDER BY u.email
  ), '[]'::jsonb)
  INTO v_other
  FROM public.gpsl_owner_registry r
  JOIN auth.users u ON u.id = r.owner_id
  WHERE r.status = 'awaiting_club_auction'
    AND NOT EXISTS (SELECT 1 FROM public."Clubs" c WHERE c.owner_id = r.owner_id);

  SELECT coalesce(jsonb_agg(
    jsonb_build_object(
      'owner_id', r.owner_id,
      'email', u.email,
      'owner_tag', coalesce(
        nullif(btrim(public.owner_registry_resolve_tag(r.owner_id)), ''),
        '—'
      ),
      'status', r.status,
      'status_note', r.status_note,
      'last_club_short_name', r.last_club_short_name,
      'last_nation_code', r.last_nation_code,
      'status_changed_at', r.status_changed_at,
      'confirmed_test_season', coalesce(r.confirmed_test_season, false),
      'confirmed_live_season', coalesce(r.confirmed_live_season, false),
      'list_kind', 'on_break'
    )
    ORDER BY r.status_changed_at DESC NULLS LAST, u.email
  ), '[]'::jsonb)
  INTO v_on_break
  FROM public.gpsl_owner_registry r
  JOIN auth.users u ON u.id = r.owner_id
  WHERE r.status = 'on_break'
    AND NOT EXISTS (SELECT 1 FROM public."Clubs" c WHERE c.owner_id = r.owner_id);

  RETURN jsonb_build_object(
    'priority', v_priority,
    'waiting', v_waiting,
    'invited_to_auction', v_other,
    'on_break', coalesce(v_on_break, '[]'::jsonb),
    'priority_uses_admin_sort', v_use_admin
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.admin_owner_return_to_waiting_list(uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.waiting_list_admin() TO authenticated;

-- Allow archiving on_break rows from the new On break section
CREATE OR REPLACE FUNCTION public.admin_waiting_list_remove(
  p_owner_email text DEFAULT NULL,
  p_owner_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_user_id uuid;
  v_email text;
  v_tag text;
  v_status text;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF p_owner_id IS NOT NULL THEN
    v_user_id := p_owner_id;
  ELSIF nullif(btrim(p_owner_email), '') IS NOT NULL THEN
    SELECT u.id INTO v_user_id
    FROM auth.users u
    WHERE lower(u.email) = lower(btrim(p_owner_email))
    LIMIT 1;
  ELSE
    RAISE EXCEPTION 'Provide owner email or owner id';
  END IF;

  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'No auth user found';
  END IF;

  SELECT u.email INTO v_email FROM auth.users u WHERE u.id = v_user_id;

  IF EXISTS (SELECT 1 FROM public."Clubs" c WHERE c.owner_id = v_user_id) THEN
    RAISE EXCEPTION 'User still has a club — remove from club first';
  END IF;

  SELECT r.status, coalesce(nullif(btrim(r.owner_tag), ''), nullif(btrim(v_email), ''))
  INTO v_status, v_tag
  FROM public.gpsl_owner_registry r
  WHERE r.owner_id = v_user_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Owner is not in the registry';
  END IF;

  IF v_status NOT IN ('member', 'on_absence', 'awaiting_club_auction', 'on_break') THEN
    RAISE EXCEPTION 'Owner is not on the waiting list / on break (status=%)', v_status;
  END IF;

  UPDATE public.gpsl_owner_registry
  SET status = 'archived',
      waiting_list_tier = NULL,
      waiting_list_admin_sort = NULL,
      waiting_list_use_admin_sort = false,
      returned_to_list_at = NULL,
      absence_note = NULL,
      pending_starting_balance = 0,
      status_note = CASE
        WHEN v_status = 'on_break' THEN coalesce(nullif(btrim(status_note), ''), 'Archived from on break')
        ELSE coalesce(status_note, 'Removed from waiting list')
      END,
      status_changed_at = now()
  WHERE owner_id = v_user_id;

  RETURN jsonb_build_object(
    'ok', true,
    'owner_id', v_user_id,
    'email', v_email,
    'owner_tag', v_tag,
    'previous_status', v_status,
    'status', 'archived'
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.admin_waiting_list_remove(text, uuid) TO authenticated;

NOTIFY pgrst, 'reload schema';
