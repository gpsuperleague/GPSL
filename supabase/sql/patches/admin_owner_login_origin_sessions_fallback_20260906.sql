-- =============================================================================
-- Admin owner login origin: fall back to auth.sessions for IP visibility
--
-- Why:
--   Fresh country/IP audit rows only appear after users log in again post-deploy.
--   To avoid blank admin board columns, use auth.sessions.ip as a fallback.
--
-- Country still depends on owner_login_origin_events (captured by edge function).
-- Duplicate recent IP review uses both audit rows and recent auth.sessions rows.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.admin_owner_login_security_map(
  p_recent_days int DEFAULT 30
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_recent_days int := greatest(coalesce(p_recent_days, 30), 1);
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  RETURN jsonb_build_object(
    'recent_days', v_recent_days,
    'owners', coalesce(
      (
        WITH owner_ids AS (
          SELECT r.owner_id
          FROM public.gpsl_owner_registry r
          WHERE r.owner_id IS NOT NULL
          UNION
          SELECT c.owner_id
          FROM public."Clubs" c
          WHERE c.owner_id IS NOT NULL
        ),
        latest_origin AS (
          SELECT DISTINCT ON (e.owner_id)
            e.owner_id,
            e.logged_in_at,
            nullif(btrim(coalesce(e.ip_address, '')), '') AS ip_address,
            nullif(btrim(coalesce(e.ip_address_norm, '')), '') AS ip_address_norm,
            upper(nullif(btrim(coalesce(e.country_code, '')), '')) AS country_code
          FROM public.owner_login_origin_events e
          ORDER BY e.owner_id, e.logged_in_at DESC, e.id DESC
        ),
        latest_session AS (
          SELECT DISTINCT ON (s.user_id)
            s.user_id AS owner_id,
            s.created_at,
            nullif(btrim(coalesce(s.ip::text, '')), '') AS ip_address,
            lower(nullif(btrim(coalesce(s.ip::text, '')), '')) AS ip_address_norm
          FROM auth.sessions s
          ORDER BY s.user_id, s.created_at DESC, s.id DESC
        ),
        recent_ip_sources AS (
          SELECT
            e.owner_id,
            e.logged_in_at AS seen_at,
            nullif(btrim(coalesce(e.ip_address_norm, '')), '') AS ip_address_norm
          FROM public.owner_login_origin_events e
          WHERE e.logged_in_at >= now() - make_interval(days => v_recent_days)

          UNION ALL

          SELECT
            s.user_id AS owner_id,
            s.created_at AS seen_at,
            lower(nullif(btrim(coalesce(s.ip::text, '')), '')) AS ip_address_norm
          FROM auth.sessions s
          WHERE s.created_at >= now() - make_interval(days => v_recent_days)
        ),
        recent_ip_groups AS (
          SELECT
            r.ip_address_norm,
            count(DISTINCT r.owner_id)::int AS owner_count,
            array_remove(
              array_agg(DISTINCT public.owner_registry_resolve_tag(r.owner_id) ORDER BY public.owner_registry_resolve_tag(r.owner_id)),
              NULL
            ) AS owner_tags
          FROM recent_ip_sources r
          WHERE r.ip_address_norm IS NOT NULL
          GROUP BY r.ip_address_norm
          HAVING count(DISTINCT r.owner_id) > 1
        )
        SELECT jsonb_agg(
          jsonb_build_object(
            'owner_id', o.owner_id,
            'last_ip_address', coalesce(lo.ip_address, ls.ip_address),
            'last_country_code', lo.country_code,
            'last_origin_at', greatest(lo.logged_in_at, ls.created_at),
            'shared_recent_ip', coalesce(g.owner_count, 0) > 1,
            'shared_recent_ip_owner_count', coalesce(g.owner_count, 0),
            'shared_recent_with', to_jsonb(coalesce(g.owner_tags, ARRAY[]::text[]))
          )
          ORDER BY greatest(lo.logged_in_at, ls.created_at) DESC NULLS LAST, o.owner_id
        )
        FROM owner_ids o
        LEFT JOIN latest_origin lo
          ON lo.owner_id = o.owner_id
        LEFT JOIN latest_session ls
          ON ls.owner_id = o.owner_id
        LEFT JOIN recent_ip_groups g
          ON g.ip_address_norm = coalesce(lo.ip_address_norm, ls.ip_address_norm)
      ),
      '[]'::jsonb
    )
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.admin_owner_login_security_map(int)
  TO authenticated;

NOTIFY pgrst, 'reload schema';
