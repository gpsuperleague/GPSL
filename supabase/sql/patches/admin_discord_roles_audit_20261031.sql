-- =============================================================================
-- Admin: Discord ↔ GPSL membership audit (Owner / Member / Visitor)
--
-- Explains gaps like:
--   Discord Owner role 11 vs GPSL club owners ~30
--   Discord Member role 26 vs many GPSL accounts
--   Discord Visitor role 2 vs many Discord-only people
--
-- Sync only updates accounts that have registry.discord_user_id (or gpsl_visitors).
-- Unlinked GPSL owners/members never get Discord roles until linked + synced.
-- Full-guild Visitor assignment needs discord-sync-roles action sync_guild.
--
-- Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.admin_discord_gpsl_roles_audit()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club_owners int := 0;
  v_club_owners_linked int := 0;
  v_club_owners_unlinked int := 0;
  v_registry int := 0;
  v_registry_linked int := 0;
  v_registry_unlinked int := 0;
  v_registry_non_archived int := 0;
  v_registry_non_archived_linked int := 0;
  v_visitors_table int := 0;
  v_visitors_linked int := 0;
  v_settings jsonb;
  v_unlinked_owners jsonb := '[]'::jsonb;
  v_unlinked_members jsonb := '[]'::jsonb;
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  SELECT count(*)::int INTO v_club_owners
  FROM public."Clubs" c
  WHERE c.owner_id IS NOT NULL
    AND c."ShortName" IS DISTINCT FROM 'FOREIGN'
    AND coalesce(c.is_archived, false) = false;

  SELECT count(*)::int INTO v_club_owners_linked
  FROM public."Clubs" c
  JOIN public.gpsl_owner_registry r ON r.owner_id = c.owner_id
  WHERE c.owner_id IS NOT NULL
    AND c."ShortName" IS DISTINCT FROM 'FOREIGN'
    AND coalesce(c.is_archived, false) = false
    AND nullif(btrim(coalesce(r.discord_user_id, '')), '') IS NOT NULL;

  v_club_owners_unlinked := greatest(v_club_owners - v_club_owners_linked, 0);

  SELECT count(*)::int INTO v_registry
  FROM public.gpsl_owner_registry;

  SELECT count(*)::int INTO v_registry_linked
  FROM public.gpsl_owner_registry r
  WHERE nullif(btrim(coalesce(r.discord_user_id, '')), '') IS NOT NULL;

  v_registry_unlinked := greatest(v_registry - v_registry_linked, 0);

  SELECT count(*)::int INTO v_registry_non_archived
  FROM public.gpsl_owner_registry r
  WHERE coalesce(r.status, '') IS DISTINCT FROM 'archived';

  SELECT count(*)::int INTO v_registry_non_archived_linked
  FROM public.gpsl_owner_registry r
  WHERE coalesce(r.status, '') IS DISTINCT FROM 'archived'
    AND nullif(btrim(coalesce(r.discord_user_id, '')), '') IS NOT NULL;

  BEGIN
    SELECT count(*)::int INTO v_visitors_table FROM public.gpsl_visitors;
    SELECT count(*)::int INTO v_visitors_linked
    FROM public.gpsl_visitors v
    WHERE nullif(btrim(coalesce(v.discord_user_id, '')), '') IS NOT NULL;
  EXCEPTION WHEN undefined_table THEN
    v_visitors_table := 0;
    v_visitors_linked := 0;
  END;

  BEGIN
    SELECT to_jsonb(s) INTO v_settings
    FROM public.gpsl_discord_roles_settings s
    WHERE s.id = 1;
  EXCEPTION WHEN undefined_table THEN
    v_settings := NULL;
  END;

  SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY x.owner_tag), '[]'::jsonb)
  INTO v_unlinked_owners
  FROM (
    SELECT
      c."ShortName" AS club_short_name,
      c."Club" AS club_name,
      r.owner_tag,
      r.status,
      r.owner_id
    FROM public."Clubs" c
    LEFT JOIN public.gpsl_owner_registry r ON r.owner_id = c.owner_id
    WHERE c.owner_id IS NOT NULL
      AND c."ShortName" IS DISTINCT FROM 'FOREIGN'
      AND coalesce(c.is_archived, false) = false
      AND nullif(btrim(coalesce(r.discord_user_id, '')), '') IS NULL
    ORDER BY c."ShortName"
    LIMIT 40
  ) x;

  SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY x.owner_tag), '[]'::jsonb)
  INTO v_unlinked_members
  FROM (
    SELECT
      r.owner_tag,
      r.status,
      r.owner_id,
      EXISTS (SELECT 1 FROM public."Clubs" c WHERE c.owner_id = r.owner_id) AS has_club
    FROM public.gpsl_owner_registry r
    WHERE coalesce(r.status, '') IS DISTINCT FROM 'archived'
      AND nullif(btrim(coalesce(r.discord_user_id, '')), '') IS NULL
      AND NOT EXISTS (
        SELECT 1 FROM public."Clubs" c
        WHERE c.owner_id = r.owner_id
          AND coalesce(c.is_archived, false) = false
      )
    ORDER BY r.owner_tag
    LIMIT 40
  ) x;

  RETURN jsonb_build_object(
    'ok', true,
    'mapping', jsonb_build_object(
      'owner', 'Clubs.owner_id set → Discord Owner + Member',
      'member', 'gpsl_owner_registry row → Discord Member',
      'visitor', 'In Discord guild, no GPSL registry → Discord Visitor'
    ),
    'gpsl', jsonb_build_object(
      'club_owners', v_club_owners,
      'club_owners_with_discord_id', v_club_owners_linked,
      'club_owners_missing_discord_id', v_club_owners_unlinked,
      'registry_total', v_registry,
      'registry_with_discord_id', v_registry_linked,
      'registry_missing_discord_id', v_registry_unlinked,
      'registry_non_archived', v_registry_non_archived,
      'registry_non_archived_with_discord_id', v_registry_non_archived_linked,
      'gpsl_visitors_rows', v_visitors_table,
      'gpsl_visitors_with_discord_id', v_visitors_linked
    ),
    'why_discord_roles_lag', jsonb_build_array(
      'Sync only updates people with registry.discord_user_id (or gpsl_visitors.discord_user_id).',
      '“Sync roles now” is sync_linked (batch of linked accounts) — not every Discord server member.',
      'Club owners without a Discord ID on their GPSL registry cannot receive the Owner role.',
      'Discord-only people only get Visitor after sync_guild (or a visitors-table sync).'
    ),
    'sample_unlinked_club_owners', v_unlinked_owners,
    'sample_unlinked_non_owner_registry', v_unlinked_members,
    'discord_roles_settings', v_settings
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.admin_discord_gpsl_roles_audit() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_discord_gpsl_roles_audit() TO authenticated;

NOTIFY pgrst, 'reload schema';

SELECT public.admin_discord_gpsl_roles_audit() AS audit;
