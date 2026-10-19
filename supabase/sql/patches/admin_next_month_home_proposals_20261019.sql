-- =============================================================================
-- Season owner board: next GPSL month home kick-off proposals (league + cup)
--
-- Example: current month = July → column shows August home fixtures proposed
-- by that club as proposed/total (e.g. 2/3). Rolls with the season.
-- Excludes fixtures involving a vacant club (either side).
--
-- Safe re-run. Admin only.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.admin_club_next_month_home_proposals()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season_id bigint;
  v_cur text;
  v_next text;
  v_by_club jsonb := '{}'::jsonb;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  SELECT s.id INTO v_season_id
  FROM public.competition_seasons s
  WHERE s.is_current = true
    AND s.status IN ('active', 'preseason')
  ORDER BY CASE s.status WHEN 'active' THEN 0 ELSE 1 END, s.id DESC
  LIMIT 1;

  IF v_season_id IS NULL THEN
    RETURN jsonb_build_object(
      'current_gpsl_month', null,
      'next_gpsl_month', null,
      'next_gpsl_month_label', null,
      'by_club', '{}'::jsonb
    );
  END IF;

  v_cur := public.competition_active_gpsl_month(v_season_id, now());

  IF v_cur IS NOT NULL THEN
    SELECT m.gpsl_month
    INTO v_next
    FROM public.competition_season_calendar m
    WHERE m.season_id = v_season_id
      AND public.competition_gpsl_month_sort(m.gpsl_month)
        > public.competition_gpsl_month_sort(v_cur)
    ORDER BY public.competition_gpsl_month_sort(m.gpsl_month) ASC
    LIMIT 1;
  ELSE
    -- Pre-season / between months: treat the earliest unlocked-or-upcoming month as "next"
    SELECT m.gpsl_month
    INTO v_next
    FROM public.competition_season_calendar m
    WHERE m.season_id = v_season_id
      AND m.lock_at > now()
    ORDER BY public.competition_gpsl_month_sort(m.gpsl_month) ASC
    LIMIT 1;
  END IF;

  IF v_next IS NULL THEN
    RETURN jsonb_build_object(
      'current_gpsl_month', v_cur,
      'current_gpsl_month_label', public.competition_gpsl_month_label(v_cur),
      'next_gpsl_month', null,
      'next_gpsl_month_label', null,
      'by_club', '{}'::jsonb
    );
  END IF;

  SELECT coalesce(jsonb_object_agg(club_key, stats), '{}'::jsonb)
  INTO v_by_club
  FROM (
    SELECT
      upper(btrim(f.home_club_short_name)) AS club_key,
      jsonb_build_object(
        'proposed', count(*) FILTER (
          WHERE public.match_schedule_home_has_proposed(f.id, now())
        )::int,
        'total', count(*)::int
      ) AS stats
    FROM public.competition_fixtures f
    WHERE f.season_id = v_season_id
      AND lower(btrim(f.gpsl_month)) = lower(btrim(v_next))
      AND f.competition_type IN ('league', 'cup')
      AND f.status = 'scheduled'
      AND f.home_club_short_name IS NOT NULL
      AND btrim(f.home_club_short_name) <> ''
      AND EXISTS (
        SELECT 1
        FROM public."Clubs" c
        WHERE c."ShortName" = f.home_club_short_name
          AND c.owner_id IS NOT NULL
      )
      AND NOT public.competition_fixture_involves_vacant_club(f.id)
    GROUP BY upper(btrim(f.home_club_short_name))
  ) x;

  RETURN jsonb_build_object(
    'current_gpsl_month', v_cur,
    'current_gpsl_month_label', public.competition_gpsl_month_label(v_cur),
    'next_gpsl_month', v_next,
    'next_gpsl_month_label', public.competition_gpsl_month_label(v_next),
    'by_club', coalesce(v_by_club, '{}'::jsonb)
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.admin_club_next_month_home_proposals() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_club_next_month_home_proposals() TO authenticated;

COMMENT ON FUNCTION public.admin_club_next_month_home_proposals() IS
  'Admin board: per-club home kick-off proposals for the next GPSL month (league+cup) as proposed/total.';

NOTIFY pgrst, 'reload schema';
