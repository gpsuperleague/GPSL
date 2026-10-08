-- =============================================================================
-- Prestige cup entry overrides + Season 1 Shield = every owned league club
-- =============================================================================
-- Prestige cups normally qualify from the PREVIOUS season's final table. The
-- inaugural season has none, so the Shield draw finds no (or nonsense) clubs.
--
-- competition_cup_entry_overrides(season_id, cup_code, club): when a season +
-- cup has any rows, those clubs ARE the entrants (draw, byes panel and admin
-- qualifier list all read through the wrappers below). No rows = normal rules.
--
-- Implementation: the existing qualify functions are renamed to *_base once,
-- and thin wrappers take their names. If a later patch re-creates
-- competition_qualify_cup_clubs / _detailed, re-run this file.
--
-- Then fills the current season's Shield with all owned clubs in the Super
-- League / Championship A / Championship B (32 today = full last-32, no byes).
--
-- Safe to re-run (refreshes the Shield list from current owners until drawn).
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.competition_cup_entry_overrides (
  season_id bigint NOT NULL REFERENCES public.competition_seasons (id) ON DELETE CASCADE,
  cup_code text NOT NULL,
  club_short_name text NOT NULL REFERENCES public."Clubs" ("ShortName") ON DELETE CASCADE,
  note text,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (season_id, cup_code, club_short_name)
);

ALTER TABLE public.competition_cup_entry_overrides ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS competition_cup_entry_overrides_read ON public.competition_cup_entry_overrides;
CREATE POLICY competition_cup_entry_overrides_read
  ON public.competition_cup_entry_overrides
  FOR SELECT TO authenticated
  USING (true);

-- Move the current implementations to *_base. If a later patch has replaced
-- the wrapper with new qualify logic, that newer version becomes the base.
DO $rename$
DECLARE
  v_fn text;
BEGIN
  FOREACH v_fn IN ARRAY ARRAY['competition_qualify_cup_clubs', 'competition_qualify_cup_clubs_detailed']
  LOOP
    IF to_regprocedure(format('public.%I(bigint,text)', v_fn)) IS NOT NULL
       AND position('competition_cup_entry_overrides' IN
         pg_get_functiondef(format('public.%I(bigint,text)', v_fn)::regprocedure)) = 0 THEN
      EXECUTE format('DROP FUNCTION IF EXISTS public.%I(bigint, text)', v_fn || '_base');
      EXECUTE format('ALTER FUNCTION public.%I(bigint, text) RENAME TO %I', v_fn, v_fn || '_base');
    END IF;
  END LOOP;
END;
$rename$;

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
      'reason', coalesce(
        o.note,
        public.competition_cup_division_label(ccs.division) || ' · admin entry list'
      )
    )
    ORDER BY
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

GRANT EXECUTE ON FUNCTION public.competition_qualify_cup_clubs(bigint, text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.competition_qualify_cup_clubs_detailed(bigint, text) TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.competition_qualify_cup_clubs_base(bigint, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.competition_qualify_cup_clubs_detailed_base(bigint, text) FROM PUBLIC, anon;

-- Season 1 Shield: every owned club in a league division (refresh until drawn)
DO $fill$
DECLARE
  v_season bigint;
BEGIN
  SELECT id INTO v_season
  FROM public.competition_seasons
  WHERE is_current
  ORDER BY id DESC
  LIMIT 1;

  IF v_season IS NULL THEN
    RAISE NOTICE 'No current season — Shield list not filled';
    RETURN;
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.competition_cup_entry_overrides o
    WHERE o.season_id <> v_season AND o.cup_code = 'shield'
  ) THEN
    RAISE NOTICE 'Shield entry list belongs to an earlier season — season % uses normal qualifying', v_season;
    RETURN;
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.competition_cup_bracket_nodes n
    WHERE n.season_id = v_season AND n.cup_code = 'shield'
  ) THEN
    RAISE NOTICE 'Shield already drawn for season % — entry list left as is', v_season;
    RETURN;
  END IF;

  DELETE FROM public.competition_cup_entry_overrides
  WHERE season_id = v_season AND cup_code = 'shield';

  INSERT INTO public.competition_cup_entry_overrides (season_id, cup_code, club_short_name, note)
  SELECT v_season, 'shield', ccs.club_short_name,
         public.competition_cup_division_label(ccs.division) || ' · Season 1 owned-club entry'
  FROM public.competition_club_seasons ccs
  JOIN public."Clubs" c ON c."ShortName" = ccs.club_short_name
  WHERE ccs.season_id = v_season
    AND ccs.division IN ('superleague', 'championship_a', 'championship_b')
    AND c.owner_id IS NOT NULL;
END;
$fill$;

NOTIFY pgrst, 'reload schema';

-- Check
WITH s AS (SELECT id FROM public.competition_seasons WHERE is_current ORDER BY id DESC LIMIT 1)
SELECT
  (SELECT count(*) FROM public.competition_cup_entry_overrides o, s
    WHERE o.season_id = s.id AND o.cup_code = 'shield') AS shield_entries,
  coalesce(array_length(public.competition_qualify_cup_clubs((SELECT id FROM s), 'shield'), 1), 0) AS draw_will_use,
  (SELECT count(*) FROM public.competition_cup_bracket_nodes n, s
    WHERE n.season_id = s.id AND n.cup_code = 'shield') AS shield_nodes_already,
  (SELECT string_agg(round_label || ' ' || gpsl_month, ', ' ORDER BY round_no)
     FROM public.competition_cup_round_schedule WHERE cup_code = 'shield') AS shield_schedule;
