-- =============================================================================
-- Season 2 incident: "16v17" Shield/Bowl ties were contested by mid-table clubs
--   CH A: Rosario (6th) vs River Plate (5th)  — should have been Marseille vs Man City
--   CH B: Sao Paulo (8th) vs Real Betis (7th) — should have been Atletico Nacional vs Celtic
--
-- Cause: playoff seed used live standings_public at generate time, which did not
-- match the final archived table (16th/17th). Sync then faithfully copied those
-- wrong results into Shield qualifiers.
--
-- Fix:
--   1) Seed playoffs from archive final_position when available
--   2) Admin rebuild CH Shield/Bowl ties from the final table (16 vs 17)
--   3) Diagnose mismatch helper
--
-- After apply (Season 2 repair):
--   SELECT public.competition_admin_diagnose_ch_sb_ties(2);
--   SELECT public.competition_admin_rebuild_ch_sb_ties_from_table(2);
--   Play (or admin-confirm) the two new 16v17 fixtures
--   SELECT public.competition_admin_fix_shield_bowl_qualifiers();
--   Admin Cups → Shield → re-save byes → re-draw
-- Safe re-run.
-- =============================================================================

-- Prefer archived final table for playoff seeding
CREATE OR REPLACE FUNCTION public.competition_playoff_standing_club(
  p_season_id bigint,
  p_division text,
  p_position integer
)
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text;
BEGIN
  IF to_regclass('public.competition_club_season_archive') IS NOT NULL THEN
    SELECT a.club_short_name INTO v_club
    FROM public.competition_club_season_archive a
    WHERE a.season_id = p_season_id
      AND a.division = p_division
      AND a.final_position = p_position
    LIMIT 1;
    IF v_club IS NOT NULL THEN
      RETURN v_club;
    END IF;
  END IF;

  SELECT s.club_short_name INTO v_club
  FROM public.competition_standings_public s
  WHERE s.season_id = p_season_id
    AND s.division = p_division
    AND s.table_position = p_position
  LIMIT 1;

  RETURN v_club;
END;
$function$;

CREATE OR REPLACE FUNCTION public.competition_admin_diagnose_ch_sb_ties(
  p_season_id bigint DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season bigint := p_season_id;
  v_out jsonb := '[]'::jsonb;
  v_div text;
  v_bracket text;
  v_expected_home text;
  v_expected_away text;
  v_tie public.competition_playoff_ties%rowtype;
  v_ok boolean;
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF v_season IS NULL THEN
    SELECT t.season_id INTO v_season
    FROM public.competition_playoff_ties t
    WHERE t.bracket IN ('ch_sb_a', 'ch_sb_b')
    GROUP BY t.season_id
    ORDER BY t.season_id DESC
    LIMIT 1;
  END IF;

  IF v_season IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_season');
  END IF;

  FOR v_div, v_bracket IN
    SELECT * FROM (VALUES
      ('championship_a', 'ch_sb_a'),
      ('championship_b', 'ch_sb_b')
    ) AS x(division, bracket)
  LOOP
    v_expected_home := public.competition_playoff_standing_club(v_season, v_div, 16);
    v_expected_away := public.competition_playoff_standing_club(v_season, v_div, 17);

    SELECT * INTO v_tie
    FROM public.competition_playoff_ties t
    WHERE t.season_id = v_season AND t.bracket = v_bracket
    LIMIT 1;

    v_ok := FOUND
      AND v_expected_home IS NOT NULL
      AND v_expected_away IS NOT NULL
      AND (
        (upper(coalesce(v_tie.home_club_short_name, '')) = upper(v_expected_home)
         AND upper(coalesce(v_tie.away_club_short_name, '')) = upper(v_expected_away))
        OR
        (upper(coalesce(v_tie.home_club_short_name, '')) = upper(v_expected_away)
         AND upper(coalesce(v_tie.away_club_short_name, '')) = upper(v_expected_home))
      );

    v_out := v_out || jsonb_build_array(jsonb_build_object(
      'division', v_div,
      'bracket', v_bracket,
      'expected_16', v_expected_home,
      'expected_17', v_expected_away,
      'tie_home', v_tie.home_club_short_name,
      'tie_away', v_tie.away_club_short_name,
      'tie_winner', v_tie.winner_club_short_name,
      'tie_status', v_tie.status,
      'participants_match_table', v_ok
    ));
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true,
    'season_id', v_season,
    'ties', v_out,
    'needs_rebuild', EXISTS (
      SELECT 1
      FROM jsonb_array_elements(v_out) e
      WHERE coalesce((e->>'participants_match_table')::boolean, false) IS NOT TRUE
    )
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_admin_diagnose_ch_sb_ties(bigint)
  TO authenticated;

-- Rebuild CH Shield/Bowl ties as true 16 vs 17 from final table; drop wrong fixtures/results
CREATE OR REPLACE FUNCTION public.competition_admin_rebuild_ch_sb_ties_from_table(
  p_season_id bigint DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season bigint := p_season_id;
  v_div text;
  v_bracket text;
  v_cup text;
  v_home text;
  v_away text;
  v_tie_id bigint;
  v_old_fixture bigint;
  v_details jsonb := '[]'::jsonb;
  v_scheduled int := 0;
  v_label text;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF v_season IS NULL THEN
    SELECT t.season_id INTO v_season
    FROM public.competition_playoff_ties t
    WHERE t.bracket IN ('ch_sb_a', 'ch_sb_b')
    GROUP BY t.season_id
    ORDER BY t.season_id DESC
    LIMIT 1;
  END IF;

  IF v_season IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_season');
  END IF;

  FOR v_div, v_bracket, v_cup IN
    SELECT * FROM (VALUES
      ('championship_a', 'ch_sb_a', 'po_ch_sb_a'),
      ('championship_b', 'ch_sb_b', 'po_ch_sb_b')
    ) AS x(division, bracket, cup_code)
  LOOP
    v_home := public.competition_playoff_standing_club(v_season, v_div, 16);
    v_away := public.competition_playoff_standing_club(v_season, v_div, 17);

    IF v_home IS NULL OR v_away IS NULL THEN
      RETURN jsonb_build_object(
        'ok', false,
        'reason', 'missing_16_17',
        'division', v_div,
        'pos16', v_home,
        'pos17', v_away,
        'hint', 'Archive/standings must have final positions 16 and 17 for both Championship divisions.'
      );
    END IF;

    SELECT id, fixture_id INTO v_tie_id, v_old_fixture
    FROM public.competition_playoff_ties
    WHERE season_id = v_season AND bracket = v_bracket
    LIMIT 1;

    IF v_old_fixture IS NOT NULL THEN
      DELETE FROM public.competition_fixtures WHERE id = v_old_fixture;
    END IF;

    v_label := CASE v_div
      WHEN 'championship_a' THEN 'Championship A Shield Playoff Final — 16th vs 17th'
      ELSE 'Championship B Shield Playoff Final — 16th vs 17th'
    END;

    IF v_tie_id IS NULL THEN
      INSERT INTO public.competition_playoff_ties (
        season_id, bracket, round_no, match_no, label, week_in_month,
        home_club_short_name, away_club_short_name, cup_code, status,
        winner_club_short_name, loser_club_short_name, fixture_id
      ) VALUES (
        v_season, v_bracket, 1, 1, v_label, 1,
        v_home, v_away, v_cup, 'ready',
        NULL, NULL, NULL
      )
      RETURNING id INTO v_tie_id;
    ELSE
      UPDATE public.competition_playoff_ties
      SET label = v_label,
          home_club_short_name = v_home,
          away_club_short_name = v_away,
          winner_club_short_name = NULL,
          loser_club_short_name = NULL,
          fixture_id = NULL,
          status = 'ready',
          cup_code = v_cup
      WHERE id = v_tie_id;
    END IF;

    -- Clear bad qualifier rows for this division (will be rewritten after replay)
    DELETE FROM public.competition_cup_manual_qualifiers q
    WHERE q.season_id = v_season
      AND q.division = v_div
      AND q.qualifier_role IN ('shield_playoff_winner', 'bowl_playoff_loser');

    v_details := v_details || jsonb_build_array(jsonb_build_object(
      'division', v_div,
      'bracket', v_bracket,
      'home_16', v_home,
      'away_17', v_away,
      'tie_id', v_tie_id,
      'action', 'rebuilt_ready_to_play'
    ));
  END LOOP;

  -- Do not force live fixtures — season may already be finished (e.g. repairing S2 while on S3).
  -- Admins set winners via competition_admin_set_ch_sb_winner.

  RETURN jsonb_build_object(
    'ok', true,
    'season_id', v_season,
    'ties', v_details,
    'message',
      'Championship Shield/Bowl ties rebuilt as true 16th vs 17th. '
      || 'Season may already be finished — pick each winner with Set 16v17 winners (no need to replay matchdays), then re-draw Shield.'
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_admin_rebuild_ch_sb_ties_from_table(bigint)
  TO authenticated;

-- Load current 16v17 pairings (for admin winner dropdowns)
CREATE OR REPLACE FUNCTION public.competition_admin_ch_sb_tie_options(
  p_season_id bigint DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season bigint := p_season_id;
  v_out jsonb := '[]'::jsonb;
  v_row record;
  v_hname text;
  v_aname text;
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF v_season IS NULL THEN
    SELECT t.season_id INTO v_season
    FROM public.competition_playoff_ties t
    WHERE t.bracket IN ('ch_sb_a', 'ch_sb_b')
    GROUP BY t.season_id
    ORDER BY t.season_id DESC
    LIMIT 1;
  END IF;

  IF v_season IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_season');
  END IF;

  FOR v_row IN
    SELECT *
    FROM public.competition_playoff_shield_bowl_winners(v_season)
    ORDER BY bracket
  LOOP
    SELECT c."Club" INTO v_hname FROM public."Clubs" c WHERE c."ShortName" = v_row.home_club;
    SELECT c."Club" INTO v_aname FROM public."Clubs" c WHERE c."ShortName" = v_row.away_club;
    v_out := v_out || jsonb_build_array(jsonb_build_object(
      'division', v_row.division,
      'bracket', v_row.bracket,
      'status', v_row.status,
      'home', v_row.home_club,
      'home_name', coalesce(v_hname, v_row.home_club),
      'away', v_row.away_club,
      'away_name', coalesce(v_aname, v_row.away_club),
      'winner', v_row.winner_club
    ));
  END LOOP;

  RETURN jsonb_build_object('ok', true, 'season_id', v_season, 'ties', v_out);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_admin_ch_sb_tie_options(bigint)
  TO authenticated;

-- Set 16v17 winner without playing a live fixture (for finished seasons)
CREATE OR REPLACE FUNCTION public.competition_admin_set_ch_sb_winner(
  p_division text,
  p_winner_club text,
  p_season_id bigint DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season bigint := p_season_id;
  v_div text := lower(btrim(coalesce(p_division, '')));
  v_winner text := upper(btrim(coalesce(p_winner_club, '')));
  v_bracket text;
  v_tie public.competition_playoff_ties%rowtype;
  v_loser text;
  v_win_name text;
  v_lose_name text;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF v_div NOT IN ('championship_a', 'championship_b') THEN
    RAISE EXCEPTION 'Division must be championship_a or championship_b';
  END IF;
  IF v_winner = '' THEN
    RAISE EXCEPTION 'Winner club required';
  END IF;

  v_bracket := CASE v_div WHEN 'championship_a' THEN 'ch_sb_a' ELSE 'ch_sb_b' END;

  IF v_season IS NULL THEN
    SELECT t.season_id INTO v_season
    FROM public.competition_playoff_ties t
    WHERE t.bracket = v_bracket
    ORDER BY t.season_id DESC
    LIMIT 1;
  END IF;

  SELECT * INTO v_tie
  FROM public.competition_playoff_ties t
  WHERE t.season_id = v_season AND t.bracket = v_bracket
  LIMIT 1;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'No % Shield/Bowl tie for season % — run Rebuild 16v17 from final table first',
      v_div, v_season;
  END IF;

  IF v_winner NOT IN (
    upper(btrim(coalesce(v_tie.home_club_short_name, ''))),
    upper(btrim(coalesce(v_tie.away_club_short_name, '')))
  ) THEN
    RAISE EXCEPTION
      '% is not in this 16v17 tie (% vs %). Rebuild from final table first.',
      v_winner,
      v_tie.home_club_short_name,
      v_tie.away_club_short_name;
  END IF;

  v_loser := CASE
    WHEN upper(btrim(v_tie.home_club_short_name)) = v_winner
      THEN upper(btrim(v_tie.away_club_short_name))
    ELSE upper(btrim(v_tie.home_club_short_name))
  END;

  UPDATE public.competition_playoff_ties
  SET winner_club_short_name = v_winner,
      loser_club_short_name = v_loser,
      status = 'played',
      fixture_id = NULL
  WHERE id = v_tie.id;

  INSERT INTO public.competition_cup_manual_qualifiers (
    season_id, cup_code, division, club_short_name, qualifier_role
  ) VALUES
    (v_season, 'shield', v_div, v_winner, 'shield_playoff_winner'),
    (v_season, 'bowl', v_div, v_loser, 'bowl_playoff_loser')
  ON CONFLICT (season_id, cup_code, division, qualifier_role)
  DO UPDATE SET club_short_name = excluded.club_short_name;

  SELECT c."Club" INTO v_win_name FROM public."Clubs" c WHERE c."ShortName" = v_winner;
  SELECT c."Club" INTO v_lose_name FROM public."Clubs" c WHERE c."ShortName" = v_loser;

  RETURN jsonb_build_object(
    'ok', true,
    'season_id', v_season,
    'division', v_div,
    'shield_winner', v_winner,
    'shield_winner_name', coalesce(v_win_name, v_winner),
    'bowl_loser', v_loser,
    'bowl_loser_name', coalesce(v_lose_name, v_loser)
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_admin_set_ch_sb_winner(text, text, bigint)
  TO authenticated;

NOTIFY pgrst, 'reload schema';
