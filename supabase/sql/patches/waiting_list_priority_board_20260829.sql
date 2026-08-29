-- =============================================================================
-- Waiting list admin: season priority board
--
-- - Combined ordered board: waiting-list members + current club owners
-- - Drag-and-drop reorder via admin_waiting_list_reorder(uuid[])
-- - Club owners appear ghosted in the UI; their admin_sort is stored so season
--   priority can include active owners. Public waiting list still only ranks
--   people without a club (relative admin_sort among waiters is preserved).
-- Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.waiting_list_clear_sort_flags()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  UPDATE public.gpsl_owner_registry r
  SET waiting_list_admin_sort = NULL,
      waiting_list_use_admin_sort = false
  WHERE r.waiting_list_use_admin_sort
     OR r.waiting_list_admin_sort IS NOT NULL;
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
  v_use_admin boolean;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  -- Full season-priority board only when every board member has an admin sort.
  -- Otherwise interleave by account created_at so current owners sit where they
  -- would have been by join date among waiters.
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

  -- Re-number waiting-only positions for any legacy consumers of "waiting".
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

  RETURN jsonb_build_object(
    'priority', v_priority,
    'waiting', v_waiting,
    'invited_to_auction', v_other,
    'priority_uses_admin_sort', v_use_admin
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_waiting_list_reorder(p_owner_ids uuid[])
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_id uuid;
  v_idx int := 0;
  v_ok int := 0;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF p_owner_ids IS NULL OR coalesce(array_length(p_owner_ids, 1), 0) = 0 THEN
    RAISE EXCEPTION 'owner_ids required';
  END IF;

  -- Clear previous board sorts so dropped people (e.g. left club) do not stick.
  UPDATE public.gpsl_owner_registry r
  SET waiting_list_admin_sort = NULL,
      waiting_list_use_admin_sort = false
  WHERE r.waiting_list_use_admin_sort
     OR r.waiting_list_admin_sort IS NOT NULL;

  FOREACH v_id IN ARRAY p_owner_ids
  LOOP
    v_idx := v_idx + 1;

    IF NOT EXISTS (
      SELECT 1
      FROM public.gpsl_owner_registry r
      WHERE r.owner_id = v_id
        AND (
          (
            public.waiting_list_on_list_status(r.status)
            AND NOT EXISTS (SELECT 1 FROM public."Clubs" c WHERE c.owner_id = r.owner_id)
          )
          OR EXISTS (SELECT 1 FROM public."Clubs" c WHERE c.owner_id = r.owner_id)
        )
    ) THEN
      RAISE EXCEPTION 'Owner % is not on the priority board', v_id;
    END IF;

    UPDATE public.gpsl_owner_registry
    SET waiting_list_admin_sort = v_idx * 1000,
        waiting_list_use_admin_sort = true
    WHERE owner_id = v_id;

    v_ok := v_ok + 1;
  END LOOP;

  RETURN jsonb_build_object('ok', true, 'count', v_ok);
END;
$function$;

-- Keep ↑/↓ move working against the full priority board (waiters + club owners).
CREATE OR REPLACE FUNCTION public.admin_waiting_list_move(
  p_owner_id uuid,
  p_direction integer
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_ids uuid[];
  v_idx int;
  v_swap int;
  v_tmp uuid;
  v_payload jsonb;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF p_direction NOT IN (-1, 1) THEN
    RAISE EXCEPTION 'direction must be -1 or 1';
  END IF;

  SELECT array_agg((elem->>'owner_id')::uuid ORDER BY (elem->>'position')::int)
  INTO v_ids
  FROM jsonb_array_elements(public.waiting_list_admin()->'priority') elem;

  IF v_ids IS NULL OR array_length(v_ids, 1) IS NULL THEN
    RAISE EXCEPTION 'Priority board is empty';
  END IF;

  SELECT ord INTO v_idx
  FROM unnest(v_ids) WITH ORDINALITY AS t(owner_id, ord)
  WHERE owner_id = p_owner_id;

  IF v_idx IS NULL THEN
    RAISE EXCEPTION 'Owner is not on the priority board';
  END IF;

  v_swap := v_idx + p_direction;
  IF v_swap < 1 OR v_swap > array_length(v_ids, 1) THEN
    RETURN jsonb_build_object('ok', true, 'moved', false, 'reason', 'already_at_edge');
  END IF;

  v_tmp := v_ids[v_idx];
  v_ids[v_idx] := v_ids[v_swap];
  v_ids[v_swap] := v_tmp;

  v_payload := public.admin_waiting_list_reorder(v_ids);
  RETURN jsonb_build_object('ok', true, 'moved', true) || coalesce(v_payload, '{}'::jsonb);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.waiting_list_admin() TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_waiting_list_reorder(uuid[]) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_waiting_list_move(uuid, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.waiting_list_clear_sort_flags() TO authenticated;

NOTIFY pgrst, 'reload schema';
