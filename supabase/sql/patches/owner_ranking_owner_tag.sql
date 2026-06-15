-- Fix owner rankings showing club ShortName (e.g. URD) instead of owner tag.
-- Run once in Supabase SQL Editor, then hard-refresh owner_rankings.html

CREATE OR REPLACE FUNCTION public.owner_registry_resolve_tag(p_owner_id uuid)
RETURNS text
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT coalesce(
    (
      SELECT nullif(btrim(r.owner_tag), '')
      FROM public.gpsl_owner_registry r
      WHERE r.owner_id = p_owner_id
    ),
    (
      SELECT nullif(btrim(x.owner_tag), '')
      FROM public.competition_owner_season_ranking x
      WHERE x.owner_id = p_owner_id
        AND upper(btrim(x.owner_tag)) IS DISTINCT FROM upper(x.club_short_name)
      ORDER BY x.season_id DESC
      LIMIT 1
    ),
    (
      SELECT nullif(btrim(c.owner), '')
      FROM public."Clubs" c
      WHERE c.owner_id = p_owner_id
        AND upper(btrim(c.owner)) IS DISTINCT FROM upper(c."ShortName")
      LIMIT 1
    )
  );
$$;

CREATE OR REPLACE FUNCTION public.competition_owner_display_name(p_owner_id uuid)
RETURNS text
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT coalesce(
    nullif(btrim(public.owner_registry_resolve_tag(p_owner_id)), ''),
    'Former owner'
  );
$$;

CREATE OR REPLACE FUNCTION public.competition_owner_ranking_recompute_season(
  p_season_id bigint
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season record;
  v_club record;
  v_league_pts numeric;
  v_super8_pts numeric;
  v_plate_pts numeric;
  v_shield_pts numeric;
  v_spoon_pts numeric;
  v_lc_pts numeric;
  v_total numeric;
  v_ach text;
  v_detail jsonb;
  v_count int := 0;
  v_owner_id uuid;
  v_owner_tag text;
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  SELECT id, label INTO v_season
  FROM public.competition_seasons
  WHERE id = p_season_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Season not found';
  END IF;

  FOR v_club IN
    SELECT c."ShortName" AS club_short_name, c.owner_id
    FROM public."Clubs" c
    WHERE c.owner_id IS NOT NULL
  LOOP
    v_owner_id := v_club.owner_id;
    v_owner_tag := coalesce(public.owner_registry_resolve_tag(v_owner_id), '');

    SELECT coalesce(public.competition_owner_league_points(a.division, a.final_position), 0)
    INTO v_league_pts
    FROM public.competition_club_season_archive a
    WHERE a.season_id = p_season_id
      AND a.club_short_name = v_club.club_short_name;

    v_league_pts := coalesce(v_league_pts, 0);

    v_ach := public.competition_club_cup_achievement(p_season_id, v_club.club_short_name, 'super8');
    v_super8_pts := coalesce(public.competition_owner_cup_points('super8', v_ach), 0);

    v_ach := public.competition_club_cup_achievement(p_season_id, v_club.club_short_name, 'plate');
    v_plate_pts := coalesce(public.competition_owner_cup_points('plate', v_ach), 0);

    v_ach := public.competition_club_cup_achievement(p_season_id, v_club.club_short_name, 'shield');
    v_shield_pts := coalesce(public.competition_owner_cup_points('shield', v_ach), 0);

    v_ach := public.competition_club_cup_achievement(p_season_id, v_club.club_short_name, 'spoon');
    v_spoon_pts := coalesce(public.competition_owner_cup_points('spoon', v_ach), 0);

    v_ach := public.competition_club_cup_achievement(p_season_id, v_club.club_short_name, 'league_cup');
    v_lc_pts := coalesce(public.competition_owner_cup_points('league_cup', v_ach), 0);

    v_total := v_league_pts + v_super8_pts + v_plate_pts + v_shield_pts + v_spoon_pts + v_lc_pts;

    v_detail := jsonb_build_object(
      'league', jsonb_build_object('points', v_league_pts),
      'super8', jsonb_build_object(
        'achievement', public.competition_club_cup_achievement(p_season_id, v_club.club_short_name, 'super8'),
        'points', v_super8_pts
      ),
      'plate', jsonb_build_object(
        'achievement', public.competition_club_cup_achievement(p_season_id, v_club.club_short_name, 'plate'),
        'points', v_plate_pts
      ),
      'shield', jsonb_build_object(
        'achievement', public.competition_club_cup_achievement(p_season_id, v_club.club_short_name, 'shield'),
        'points', v_shield_pts
      ),
      'spoon', jsonb_build_object(
        'achievement', public.competition_club_cup_achievement(p_season_id, v_club.club_short_name, 'spoon'),
        'points', v_spoon_pts
      ),
      'league_cup', jsonb_build_object(
        'achievement', public.competition_club_cup_achievement(p_season_id, v_club.club_short_name, 'league_cup'),
        'points', v_lc_pts
      )
    );

    INSERT INTO public.competition_owner_season_ranking (
      season_id,
      season_label,
      club_short_name,
      owner_id,
      owner_tag,
      league_points,
      super8_points,
      plate_points,
      shield_points,
      spoon_points,
      league_cup_points,
      season_total,
      detail,
      computed_at
    )
    VALUES (
      p_season_id,
      v_season.label,
      v_club.club_short_name,
      v_owner_id,
      v_owner_tag,
      v_league_pts,
      v_super8_pts,
      v_plate_pts,
      v_shield_pts,
      v_spoon_pts,
      v_lc_pts,
      v_total,
      v_detail,
      now()
    )
    ON CONFLICT (season_id, club_short_name) DO UPDATE
    SET owner_tag = excluded.owner_tag,
        league_points = excluded.league_points,
        super8_points = excluded.super8_points,
        plate_points = excluded.plate_points,
        shield_points = excluded.shield_points,
        spoon_points = excluded.spoon_points,
        league_cup_points = excluded.league_cup_points,
        season_total = excluded.season_total,
        detail = excluded.detail,
        computed_at = now();

    v_count := v_count + 1;
  END LOOP;

  RETURN v_count;
END;
$function$;

DROP VIEW IF EXISTS public.competition_owner_ranking_rolling4_public;
CREATE VIEW public.competition_owner_ranking_rolling4_public
WITH (security_invoker = false)
AS
WITH last_four AS (
  SELECT s.season_id AS id
  FROM (
    SELECT DISTINCT season_id
    FROM public.competition_owner_season_ranking
    ORDER BY season_id DESC
    LIMIT 4
  ) s
),
totals AS (
  SELECT
    r.owner_id,
    r.club_short_name,
    sum(r.season_total) AS rolling_points,
    count(*)::integer AS seasons_count,
    jsonb_agg(
      jsonb_build_object(
        'season_id', r.season_id,
        'season_label', r.season_label,
        'season_total', r.season_total
      )
      ORDER BY r.season_id DESC
    ) AS season_breakdown
  FROM public.competition_owner_season_ranking r
  WHERE r.season_id IN (SELECT id FROM last_four)
    AND r.owner_id IS NOT NULL
  GROUP BY r.owner_id, r.club_short_name
)
SELECT
  row_number() OVER (
    ORDER BY coalesce(t.rolling_points, 0) DESC,
      public.competition_owner_display_name(c.owner_id),
      c."ShortName"
  )::smallint AS rank_position,
  c.owner_id,
  public.competition_owner_display_name(c.owner_id) AS owner_name,
  c."ShortName" AS club_short_name,
  c."Club" AS club_name,
  public.owner_registry_resolve_tag(c.owner_id) AS owner_tag,
  round(coalesce(t.rolling_points, 0), 2) AS rolling_points,
  coalesce(t.seasons_count, 0) AS seasons_count,
  coalesce(t.season_breakdown, '[]'::jsonb) AS season_breakdown
FROM public."Clubs" c
LEFT JOIN totals t ON t.club_short_name = c."ShortName"
WHERE c.owner_id IS NOT NULL
ORDER BY rank_position;

DROP VIEW IF EXISTS public.competition_owner_season_ranking_public;
CREATE VIEW public.competition_owner_season_ranking_public
WITH (security_invoker = false)
AS
SELECT
  r.season_id,
  r.season_label,
  r.club_short_name,
  c."Club" AS club_name,
  r.owner_id,
  public.competition_owner_display_name(r.owner_id) AS owner_name,
  coalesce(
    nullif(btrim(public.owner_registry_resolve_tag(r.owner_id)), ''),
    nullif(btrim(r.owner_tag), '')
  ) AS owner_tag,
  r.league_points,
  r.super8_points,
  r.plate_points,
  r.shield_points,
  r.spoon_points,
  r.league_cup_points,
  r.season_total,
  r.detail,
  r.computed_at
FROM public.competition_owner_season_ranking r
JOIN public."Clubs" c ON c."ShortName" = r.club_short_name
ORDER BY r.season_id DESC, r.season_total DESC;

CREATE OR REPLACE FUNCTION public.international_owner_draft_order()
RETURNS TABLE (
  pick_order smallint,
  club_short_name text,
  club_name text,
  owner_id uuid,
  owner_name text,
  owner_tag text,
  rank_points numeric,
  nation_code text,
  nation_name text,
  flag_emoji text
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    row_number() OVER (
      ORDER BY
        coalesce(r4.rolling_points, 0) DESC,
        public.competition_owner_display_name(c.owner_id),
        c."ShortName"
    )::smallint AS pick_order,
    c."ShortName" AS club_short_name,
    c."Club" AS club_name,
    c.owner_id,
    public.competition_owner_display_name(c.owner_id) AS owner_name,
    public.owner_registry_resolve_tag(c.owner_id) AS owner_tag,
    coalesce(r4.rolling_points, 0) AS rank_points,
    ion.nation_code,
    n.name AS nation_name,
    n.flag_emoji
  FROM public."Clubs" c
  LEFT JOIN public.competition_owner_ranking_rolling4_public r4
    ON r4.club_short_name = c."ShortName"
  LEFT JOIN public.international_owner_nations ion
    ON ion.club_short_name = c."ShortName" AND ion.is_active = true
  LEFT JOIN public.international_nations n ON n.code = ion.nation_code
  WHERE c.owner_id IS NOT NULL
  ORDER BY pick_order;
$$;

UPDATE public.competition_owner_season_ranking r
SET owner_tag = coalesce(public.owner_registry_resolve_tag(r.owner_id), '')
WHERE r.owner_id IS NOT NULL;

GRANT EXECUTE ON FUNCTION public.owner_registry_resolve_tag(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.competition_owner_display_name(uuid) TO authenticated;

NOTIFY pgrst, 'reload schema';
