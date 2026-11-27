-- Owner profile record: only matches played while this owner held the club.
-- A mid-season takeover no longer inherits the previous owner's results.
-- Kickoff is the match time when it exists; otherwise the result post time.
-- Friendlies stay out. League, cup and World Cup stay in.

CREATE OR REPLACE FUNCTION public.owner_profile_competitive_record(p_owner_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_owner uuid := p_owner_id;
  v_out jsonb;
BEGIN
  IF v_owner IS NULL THEN
    RETURN jsonb_build_object(
      'mp', 0, 'won', 0, 'drawn', 0, 'lost', 0,
      'gf', 0, 'ga', 0, 'gd', 0, 'pts', 0,
      'win_pct', NULL, 'ppg', NULL,
      'comps', 'league_cup_world_cup',
      'managed_only', true
    );
  END IF;

  WITH tenure AS (
    SELECT
      s.id AS season_id,
      c."ShortName" AS club_short_name,
      c.owner_assigned_at AS started_at,
      NULL::timestamptz AS ended_at
    FROM public."Clubs" c
    JOIN public.competition_seasons s ON s.is_current = true
    WHERE c.owner_id = v_owner
    UNION ALL
    SELECT
      r.season_id,
      r.club_short_name,
      NULL::timestamptz,
      CASE
        WHEN c.owner_id IS DISTINCT FROM v_owner
         AND c.owner_assigned_at IS NOT NULL
         AND c.owner_assigned_season_id IS NOT DISTINCT FROM r.season_id
        THEN c.owner_assigned_at
        ELSE NULL
      END
    FROM public.competition_owner_season_ranking r
    LEFT JOIN public."Clubs" c ON c."ShortName" = r.club_short_name
    WHERE r.owner_id = v_owner
      AND NOT (
        c.owner_id IS NOT DISTINCT FROM v_owner
        AND EXISTS (
          SELECT 1 FROM public.competition_seasons s
          WHERE s.id = r.season_id AND s.is_current = true
        )
      )
  ),
  club_played AS (
    SELECT
      f.id AS fixture_id,
      CASE
        WHEN lower(coalesce(f.competition_type, 'league')) = 'cup' THEN
          CASE lower(coalesce(f.cup_code, ''))
            WHEN 'super8' THEN 'Super8'
            WHEN 'plate' THEN 'Plate'
            WHEN 'shield' THEN 'Shield'
            WHEN 'bowl' THEN 'Bowl'
            WHEN 'league_cup' THEN 'League Cup'
            WHEN '' THEN 'Cup'
            ELSE initcap(replace(f.cup_code, '_', ' '))
          END
        ELSE
          CASE lower(coalesce(cs.division, ''))
            WHEN 'superleague' THEN 'Super League'
            WHEN 'championship_a' THEN 'Championship A'
            WHEN 'championship_b' THEN 'Championship B'
            WHEN 'championship_pool' THEN 'Championship'
            ELSE 'League'
          END
      END AS comp_label,
      CASE
        WHEN lower(coalesce(f.competition_type, 'league')) = 'cup' THEN 2
        ELSE 1
      END AS comp_sort,
      CASE
        WHEN f.home_club_short_name = t.club_short_name THEN 'home'
        ELSE 'away'
      END AS venue,
      CASE
        WHEN f.home_club_short_name = t.club_short_name THEN coalesce(f.home_goals, 0)
        ELSE coalesce(f.away_goals, 0)
      END AS gf,
      CASE
        WHEN f.home_club_short_name = t.club_short_name THEN coalesce(f.away_goals, 0)
        ELSE coalesce(f.home_goals, 0)
      END AS ga,
      CASE
        WHEN f.home_club_short_name = t.club_short_name THEN f.away_club_short_name
        ELSE f.home_club_short_name
      END AS opponent_short,
      coalesce(sch.agreed_kickoff_at, f.result_posted_at) AS played_at,
      t.season_id
    FROM tenure t
    JOIN public.competition_fixtures f
      ON f.season_id = t.season_id
     AND (
       f.home_club_short_name = t.club_short_name
       OR f.away_club_short_name = t.club_short_name
     )
    LEFT JOIN public.competition_fixture_schedule sch ON sch.fixture_id = f.id
    LEFT JOIN public.competition_club_seasons cs
      ON cs.season_id = f.season_id
     AND cs.club_short_name = t.club_short_name
    WHERE lower(coalesce(f.status, '')) IN ('played', 'completed', 'forfeit')
      AND f.home_goals IS NOT NULL
      AND f.away_goals IS NOT NULL
      AND lower(coalesce(f.competition_type, 'league')) IN ('league', 'cup')
      AND (
        t.started_at IS NULL
        OR coalesce(sch.agreed_kickoff_at, f.result_posted_at) >= t.started_at
      )
      AND (
        t.ended_at IS NULL
        OR coalesce(sch.agreed_kickoff_at, f.result_posted_at) < t.ended_at
      )
  ),
  intl_played AS (
    SELECT
      f.id AS fixture_id,
      'World Cup'::text AS comp_label,
      3 AS comp_sort,
      CASE WHEN f.home_nation = ion.nation_code THEN 'home' ELSE 'away' END AS venue,
      CASE
        WHEN f.home_nation = ion.nation_code THEN coalesce(f.home_goals, 0)
        ELSE coalesce(f.away_goals, 0)
      END AS gf,
      CASE
        WHEN f.home_nation = ion.nation_code THEN coalesce(f.away_goals, 0)
        ELSE coalesce(f.home_goals, 0)
      END AS ga,
      CASE
        WHEN f.home_nation = ion.nation_code THEN f.away_nation
        ELSE f.home_nation
      END AS opponent_short,
      f.played_at,
      t.season_id
    FROM tenure t
    JOIN public.international_owner_nations ion
      ON ion.club_short_name = t.club_short_name
     AND coalesce(ion.is_active, true) = true
    JOIN public.international_fixtures f
      ON f.home_nation = ion.nation_code
      OR f.away_nation = ion.nation_code
    WHERE (
        coalesce(f.played, false) = true
        OR lower(coalesce(f.status, '')) IN ('played', 'completed')
      )
      AND f.home_goals IS NOT NULL
      AND f.away_goals IS NOT NULL
      AND (
        t.started_at IS NULL
        OR f.played_at >= t.started_at
      )
      AND (
        t.ended_at IS NULL
        OR f.played_at < t.ended_at
      )
  ),
  played AS (
    SELECT
      p.comp_label,
      p.comp_sort,
      p.venue,
      p.gf,
      p.ga,
      p.opponent_short,
      coalesce(cl."Club", nat.name, p.opponent_short) AS opponent_name,
      p.played_at,
      p.season_id
    FROM (
      SELECT * FROM club_played
      UNION ALL
      SELECT * FROM intl_played
    ) p
    LEFT JOIN public."Clubs" cl ON cl."ShortName" = p.opponent_short
    LEFT JOIN public.international_nations nat ON nat.code = p.opponent_short
  ),
  line AS (
    SELECT
      count(*)::int AS mp,
      count(*) FILTER (WHERE gf > ga)::int AS won,
      count(*) FILTER (WHERE gf = ga)::int AS drawn,
      count(*) FILTER (WHERE gf < ga)::int AS lost,
      coalesce(sum(gf), 0)::int AS gf,
      coalesce(sum(ga), 0)::int AS ga,
      count(*) FILTER (WHERE ga = 0)::int AS clean_sheets,
      count(*) FILTER (WHERE gf = 0)::int AS failed_to_score,
      count(*) FILTER (WHERE gf > 0)::int AS scored,
      count(DISTINCT season_id)::int AS managed_seasons
    FROM played
  ),
  venue_line AS (
    SELECT venue,
      count(*)::int AS mp,
      count(*) FILTER (WHERE gf > ga)::int AS won,
      count(*) FILTER (WHERE gf = ga)::int AS drawn,
      count(*) FILTER (WHERE gf < ga)::int AS lost,
      coalesce(sum(gf), 0)::int AS gf,
      coalesce(sum(ga), 0)::int AS ga
    FROM played
    GROUP BY venue
  ),
  comp_line AS (
    SELECT comp_label AS label,
      min(comp_sort) AS comp_sort,
      count(*)::int AS mp,
      count(*) FILTER (WHERE gf > ga)::int AS won,
      count(*) FILTER (WHERE gf = ga)::int AS drawn,
      count(*) FILTER (WHERE gf < ga)::int AS lost,
      coalesce(sum(gf), 0)::int AS gf,
      coalesce(sum(ga), 0)::int AS ga
    FROM played
    GROUP BY comp_label
  )
  SELECT jsonb_build_object(
    'mp', l.mp,
    'won', l.won,
    'drawn', l.drawn,
    'lost', l.lost,
    'gf', l.gf,
    'ga', l.ga,
    'gd', l.gf - l.ga,
    'pts', (l.won * 3) + l.drawn,
    'win_pct', CASE WHEN l.mp > 0 THEN round(100.0 * l.won::numeric / l.mp, 1) END,
    'draw_pct', CASE WHEN l.mp > 0 THEN round(100.0 * l.drawn::numeric / l.mp, 1) END,
    'loss_pct', CASE WHEN l.mp > 0 THEN round(100.0 * l.lost::numeric / l.mp, 1) END,
    'avg_gf', CASE WHEN l.mp > 0 THEN round(l.gf::numeric / l.mp, 2) END,
    'avg_ga', CASE WHEN l.mp > 0 THEN round(l.ga::numeric / l.mp, 2) END,
    'clean_sheet_pct', CASE WHEN l.mp > 0 THEN round(100.0 * l.clean_sheets::numeric / l.mp, 1) END,
    'ppg', CASE WHEN l.mp > 0 THEN round(((l.won * 3) + l.drawn)::numeric / l.mp, 2) END,
    'clean_sheets', l.clean_sheets,
    'failed_to_score', l.failed_to_score,
    'scored', l.scored,
    'managed_seasons', l.managed_seasons,
    'managed_only', true,
    'comps', 'league_cup_world_cup',
    'home', (
      SELECT jsonb_build_object(
        'mp', v.mp, 'won', v.won, 'drawn', v.drawn, 'lost', v.lost,
        'gf', v.gf, 'ga', v.ga, 'gd', v.gf - v.ga,
        'win_pct', CASE WHEN v.mp > 0 THEN round(100.0 * v.won::numeric / v.mp, 1) END
      )
      FROM venue_line v WHERE v.venue = 'home'
    ),
    'away', (
      SELECT jsonb_build_object(
        'mp', v.mp, 'won', v.won, 'drawn', v.drawn, 'lost', v.lost,
        'gf', v.gf, 'ga', v.ga, 'gd', v.gf - v.ga,
        'win_pct', CASE WHEN v.mp > 0 THEN round(100.0 * v.won::numeric / v.mp, 1) END
      )
      FROM venue_line v WHERE v.venue = 'away'
    ),
    'splits', coalesce((
      SELECT jsonb_agg(
        jsonb_build_object(
          'label', c.label,
          'mp', c.mp, 'won', c.won, 'drawn', c.drawn, 'lost', c.lost,
          'gf', c.gf, 'ga', c.ga, 'gd', c.gf - c.ga,
          'win_pct', CASE WHEN c.mp > 0 THEN round(100.0 * c.won::numeric / c.mp, 1) END
        )
        ORDER BY c.comp_sort, c.label
      )
      FROM comp_line c
    ), '[]'::jsonb),
    'biggest_win', (
      SELECT jsonb_build_object(
        'gf', p.gf, 'ga', p.ga,
        'score', p.gf::text || '–' || p.ga::text,
        'opponent', p.opponent_name,
        'opponent_short', p.opponent_short,
        'competition', p.comp_label,
        'venue', p.venue
      )
      FROM played p
      WHERE p.gf > p.ga
      ORDER BY (p.gf - p.ga) DESC, p.gf DESC, p.played_at DESC NULLS LAST
      LIMIT 1
    ),
    'heaviest_defeat', (
      SELECT jsonb_build_object(
        'gf', p.gf, 'ga', p.ga,
        'score', p.gf::text || '–' || p.ga::text,
        'opponent', p.opponent_name,
        'opponent_short', p.opponent_short,
        'competition', p.comp_label,
        'venue', p.venue
      )
      FROM played p
      WHERE p.gf < p.ga
      ORDER BY (p.ga - p.gf) DESC, p.ga DESC, p.played_at DESC NULLS LAST
      LIMIT 1
    )
  )
  INTO v_out
  FROM line l;

  RETURN v_out;
END;
$function$;

REVOKE ALL ON FUNCTION public.owner_profile_competitive_record(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.owner_profile_competitive_record(uuid)
  TO authenticated, anon;

NOTIFY pgrst, 'reload schema';
