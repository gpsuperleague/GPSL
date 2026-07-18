-- Prestige cups (Super8 / Plate / Shield / Bowl) qualify from the PREVIOUS
-- season's final league table (+ playoff manual qualifiers), not the season
-- the cup bracket is drawn into.
--
-- League Cup still uses the current season's club list.
--
-- Source season resolution (newest first among prior seasons):
--   1) archived SuperLeague table with positions 1–8
--   2) live standings with SuperLeague positions 1–8
--   3) fall back to p_season_id if it itself has that data (inaugural season)

CREATE OR REPLACE FUNCTION public.competition_cup_qualification_source_season(
  p_season_id bigint,
  p_cup_code text DEFAULT 'super8'
)
RETURNS bigint
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_code text := lower(btrim(coalesce(p_cup_code, '')));
  v_src bigint;
  v_cand record;
  v_n int;
BEGIN
  IF v_code = 'spoon' THEN
    v_code := 'bowl';
  END IF;

  -- League Cup is always the season being drawn.
  IF v_code = 'league_cup' THEN
    RETURN p_season_id;
  END IF;

  -- Prefer a fully archived SuperLeague table (20 clubs) on a finished season.
  IF to_regclass('public.competition_club_season_archive') IS NOT NULL THEN
    SELECT a.season_id INTO v_src
    FROM public.competition_club_season_archive a
    JOIN public.competition_seasons s ON s.id = a.season_id
    WHERE a.season_id < p_season_id
      AND s.status NOT IN ('preseason', 'setup')
      AND a.division = 'superleague'
    GROUP BY a.season_id
    HAVING count(*) FILTER (WHERE a.final_position BETWEEN 1 AND 8) >= 8
       AND count(*) >= 20
    ORDER BY a.season_id DESC
    LIMIT 1;

    IF v_src IS NOT NULL THEN
      RETURN v_src;
    END IF;

    SELECT a.season_id INTO v_src
    FROM public.competition_club_season_archive a
    JOIN public.competition_seasons s ON s.id = a.season_id
    WHERE a.season_id < p_season_id
      AND s.status NOT IN ('preseason', 'setup')
      AND a.division = 'superleague'
      AND a.final_position BETWEEN 1 AND 8
    GROUP BY a.season_id
    HAVING count(*) >= 8
    ORDER BY a.season_id DESC
    LIMIT 1;

    IF v_src IS NOT NULL THEN
      RETURN v_src;
    END IF;
  END IF;

  FOR v_cand IN
    SELECT s.id, s.label, s.status
    FROM public.competition_seasons s
    WHERE s.id < p_season_id
      AND s.status NOT IN ('preseason', 'setup')
    ORDER BY s.id DESC
  LOOP
    SELECT count(*)::int INTO v_n
    FROM public.competition_standings_public st
    WHERE st.season_id = v_cand.id
      AND st.division = 'superleague'
      AND st.table_position BETWEEN 1 AND 8;

    IF v_n >= 8 THEN
      RETURN v_cand.id;
    END IF;
  END LOOP;

  -- Inaugural / same-season fallback
  IF to_regclass('public.competition_club_season_archive') IS NOT NULL THEN
    SELECT count(*)::int INTO v_n
    FROM public.competition_club_season_archive a
    WHERE a.season_id = p_season_id
      AND a.division = 'superleague'
      AND a.final_position BETWEEN 1 AND 8;

    IF v_n >= 8 THEN
      RETURN p_season_id;
    END IF;
  END IF;

  SELECT count(*)::int INTO v_n
  FROM public.competition_standings_public s
  WHERE s.season_id = p_season_id
    AND s.division = 'superleague'
    AND s.table_position BETWEEN 1 AND 8;

  IF v_n >= 8 THEN
    RETURN p_season_id;
  END IF;

  -- Last resort: any prior season id (caller may still fail on empty clubs)
  SELECT s.id INTO v_src
  FROM public.competition_seasons s
  WHERE s.id < p_season_id
  ORDER BY s.id DESC
  LIMIT 1;

  RETURN coalesce(v_src, p_season_id);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_cup_qualification_source_season(bigint, text)
  TO authenticated, service_role;

-- Standing row helper: archive final_position preferred, else live table_position
CREATE OR REPLACE FUNCTION public.competition_cup_source_league_places(
  p_source_season_id bigint,
  p_division text,
  p_pos_from int,
  p_pos_to int
)
RETURNS TABLE (club_short_name text, sort_key int)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_n int := 0;
BEGIN
  IF to_regclass('public.competition_club_season_archive') IS NOT NULL THEN
    SELECT count(*)::int INTO v_n
    FROM public.competition_club_season_archive a
    WHERE a.season_id = p_source_season_id
      AND a.division = p_division
      AND a.final_position BETWEEN p_pos_from AND p_pos_to;
  END IF;

  IF v_n > 0 THEN
    RETURN QUERY
    SELECT a.club_short_name, a.final_position::int
    FROM public.competition_club_season_archive a
    WHERE a.season_id = p_source_season_id
      AND a.division = p_division
      AND a.final_position BETWEEN p_pos_from AND p_pos_to;
    RETURN;
  END IF;

  RETURN QUERY
  SELECT s.club_short_name, s.table_position::int
  FROM public.competition_standings_public s
  WHERE s.season_id = p_source_season_id
    AND s.division = p_division
    AND s.table_position BETWEEN p_pos_from AND p_pos_to;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_cup_source_league_places(bigint, text, int, int)
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
    SELECT array_agg(x.club ORDER BY x.sort_key, x.club)
    INTO v_clubs
    FROM (
      SELECT p.club_short_name AS club, p.sort_key
      FROM public.competition_cup_source_league_places(
        v_src, 'superleague', 17, 20
      ) p
      UNION ALL
      SELECT p.club_short_name, 100 + p.sort_key
      FROM public.competition_cup_source_league_places(
        v_src, 'championship_a', 5, 15
      ) p
      UNION ALL
      SELECT p.club_short_name, 200 + p.sort_key
      FROM public.competition_cup_source_league_places(
        v_src, 'championship_b', 5, 15
      ) p
      UNION ALL
      SELECT q.club_short_name, 50
      FROM public.competition_cup_manual_qualifiers q
      WHERE q.season_id = v_src
        AND q.cup_code = 'shield'
        AND q.qualifier_role = 'shield_playoff_winner'
    ) x;
  ELSIF v_code = 'bowl' THEN
    SELECT array_agg(x.club ORDER BY x.sort_key, x.club)
    INTO v_clubs
    FROM (
      SELECT p.club_short_name AS club, p.sort_key
      FROM public.competition_cup_source_league_places(
        v_src, 'championship_a', 18, 20
      ) p
      UNION ALL
      SELECT p.club_short_name, 100 + p.sort_key
      FROM public.competition_cup_source_league_places(
        v_src, 'championship_b', 18, 20
      ) p
      UNION ALL
      SELECT q.club_short_name, 50
      FROM public.competition_cup_manual_qualifiers q
      WHERE q.season_id = v_src
        AND q.cup_code IN ('bowl', 'spoon')
        AND q.qualifier_role IN ('bowl_playoff_loser', 'spoon_playoff_loser')
    ) x;
  ELSIF v_code = 'league_cup' THEN
    SELECT array_agg(ccs.club_short_name ORDER BY ccs.club_short_name)
    INTO v_clubs
    FROM public.competition_club_seasons ccs
    WHERE ccs.season_id = p_season_id
      AND ccs.division IN ('superleague', 'championship_a', 'championship_b');
  END IF;

  RETURN coalesce(v_clubs, ARRAY[]::text[]);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_qualify_cup_clubs(bigint, text)
  TO authenticated, service_role;

-- Expose source season on bye panel / draw UI
CREATE OR REPLACE FUNCTION public.competition_cup_compute_bye_requirements(
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
  v_clubs text[];
  v_n int;
  v_target int;
  v_slots int;
  v_byes int;
  v_src bigint;
  v_src_label text;
BEGIN
  IF v_code = 'spoon' THEN
    v_code := 'bowl';
  END IF;

  v_src := public.competition_cup_qualification_source_season(p_season_id, v_code);
  SELECT s.label INTO v_src_label
  FROM public.competition_seasons s
  WHERE s.id = v_src;

  v_clubs := public.competition_qualify_cup_clubs(p_season_id, v_code);
  v_n := coalesce(array_length(v_clubs, 1), 0);

  v_slots := public.competition_cup_first_round_slots(v_code);
  v_target := greatest(v_slots, 1);

  IF v_slots IS NULL OR v_slots < 1 THEN
    v_target := 1;
    WHILE v_target < v_n LOOP
      v_target := v_target * 2;
    END LOOP;
  ELSIF v_target < v_n THEN
    WHILE v_target < v_n LOOP
      v_target := v_target * 2;
    END LOOP;
  END IF;

  v_byes := greatest(v_target - v_n, 0);

  RETURN jsonb_build_object(
    'cup_code', v_code,
    'qualified_count', v_n,
    'first_round_slots', v_target,
    'required_byes', v_byes,
    'r1_fixtures', v_target / 2,
    'qualified_clubs', to_jsonb(coalesce(v_clubs, ARRAY[]::text[])),
    'qualification_season_id', v_src,
    'qualification_season_label', v_src_label
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_cup_compute_bye_requirements(bigint, text)
  TO authenticated, service_role;

-- random() must not be IMMUTABLE (can freeze draw order)
CREATE OR REPLACE FUNCTION public.competition_shuffle_club_array(p_clubs text[])
RETURNS text[]
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_result text[] := p_clubs;
  v_i int;
  v_j int;
  v_tmp text;
BEGIN
  IF v_result IS NULL OR coalesce(array_length(v_result, 1), 0) < 2 THEN
    RETURN v_result;
  END IF;

  FOR v_i IN REVERSE array_length(v_result, 1)..2 LOOP
    v_j := 1 + floor(random() * v_i)::int;
    v_tmp := v_result[v_i];
    v_result[v_i] := v_result[v_j];
    v_result[v_j] := v_tmp;
  END LOOP;

  RETURN v_result;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_shuffle_club_array(text[])
  TO authenticated, service_role;
