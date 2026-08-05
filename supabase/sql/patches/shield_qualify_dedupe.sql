-- =============================================================================
-- Fix: Shield (and Bowl) qualifier double-count → empty Last 32 slots (TBD vs TBD)
--
-- Symptom:
--   Cup setup shows 28 Shield teams / 4 byes, but the drawn Last 32 only has
--   26 real clubs and one tie is TBD vs TBD (no fixture, pathway dies).
--
-- Cause:
--   competition_qualify_cup_clubs uses UNION ALL of league places + manual
--   playoff winners. A playoff winner who also finished in CH 5–15 (or SL
--   17–20) appears twice. array_length = 28 → bye math uses 4 byes, but
--   player pairing uses set EXCEPT (unique clubs) → only 26 unique → 2 empty
--   R1 slots → TBD vs TBD.
--
-- Fix:
--   Deduplicate qualifier lists (prefer playoff row when both apply).
--   Harden draw to dedupe before bracket build and fail if R1 slots go empty.
--
-- After apply: reload Shield bye panel (expect unique count; likely 26 → 6
-- byes if 2 playoff winners were already in the league band), re-save byes,
-- re-draw Shield.
-- Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.competition_cup_dedupe_clubs(p_clubs text[])
RETURNS text[]
LANGUAGE sql
IMMUTABLE
AS $function$
  SELECT coalesce(
    array_agg(x.club ORDER BY x.ord),
    ARRAY[]::text[]
  )
  FROM (
    SELECT DISTINCT ON (upper(btrim(c)))
      upper(btrim(c)) AS club,
      ord
    FROM unnest(coalesce(p_clubs, ARRAY[]::text[])) WITH ORDINALITY AS t(c, ord)
    WHERE nullif(btrim(c), '') IS NOT NULL
    ORDER BY upper(btrim(c)), ord
  ) x;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_cup_dedupe_clubs(text[])
  TO authenticated, service_role;

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
    -- DISTINCT ON club: playoff winner rows win over league-place duplicates
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
        SELECT q.club_short_name, 50, 0
        FROM public.competition_cup_manual_qualifiers q
        WHERE q.season_id = v_src
          AND q.cup_code = 'shield'
          AND q.qualifier_role = 'shield_playoff_winner'
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
        SELECT q.club_short_name, 50, 0
        FROM public.competition_cup_manual_qualifiers q
        WHERE q.season_id = v_src
          AND q.cup_code IN ('bowl', 'spoon')
          AND q.qualifier_role IN ('bowl_playoff_loser', 'spoon_playoff_loser')
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

  RETURN public.competition_cup_dedupe_clubs(coalesce(v_clubs, ARRAY[]::text[]));
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
            || ' · finished '
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
          || ' · finished '
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
          || ' · finished '
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
          || ' · finished '
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
            || ' · finished '
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
            || ' · finished '
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
            || ' · finished '
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
          0,
          'Shield / Bowl playoff winner'
        FROM public.competition_cup_manual_qualifiers q
        WHERE q.season_id = v_src
          AND q.cup_code = 'shield'
          AND q.qualifier_role = 'shield_playoff_winner'
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
            || ' · finished '
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
            || ' · finished '
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
          0,
          'Shield / Bowl playoff loser'
        FROM public.competition_cup_manual_qualifiers q
        WHERE q.season_id = v_src
          AND q.cup_code IN ('bowl', 'spoon')
          AND q.qualifier_role IN ('bowl_playoff_loser', 'spoon_playoff_loser')
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
            || ' · current season entry'
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

-- Draw: dedupe before bracket build; surface how many duplicates were dropped
CREATE OR REPLACE FUNCTION public.competition_draw_prestige_cup(
  p_season_id bigint,
  p_cup_code text,
  p_player_order text[] DEFAULT NULL,
  p_bye_match_nos int[] DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_code text := lower(btrim(coalesce(p_cup_code, '')));
  v_clubs text[];
  v_raw_n int;
  v_unique_n int;
  v_byes text[];
  v_result jsonb;
  v_sync jsonb;
  v_empty int;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF v_code NOT IN ('super8', 'plate', 'shield', 'spoon', 'bowl') THEN
    RAISE EXCEPTION 'Invalid prestige cup code';
  END IF;

  IF v_code = 'bowl' THEN
    v_clubs := public.competition_qualify_cup_clubs(p_season_id, 'spoon');
    IF NOT EXISTS (
      SELECT 1
      FROM public.competition_cup_round_schedule s
      WHERE s.cup_code = 'bowl'
      LIMIT 1
    ) THEN
      v_code := 'spoon';
    END IF;
  ELSE
    v_clubs := public.competition_qualify_cup_clubs(p_season_id, v_code);
  END IF;

  v_raw_n := coalesce(array_length(v_clubs, 1), 0);
  v_clubs := public.competition_cup_dedupe_clubs(v_clubs);
  v_unique_n := coalesce(array_length(v_clubs, 1), 0);

  IF v_unique_n < 2 THEN
    RAISE EXCEPTION 'Not enough qualified clubs for % (% found)', v_code, v_unique_n;
  END IF;

  IF to_regprocedure('public.competition_cup_load_saved_byes(bigint, text)') IS NOT NULL THEN
    v_byes := public.competition_cup_load_saved_byes(p_season_id, v_code);
  END IF;

  v_result := public.competition_build_knockout_bracket(
    p_season_id,
    v_code,
    v_clubs,
    CASE WHEN coalesce(array_length(v_byes, 1), 0) > 0 THEN v_byes ELSE NULL END,
    p_player_order,
    p_bye_match_nos
  );

  -- Guard: R1 must not contain empty (TBD vs TBD) non-bye shells
  SELECT count(*)::int
  INTO v_empty
  FROM public.competition_cup_bracket_nodes n
  WHERE n.season_id = p_season_id
    AND n.cup_code = v_code
    AND n.round_no = (
      SELECT min(round_no)
      FROM public.competition_cup_round_schedule
      WHERE cup_code = v_code
    )
    AND n.cup_leg = 1
    AND n.home_club_short_name IS NULL
    AND n.away_club_short_name IS NULL;

  IF coalesce(v_empty, 0) > 0 THEN
    RAISE EXCEPTION
      '% draw left % empty first-round tie(s) (TBD vs TBD). Unique clubs=%, saved byes=%. Re-check bye count and re-draw.',
      v_code,
      v_empty,
      v_unique_n,
      coalesce(array_length(v_byes, 1), 0);
  END IF;

  IF to_regprocedure('public.competition_cup_sync_all_scheduled_cup_fixtures(bigint, text)') IS NOT NULL THEN
    v_sync := public.competition_cup_sync_all_scheduled_cup_fixtures(p_season_id, v_code);
    v_result := v_result || coalesce(v_sync, '{}'::jsonb);
  END IF;

  RETURN coalesce(v_result, '{}'::jsonb) || jsonb_build_object(
    'cup_code', v_code,
    'qualified_raw_count', v_raw_n,
    'qualified_unique_count', v_unique_n,
    'duplicates_removed', greatest(v_raw_n - v_unique_n, 0)
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_draw_prestige_cup(bigint, text, text[], int[])
  TO authenticated;

-- Diagnostic helper (admin): find duplicate Shield qualifier rows on source season
CREATE OR REPLACE FUNCTION public.competition_cup_diagnose_qualifier_dupes(
  p_season_id bigint DEFAULT NULL,
  p_cup_code text DEFAULT 'shield'
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season bigint := p_season_id;
  v_code text := lower(btrim(coalesce(p_cup_code, 'shield')));
  v_src bigint;
  v_details jsonb;
  v_dupes jsonb;
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

  v_src := public.competition_cup_qualification_source_season(v_season, v_code);
  v_details := public.competition_qualify_cup_clubs_detailed(v_season, v_code);

  -- Pre-dedupe view: rebuild raw union counts from manual + league for shield
  IF v_code IN ('shield', 'bowl', 'spoon') THEN
    SELECT coalesce(jsonb_agg(row_to_json(x)::jsonb ORDER BY x.cnt DESC, x.club), '[]'::jsonb)
    INTO v_dupes
    FROM (
      SELECT upper(btrim(club)) AS club, count(*)::int AS cnt
      FROM (
        SELECT q.club_short_name AS club
        FROM public.competition_cup_manual_qualifiers q
        WHERE q.season_id = v_src
          AND (
            (v_code = 'shield' AND q.cup_code = 'shield' AND q.qualifier_role = 'shield_playoff_winner')
            OR (
              v_code IN ('bowl', 'spoon')
              AND q.cup_code IN ('bowl', 'spoon')
              AND q.qualifier_role IN ('bowl_playoff_loser', 'spoon_playoff_loser')
            )
          )
        UNION ALL
        SELECT p.club_short_name
        FROM public.competition_cup_source_league_places(
          v_src,
          CASE WHEN v_code = 'shield' THEN 'superleague' ELSE 'championship_a' END,
          CASE WHEN v_code = 'shield' THEN 17 ELSE 18 END,
          CASE WHEN v_code = 'shield' THEN 20 ELSE 20 END
        ) p
        WHERE v_code = 'shield'
        UNION ALL
        SELECT p.club_short_name
        FROM public.competition_cup_source_league_places(v_src, 'championship_a', 5, 15) p
        WHERE v_code = 'shield'
        UNION ALL
        SELECT p.club_short_name
        FROM public.competition_cup_source_league_places(v_src, 'championship_b', 5, 15) p
        WHERE v_code = 'shield'
        UNION ALL
        SELECT p.club_short_name
        FROM public.competition_cup_source_league_places(v_src, 'championship_a', 18, 20) p
        WHERE v_code IN ('bowl', 'spoon')
        UNION ALL
        SELECT p.club_short_name
        FROM public.competition_cup_source_league_places(v_src, 'championship_b', 18, 20) p
        WHERE v_code IN ('bowl', 'spoon')
      ) raw
      GROUP BY upper(btrim(club))
      HAVING count(*) > 1
    ) x;
  ELSE
    v_dupes := '[]'::jsonb;
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'season_id', v_season,
    'cup_code', v_code,
    'qualification_season_id', v_src,
    'unique_qualified', jsonb_array_length(coalesce(v_details, '[]'::jsonb)),
    'duplicate_clubs', coalesce(v_dupes, '[]'::jsonb),
    'qualified_details', coalesce(v_details, '[]'::jsonb)
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_cup_diagnose_qualifier_dupes(bigint, text)
  TO authenticated;

NOTIFY pgrst, 'reload schema';

-- Quick check after apply:
--   SELECT public.competition_cup_diagnose_qualifier_dupes();
-- Expect duplicate_clubs to list the 2 playoff winners that were also in the league band.
