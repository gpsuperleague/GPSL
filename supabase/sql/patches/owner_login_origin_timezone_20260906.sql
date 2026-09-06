-- =============================================================================
-- Owner login origin audit: store timezone from IP geolocation
--
-- This keeps country and UK +/- time difference aligned to the same source.
-- =============================================================================

ALTER TABLE public.owner_login_origin_events
  ADD COLUMN IF NOT EXISTS timezone_name text;

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
            upper(nullif(btrim(coalesce(e.country_code, '')), '')) AS country_code,
            nullif(btrim(coalesce(e.timezone_name, '')), '') AS timezone_name
          FROM public.owner_login_origin_events e
          ORDER BY e.owner_id, e.logged_in_at DESC, e.id DESC
        ),
        recent_ip_groups AS (
          SELECT
            e.ip_address_norm,
            count(DISTINCT e.owner_id)::int AS owner_count,
            array_remove(
              array_agg(DISTINCT public.owner_registry_resolve_tag(e.owner_id) ORDER BY public.owner_registry_resolve_tag(e.owner_id)),
              NULL
            ) AS owner_tags
          FROM public.owner_login_origin_events e
          WHERE nullif(btrim(coalesce(e.ip_address_norm, '')), '') IS NOT NULL
            AND e.logged_in_at >= now() - make_interval(days => v_recent_days)
          GROUP BY e.ip_address_norm
          HAVING count(DISTINCT e.owner_id) > 1
        )
        SELECT jsonb_agg(
          jsonb_build_object(
            'owner_id', o.owner_id,
            'last_ip_address', lo.ip_address,
            'last_country_code', lo.country_code,
            'last_timezone_name', lo.timezone_name,
            'last_origin_at', lo.logged_in_at,
            'shared_recent_ip', coalesce(g.owner_count, 0) > 1,
            'shared_recent_ip_owner_count', coalesce(g.owner_count, 0),
            'shared_recent_with', to_jsonb(coalesce(g.owner_tags, ARRAY[]::text[]))
          )
          ORDER BY lo.logged_in_at DESC NULLS LAST, o.owner_id
        )
        FROM owner_ids o
        LEFT JOIN latest_origin lo
          ON lo.owner_id = o.owner_id
        LEFT JOIN recent_ip_groups g
          ON g.ip_address_norm = lo.ip_address_norm
      ),
      '[]'::jsonb
    )
  );
END;
$function$;

COMMENT ON FUNCTION public.admin_owner_login_security_map(int) IS
  'Admin-only latest IP/country/timezone per owner plus recent shared-IP review flag.';

NOTIFY pgrst, 'reload schema';
