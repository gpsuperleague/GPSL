-- =============================================================================
-- Season 1 Shield: all 40 league clubs, preliminary round, no vacant v vacant
-- =============================================================================
-- Prestige cups normally qualify from the PREVIOUS season's final table. The
-- inaugural season has none, so this patch adds two season-scoped overrides:
--
-- 1) competition_cup_entry_overrides(season, cup, club)
--    When a season + cup has rows, those clubs ARE the entrants (draw, byes
--    panel, admin qualifier list). No rows = normal qualifying rules.
--
-- 2) competition_cup_season_schedule(season, cup, round …)
--    A season-specific round schedule. The bracket builder swaps it into the
--    shared competition_cup_round_schedule when that season's cup is drawn,
--    and swaps the saved standard schedule back when any other season draws
--    the same cup. For a season with its own schedule the draw also:
--      * gives byes only to owned clubs (saved byes kept if owned, topped up
--        at random), and
--      * pairs every vacant club with an owned club in the first round.
--
-- Season 1 Shield (40 clubs = 32 owned + 8 vacant):
--   Preliminary (GPSL August, 64-slot round): 8 ties owned v vacant, 24 owned byes
--     → vacant clubs give a 3–0 walkover at the August lock unless they gain an owner
--   Last 32 Sep · Last 16 Oct · Quarter-final Nov · Semi-final Dec · Final Dec
--
-- Future seasons: no override rows → normal qualifying and the standard
-- 5-round Shield schedule (restored automatically at their draw).
--
-- Implementation note: competition_qualify_cup_clubs(_detailed) and
-- competition_build_knockout_bracket are renamed to *_base once and thin
-- wrappers take their names. If a later patch re-creates any of them, re-run
-- this file (it adopts the newer version as the base).
--
-- Do not re-run competition_cup_schedule.sql during Season 1 (it truncates
-- the shared schedule and would drop the 6th Shield round).
--
-- Safe to re-run until the Season 1 Shield is drawn.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.competition_cup_entry_overrides (
  season_id bigint NOT NULL REFERENCES public.competition_seasons (id) ON DELETE CASCADE,
  cup_code text NOT NULL,
  club_short_name text NOT NULL REFERENCES public."Clubs" ("ShortName") ON DELETE CASCADE,
  note text,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (season_id, cup_code, club_short_name)
);

CREATE TABLE IF NOT EXISTS public.competition_cup_season_schedule (
  season_id bigint NOT NULL REFERENCES public.competition_seasons (id) ON DELETE CASCADE,
  cup_code text NOT NULL,
  round_no smallint NOT NULL,
  cup_leg smallint NOT NULL DEFAULT 1,
  gpsl_month text NOT NULL,
  stage text NOT NULL,
  round_label text NOT NULL,
  matches_in_round smallint NOT NULL,
  PRIMARY KEY (season_id, cup_code, round_no, cup_leg)
);

-- Standard rows saved before any season schedule is swapped in
CREATE TABLE IF NOT EXISTS public.competition_cup_standard_schedule (
  LIKE public.competition_cup_round_schedule INCLUDING DEFAULTS
);

ALTER TABLE public.competition_cup_entry_overrides ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.competition_cup_season_schedule ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.competition_cup_standard_schedule ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS competition_cup_entry_overrides_read ON public.competition_cup_entry_overrides;
CREATE POLICY competition_cup_entry_overrides_read
  ON public.competition_cup_entry_overrides FOR SELECT TO authenticated USING (true);

DROP POLICY IF EXISTS competition_cup_season_schedule_read ON public.competition_cup_season_schedule;
CREATE POLICY competition_cup_season_schedule_read
  ON public.competition_cup_season_schedule FOR SELECT TO authenticated USING (true);

-- Save the standard Shield schedule once (never a season version)
INSERT INTO public.competition_cup_standard_schedule
SELECT s.*
FROM public.competition_cup_round_schedule s
WHERE s.cup_code = 'shield'
  AND NOT EXISTS (SELECT 1 FROM public.competition_cup_standard_schedule b WHERE b.cup_code = 'shield')
  AND NOT EXISTS (
    SELECT 1 FROM public.competition_cup_round_schedule x
    WHERE x.cup_code = 'shield' AND x.round_label = 'Preliminary round'
  );

-- ---------------------------------------------------------------------------
-- Move current implementations to *_base (adopts newer versions on re-run)
-- ---------------------------------------------------------------------------
DO $rename$
DECLARE
  v_fn text;
  v_sig text;
  v_marker text;
BEGIN
  FOR v_fn, v_sig, v_marker IN
    SELECT * FROM (VALUES
      ('competition_qualify_cup_clubs', 'bigint, text', 'competition_cup_entry_overrides'),
      ('competition_qualify_cup_clubs_detailed', 'bigint, text', 'competition_cup_entry_overrides'),
      ('competition_build_knockout_bracket', 'bigint, text, text[], text[], text[], integer[]', 'competition_cup_season_schedule')
    ) AS t(fn, sig, marker)
  LOOP
    IF to_regprocedure(format('public.%I(%s)', v_fn, v_sig)) IS NOT NULL
       AND position(v_marker IN
         pg_get_functiondef(format('public.%I(%s)', v_fn, v_sig)::regprocedure)) = 0 THEN
      EXECUTE format('DROP FUNCTION IF EXISTS public.%I(%s)', v_fn || '_base', v_sig);
      EXECUTE format('ALTER FUNCTION public.%I(%s) RENAME TO %I', v_fn, v_sig, v_fn || '_base');
    END IF;
  END LOOP;
END;
$rename$;

-- ---------------------------------------------------------------------------
-- Qualify wrappers
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
  v_clubs text[];
BEGIN
  IF v_code = 'spoon' THEN
    v_code := 'bowl';
  END IF;

  SELECT array_agg(o.club_short_name ORDER BY o.club_short_name)
  INTO v_clubs
  FROM public.competition_cup_entry_overrides o
  WHERE o.season_id = p_season_id
    AND o.cup_code = v_code;

  IF coalesce(array_length(v_clubs, 1), 0) > 0 THEN
    RETURN v_clubs;
  END IF;

  RETURN public.competition_qualify_cup_clubs_base(p_season_id, p_cup_code);
END;
$function$;

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
  v_rows jsonb;
BEGIN
  IF v_code = 'spoon' THEN
    v_code := 'bowl';
  END IF;

  SELECT jsonb_agg(
    jsonb_build_object(
      'club', o.club_short_name,
      'division', ccs.division,
      'position', NULL,
      'reason',
        public.competition_cup_division_label(ccs.division)
        || CASE WHEN c.owner_id IS NULL THEN ' · vacant (walkover unless it gains an owner)' ELSE ' · owned' END
    )
    ORDER BY (c.owner_id IS NULL),
      CASE ccs.division
        WHEN 'superleague' THEN 1
        WHEN 'championship_a' THEN 2
        WHEN 'championship_b' THEN 3
        ELSE 9
      END,
      o.club_short_name
  )
  INTO v_rows
  FROM public.competition_cup_entry_overrides o
  JOIN public."Clubs" c ON c."ShortName" = o.club_short_name
  LEFT JOIN public.competition_club_seasons ccs
    ON ccs.season_id = o.season_id AND ccs.club_short_name = o.club_short_name
  WHERE o.season_id = p_season_id
    AND o.cup_code = v_code;

  IF v_rows IS NOT NULL AND jsonb_array_length(v_rows) > 0 THEN
    RETURN v_rows;
  END IF;

  RETURN public.competition_qualify_cup_clubs_detailed_base(p_season_id, p_cup_code);
END;
$function$;

-- ---------------------------------------------------------------------------
-- Schedule swap
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.competition_cup_apply_season_schedule(
  p_season_id bigint,
  p_cup_code text
)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_cup text := lower(btrim(coalesce(p_cup_code, '')));
BEGIN
  IF EXISTS (
    SELECT 1 FROM public.competition_cup_season_schedule
    WHERE season_id = p_season_id AND cup_code = v_cup
  ) THEN
    DELETE FROM public.competition_cup_round_schedule WHERE cup_code = v_cup;
    INSERT INTO public.competition_cup_round_schedule (
      cup_code, round_no, cup_leg, gpsl_month, stage, round_label, matches_in_round
    )
    SELECT cup_code, round_no, cup_leg, gpsl_month, stage, round_label, matches_in_round
    FROM public.competition_cup_season_schedule
    WHERE season_id = p_season_id AND cup_code = v_cup;
    RETURN 'season';
  END IF;

  IF EXISTS (SELECT 1 FROM public.competition_cup_standard_schedule WHERE cup_code = v_cup) THEN
    DELETE FROM public.competition_cup_round_schedule WHERE cup_code = v_cup;
    INSERT INTO public.competition_cup_round_schedule
    SELECT * FROM public.competition_cup_standard_schedule WHERE cup_code = v_cup;
    RETURN 'standard';
  END IF;

  RETURN 'unchanged';
END;
$function$;

REVOKE ALL ON FUNCTION public.competition_cup_apply_season_schedule(bigint, text) FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Bracket builder wrapper
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.competition_build_knockout_bracket(
  p_season_id bigint,
  p_cup_code text,
  p_clubs text[],
  p_bye_clubs text[] DEFAULT NULL,
  p_player_order text[] DEFAULT NULL,
  p_bye_match_nos int[] DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_cup text := lower(btrim(coalesce(p_cup_code, '')));
  v_clubs text[];
  v_n int;
  v_target int;
  v_req int;
  v_byes text[];
  v_owned text[];
  v_vacant text[];
  v_order text[] := ARRAY[]::text[];
  v_nv int;
  v_i int;
BEGIN
  IF v_cup = 'spoon' THEN
    v_cup := 'bowl';
  END IF;

  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  PERFORM public.competition_cup_apply_season_schedule(p_season_id, v_cup);

  IF NOT EXISTS (
    SELECT 1 FROM public.competition_cup_season_schedule
    WHERE season_id = p_season_id AND cup_code = v_cup
  ) THEN
    RETURN public.competition_build_knockout_bracket_base(
      p_season_id, p_cup_code, p_clubs, p_bye_clubs, p_player_order, p_bye_match_nos
    );
  END IF;

  v_clubs := ARRAY(
    SELECT DISTINCT c."ShortName"
    FROM unnest(coalesce(p_clubs, ARRAY[]::text[])) AS x
    JOIN public."Clubs" c ON upper(c."ShortName") = upper(btrim(x))
  );
  v_n := coalesce(array_length(v_clubs, 1), 0);

  SELECT max(matches_in_round) * 2 INTO v_target
  FROM public.competition_cup_round_schedule
  WHERE cup_code = v_cup
    AND round_no = (SELECT min(round_no) FROM public.competition_cup_round_schedule WHERE cup_code = v_cup);
  v_target := greatest(coalesce(v_target, 1), 1);
  WHILE v_target < v_n LOOP
    v_target := v_target * 2;
  END LOOP;
  v_req := v_target - v_n;

  -- Byes: owned clubs only — saved picks first, then random owned clubs
  SELECT coalesce(array_agg(d.c ORDER BY d.pri, d.k), ARRAY[]::text[])
  INTO v_byes
  FROM (
    SELECT dd.c, dd.pri, dd.k
    FROM (
      SELECT DISTINCT ON (a.c) a.c, a.pri, a.k
      FROM (
        SELECT cl."ShortName" AS c, 0 AS pri, u.ord::float8 AS k
        FROM unnest(coalesce(p_bye_clubs, ARRAY[]::text[])) WITH ORDINALITY AS u(b, ord)
        JOIN public."Clubs" cl ON upper(cl."ShortName") = upper(btrim(u.b))
        UNION ALL
        SELECT x, 1, random() FROM unnest(v_clubs) AS x
      ) a
      WHERE a.c = ANY (v_clubs)
        AND NOT public.competition_club_is_vacant(a.c)
      ORDER BY a.c, a.pri, a.k
    ) dd
    ORDER BY dd.pri, dd.k
    LIMIT v_req
  ) d;

  IF coalesce(array_length(v_byes, 1), 0) <> v_req THEN
    RAISE EXCEPTION 'Need % owned clubs for byes in % — only % available', v_req, v_cup,
      coalesce(array_length(v_byes, 1), 0);
  END IF;

  v_vacant := ARRAY(
    SELECT x FROM unnest(v_clubs) AS x
    WHERE NOT (x = ANY (v_byes)) AND public.competition_club_is_vacant(x)
    ORDER BY random()
  );
  v_owned := ARRAY(
    SELECT x FROM unnest(v_clubs) AS x
    WHERE NOT (x = ANY (v_byes)) AND NOT public.competition_club_is_vacant(x)
    ORDER BY random()
  );
  v_nv := coalesce(array_length(v_vacant, 1), 0);

  IF v_nv > coalesce(array_length(v_owned, 1), 0) THEN
    RAISE EXCEPTION '% has more vacant clubs (%) than owned opponents (%) — cannot avoid vacant v vacant',
      v_cup, v_nv, coalesce(array_length(v_owned, 1), 0);
  END IF;

  FOR v_i IN 1..v_nv LOOP
    IF random() < 0.5 THEN
      v_order := v_order || v_owned[v_i] || v_vacant[v_i];
    ELSE
      v_order := v_order || v_vacant[v_i] || v_owned[v_i];
    END IF;
  END LOOP;
  FOR v_i IN (v_nv + 1)..coalesce(array_length(v_owned, 1), 0) LOOP
    v_order := v_order || v_owned[v_i];
  END LOOP;

  RETURN public.competition_build_knockout_bracket_base(
    p_season_id, p_cup_code, v_clubs, v_byes, v_order, p_bye_match_nos
  ) || jsonb_build_object(
    'season_schedule', true,
    'vacant_paired_with_owned', v_nv
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_qualify_cup_clubs(bigint, text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.competition_qualify_cup_clubs_detailed(bigint, text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.competition_build_knockout_bracket(bigint, text, text[], text[], text[], int[]) TO authenticated;
REVOKE ALL ON FUNCTION public.competition_qualify_cup_clubs_base(bigint, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.competition_qualify_cup_clubs_detailed_base(bigint, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.competition_build_knockout_bracket_base(bigint, text, text[], text[], text[], int[]) FROM PUBLIC, anon;

-- ---------------------------------------------------------------------------
-- Season 1 Shield: entries, schedule, starter byes (refresh until drawn)
-- ---------------------------------------------------------------------------
DO $fill$
DECLARE
  v_season bigint;
  v_n int;
  v_req int;
BEGIN
  SELECT id INTO v_season
  FROM public.competition_seasons
  WHERE is_current
  ORDER BY id DESC
  LIMIT 1;

  IF v_season IS NULL THEN
    RAISE NOTICE 'No current season — Shield not set up';
    RETURN;
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.competition_cup_entry_overrides o
    WHERE o.season_id <> v_season AND o.cup_code = 'shield'
  ) THEN
    RAISE NOTICE 'Shield overrides belong to an earlier season — season % uses normal qualifying', v_season;
    RETURN;
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.competition_cup_bracket_nodes n
    WHERE n.season_id = v_season AND n.cup_code = 'shield'
  ) THEN
    RAISE NOTICE 'Shield already drawn for season % — left as is', v_season;
    RETURN;
  END IF;

  DELETE FROM public.competition_cup_entry_overrides
  WHERE season_id = v_season AND cup_code = 'shield';

  INSERT INTO public.competition_cup_entry_overrides (season_id, cup_code, club_short_name, note)
  SELECT v_season, 'shield', ccs.club_short_name, 'Season 1 — every league club'
  FROM public.competition_club_seasons ccs
  WHERE ccs.season_id = v_season
    AND ccs.division IN ('superleague', 'championship_a', 'championship_b');

  DELETE FROM public.competition_cup_season_schedule
  WHERE season_id = v_season AND cup_code = 'shield';

  INSERT INTO public.competition_cup_season_schedule (
    season_id, cup_code, round_no, cup_leg, gpsl_month, stage, round_label, matches_in_round
  ) VALUES
    (v_season, 'shield', 1, 1, 'august',    'r32',   'Preliminary round', 32),
    (v_season, 'shield', 2, 1, 'september', 'r1',    'Last 32',           16),
    (v_season, 'shield', 3, 1, 'october',   'r2',    'Last 16',            8),
    (v_season, 'shield', 4, 1, 'november',  'qf',    'Quarter-final',      4),
    (v_season, 'shield', 5, 1, 'december',  'sf',    'Semi-final',         2),
    (v_season, 'shield', 6, 1, 'december',  'final', 'Final',              1);

  -- Starter byes so the admin panel is ready to draw (owned clubs only)
  SELECT count(*)::int INTO v_n
  FROM public.competition_cup_entry_overrides
  WHERE season_id = v_season AND cup_code = 'shield';
  v_req := greatest(64 - v_n, 0);

  DELETE FROM public.competition_cup_first_round_byes
  WHERE season_id = v_season AND cup_code = 'shield';

  INSERT INTO public.competition_cup_first_round_byes (season_id, cup_code, club_short_name, sort_order)
  SELECT v_season, 'shield', b.club_short_name, row_number() OVER ()::int
  FROM (
    SELECT o.club_short_name
    FROM public.competition_cup_entry_overrides o
    JOIN public."Clubs" c ON c."ShortName" = o.club_short_name
    WHERE o.season_id = v_season AND o.cup_code = 'shield'
      AND c.owner_id IS NOT NULL
    ORDER BY random()
    LIMIT v_req
  ) b;
END;
$fill$;

NOTIFY pgrst, 'reload schema';

-- Check
WITH s AS (SELECT id FROM public.competition_seasons WHERE is_current ORDER BY id DESC LIMIT 1)
SELECT
  (SELECT count(*) FROM public.competition_cup_entry_overrides o, s
    WHERE o.season_id = s.id AND o.cup_code = 'shield') AS shield_entries,
  (SELECT count(*) FROM public.competition_cup_entry_overrides o JOIN public."Clubs" c ON c."ShortName" = o.club_short_name, s
    WHERE o.season_id = s.id AND o.cup_code = 'shield' AND c.owner_id IS NULL) AS vacant_entries,
  (SELECT count(*) FROM public.competition_cup_first_round_byes b, s
    WHERE b.season_id = s.id AND b.cup_code = 'shield') AS starter_byes,
  (SELECT string_agg(round_label || ' ' || gpsl_month, ', ' ORDER BY round_no)
     FROM public.competition_cup_season_schedule x, s
    WHERE x.season_id = s.id AND x.cup_code = 'shield') AS season1_schedule,
  (SELECT count(*) FROM public.competition_cup_standard_schedule WHERE cup_code = 'shield') AS standard_rounds_saved,
  (SELECT count(*) FROM public.competition_cup_bracket_nodes n, s
    WHERE n.season_id = s.id AND n.cup_code = 'shield') AS shield_nodes_already;
