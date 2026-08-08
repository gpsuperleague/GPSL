-- =============================================================================
-- Waiting list public: "I'm on board" panel + confirm join order
--
-- - Timestamps when admin ticks Test / Live season confirmed
-- - waiting_list_public() returns on_board rows (tag only) in join order
-- - Public on_board panel = test-season confirms only
-- - Public waiting panel filters those out (display only — registry/queue unchanged)
--
-- Run after gpsl_waiting_list_season_confirm.sql. Safe re-run.
-- =============================================================================

ALTER TABLE public.gpsl_owner_registry
  ADD COLUMN IF NOT EXISTS confirmed_test_season boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS confirmed_live_season boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS confirmed_test_season_at timestamptz,
  ADD COLUMN IF NOT EXISTS confirmed_live_season_at timestamptz;

COMMENT ON COLUMN public.gpsl_owner_registry.confirmed_test_season_at IS
  'When admin first marked confirmed_test_season (join order for I''m on board).';
COMMENT ON COLUMN public.gpsl_owner_registry.confirmed_live_season_at IS
  'When admin first marked confirmed_live_season (join order for I''m on board).';

-- Backfill: already-confirmed owners get a stable order from account / registry time
UPDATE public.gpsl_owner_registry r
SET confirmed_test_season_at = coalesce(
  r.confirmed_test_season_at,
  r.returned_to_list_at,
  u.created_at,
  now()
)
FROM auth.users u
WHERE u.id = r.owner_id
  AND r.confirmed_test_season = true
  AND r.confirmed_test_season_at IS NULL;

UPDATE public.gpsl_owner_registry r
SET confirmed_live_season_at = coalesce(
  r.confirmed_live_season_at,
  r.returned_to_list_at,
  u.created_at,
  now()
)
FROM auth.users u
WHERE u.id = r.owner_id
  AND r.confirmed_live_season = true
  AND r.confirmed_live_season_at IS NULL;

CREATE OR REPLACE FUNCTION public.admin_waiting_list_set_season_confirmed(
  p_owner_id uuid,
  p_which text,
  p_confirmed boolean
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_which text := lower(btrim(coalesce(p_which, '')));
  v_confirmed boolean := coalesce(p_confirmed, false);
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF p_owner_id IS NULL THEN
    RAISE EXCEPTION 'owner_id required';
  END IF;

  IF v_which NOT IN ('test', 'live') THEN
    RAISE EXCEPTION 'p_which must be test or live';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.gpsl_owner_registry r WHERE r.owner_id = p_owner_id
  ) THEN
    RAISE EXCEPTION 'Owner not found in registry';
  END IF;

  IF v_which = 'test' THEN
    IF v_confirmed THEN
      UPDATE public.gpsl_owner_registry
      SET
        confirmed_test_season = true,
        confirmed_test_season_at = coalesce(confirmed_test_season_at, now())
      WHERE owner_id = p_owner_id;
    ELSE
      UPDATE public.gpsl_owner_registry
      SET
        confirmed_test_season = false,
        confirmed_test_season_at = null
      WHERE owner_id = p_owner_id;
    END IF;
  ELSE
    IF v_confirmed THEN
      UPDATE public.gpsl_owner_registry
      SET
        confirmed_live_season = true,
        confirmed_live_season_at = coalesce(confirmed_live_season_at, now())
      WHERE owner_id = p_owner_id;
    ELSE
      UPDATE public.gpsl_owner_registry
      SET
        confirmed_live_season = false,
        confirmed_live_season_at = null
      WHERE owner_id = p_owner_id;
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'owner_id', p_owner_id,
    'which', v_which,
    'confirmed', v_confirmed
  );
END;
$function$;

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
BEGIN
  -- Public "I'm on board" = test-season confirms only (admin Live tick stays admin-only).
  v_on_board_mode := 'test';

  WITH onboard AS (
    SELECT
      r.owner_id,
      public.owner_registry_resolve_tag(r.owner_id) AS owner_tag,
      r.confirmed_test_season_at AS joined_at
    FROM public.gpsl_owner_registry r
    WHERE coalesce(r.status, '') IS DISTINCT FROM 'archived'
      AND r.confirmed_test_season = true
  ),
  ranked AS (
    SELECT
      o.*,
      row_number() OVER (
        ORDER BY o.joined_at NULLS LAST, o.owner_tag, o.owner_id
      )::int AS position
    FROM onboard o
  )
  SELECT
    coalesce(jsonb_agg(
      jsonb_build_object(
        'position', ranked.position,
        'owner_tag', ranked.owner_tag
      )
      ORDER BY ranked.position
    ), '[]'::jsonb),
    count(*)::int,
    max(CASE WHEN ranked.owner_id = auth.uid() THEN ranked.position END)
  INTO v_on_board, v_on_board_total, v_self_on_board_pos
  FROM ranked;

  -- Waiting panel: same queue, but hide anyone already on the test "I'm on board" list.
  -- Display renumber only — does not change waiting_list_ordered_rows / admin order.
  WITH waiting AS (
    SELECT
      w.owner_id,
      w.owner_tag,
      w.registry_status,
      w.list_position AS queue_position
    FROM public.waiting_list_ordered_rows(false) w
    WHERE NOT EXISTS (
      SELECT 1
      FROM public.gpsl_owner_registry r
      WHERE r.owner_id = w.owner_id
        AND r.confirmed_test_season = true
    )
  ),
  waiting_ranked AS (
    SELECT
      waiting.*,
      row_number() OVER (ORDER BY waiting.queue_position)::int AS position
    FROM waiting
  )
  SELECT
    coalesce(jsonb_agg(
      jsonb_build_object(
        'position', waiting_ranked.position,
        'owner_tag', waiting_ranked.owner_tag,
        'status', waiting_ranked.registry_status
      )
      ORDER BY waiting_ranked.position
    ), '[]'::jsonb),
    count(*)::int,
    max(CASE WHEN waiting_ranked.owner_id = auth.uid() THEN waiting_ranked.position END)
  INTO v_rows, v_total, v_self_pos
  FROM waiting_ranked;

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

GRANT EXECUTE ON FUNCTION public.admin_waiting_list_set_season_confirmed(uuid, text, boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.waiting_list_public() TO authenticated;

NOTIFY pgrst, 'reload schema';
