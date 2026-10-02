-- =============================================================================
-- Club season checklist: owner club-auction readiness
--
-- Lists every owner without a club who is invited to the club auction
-- (awaiting_club_auction) or on the waiting list (member / on_absence), with the
-- same five required entry items as the owner's own checklist on
-- awaiting_club.html: owner tag, timezone, match availability, primary club
-- interest, backup club.
--
-- Run once in Supabase SQL Editor. Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.admin_club_auction_owner_readiness()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_rows jsonb;
BEGIN
  IF NOT (
    public.is_gpsl_admin()
    OR (
      to_regprocedure('public.is_gpsl_admin_or_mod()') IS NOT NULL
      AND public.is_gpsl_admin_or_mod()
    )
  ) THEN
    RAISE EXCEPTION 'Admin or mod only';
  END IF;

  WITH owners AS (
    SELECT
      r.owner_id,
      r.status,
      coalesce(r.confirmed_live_season, false) AS confirmed_live_season,
      nullif(btrim(public.owner_registry_resolve_tag(r.owner_id)), '') AS owner_tag,
      nullif(btrim(coalesce(r.owner_timezone, '')), '') AS owner_timezone,
      u.email::text AS email
    FROM public.gpsl_owner_registry r
    LEFT JOIN auth.users u ON u.id = r.owner_id
    WHERE (
        r.status = 'awaiting_club_auction'
        OR public.waiting_list_on_list_status(r.status)
      )
      AND NOT EXISTS (
        SELECT 1 FROM public."Clubs" c WHERE c.owner_id = r.owner_id
      )
  ),
  slots AS (
    SELECT s.owner_id, count(*)::int AS slot_count
    FROM public.gpsl_owner_registry_availability_slot s
    GROUP BY s.owner_id
  ),
  marks AS (
    SELECT
      i.owner_id,
      max(i.club_short_name) FILTER (WHERE i.mark_kind = 'interest') AS interest_short,
      max(i.club_short_name) FILTER (WHERE i.mark_kind = 'backup') AS backup_short
    FROM public.club_auction_interests i
    GROUP BY i.owner_id
  ),
  wl AS (
    SELECT w.owner_id, w.list_position
    FROM public.waiting_list_ordered_rows(false) w
  ),
  joined AS (
    SELECT
      o.*,
      coalesce(s.slot_count, 0) AS slot_count,
      m.interest_short,
      ci."Club" AS interest_name,
      m.backup_short,
      cb."Club" AS backup_name,
      wl.list_position
    FROM owners o
    LEFT JOIN slots s ON s.owner_id = o.owner_id
    LEFT JOIN marks m ON m.owner_id = o.owner_id
    LEFT JOIN public."Clubs" ci ON ci."ShortName" = m.interest_short
    LEFT JOIN public."Clubs" cb ON cb."ShortName" = m.backup_short
    LEFT JOIN wl ON wl.owner_id = o.owner_id
  )
  SELECT coalesce(jsonb_agg(
    jsonb_build_object(
      'owner_id', j.owner_id,
      'owner_tag', j.owner_tag,
      'email', j.email,
      'status', j.status,
      'invited_to_auction', j.status = 'awaiting_club_auction',
      'confirmed_live_season', j.confirmed_live_season,
      'waiting_list_position', j.list_position,
      'owner_timezone', j.owner_timezone,
      'availability_slot_count', j.slot_count,
      'interest_club_short', j.interest_short,
      'interest_club_name', j.interest_name,
      'backup_club_short', j.backup_short,
      'backup_club_name', j.backup_name,
      'has_tag', j.owner_tag IS NOT NULL,
      'has_timezone', j.owner_timezone IS NOT NULL,
      'has_availability', j.slot_count > 0,
      'has_interest', j.interest_short IS NOT NULL,
      'has_backup', j.backup_short IS NOT NULL,
      'ready',
        j.owner_tag IS NOT NULL
        AND j.owner_timezone IS NOT NULL
        AND j.slot_count > 0
        AND j.interest_short IS NOT NULL
        AND j.backup_short IS NOT NULL
    )
    ORDER BY
      (j.status = 'awaiting_club_auction') DESC,
      j.list_position NULLS LAST,
      lower(coalesce(j.owner_tag, j.email, ''))
  ), '[]'::jsonb)
  INTO v_rows
  FROM joined j;

  RETURN v_rows;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.admin_club_auction_owner_readiness() TO authenticated;

NOTIFY pgrst, 'reload schema';
