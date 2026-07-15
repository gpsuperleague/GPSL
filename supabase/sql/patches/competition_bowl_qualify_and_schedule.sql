-- =============================================================================
-- Bowl: finish spoon→bowl alignment for qualify + round schedule + byes
--
-- Symptom (admin Bowl page): "Not enough qualified clubs for a random draw
-- (need 1, have 0)" — UI passes cup_code 'bowl', but qualify/schedule still
-- only knew 'spoon', so qualified_clubs = [] and bye math fell back to need 1.
--
-- Safe re-run.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Round schedule: spoon → bowl
-- ---------------------------------------------------------------------------

UPDATE public.competition_cup_round_schedule
SET cup_code = 'bowl'
WHERE cup_code = 'spoon';

ALTER TABLE public.competition_cup_round_schedule
  DROP CONSTRAINT IF EXISTS competition_cup_round_schedule_cup_code_check;

ALTER TABLE public.competition_cup_round_schedule
  ADD CONSTRAINT competition_cup_round_schedule_cup_code_check
  CHECK (cup_code IN ('super8', 'plate', 'shield', 'bowl', 'league_cup'));

-- Seed Bowl calendar if missing (same as legacy Spoon)
INSERT INTO public.competition_cup_round_schedule (
  cup_code, round_no, cup_leg, gpsl_month, stage, round_label, matches_in_round
)
SELECT v.cup_code, v.round_no, v.cup_leg, v.gpsl_month, v.stage, v.round_label, v.matches_in_round
FROM (
  VALUES
    ('bowl'::text, 1::smallint, 1::smallint, 'september'::text, 'qf'::text, 'Quarter-final'::text, 4::smallint),
    ('bowl', 1, 2, 'october', 'qf', 'Quarter-final', 4),
    ('bowl', 2, 1, 'november', 'sf', 'Semi-final', 2),
    ('bowl', 3, 1, 'december', 'final', 'Final', 1)
) AS v(cup_code, round_no, cup_leg, gpsl_month, stage, round_label, matches_in_round)
WHERE NOT EXISTS (
  SELECT 1 FROM public.competition_cup_round_schedule s WHERE s.cup_code = 'bowl'
);

-- ---------------------------------------------------------------------------
-- First-round byes table (if present)
-- ---------------------------------------------------------------------------

DO $$
BEGIN
  IF to_regclass('public.competition_cup_first_round_byes') IS NOT NULL THEN
    UPDATE public.competition_cup_first_round_byes
    SET cup_code = 'bowl'
    WHERE cup_code = 'spoon';

    ALTER TABLE public.competition_cup_first_round_byes
      DROP CONSTRAINT IF EXISTS competition_cup_first_round_byes_cup_check;

    ALTER TABLE public.competition_cup_first_round_byes
      ADD CONSTRAINT competition_cup_first_round_byes_cup_check
      CHECK (cup_code IN ('super8', 'plate', 'shield', 'bowl', 'league_cup'));
  END IF;
END $$;

-- Manual qualifiers: keep both role names readable during transition
UPDATE public.competition_cup_manual_qualifiers
SET cup_code = 'bowl'
WHERE cup_code = 'spoon';

UPDATE public.competition_cup_manual_qualifiers
SET qualifier_role = 'bowl_playoff_loser'
WHERE qualifier_role = 'spoon_playoff_loser';

-- ---------------------------------------------------------------------------
-- Qualify: accept bowl (and legacy spoon)
-- ---------------------------------------------------------------------------

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
  v_clubs text[] := ARRAY[]::text[];
BEGIN
  IF v_code = 'spoon' THEN
    v_code := 'bowl';
  END IF;

  IF v_code = 'super8' THEN
    SELECT array_agg(s.club_short_name ORDER BY s.table_position)
    INTO v_clubs
    FROM public.competition_standings_public s
    WHERE s.season_id = p_season_id
      AND s.division = 'superleague'
      AND s.table_position <= 8;
  ELSIF v_code = 'plate' THEN
    SELECT array_agg(x.club ORDER BY x.sort_key, x.club)
    INTO v_clubs
    FROM (
      SELECT s.club_short_name AS club, s.table_position AS sort_key
      FROM public.competition_standings_public s
      WHERE s.season_id = p_season_id
        AND s.division = 'superleague'
        AND s.table_position BETWEEN 9 AND 16
      UNION ALL
      SELECT s.club_short_name, 100 + s.table_position
      FROM public.competition_standings_public s
      WHERE s.season_id = p_season_id
        AND s.division = 'championship_a'
        AND s.table_position <= 4
      UNION ALL
      SELECT s.club_short_name, 200 + s.table_position
      FROM public.competition_standings_public s
      WHERE s.season_id = p_season_id
        AND s.division = 'championship_b'
        AND s.table_position <= 4
    ) x;
  ELSIF v_code = 'shield' THEN
    SELECT array_agg(x.club ORDER BY x.sort_key, x.club)
    INTO v_clubs
    FROM (
      SELECT s.club_short_name AS club, s.table_position AS sort_key
      FROM public.competition_standings_public s
      WHERE s.season_id = p_season_id
        AND s.division = 'superleague'
        AND s.table_position BETWEEN 17 AND 20
      UNION ALL
      SELECT s.club_short_name, 100 + s.table_position
      FROM public.competition_standings_public s
      WHERE s.season_id = p_season_id
        AND s.division = 'championship_a'
        AND s.table_position BETWEEN 5 AND 15
      UNION ALL
      SELECT s.club_short_name, 200 + s.table_position
      FROM public.competition_standings_public s
      WHERE s.season_id = p_season_id
        AND s.division = 'championship_b'
        AND s.table_position BETWEEN 5 AND 15
      UNION ALL
      SELECT q.club_short_name, 50
      FROM public.competition_cup_manual_qualifiers q
      WHERE q.season_id = p_season_id
        AND q.cup_code = 'shield'
        AND q.qualifier_role = 'shield_playoff_winner'
    ) x;
  ELSIF v_code = 'bowl' THEN
    SELECT array_agg(x.club ORDER BY x.sort_key, x.club)
    INTO v_clubs
    FROM (
      SELECT s.club_short_name AS club, s.table_position AS sort_key
      FROM public.competition_standings_public s
      WHERE s.season_id = p_season_id
        AND s.division = 'championship_a'
        AND s.table_position >= 18
      UNION ALL
      SELECT s.club_short_name, 100 + s.table_position
      FROM public.competition_standings_public s
      WHERE s.season_id = p_season_id
        AND s.division = 'championship_b'
        AND s.table_position >= 18
      UNION ALL
      SELECT q.club_short_name, 50
      FROM public.competition_cup_manual_qualifiers q
      WHERE q.season_id = p_season_id
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

GRANT EXECUTE ON FUNCTION public.competition_qualify_cup_clubs(bigint, text) TO authenticated;

-- ---------------------------------------------------------------------------
-- Bye helpers: normalize spoon → bowl
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.competition_cup_normalize_code(p_cup_code text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE lower(btrim(coalesce(p_cup_code, '')))
    WHEN 'spoon' THEN 'bowl'
    ELSE lower(btrim(coalesce(p_cup_code, '')))
  END;
$$;

CREATE OR REPLACE FUNCTION public.competition_cup_first_round_slots(p_cup_code text)
RETURNS int
LANGUAGE sql
STABLE
AS $$
  SELECT coalesce(
    (
      SELECT (max(s.matches_in_round) * 2)::int
      FROM public.competition_cup_round_schedule s
      WHERE s.cup_code = public.competition_cup_normalize_code(p_cup_code)
        AND s.round_no = 1
    ),
    0
  );
$$;

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
  v_code text := public.competition_cup_normalize_code(p_cup_code);
  v_clubs text[];
  v_n int;
  v_target int;
  v_slots int;
  v_byes int;
BEGIN
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
    'qualified_clubs', to_jsonb(coalesce(v_clubs, ARRAY[]::text[]))
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.competition_cup_byes_get(
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
  v_code text := public.competition_cup_normalize_code(p_cup_code);
  v_req jsonb;
  v_selected text[];
BEGIN
  v_req := public.competition_cup_compute_bye_requirements(p_season_id, v_code);

  SELECT coalesce(array_agg(b.club_short_name ORDER BY b.sort_order, b.club_short_name), ARRAY[]::text[])
  INTO v_selected
  FROM public.competition_cup_first_round_byes b
  WHERE b.season_id = p_season_id
    AND b.cup_code = v_code;

  RETURN v_req || jsonb_build_object(
    'selected_byes', to_jsonb(v_selected),
    'selected_count', coalesce(array_length(v_selected, 1), 0),
    'ready_to_draw',
      coalesce((v_req ->> 'required_byes')::int, 0) = coalesce(array_length(v_selected, 1), 0)
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.competition_admin_set_cup_byes(
  p_season_id bigint,
  p_cup_code text,
  p_clubs text[]
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_code text := public.competition_cup_normalize_code(p_cup_code);
  v_req jsonb;
  v_required int;
  v_qualified text[];
  v_norm text[];
  v_club text;
  v_i int;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF v_code NOT IN ('super8', 'plate', 'shield', 'bowl', 'league_cup') THEN
    RAISE EXCEPTION 'Invalid cup code';
  END IF;

  v_req := public.competition_cup_compute_bye_requirements(p_season_id, v_code);
  v_required := coalesce((v_req ->> 'required_byes')::int, 0);
  v_qualified := ARRAY(
    SELECT upper(jsonb_array_elements_text(coalesce(v_req -> 'qualified_clubs', '[]'::jsonb)))
  );

  v_norm := ARRAY[]::text[];
  IF p_clubs IS NOT NULL THEN
    FOREACH v_club IN ARRAY p_clubs LOOP
      v_club := upper(trim(coalesce(v_club, '')));
      IF v_club = '' THEN
        CONTINUE;
      END IF;
      IF NOT (v_club = ANY (v_qualified)) THEN
        RAISE EXCEPTION 'Club % is not qualified for %', v_club, v_code;
      END IF;
      IF v_club = ANY (v_norm) THEN
        RAISE EXCEPTION 'Duplicate bye club %', v_club;
      END IF;
      v_norm := array_append(v_norm, v_club);
    END LOOP;
  END IF;

  IF coalesce(array_length(v_norm, 1), 0) <> v_required THEN
    RAISE EXCEPTION 'Select exactly % bye club(s) for % (% qualified, % first-round slots)',
      v_required, v_code,
      coalesce((v_req ->> 'qualified_count')::int, 0),
      coalesce((v_req ->> 'first_round_slots')::int, 0);
  END IF;

  DELETE FROM public.competition_cup_first_round_byes
  WHERE season_id = p_season_id
    AND cup_code = v_code;

  v_i := 0;
  FOREACH v_club IN ARRAY v_norm LOOP
    v_i := v_i + 1;
    INSERT INTO public.competition_cup_first_round_byes (
      season_id, cup_code, club_short_name, sort_order
    )
    VALUES (p_season_id, v_code, v_club, v_i);
  END LOOP;

  RETURN public.competition_cup_byes_get(p_season_id, v_code);
END;
$function$;

CREATE OR REPLACE FUNCTION public.competition_cup_load_saved_byes(
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
  v_code text := public.competition_cup_normalize_code(p_cup_code);
  v_byes text[];
BEGIN
  SELECT coalesce(array_agg(b.club_short_name ORDER BY b.sort_order, b.club_short_name), ARRAY[]::text[])
  INTO v_byes
  FROM public.competition_cup_first_round_byes b
  WHERE b.season_id = p_season_id
    AND b.cup_code = v_code;

  RETURN v_byes;
END;
$function$;

-- ---------------------------------------------------------------------------
-- Draw: single overload, bowl-aware
-- ---------------------------------------------------------------------------

DROP FUNCTION IF EXISTS public.competition_draw_prestige_cup(bigint, text);
DROP FUNCTION IF EXISTS public.competition_draw_prestige_cup(bigint, text, text[]);
DROP FUNCTION IF EXISTS public.competition_draw_prestige_cup(bigint, text, text[], int[]);

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
  v_code text := public.competition_cup_normalize_code(p_cup_code);
  v_clubs text[];
  v_byes text[];
  v_result jsonb;
  v_sync jsonb;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF v_code NOT IN ('super8', 'plate', 'shield', 'bowl') THEN
    RAISE EXCEPTION 'Invalid prestige cup code';
  END IF;

  v_clubs := public.competition_qualify_cup_clubs(p_season_id, v_code);

  IF coalesce(array_length(v_clubs, 1), 0) < 2 THEN
    RAISE EXCEPTION 'Not enough qualified clubs for % (% found)', v_code, coalesce(array_length(v_clubs, 1), 0);
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

  IF to_regprocedure('public.competition_cup_sync_all_scheduled_cup_fixtures(bigint, text)') IS NOT NULL THEN
    v_sync := public.competition_cup_sync_all_scheduled_cup_fixtures(p_season_id, v_code);
    v_result := coalesce(v_result, '{}'::jsonb) || coalesce(v_sync, '{}'::jsonb);
  END IF;

  RETURN coalesce(v_result, '{}'::jsonb) || jsonb_build_object('cup_code', v_code);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_cup_normalize_code(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.competition_cup_compute_bye_requirements(bigint, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.competition_cup_byes_get(bigint, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.competition_admin_set_cup_byes(bigint, text, text[]) TO authenticated;
GRANT EXECUTE ON FUNCTION public.competition_cup_load_saved_byes(bigint, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.competition_draw_prestige_cup(bigint, text, text[], int[]) TO authenticated;

NOTIFY pgrst, 'reload schema';
