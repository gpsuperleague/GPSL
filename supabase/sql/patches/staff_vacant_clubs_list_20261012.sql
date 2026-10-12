-- =============================================================================
-- Staff: vacant clubs list (2026-10-12)
-- =============================================================================
-- Every club in a league this season with no owner (all divisions), for the
-- "Copy vacant clubs" button on Staff alerts — paste into a Discord DM to a
-- member without a club. Admins and mods. Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.staff_vacant_clubs_list()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season_id bigint;
  v_season_label text;
BEGIN
  IF NOT public.is_gpsl_admin_or_mod() THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'staff_only');
  END IF;

  SELECT s.id, s.label
  INTO v_season_id, v_season_label
  FROM public.competition_seasons s
  WHERE s.is_current = true
  ORDER BY s.id DESC
  LIMIT 1;

  IF v_season_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_season');
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'season_id', v_season_id,
    'season_label', v_season_label,
    'clubs', coalesce((
      SELECT jsonb_agg(
        jsonb_build_object(
          'short_name', q.short_name,
          'club_name', q.club_name,
          'division', q.division,
          'division_label', public.gpsl_discord_division_label(q.division)
        )
        ORDER BY q.div_rank, q.club_name
      )
      FROM (
        SELECT
          c."ShortName" AS short_name,
          coalesce(nullif(btrim(c."Club"), ''), c."ShortName") AS club_name,
          ccs.division,
          CASE lower(ccs.division)
            WHEN 'superleague' THEN 1
            WHEN 'championship_a' THEN 2
            WHEN 'championship_b' THEN 3
            ELSE 4
          END AS div_rank
        FROM public.competition_club_seasons ccs
        JOIN public."Clubs" c ON c."ShortName" = ccs.club_short_name
        WHERE ccs.season_id = v_season_id
          AND c.owner_id IS NULL
          AND upper(c."ShortName") <> 'FOREIGN'
      ) q
    ), '[]'::jsonb)
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.staff_vacant_clubs_list() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.staff_vacant_clubs_list() TO authenticated;

NOTIFY pgrst, 'reload schema';

SELECT
  ccs.division,
  count(*) AS vacant_clubs,
  string_agg(c."ShortName", ', ' ORDER BY c."ShortName") AS clubs
FROM public.competition_club_seasons ccs
JOIN public."Clubs" c ON c."ShortName" = ccs.club_short_name
WHERE ccs.season_id = (
    SELECT id FROM public.competition_seasons WHERE is_current = true ORDER BY id DESC LIMIT 1
  )
  AND c.owner_id IS NULL
  AND upper(c."ShortName") <> 'FOREIGN'
GROUP BY ccs.division
ORDER BY ccs.division;
