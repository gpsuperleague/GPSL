-- =============================================================================
-- Waiting list public: include country + UK time offset helpers
--
-- Safe public exposure:
--   * latest known country code
--   * saved owner timezone
-- No IP addresses are exposed.
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
BEGIN
  v_on_board_mode := 'test';

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
  onboard AS (
    SELECT
      r.owner_id,
      public.owner_registry_resolve_tag(r.owner_id) AS owner_tag,
      r.confirmed_test_season_at AS joined_at,
      lo.country_code,
      lo.timezone_name AS origin_timezone
    FROM public.gpsl_owner_registry r
    LEFT JOIN latest_origin lo
      ON lo.owner_id = r.owner_id
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
        'owner_tag', ranked.owner_tag,
        'country_code', ranked.country_code,
        'origin_timezone', ranked.origin_timezone
      )
      ORDER BY ranked.position
    ), '[]'::jsonb),
    count(*)::int,
    max(CASE WHEN ranked.owner_id = auth.uid() THEN ranked.position END)
  INTO v_on_board, v_on_board_total, v_self_on_board_pos
  FROM ranked;

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
  waiting AS (
    SELECT
      w.owner_id,
      w.owner_tag,
      w.registry_status,
      w.list_position AS queue_position,
      lo.country_code,
      lo.timezone_name AS origin_timezone
    FROM public.waiting_list_ordered_rows(false) w
    LEFT JOIN latest_origin lo
      ON lo.owner_id = w.owner_id
    WHERE NOT EXISTS (
      SELECT 1
      FROM public.gpsl_owner_registry r2
      WHERE r2.owner_id = w.owner_id
        AND r2.confirmed_test_season = true
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
        'status', waiting_ranked.registry_status,
        'country_code', waiting_ranked.country_code,
        'origin_timezone', waiting_ranked.origin_timezone
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

GRANT EXECUTE ON FUNCTION public.waiting_list_public() TO authenticated;

NOTIFY pgrst, 'reload schema';
