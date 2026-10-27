-- =============================================================================
-- Staff vacant clubs list: include unowned clubs not in a league division
-- Safe re-run. Extends staff_vacant_clubs_list_20261012.sql
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
          'division_label', q.division_label
        )
        ORDER BY q.div_rank, q.club_name
      )
      FROM (
        -- League clubs (current season) with no owner
        SELECT
          c."ShortName" AS short_name,
          coalesce(nullif(btrim(c."Club"), ''), c."ShortName") AS club_name,
          ccs.division,
          public.gpsl_discord_division_label(ccs.division) AS division_label,
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

        UNION ALL

        -- Unowned clubs not registered in any current-season division
        SELECT
          c."ShortName" AS short_name,
          coalesce(nullif(btrim(c."Club"), ''), c."ShortName") AS club_name,
          NULL::text AS division,
          'Not in a division'::text AS division_label,
          5 AS div_rank
        FROM public."Clubs" c
        WHERE c.owner_id IS NULL
          AND upper(c."ShortName") <> 'FOREIGN'
          AND NOT EXISTS (
            SELECT 1
            FROM public.competition_club_seasons ccs
            WHERE ccs.season_id = v_season_id
              AND ccs.club_short_name = c."ShortName"
          )
      ) q
    ), '[]'::jsonb)
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.staff_vacant_clubs_list() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.staff_vacant_clubs_list() TO authenticated;

NOTIFY pgrst, 'reload schema';
