-- =============================================================================
-- Fix: How they qualified shows mojibake instead of a separator
-- Cause: UTF-8 middle-dot corrupted when SQL was applied (common on JP Windows).
-- Fix: ASCII " - " in reason strings. Safe re-run.
-- =============================================================================

-- Detailed qualifiers for admin cup draw UI: club + how they qualified
CREATE OR REPLACE FUNCTION public.competition_qualify_cup_clubs_detailed(
  p_season_id bigint,
  p_cup_code text
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_code text := lower(btrim(coalesce(p_cup_code, '')));
  v_src bigint;
  v_rows jsonb := '[]'::jsonb;
BEGIN
  IF v_code = 'spoon' THEN
    v_code := 'bowl';
  END IF;

  v_src := public.competition_cup_qualification_source_season(p_season_id, v_code);

  IF v_code = 'super8' THEN
    SELECT coalesce(
      jsonb_agg(
        jsonb_build_object(
          'club', p.club_short_name,
          'division', 'superleague',
          'position', p.sort_key,
          'reason',
            public.competition_cup_division_label('superleague')
            || ' - finished '
            || public.competition_cup_ordinal(p.sort_key)
        )
        ORDER BY p.sort_key, p.club_short_name
      ),
      '[]'::jsonb
    )
    INTO v_rows
    FROM public.competition_cup_source_league_places(
      v_src, 'superleague', 1, 8
    ) p;
  ELSIF v_code = 'plate' THEN
    SELECT coalesce(
      jsonb_agg(
        jsonb_build_object(
          'club', x.club,
          'division', x.division,
          'position', x.pos,
          'reason', x.reason
        )
        ORDER BY x.sort_key, x.club
      ),
      '[]'::jsonb
    )
    INTO v_rows
    FROM (
      SELECT
        p.club_short_name AS club,
        'superleague'::text AS division,
        p.sort_key AS pos,
        p.sort_key AS sort_key,
        public.competition_cup_division_label('superleague')
          || ' - finished '
          || public.competition_cup_ordinal(p.sort_key) AS reason
      FROM public.competition_cup_source_league_places(
        v_src, 'superleague', 9, 16
      ) p
      UNION ALL
      SELECT
        p.club_short_name,
        'championship_a',
        p.sort_key,
        100 + p.sort_key,
        public.competition_cup_division_label('championship_a')
          || ' - finished '
          || public.competition_cup_ordinal(p.sort_key)
      FROM public.competition_cup_source_league_places(
        v_src, 'championship_a', 1, 4
      ) p
      UNION ALL
      SELECT
        p.club_short_name,
        'championship_b',
        p.sort_key,
        200 + p.sort_key,
        public.competition_cup_division_label('championship_b')
          || ' - finished '
          || public.competition_cup_ordinal(p.sort_key)
      FROM public.competition_cup_source_league_places(
        v_src, 'championship_b', 1, 4
      ) p
    ) x;
  ELSIF v_code = 'shield' THEN
    SELECT coalesce(
      jsonb_agg(
        jsonb_build_object(
          'club', x.club,
          'division', x.division,
          'position', x.pos,
          'reason', x.reason
        )
        ORDER BY x.sort_key, x.club
      ),
      '[]'::jsonb
    )
    INTO v_rows
    FROM (
      SELECT
        p.club_short_name AS club,
        'superleague'::text AS division,
        p.sort_key AS pos,
        p.sort_key AS sort_key,
        public.competition_cup_division_label('superleague')
          || ' - finished '
          || public.competition_cup_ordinal(p.sort_key) AS reason
      FROM public.competition_cup_source_league_places(
        v_src, 'superleague', 17, 20
      ) p
      UNION ALL
      SELECT
        p.club_short_name,
        'championship_a',
        p.sort_key,
        100 + p.sort_key,
        public.competition_cup_division_label('championship_a')
          || ' - finished '
          || public.competition_cup_ordinal(p.sort_key)
      FROM public.competition_cup_source_league_places(
        v_src, 'championship_a', 5, 15
      ) p
      UNION ALL
      SELECT
        p.club_short_name,
        'championship_b',
        p.sort_key,
        200 + p.sort_key,
        public.competition_cup_division_label('championship_b')
          || ' - finished '
          || public.competition_cup_ordinal(p.sort_key)
      FROM public.competition_cup_source_league_places(
        v_src, 'championship_b', 5, 15
      ) p
      UNION ALL
      SELECT
        q.club_short_name,
        'playoff',
        NULL,
        50,
        'Shield / Bowl playoff winner'
      FROM public.competition_cup_manual_qualifiers q
      WHERE q.season_id = v_src
        AND q.cup_code = 'shield'
        AND q.qualifier_role = 'shield_playoff_winner'
    ) x;
  ELSIF v_code = 'bowl' THEN
    SELECT coalesce(
      jsonb_agg(
        jsonb_build_object(
          'club', x.club,
          'division', x.division,
          'position', x.pos,
          'reason', x.reason
        )
        ORDER BY x.sort_key, x.club
      ),
      '[]'::jsonb
    )
    INTO v_rows
    FROM (
      SELECT
        p.club_short_name AS club,
        'championship_a'::text AS division,
        p.sort_key AS pos,
        p.sort_key AS sort_key,
        public.competition_cup_division_label('championship_a')
          || ' - finished '
          || public.competition_cup_ordinal(p.sort_key) AS reason
      FROM public.competition_cup_source_league_places(
        v_src, 'championship_a', 18, 20
      ) p
      UNION ALL
      SELECT
        p.club_short_name,
        'championship_b',
        p.sort_key,
        100 + p.sort_key,
        public.competition_cup_division_label('championship_b')
          || ' - finished '
          || public.competition_cup_ordinal(p.sort_key)
      FROM public.competition_cup_source_league_places(
        v_src, 'championship_b', 18, 20
      ) p
      UNION ALL
      SELECT
        q.club_short_name,
        'playoff',
        NULL,
        50,
        'Shield / Bowl playoff loser'
      FROM public.competition_cup_manual_qualifiers q
      WHERE q.season_id = v_src
        AND q.cup_code IN ('bowl', 'spoon')
        AND q.qualifier_role IN ('bowl_playoff_loser', 'spoon_playoff_loser')
    ) x;
  ELSIF v_code = 'league_cup' THEN
    SELECT coalesce(
      jsonb_agg(
        jsonb_build_object(
          'club', ccs.club_short_name,
          'division', ccs.division,
          'position', NULL,
          'reason',
            public.competition_cup_division_label(ccs.division)
            || ' - current season entry'
        )
        ORDER BY
          CASE ccs.division
            WHEN 'superleague' THEN 1
            WHEN 'championship_a' THEN 2
            WHEN 'championship_b' THEN 3
            ELSE 9
          END,
          ccs.club_short_name
      ),
      '[]'::jsonb
    )
    INTO v_rows
    FROM public.competition_club_seasons ccs
    WHERE ccs.season_id = p_season_id
      AND ccs.division IN ('superleague', 'championship_a', 'championship_b');
  END IF;

  RETURN coalesce(v_rows, '[]'::jsonb);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_qualify_cup_clubs_detailed(bigint, text)
  TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';
