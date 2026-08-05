-- =============================================================================
-- Fix: Shield/Bowl playoff qualifiers must come from CH 16th vs 17th ties
--
-- Incident:
--   Rosario Central (CH A 6th) and Sao Paulo (CH B 8th) were stored as
--   shield_playoff_winner. Those finishes already auto-qualify via places 5窶・5,
--   so they double-counted and the real 16v17 winners never entered the Shield.
--
-- Rules:
--   Shield/Bowl playoff = Championship A/B 16th vs 17th only.
--   Winner 竊・Shield, loser 竊・Bowl. Never mid-table clubs.
--
-- This patch:
--   1) Prefers played ch_sb_* playoff ties over manual_qualifiers
--   2) Sync RPC to rewrite manual rows from those ties
--   3) Blocks admin manual save when club already auto-qualifies (5窶・5 / 18窶・0)
--   4) Blocks generate when 16/17 standings are missing
--
-- Run AFTER next season cup draws. Then:
--   SELECT public.competition_sync_shield_bowl_qualifiers_from_playoffs(<source_season_id>);
--   Re-check Shield bye panel 竊・re-draw if needed.
-- Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.competition_playoff_shield_bowl_winners(p_season_id bigint)
RETURNS TABLE (
  division text,
  bracket text,
  winner_club text,
  loser_club text,
  home_club text,
  away_club text,
  status text
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
  SELECT
    CASE t.bracket
      WHEN 'ch_sb_a' THEN 'championship_a'
      WHEN 'ch_sb_b' THEN 'championship_b'
    END AS division,
    t.bracket,
    nullif(btrim(t.winner_club_short_name), '') AS winner_club,
    nullif(btrim(t.loser_club_short_name), '') AS loser_club,
    nullif(btrim(t.home_club_short_name), '') AS home_club,
    nullif(btrim(t.away_club_short_name), '') AS away_club,
    t.status
  FROM public.competition_playoff_ties t
  WHERE t.season_id = p_season_id
    AND t.bracket IN ('ch_sb_a', 'ch_sb_b');
$function$;

GRANT EXECUTE ON FUNCTION public.competition_playoff_shield_bowl_winners(bigint)
  TO authenticated, service_role;

-- Rewrite manual qualifier table from played 16v17 ties (source of truth)
CREATE OR REPLACE FUNCTION public.competition_sync_shield_bowl_qualifiers_from_playoffs(
  p_season_id bigint DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season bigint := p_season_id;
  v_row record;
  v_upserted int := 0;
  v_skipped int := 0;
  v_details jsonb := '[]'::jsonb;
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF v_season IS NULL THEN
    SELECT id INTO v_season
    FROM public.competition_seasons
    WHERE is_current = true
    ORDER BY id DESC
    LIMIT 1;
  END IF;

  IF v_season IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_season');
  END IF;

  FOR v_row IN
    SELECT * FROM public.competition_playoff_shield_bowl_winners(v_season)
  LOOP
    IF v_row.status IS DISTINCT FROM 'played'
       OR v_row.winner_club IS NULL
       OR v_row.loser_club IS NULL THEN
      v_skipped := v_skipped + 1;
      v_details := v_details || jsonb_build_array(jsonb_build_object(
        'division', v_row.division,
        'bracket', v_row.bracket,
        'action', 'skipped',
        'reason', 'tie_not_played_or_incomplete',
        'home', v_row.home_club,
        'away', v_row.away_club,
        'status', v_row.status
      ));
      CONTINUE;
    END IF;

    INSERT INTO public.competition_cup_manual_qualifiers (
      season_id, cup_code, division, club_short_name, qualifier_role
    ) VALUES
      (v_season, 'shield', v_row.division, v_row.winner_club, 'shield_playoff_winner'),
      (v_season, 'bowl', v_row.division, v_row.loser_club, 'bowl_playoff_loser')
    ON CONFLICT (season_id, cup_code, division, qualifier_role)
    DO UPDATE SET club_short_name = excluded.club_short_name;

    v_upserted := v_upserted + 2;
    v_details := v_details || jsonb_build_array(jsonb_build_object(
      'division', v_row.division,
      'bracket', v_row.bracket,
      'action', 'synced',
      'shield_winner', v_row.winner_club,
      'bowl_loser', v_row.loser_club,
      'tie', v_row.home_club || ' vs ' || v_row.away_club
    ));
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true,
    'season_id', v_season,
    'rows_upserted', v_upserted,
    'ties_skipped', v_skipped,
    'details', v_details
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_sync_shield_bowl_qualifiers_from_playoffs(bigint)
  TO authenticated;

-- Admin manual save: only allow real 16/17 participants; never mid-table auto-qualifiers
CREATE OR REPLACE FUNCTION public.competition_admin_set_playoff_qualifier(
  p_season_id bigint,
  p_cup_code text,
  p_division text,
  p_club_short_name text,
  p_role text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_cup text := lower(btrim(coalesce(p_cup_code, '')));
  v_role text := lower(btrim(coalesce(p_role, '')));
  v_div text := lower(btrim(coalesce(p_division, '')));
  v_club text := upper(btrim(coalesce(p_club_short_name, '')));
  v_bracket text;
  v_pos int;
  v_in_tie boolean := false;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF v_cup = 'spoon' THEN
    v_cup := 'bowl';
  END IF;
  IF v_role = 'spoon_playoff_loser' THEN
    v_role := 'bowl_playoff_loser';
  END IF;

  IF v_cup NOT IN ('shield', 'bowl') THEN
    RAISE EXCEPTION 'Invalid cup %', v_cup;
  END IF;
  IF v_div NOT IN ('championship_a', 'championship_b') THEN
    RAISE EXCEPTION 'Invalid division %', v_div;
  END IF;
  IF v_club = '' THEN
    RAISE EXCEPTION 'Club ShortName required';
  END IF;
  IF v_role NOT IN ('shield_playoff_winner', 'bowl_playoff_loser') THEN
    RAISE EXCEPTION 'Invalid role %', v_role;
  END IF;

  v_bracket := CASE v_div
    WHEN 'championship_a' THEN 'ch_sb_a'
    ELSE 'ch_sb_b'
  END;

  SELECT EXISTS (
    SELECT 1
    FROM public.competition_playoff_ties t
    WHERE t.season_id = p_season_id
      AND t.bracket = v_bracket
      AND v_club IN (
        upper(btrim(coalesce(t.home_club_short_name, ''))),
        upper(btrim(coalesce(t.away_club_short_name, ''))),
        upper(btrim(coalesce(t.winner_club_short_name, ''))),
        upper(btrim(coalesce(t.loser_club_short_name, '')))
      )
  ) INTO v_in_tie;

  SELECT p.sort_key INTO v_pos
  FROM public.competition_cup_source_league_places(p_season_id, v_div, 1, 20) p
  WHERE upper(btrim(p.club_short_name)) = v_club
  LIMIT 1;

  IF NOT v_in_tie AND v_pos IS DISTINCT FROM 16 AND v_pos IS DISTINCT FROM 17 THEN
    RAISE EXCEPTION
      '% (%) is not a Championship 16th/17th Shield/Bowl playoff club for this season. Use the generated 16v17 ties (or Sync from playoffs).',
      v_club, coalesce('finished ' || v_pos::text, 'no table position');
  END IF;

  IF v_role = 'shield_playoff_winner' AND v_pos BETWEEN 5 AND 15 THEN
    RAISE EXCEPTION
      '% finished % 窶・they already qualify for the Shield via league places 5窶・5. Shield playoff is 16th vs 17th only.',
      v_club, v_pos;
  END IF;

  IF v_role = 'bowl_playoff_loser' AND v_pos BETWEEN 18 AND 20 THEN
    RAISE EXCEPTION
      '% finished % 窶・they already qualify for the Bowl via league places 18窶・0. Bowl playoff loser is the 16v17 loser only.',
      v_club, v_pos;
  END IF;

  INSERT INTO public.competition_cup_manual_qualifiers (
    season_id, cup_code, division, club_short_name, qualifier_role
  )
  VALUES (p_season_id, v_cup, v_div, v_club, v_role)
  ON CONFLICT (season_id, cup_code, division, qualifier_role)
  DO UPDATE SET club_short_name = excluded.club_short_name;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_admin_set_playoff_qualifier(bigint, text, text, text, text)
  TO authenticated;

-- Qualify: prefer played 16v17 winners; manual only if that division has no played tie
CREATE OR REPLACE FUNCTION public.competition_qualify_cup_clubs(
  p_season_id bigint,
  p_cup_code text
)
RETURNS text[]
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_code text := lower(btrim(coalesce(p_cup_code, '')));
  v_src bigint;
  v_clubs text[] := ARRAY[]::text[];
BEGIN
  IF v_code = 'spoon' THEN
    v_code := 'bowl';
  END IF;

  v_src := public.competition_cup_qualification_source_season(p_season_id, v_code);

  IF v_code = 'super8' THEN
    SELECT array_agg(p.club_short_name ORDER BY p.sort_key)
    INTO v_clubs
    FROM public.competition_cup_source_league_places(
      v_src, 'superleague', 1, 8
    ) p;
  ELSIF v_code = 'plate' THEN
    SELECT array_agg(x.club ORDER BY x.sort_key, x.club)
    INTO v_clubs
    FROM (
      SELECT p.club_short_name AS club, p.sort_key
      FROM public.competition_cup_source_league_places(
        v_src, 'superleague', 9, 16
      ) p
      UNION ALL
      SELECT p.club_short_name, 100 + p.sort_key
      FROM public.competition_cup_source_league_places(
        v_src, 'championship_a', 1, 4
      ) p
      UNION ALL
      SELECT p.club_short_name, 200 + p.sort_key
      FROM public.competition_cup_source_league_places(
        v_src, 'championship_b', 1, 4
      ) p
    ) x;
  ELSIF v_code = 'shield' THEN
    SELECT array_agg(d.club ORDER BY d.sort_key, d.club)
    INTO v_clubs
    FROM (
      SELECT DISTINCT ON (upper(btrim(x.club)))
        upper(btrim(x.club)) AS club,
        x.sort_key
      FROM (
        SELECT p.club_short_name AS club, p.sort_key AS sort_key, 1 AS pri
        FROM public.competition_cup_source_league_places(
          v_src, 'superleague', 17, 20
        ) p
        UNION ALL
        SELECT p.club_short_name, 100 + p.sort_key, 1
        FROM public.competition_cup_source_league_places(
          v_src, 'championship_a', 5, 15
        ) p
        UNION ALL
        SELECT p.club_short_name, 200 + p.sort_key, 1
        FROM public.competition_cup_source_league_places(
          v_src, 'championship_b', 5, 15
        ) p
        UNION ALL
        -- Played CH 16v17 winners (source of truth)
        SELECT w.winner_club, 50, 0
        FROM public.competition_playoff_shield_bowl_winners(v_src) w
        WHERE w.status = 'played'
          AND w.winner_club IS NOT NULL
        UNION ALL
        -- Manual fallback only when that division has no played 16v17 result
        SELECT q.club_short_name, 50, 0
        FROM public.competition_cup_manual_qualifiers q
        WHERE q.season_id = v_src
          AND q.cup_code = 'shield'
          AND q.qualifier_role = 'shield_playoff_winner'
          AND NOT EXISTS (
            SELECT 1
            FROM public.competition_playoff_shield_bowl_winners(v_src) w
            WHERE w.division = q.division
              AND w.status = 'played'
              AND w.winner_club IS NOT NULL
          )
      ) x
      WHERE nullif(btrim(x.club), '') IS NOT NULL
      ORDER BY upper(btrim(x.club)), x.pri, x.sort_key
    ) d;
  ELSIF v_code = 'bowl' THEN
    SELECT array_agg(d.club ORDER BY d.sort_key, d.club)
    INTO v_clubs
    FROM (
      SELECT DISTINCT ON (upper(btrim(x.club)))
        upper(btrim(x.club)) AS club,
        x.sort_key
      FROM (
        SELECT p.club_short_name AS club, p.sort_key AS sort_key, 1 AS pri
        FROM public.competition_cup_source_league_places(
          v_src, 'championship_a', 18, 20
        ) p
        UNION ALL
        SELECT p.club_short_name, 100 + p.sort_key, 1
        FROM public.competition_cup_source_league_places(
          v_src, 'championship_b', 18, 20
        ) p
        UNION ALL
        SELECT w.loser_club, 50, 0
        FROM public.competition_playoff_shield_bowl_winners(v_src) w
        WHERE w.status = 'played'
          AND w.loser_club IS NOT NULL
        UNION ALL
        SELECT q.club_short_name, 50, 0
        FROM public.competition_cup_manual_qualifiers q
        WHERE q.season_id = v_src
          AND q.cup_code IN ('bowl', 'spoon')
          AND q.qualifier_role IN ('bowl_playoff_loser', 'spoon_playoff_loser')
          AND NOT EXISTS (
            SELECT 1
            FROM public.competition_playoff_shield_bowl_winners(v_src) w
            WHERE w.division = q.division
              AND w.status = 'played'
              AND w.loser_club IS NOT NULL
          )
      ) x
      WHERE nullif(btrim(x.club), '') IS NOT NULL
      ORDER BY upper(btrim(x.club)), x.pri, x.sort_key
    ) d;
  ELSIF v_code = 'league_cup' THEN
    SELECT array_agg(ccs.club_short_name ORDER BY ccs.club_short_name)
    INTO v_clubs
    FROM public.competition_club_seasons ccs
    WHERE ccs.season_id = p_season_id
      AND ccs.division IN ('superleague', 'championship_a', 'championship_b');
  ELSE
    RETURN ARRAY[]::text[];
  END IF;

  IF to_regprocedure('public.competition_cup_dedupe_clubs(text[])') IS NOT NULL THEN
    RETURN public.competition_cup_dedupe_clubs(coalesce(v_clubs, ARRAY[]::text[]));
  END IF;
  RETURN coalesce(v_clubs, ARRAY[]::text[]);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_qualify_cup_clubs(bigint, text)
  TO authenticated, service_role;

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
            || ' ﾂｷ finished '
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
          || ' ﾂｷ finished '
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
          || ' ﾂｷ finished '
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
          || ' ﾂｷ finished '
          || public.competition_cup_ordinal(p.sort_key)
      FROM public.competition_cup_source_league_places(
        v_src, 'championship_b', 1, 4
      ) p
    ) x;
  ELSIF v_code = 'shield' THEN
    SELECT coalesce(
      jsonb_agg(
        jsonb_build_object(
          'club', d.club,
          'division', d.division,
          'position', d.pos,
          'reason', d.reason
        )
        ORDER BY d.sort_key, d.club
      ),
      '[]'::jsonb
    )
    INTO v_rows
    FROM (
      SELECT DISTINCT ON (upper(btrim(x.club)))
        upper(btrim(x.club)) AS club,
        x.division,
        x.pos,
        x.sort_key,
        x.reason
      FROM (
        SELECT
          p.club_short_name AS club,
          'superleague'::text AS division,
          p.sort_key AS pos,
          p.sort_key AS sort_key,
          1 AS pri,
          public.competition_cup_division_label('superleague')
            || ' ﾂｷ finished '
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
          1,
          public.competition_cup_division_label('championship_a')
            || ' ﾂｷ finished '
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
          1,
          public.competition_cup_division_label('championship_b')
            || ' ﾂｷ finished '
            || public.competition_cup_ordinal(p.sort_key)
        FROM public.competition_cup_source_league_places(
          v_src, 'championship_b', 5, 15
        ) p
        UNION ALL
        SELECT
          w.winner_club,
          w.division,
          NULL,
          50,
          0,
          'Championship 16th vs 17th playoff winner'
        FROM public.competition_playoff_shield_bowl_winners(v_src) w
        WHERE w.status = 'played'
          AND w.winner_club IS NOT NULL
        UNION ALL
        SELECT
          q.club_short_name,
          q.division,
          NULL,
          50,
          0,
          'Shield playoff winner (manual 窶・no played 16v17 tie)'
        FROM public.competition_cup_manual_qualifiers q
        WHERE q.season_id = v_src
          AND q.cup_code = 'shield'
          AND q.qualifier_role = 'shield_playoff_winner'
          AND NOT EXISTS (
            SELECT 1
            FROM public.competition_playoff_shield_bowl_winners(v_src) w
            WHERE w.division = q.division
              AND w.status = 'played'
              AND w.winner_club IS NOT NULL
          )
      ) x
      WHERE nullif(btrim(x.club), '') IS NOT NULL
      ORDER BY upper(btrim(x.club)), x.pri, x.sort_key
    ) d;
  ELSIF v_code = 'bowl' THEN
    SELECT coalesce(
      jsonb_agg(
        jsonb_build_object(
          'club', d.club,
          'division', d.division,
          'position', d.pos,
          'reason', d.reason
        )
        ORDER BY d.sort_key, d.club
      ),
      '[]'::jsonb
    )
    INTO v_rows
    FROM (
      SELECT DISTINCT ON (upper(btrim(x.club)))
        upper(btrim(x.club)) AS club,
        x.division,
        x.pos,
        x.sort_key,
        x.reason
      FROM (
        SELECT
          p.club_short_name AS club,
          'championship_a'::text AS division,
          p.sort_key AS pos,
          p.sort_key AS sort_key,
          1 AS pri,
          public.competition_cup_division_label('championship_a')
            || ' ﾂｷ finished '
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
          1,
          public.competition_cup_division_label('championship_b')
            || ' ﾂｷ finished '
            || public.competition_cup_ordinal(p.sort_key)
        FROM public.competition_cup_source_league_places(
          v_src, 'championship_b', 18, 20
        ) p
        UNION ALL
        SELECT
          w.loser_club,
          w.division,
          NULL,
          50,
          0,
          'Championship 16th vs 17th playoff loser'
        FROM public.competition_playoff_shield_bowl_winners(v_src) w
        WHERE w.status = 'played'
          AND w.loser_club IS NOT NULL
        UNION ALL
        SELECT
          q.club_short_name,
          q.division,
          NULL,
          50,
          0,
          'Bowl playoff loser (manual 窶・no played 16v17 tie)'
        FROM public.competition_cup_manual_qualifiers q
        WHERE q.season_id = v_src
          AND q.cup_code IN ('bowl', 'spoon')
          AND q.qualifier_role IN ('bowl_playoff_loser', 'spoon_playoff_loser')
          AND NOT EXISTS (
            SELECT 1
            FROM public.competition_playoff_shield_bowl_winners(v_src) w
            WHERE w.division = q.division
              AND w.status = 'played'
              AND w.loser_club IS NOT NULL
          )
      ) x
      WHERE nullif(btrim(x.club), '') IS NOT NULL
      ORDER BY upper(btrim(x.club)), x.pri, x.sort_key
    ) d;
  ELSIF v_code = 'league_cup' THEN
    SELECT coalesce(
      jsonb_agg(
        jsonb_build_object(
          'club', ccs.club_short_name,
          'division', ccs.division,
          'position', NULL,
          'reason',
            public.competition_cup_division_label(ccs.division)
            || ' ﾂｷ current season entry'
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

-- Admin generate wrapper: refuse if 16/17 standings missing (keeps core generate intact)
CREATE OR REPLACE FUNCTION public.admin_competition_generate_playoffs(
  p_season_id bigint DEFAULT NULL,
  p_force boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season_id bigint := p_season_id;
  v_missing text[] := ARRAY[]::text[];
  v_club text;
  v_check record;
  v_exists boolean;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF v_season_id IS NULL THEN
    SELECT id INTO v_season_id
    FROM public.competition_seasons
    WHERE is_current = true
    ORDER BY id DESC
    LIMIT 1;
  END IF;

  IF v_season_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_season');
  END IF;

  SELECT EXISTS (
    SELECT 1 FROM public.competition_playoff_ties WHERE season_id = v_season_id
  ) INTO v_exists;

  -- Only enforce when creating fresh brackets
  IF NOT v_exists OR coalesce(p_force, false) THEN
    FOR v_check IN
      SELECT * FROM (VALUES
        ('superleague', 16), ('superleague', 17),
        ('championship_a', 16), ('championship_a', 17),
        ('championship_b', 16), ('championship_b', 17)
      ) AS c(division, pos)
    LOOP
      v_club := public.competition_playoff_standing_club(
        v_season_id, v_check.division, v_check.pos
      );
      IF v_club IS NULL OR btrim(v_club) = '' THEN
        v_missing := array_append(
          v_missing,
          v_check.division || ' #' || v_check.pos::text
        );
      END IF;
    END LOOP;

    IF coalesce(array_length(v_missing, 1), 0) > 0 THEN
      RETURN jsonb_build_object(
        'ok', false,
        'reason', 'missing_standings_16_17',
        'missing', to_jsonb(v_missing),
        'hint', 'Finish league tables (positions 16 & 17) before generating playoffs. Shield/Bowl is 16th vs 17th only.'
      );
    END IF;
  END IF;

  RETURN public.competition_generate_playoffs(v_season_id, p_force);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.admin_competition_generate_playoffs(bigint, boolean)
  TO authenticated;

-- One-click admin repair: find the season with 16v17 ties, show winners, rewrite qualifiers
CREATE OR REPLACE FUNCTION public.competition_admin_fix_shield_bowl_qualifiers()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season bigint;
  v_label text;
  v_sync jsonb;
  v_ties jsonb := '[]'::jsonb;
  v_row record;
  v_club_name text;
  v_home_name text;
  v_away_name text;
  v_win_name text;
  v_lose_name text;
  v_lines text[] := ARRAY[]::text[];
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  -- Prefer the most recent season that actually has CH Shield/Bowl 16v17 ties
  SELECT t.season_id INTO v_season
  FROM public.competition_playoff_ties t
  WHERE t.bracket IN ('ch_sb_a', 'ch_sb_b')
  GROUP BY t.season_id
  ORDER BY t.season_id DESC
  LIMIT 1;

  IF v_season IS NULL THEN
    RETURN jsonb_build_object(
      'ok', false,
      'reason', 'no_ch_sb_ties',
      'message', 'No Championship 16th vs 17th Shield/Bowl playoff ties found in the database.'
    );
  END IF;

  SELECT s.label INTO v_label
  FROM public.competition_seasons s
  WHERE s.id = v_season;

  FOR v_row IN
    SELECT *
    FROM public.competition_playoff_shield_bowl_winners(v_season)
    ORDER BY bracket
  LOOP
    SELECT c."Club" INTO v_home_name FROM public."Clubs" c WHERE c."ShortName" = v_row.home_club;
    SELECT c."Club" INTO v_away_name FROM public."Clubs" c WHERE c."ShortName" = v_row.away_club;
    SELECT c."Club" INTO v_win_name FROM public."Clubs" c WHERE c."ShortName" = v_row.winner_club;
    SELECT c."Club" INTO v_lose_name FROM public."Clubs" c WHERE c."ShortName" = v_row.loser_club;

    v_ties := v_ties || jsonb_build_array(jsonb_build_object(
      'division', v_row.division,
      'bracket', v_row.bracket,
      'status', v_row.status,
      'home', v_row.home_club,
      'home_name', coalesce(v_home_name, v_row.home_club),
      'away', v_row.away_club,
      'away_name', coalesce(v_away_name, v_row.away_club),
      'winner', v_row.winner_club,
      'winner_name', coalesce(v_win_name, v_row.winner_club),
      'loser', v_row.loser_club,
      'loser_name', coalesce(v_lose_name, v_row.loser_club)
    ));

    IF v_row.status = 'played' AND v_row.winner_club IS NOT NULL THEN
      v_lines := array_append(
        v_lines,
        format(
          '%s: %s beat %s → Shield: %s · Bowl: %s',
          CASE v_row.division
            WHEN 'championship_a' THEN 'Championship A'
            WHEN 'championship_b' THEN 'Championship B'
            ELSE v_row.division
          END,
          coalesce(v_win_name, v_row.winner_club),
          coalesce(v_lose_name, v_row.loser_club),
          coalesce(v_win_name, v_row.winner_club),
          coalesce(v_lose_name, v_row.loser_club)
        )
      );
    ELSE
      v_lines := array_append(
        v_lines,
        format(
          '%s: %s vs %s — NOT PLAYED YET (status=%s)',
          CASE v_row.division
            WHEN 'championship_a' THEN 'Championship A'
            WHEN 'championship_b' THEN 'Championship B'
            ELSE v_row.division
          END,
          coalesce(v_home_name, v_row.home_club, '?'),
          coalesce(v_away_name, v_row.away_club, '?'),
          coalesce(v_row.status, 'unknown')
        )
      );
    END IF;
  END LOOP;

  v_sync := public.competition_sync_shield_bowl_qualifiers_from_playoffs(v_season);

  RETURN jsonb_build_object(
    'ok', coalesce((v_sync ->> 'ok')::boolean, false),
    'season_id', v_season,
    'season_label', v_label,
    'ties', v_ties,
    'summary_lines', to_jsonb(v_lines),
    'sync', v_sync,
    'message', CASE
      WHEN coalesce((v_sync ->> 'rows_upserted')::int, 0) > 0 THEN
        'Qualifiers rewritten from the real 16v17 results. Next: open Admin Cups → Shield → reload byes → re-draw.'
      WHEN coalesce((v_sync ->> 'ties_skipped')::int, 0) > 0 THEN
        '16v17 ties exist but are not marked played — play/confirm those fixtures first, then run this again.'
      ELSE
        'No qualifier rows changed.'
    END
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_admin_fix_shield_bowl_qualifiers()
  TO authenticated;

NOTIFY pgrst, 'reload schema';
