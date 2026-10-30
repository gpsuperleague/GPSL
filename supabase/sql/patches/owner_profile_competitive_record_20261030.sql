-- Owner profile career totals: live competitive record
-- =============================================================================
-- Header stats (P / W-D-L / win%) now come from played fixtures while the
-- owner held the club / nation — including the *current* season — and only:
--   • league
--   • cup
--   • World Cup (international_fixtures)
-- Friendlies (gpsl_friendly_*) are excluded.
-- Archived "Season by season" league table rows are unchanged.
-- Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.owner_profile_competitive_record(p_owner_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_owner uuid := p_owner_id;
  v_mp int := 0;
  v_won int := 0;
  v_drawn int := 0;
  v_lost int := 0;
  v_gf int := 0;
  v_ga int := 0;
  v_cs int := 0;
BEGIN
  IF v_owner IS NULL THEN
    RETURN jsonb_build_object(
      'mp', 0, 'won', 0, 'drawn', 0, 'lost', 0,
      'gf', 0, 'ga', 0, 'gd', 0, 'pts', 0,
      'win_pct', NULL, 'draw_pct', NULL, 'loss_pct', NULL,
      'avg_gf', NULL, 'avg_ga', NULL, 'clean_sheet_pct', NULL,
      'comps', 'league_cup_world_cup'
    );
  END IF;

  WITH tenure_clubs AS (
    SELECT DISTINCT r.season_id, r.club_short_name
    FROM public.competition_owner_season_ranking r
    WHERE r.owner_id = v_owner
    UNION
    SELECT s.id, c."ShortName"
    FROM public."Clubs" c
    CROSS JOIN public.competition_seasons s
    WHERE c.owner_id = v_owner
      AND s.is_current = true
  ),
  club_rows AS (
    SELECT
      CASE
        WHEN f.home_club_short_name = t.club_short_name
          THEN coalesce(f.home_goals, 0)
        ELSE coalesce(f.away_goals, 0)
      END AS gf,
      CASE
        WHEN f.home_club_short_name = t.club_short_name
          THEN coalesce(f.away_goals, 0)
        ELSE coalesce(f.home_goals, 0)
      END AS ga
    FROM tenure_clubs t
    JOIN public.competition_fixtures f
      ON f.season_id = t.season_id
     AND (
       f.home_club_short_name = t.club_short_name
       OR f.away_club_short_name = t.club_short_name
     )
    WHERE lower(coalesce(f.status, '')) IN ('played', 'completed', 'forfeit')
      AND f.home_goals IS NOT NULL
      AND f.away_goals IS NOT NULL
      AND lower(coalesce(f.competition_type, 'league')) IN ('league', 'cup')
  ),
  tenure_nations AS (
    SELECT DISTINCT ion.nation_code
    FROM public.international_owner_nations ion
    WHERE ion.club_short_name IN (
      SELECT club_short_name FROM tenure_clubs
    )
  ),
  intl_rows AS (
    SELECT
      CASE
        WHEN f.home_nation = n.nation_code THEN coalesce(f.home_goals, 0)
        ELSE coalesce(f.away_goals, 0)
      END AS gf,
      CASE
        WHEN f.home_nation = n.nation_code THEN coalesce(f.away_goals, 0)
        ELSE coalesce(f.home_goals, 0)
      END AS ga
    FROM tenure_nations n
    JOIN public.international_fixtures f
      ON f.home_nation = n.nation_code
      OR f.away_nation = n.nation_code
    WHERE (
        coalesce(f.played, false) = true
        OR lower(coalesce(f.status, '')) IN ('played', 'completed')
      )
      AND f.home_goals IS NOT NULL
      AND f.away_goals IS NOT NULL
  ),
  all_rows AS (
    SELECT gf, ga FROM club_rows
    UNION ALL
    SELECT gf, ga FROM intl_rows
  )
  SELECT
    count(*)::int,
    count(*) FILTER (WHERE gf > ga)::int,
    count(*) FILTER (WHERE gf = ga)::int,
    count(*) FILTER (WHERE gf < ga)::int,
    coalesce(sum(gf), 0)::int,
    coalesce(sum(ga), 0)::int,
    count(*) FILTER (WHERE ga = 0)::int
  INTO v_mp, v_won, v_drawn, v_lost, v_gf, v_ga, v_cs
  FROM all_rows;

  RETURN jsonb_build_object(
    'mp', v_mp,
    'won', v_won,
    'drawn', v_drawn,
    'lost', v_lost,
    'gf', v_gf,
    'ga', v_ga,
    'gd', v_gf - v_ga,
    'pts', (v_won * 3) + v_drawn,
    'win_pct', CASE
      WHEN v_mp > 0 THEN round(100.0 * v_won::numeric / v_mp::numeric, 1)
      ELSE NULL
    END,
    'draw_pct', CASE
      WHEN v_mp > 0 THEN round(100.0 * v_drawn::numeric / v_mp::numeric, 1)
      ELSE NULL
    END,
    'loss_pct', CASE
      WHEN v_mp > 0 THEN round(100.0 * v_lost::numeric / v_mp::numeric, 1)
      ELSE NULL
    END,
    'avg_gf', CASE
      WHEN v_mp > 0 THEN round(v_gf::numeric / v_mp::numeric, 2)
      ELSE NULL
    END,
    'avg_ga', CASE
      WHEN v_mp > 0 THEN round(v_ga::numeric / v_mp::numeric, 2)
      ELSE NULL
    END,
    'clean_sheet_pct', CASE
      WHEN v_mp > 0 THEN round(100.0 * v_cs::numeric / v_mp::numeric, 1)
      ELSE NULL
    END,
    'comps', 'league_cup_world_cup'
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.owner_profile_competitive_record(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.owner_profile_competitive_record(uuid)
  TO authenticated, anon;

-- Wire into owner_profile_bundle (replace totals block only via full function refresh)
CREATE OR REPLACE FUNCTION public.owner_profile_bundle(p_owner_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_owner uuid := p_owner_id;
  v_profile jsonb;
  v_seasons jsonb;
  v_totals jsonb;
  v_record jsonb;
  v_transfers jsonb;
  v_high_paid jsonb;
  v_high_recv jsonb;
  v_trophies jsonb;
  v_awards jsonb;
  v_achievements jsonb;
  v_xfer jsonb;
  v_season_count int := 0;
BEGIN
  IF v_owner IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_owner');
  END IF;

  IF NOT EXISTS (SELECT 1 FROM public.gpsl_owner_registry r WHERE r.owner_id = v_owner)
     AND EXISTS (SELECT 1 FROM public."Clubs" c WHERE c.owner_id = v_owner)
  THEN
    INSERT INTO public.gpsl_owner_registry (owner_id, status, owner_tag, last_club_short_name)
    SELECT
      c.owner_id,
      'active',
      nullif(btrim(c.owner), ''),
      c."ShortName"
    FROM public."Clubs" c
    WHERE c.owner_id = v_owner
    ON CONFLICT (owner_id) DO NOTHING;
  END IF;

  SELECT jsonb_build_object(
    'owner_id', p.owner_id,
    'owner_tag', p.owner_tag,
    'owner_name', p.owner_name,
    'status', p.status,
    'current_club_short_name', p.current_club_short_name,
    'current_club_name', p.current_club_name,
    'nation_code', p.last_nation_code,
    'nation_name', p.nation_name,
    'flag_emoji', p.flag_emoji,
    'badge_path', p.badge_path,
    'is_self', (auth.uid() IS NOT NULL AND auth.uid() = p.owner_id)
  )
  INTO v_profile
  FROM public.gpsl_owner_profile_public p
  WHERE p.owner_id = v_owner;

  IF v_profile IS NULL THEN
    SELECT jsonb_build_object(
      'owner_id', v_owner,
      'owner_tag', public.owner_registry_resolve_tag(v_owner),
      'owner_name', public.competition_owner_display_name(v_owner),
      'status', NULL,
      'current_club_short_name', c."ShortName",
      'current_club_name', c."Club",
      'nation_code', ion.nation_code,
      'nation_name', n.name,
      'flag_emoji', n.flag_emoji,
      'badge_path', NULL,
      'is_self', (auth.uid() IS NOT NULL AND auth.uid() = v_owner)
    )
    INTO v_profile
    FROM (SELECT v_owner AS owner_id) o
    LEFT JOIN public."Clubs" c ON c.owner_id = v_owner
    LEFT JOIN public.international_owner_nations ion
      ON ion.club_short_name = c."ShortName" AND ion.is_active = true
    LEFT JOIN public.international_nations n ON n.code = ion.nation_code;
  END IF;

  SELECT coalesce(jsonb_agg(to_jsonb(s) ORDER BY s.season_id DESC), '[]'::jsonb)
  INTO v_seasons
  FROM (
    SELECT
      h.season_id,
      h.season_label,
      h.club_short_name,
      h.club_name,
      h.division,
      h.final_position,
      h.mp,
      h.won,
      h.drawn,
      h.lost,
      h.gf,
      h.ga,
      h.gd,
      h.pts,
      CASE
        WHEN coalesce(h.mp, 0) > 0
        THEN round(100.0 * h.won::numeric / h.mp::numeric, 1)
        ELSE NULL
      END AS win_pct,
      CASE
        WHEN coalesce(h.mp, 0) > 0
        THEN round(100.0 * h.drawn::numeric / h.mp::numeric, 1)
        ELSE NULL
      END AS draw_pct,
      CASE
        WHEN coalesce(h.mp, 0) > 0
        THEN round(100.0 * h.lost::numeric / h.mp::numeric, 1)
        ELSE NULL
      END AS loss_pct,
      CASE
        WHEN coalesce(h.mp, 0) > 0
        THEN round(h.gf::numeric / h.mp::numeric, 2)
        ELSE NULL
      END AS avg_gf,
      CASE
        WHEN coalesce(h.mp, 0) > 0
        THEN round(h.ga::numeric / h.mp::numeric, 2)
        ELSE NULL
      END AS avg_ga
    FROM public.competition_club_season_history_public h
    JOIN public.competition_owner_season_ranking r
      ON r.season_id = h.season_id
     AND r.club_short_name = h.club_short_name
     AND r.owner_id = v_owner
  ) s;

  SELECT count(*)::int INTO v_season_count
  FROM public.competition_owner_season_ranking r
  WHERE r.owner_id = v_owner;

  -- Live competitive record (current season included; friendlies excluded)
  v_record := public.owner_profile_competitive_record(v_owner);
  v_totals := coalesce(v_record, '{}'::jsonb) || jsonb_build_object(
    'seasons', coalesce(v_season_count, 0)
  );

  IF to_regprocedure('public.owner_profile_transfer_stats(uuid)') IS NOT NULL THEN
    v_xfer := public.owner_profile_transfer_stats(v_owner);
  ELSE
    v_xfer := jsonb_build_object(
      'spent', 0, 'received', 0,
      'highest_fee_paid', NULL, 'highest_fee_received', NULL
    );
  END IF;
  v_transfers := jsonb_build_object(
    'spent', coalesce((v_xfer->>'spent')::numeric, 0),
    'received', coalesce((v_xfer->>'received')::numeric, 0)
  );
  v_high_paid := v_xfer->'highest_fee_paid';
  IF v_high_paid = 'null'::jsonb THEN v_high_paid := NULL; END IF;
  v_high_recv := v_xfer->'highest_fee_received';
  IF v_high_recv = 'null'::jsonb THEN v_high_recv := NULL; END IF;

  SELECT coalesce(jsonb_agg(to_jsonb(h) ORDER BY h.season_id DESC, h.honour_label), '[]'::jsonb)
  INTO v_trophies
  FROM public.competition_club_honours_public h
  JOIN public.competition_owner_season_ranking r
    ON r.season_id = h.season_id
   AND r.club_short_name = h.club_short_name
   AND r.owner_id = v_owner;

  SELECT coalesce(jsonb_agg(to_jsonb(a) ORDER BY a.season_id DESC, a.award_type), '[]'::jsonb)
  INTO v_awards
  FROM public.competition_season_awards_public a
  JOIN public.competition_owner_season_ranking r
    ON r.season_id = a.season_id
   AND r.club_short_name = a.club_short_name
   AND r.owner_id = v_owner
  WHERE a.award_type IN (
    'ballon_dor',
    'golden_boot',
    'golden_playmaker',
    'golden_glove',
    'season_potm',
    'championship_player_of_season',
    'team_of_season'
  );

  IF to_regprocedure('public.owner_profile_personal_achievements(uuid)') IS NOT NULL THEN
    v_achievements := public.owner_profile_personal_achievements(v_owner);
  ELSE
    v_achievements := '[]'::jsonb;
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'profile', v_profile,
    'career_totals', v_totals,
    'seasons', v_seasons,
    'transfers', v_transfers,
    'highest_fee_paid', v_high_paid,
    'highest_fee_received', v_high_recv,
    'trophies', v_trophies,
    'awards', v_awards,
    'achievements', v_achievements
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.owner_profile_bundle(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.owner_profile_bundle(uuid) TO anon;

NOTIFY pgrst, 'reload schema';
