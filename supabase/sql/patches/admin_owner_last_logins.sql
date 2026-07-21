-- =============================================================================
-- Admin: owner last login (GPSL site) + Discord join date
-- Safe re-run.
-- Note: Discord API does not expose last login / last seen for guild members.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.admin_owner_last_logins()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  RETURN coalesce(
    (
      SELECT jsonb_agg(
        row_to_json(x)::jsonb
        ORDER BY x.sort_ts DESC NULLS LAST,
                 x.owner_tag ASC NULLS LAST,
                 x.club_short_name ASC NULLS LAST
      )
      FROM (
        SELECT
          o.owner_id,
          public.owner_registry_resolve_tag(o.owner_id) AS owner_tag,
          coalesce(
            reg.status,
            CASE WHEN c.owner_id IS NOT NULL THEN 'active' ELSE 'member' END
          )::text AS registry_status,
          c."ShortName"::text AS club_short_name,
          c."Club"::text AS club_name,
          u.last_sign_in_at AS last_sign_in_at,
          u.created_at AS account_created_at,
          reg.discord_user_id::text AS discord_user_id,
          reg.discord_joined_at AS discord_joined_at,
          coalesce(u.last_sign_in_at, u.created_at) AS sort_ts
        FROM (
          SELECT r.owner_id FROM public.gpsl_owner_registry r
          UNION
          SELECT cl.owner_id FROM public."Clubs" cl WHERE cl.owner_id IS NOT NULL
        ) o
        JOIN auth.users u ON u.id = o.owner_id
        LEFT JOIN public."Clubs" c ON c.owner_id = o.owner_id
        LEFT JOIN public.gpsl_owner_registry reg ON reg.owner_id = o.owner_id
        WHERE coalesce(reg.status, '') IS DISTINCT FROM 'archived'
      ) x
    ),
    '[]'::jsonb
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.admin_owner_last_logins() TO authenticated;

NOTIFY pgrst, 'reload schema';
