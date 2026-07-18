-- =============================================================================
-- Phase 7 — League playoffs (Week 11)
--
-- Generates / advances:
--   • SuperLeague 16v17 (relegation playoff)
--   • Championship A/B promotion (3v6, 4v5 → div final → CH final → SL final)
--   • Championship A/B Shield/Bowl 16v17
--
-- Fixtures: competition_type=cup, cup_code po_*, gpsl_month=playoffs
-- Admin: SELECT public.admin_competition_generate_playoffs(NULL);
--        SELECT public.admin_competition_apply_playoff_movements(NULL);
-- Safe re-run (generate is no-op if ties already exist unless p_force).
-- =============================================================================

-- League-programme helper (from playoffs calendar patch; redefine if missing)
CREATE OR REPLACE FUNCTION public.competition_gpsl_month_is_league_programme(p_month text)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT lower(btrim(coalesce(p_month, ''))) IN (
    'august', 'september', 'october', 'november', 'december',
    'january', 'february', 'march', 'april', 'may'
  );
$$;

-- Allow playoff cup codes on fixtures
ALTER TABLE public.competition_fixtures
  DROP CONSTRAINT IF EXISTS competition_fixtures_cup_fields_check;

ALTER TABLE public.competition_fixtures
  ADD CONSTRAINT competition_fixtures_cup_fields_check
  CHECK (
    (
      competition_type = 'league'
      AND cup_code IS NULL
      AND cup_round IS NULL
      AND cup_match IS NULL
    )
    OR (
      competition_type = 'cup'
      AND cup_code IN (
        'super8', 'plate', 'shield', 'bowl', 'league_cup',
        'po_sl_1617', 'po_ch_a', 'po_ch_b', 'po_ch_sb_a', 'po_ch_sb_b',
        'po_ch_final', 'po_sl_final'
      )
      AND cup_round IS NOT NULL
      AND cup_match IS NOT NULL
    )
  );

-- Weather tag for playoffs week (extends phase1 helper — keep existing tags)
CREATE OR REPLACE FUNCTION public.competition_weather_for_month(p_month text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $function$
  SELECT CASE lower(btrim(coalesce(p_month, '')))
    WHEN 'august' THEN 'warm'
    WHEN 'september' THEN 'mild'
    WHEN 'october' THEN 'windy'
    WHEN 'november' THEN 'wet'
    WHEN 'december' THEN 'cold'
    WHEN 'january' THEN 'freezing'
    WHEN 'february' THEN 'cold'
    WHEN 'march' THEN 'showers'
    WHEN 'april' THEN 'mild'
    WHEN 'may' THEN 'sunny'
    WHEN 'playoffs' THEN 'sunny'
    ELSE 'unknown'
  END;
$function$;

CREATE TABLE IF NOT EXISTS public.competition_playoff_ties (
  id bigserial PRIMARY KEY,
  season_id bigint NOT NULL REFERENCES public.competition_seasons(id) ON DELETE CASCADE,
  bracket text NOT NULL,
  round_no integer NOT NULL CHECK (round_no >= 1 AND round_no <= 4),
  match_no integer NOT NULL DEFAULT 1 CHECK (match_no >= 1 AND match_no <= 4),
  label text NOT NULL,
  week_in_month smallint NOT NULL DEFAULT 1 CHECK (week_in_month BETWEEN 1 AND 4),
  home_club_short_name text REFERENCES public."Clubs"("ShortName"),
  away_club_short_name text REFERENCES public."Clubs"("ShortName"),
  home_source text,
  away_source text,
  winner_club_short_name text REFERENCES public."Clubs"("ShortName"),
  loser_club_short_name text REFERENCES public."Clubs"("ShortName"),
  fixture_id bigint REFERENCES public.competition_fixtures(id) ON DELETE SET NULL,
  cup_code text NOT NULL,
  status text NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending', 'ready', 'scheduled', 'played', 'cancelled')),
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (season_id, bracket, round_no, match_no)
);

CREATE INDEX IF NOT EXISTS competition_playoff_ties_season_idx
  ON public.competition_playoff_ties (season_id, bracket, round_no, match_no);

CREATE TABLE IF NOT EXISTS public.competition_season_movements (
  id bigserial PRIMARY KEY,
  season_id bigint NOT NULL REFERENCES public.competition_seasons(id) ON DELETE CASCADE,
  club_short_name text NOT NULL REFERENCES public."Clubs"("ShortName"),
  from_division text NOT NULL,
  to_division text NOT NULL,
  reason text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (season_id, club_short_name, reason)
);

CREATE TABLE IF NOT EXISTS public.competition_playoff_season_state (
  season_id bigint PRIMARY KEY REFERENCES public.competition_seasons(id) ON DELETE CASCADE,
  generated_at timestamptz,
  completed_at timestamptz,
  movements_applied_at timestamptz,
  notes jsonb NOT NULL DEFAULT '{}'::jsonb
);

ALTER TABLE public.competition_playoff_ties ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.competition_season_movements ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.competition_playoff_season_state ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS competition_playoff_ties_select ON public.competition_playoff_ties;
CREATE POLICY competition_playoff_ties_select ON public.competition_playoff_ties
  FOR SELECT TO authenticated USING (true);

DROP POLICY IF EXISTS competition_season_movements_select ON public.competition_season_movements;
CREATE POLICY competition_season_movements_select ON public.competition_season_movements
  FOR SELECT TO authenticated USING (true);

DROP POLICY IF EXISTS competition_playoff_season_state_select ON public.competition_playoff_season_state;
CREATE POLICY competition_playoff_season_state_select ON public.competition_playoff_season_state
  FOR SELECT TO authenticated USING (true);

GRANT SELECT ON public.competition_playoff_ties TO authenticated;
GRANT SELECT ON public.competition_season_movements TO authenticated;
GRANT SELECT ON public.competition_playoff_season_state TO authenticated;
GRANT ALL ON public.competition_playoff_ties TO service_role;
GRANT ALL ON public.competition_season_movements TO service_role;
GRANT ALL ON public.competition_playoff_season_state TO service_role;
GRANT USAGE, SELECT ON SEQUENCE public.competition_playoff_ties_id_seq TO service_role;
GRANT USAGE, SELECT ON SEQUENCE public.competition_season_movements_id_seq TO service_role;

CREATE OR REPLACE FUNCTION public.competition_playoff_cup_code(p_bracket text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE p_bracket
    WHEN 'sl_1617' THEN 'po_sl_1617'
    WHEN 'ch_promo_a' THEN 'po_ch_a'
    WHEN 'ch_promo_b' THEN 'po_ch_b'
    WHEN 'ch_sb_a' THEN 'po_ch_sb_a'
    WHEN 'ch_sb_b' THEN 'po_ch_sb_b'
    WHEN 'ch_final' THEN 'po_ch_final'
    WHEN 'sl_final' THEN 'po_sl_final'
    ELSE NULL
  END;
$$;

CREATE OR REPLACE FUNCTION public.competition_playoff_standing_club(
  p_season_id bigint,
  p_division text,
  p_position integer
)
RETURNS text
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT s.club_short_name
  FROM public.competition_standings_public s
  WHERE s.season_id = p_season_id
    AND s.division = p_division
    AND s.table_position = p_position
  LIMIT 1;
$$;

CREATE OR REPLACE FUNCTION public.competition_playoff_create_fixture(p_tie_id bigint)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  t public.competition_playoff_ties%ROWTYPE;
  v_fid bigint;
  v_weather text;
BEGIN
  SELECT * INTO t FROM public.competition_playoff_ties WHERE id = p_tie_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Playoff tie % not found', p_tie_id;
  END IF;

  IF t.fixture_id IS NOT NULL THEN
    RETURN t.fixture_id;
  END IF;

  IF t.home_club_short_name IS NULL OR t.away_club_short_name IS NULL THEN
    RETURN NULL;
  END IF;

  BEGIN
    v_weather := public.competition_weather_for_gpsl_month('playoffs');
  EXCEPTION WHEN OTHERS THEN
    v_weather := 'warm';
  END;

  INSERT INTO public.competition_fixtures (
    season_id, division, competition_type, matchday,
    gpsl_month, week_in_month,
    home_club_short_name, away_club_short_name, weather,
    cup_code, cup_round, cup_match, cup_leg, status
  )
  VALUES (
    t.season_id, 'cup', 'cup', t.round_no,
    'playoffs', t.week_in_month,
    t.home_club_short_name, t.away_club_short_name, v_weather,
    t.cup_code, t.round_no, t.match_no, 1, 'scheduled'
  )
  RETURNING id INTO v_fid;

  UPDATE public.competition_playoff_ties
  SET fixture_id = v_fid,
      status = 'scheduled'
  WHERE id = p_tie_id;

  RETURN v_fid;
END;
$function$;

CREATE OR REPLACE FUNCTION public.competition_playoff_try_schedule_ready(p_season_id bigint)
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  t record;
  v_n int := 0;
  v_fid bigint;
BEGIN
  FOR t IN
    SELECT id
    FROM public.competition_playoff_ties
    WHERE season_id = p_season_id
      AND status IN ('pending', 'ready')
      AND home_club_short_name IS NOT NULL
      AND away_club_short_name IS NOT NULL
      AND fixture_id IS NULL
  LOOP
    UPDATE public.competition_playoff_ties
    SET status = 'ready'
    WHERE id = t.id;

    v_fid := public.competition_playoff_create_fixture(t.id);
    IF v_fid IS NOT NULL THEN
      v_n := v_n + 1;
    END IF;
  END LOOP;
  RETURN v_n;
END;
$function$;

CREATE OR REPLACE FUNCTION public.competition_playoff_fill_from_sources(p_season_id bigint)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  t record;
  v_home text;
  v_away text;
  v_src_id bigint;
BEGIN
  FOR t IN
    SELECT *
    FROM public.competition_playoff_ties
    WHERE season_id = p_season_id
      AND status IN ('pending', 'ready')
      AND (home_club_short_name IS NULL OR away_club_short_name IS NULL)
  LOOP
    v_home := t.home_club_short_name;
    v_away := t.away_club_short_name;

    IF v_home IS NULL AND t.home_source LIKE 'winner:%' THEN
      v_src_id := nullif(split_part(t.home_source, ':', 2), '')::bigint;
      SELECT winner_club_short_name INTO v_home
      FROM public.competition_playoff_ties WHERE id = v_src_id;
    END IF;

    IF v_away IS NULL AND t.away_source LIKE 'winner:%' THEN
      v_src_id := nullif(split_part(t.away_source, ':', 2), '')::bigint;
      SELECT winner_club_short_name INTO v_away
      FROM public.competition_playoff_ties WHERE id = v_src_id;
    END IF;

    IF v_home IS DISTINCT FROM t.home_club_short_name
       OR v_away IS DISTINCT FROM t.away_club_short_name THEN
      UPDATE public.competition_playoff_ties
      SET home_club_short_name = v_home,
          away_club_short_name = v_away,
          status = CASE
            WHEN v_home IS NOT NULL AND v_away IS NOT NULL THEN 'ready'
            ELSE status
          END
      WHERE id = t.id;
    END IF;
  END LOOP;
END;
$function$;

CREATE OR REPLACE FUNCTION public.competition_generate_playoffs(
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
  v_club text;
  v_id bigint;
  v_semi_a_36 bigint;
  v_semi_a_45 bigint;
  v_semi_b_36 bigint;
  v_semi_b_45 bigint;
  v_final_a bigint;
  v_final_b bigint;
  v_sl1617 bigint;
  v_ch_final bigint;
  v_created int := 0;
  v_scheduled int := 0;
BEGIN
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

  -- Ensure playoffs calendar week exists
  BEGIN
    PERFORM public.competition_admin_ensure_playoffs_week(v_season_id);
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;

  IF EXISTS (
    SELECT 1 FROM public.competition_playoff_ties WHERE season_id = v_season_id
  ) AND NOT coalesce(p_force, false) THEN
    PERFORM public.competition_playoff_fill_from_sources(v_season_id);
    v_scheduled := public.competition_playoff_try_schedule_ready(v_season_id);
    RETURN jsonb_build_object(
      'ok', true,
      'season_id', v_season_id,
      'already', true,
      'scheduled_now', v_scheduled
    );
  END IF;

  IF coalesce(p_force, false) THEN
    DELETE FROM public.competition_fixtures f
    WHERE f.season_id = v_season_id
      AND f.competition_type = 'cup'
      AND f.cup_code LIKE 'po_%';
    DELETE FROM public.competition_playoff_ties WHERE season_id = v_season_id;
    DELETE FROM public.competition_season_movements WHERE season_id = v_season_id;
    DELETE FROM public.competition_playoff_season_state WHERE season_id = v_season_id;
  END IF;

  -- SuperLeague 16v17
  INSERT INTO public.competition_playoff_ties (
    season_id, bracket, round_no, match_no, label, week_in_month,
    home_club_short_name, away_club_short_name, cup_code, status
  )
  VALUES (
    v_season_id, 'sl_1617', 1, 1, 'Super League Relegation Playoff Final — 16th vs 17th', 1,
    public.competition_playoff_standing_club(v_season_id, 'superleague', 16),
    public.competition_playoff_standing_club(v_season_id, 'superleague', 17),
    'po_sl_1617', 'ready'
  )
  RETURNING id INTO v_sl1617;
  v_created := v_created + 1;

  -- Championship Shield/Bowl 16v17
  INSERT INTO public.competition_playoff_ties (
    season_id, bracket, round_no, match_no, label, week_in_month,
    home_club_short_name, away_club_short_name, cup_code, status
  )
  VALUES (
    v_season_id, 'ch_sb_a', 1, 1, 'Championship A Shield Playoff Final — 16th vs 17th', 1,
    public.competition_playoff_standing_club(v_season_id, 'championship_a', 16),
    public.competition_playoff_standing_club(v_season_id, 'championship_a', 17),
    'po_ch_sb_a', 'ready'
  );
  v_created := v_created + 1;

  INSERT INTO public.competition_playoff_ties (
    season_id, bracket, round_no, match_no, label, week_in_month,
    home_club_short_name, away_club_short_name, cup_code, status
  )
  VALUES (
    v_season_id, 'ch_sb_b', 1, 1, 'Championship B Shield Playoff Final — 16th vs 17th', 1,
    public.competition_playoff_standing_club(v_season_id, 'championship_b', 16),
    public.competition_playoff_standing_club(v_season_id, 'championship_b', 17),
    'po_ch_sb_b', 'ready'
  );
  v_created := v_created + 1;

  -- Championship A promotion semis
  INSERT INTO public.competition_playoff_ties (
    season_id, bracket, round_no, match_no, label, week_in_month,
    home_club_short_name, away_club_short_name, cup_code, status
  )
  VALUES (
    v_season_id, 'ch_promo_a', 1, 1, 'Championship A Semi Final — 3rd vs 6th', 1,
    public.competition_playoff_standing_club(v_season_id, 'championship_a', 3),
    public.competition_playoff_standing_club(v_season_id, 'championship_a', 6),
    'po_ch_a', 'ready'
  )
  RETURNING id INTO v_semi_a_36;
  v_created := v_created + 1;

  INSERT INTO public.competition_playoff_ties (
    season_id, bracket, round_no, match_no, label, week_in_month,
    home_club_short_name, away_club_short_name, cup_code, status
  )
  VALUES (
    v_season_id, 'ch_promo_a', 1, 2, 'Championship A Semi Final — 4th vs 5th', 1,
    public.competition_playoff_standing_club(v_season_id, 'championship_a', 4),
    public.competition_playoff_standing_club(v_season_id, 'championship_a', 5),
    'po_ch_a', 'ready'
  )
  RETURNING id INTO v_semi_a_45;
  v_created := v_created + 1;

  INSERT INTO public.competition_playoff_ties (
    season_id, bracket, round_no, match_no, label, week_in_month,
    home_source, away_source, cup_code, status
  )
  VALUES (
    v_season_id, 'ch_promo_a', 2, 1, 'Championship A Final — semi-final winners', 2,
    'winner:' || v_semi_a_36::text, 'winner:' || v_semi_a_45::text,
    'po_ch_a', 'pending'
  )
  RETURNING id INTO v_final_a;
  v_created := v_created + 1;

  -- Championship B promotion semis
  INSERT INTO public.competition_playoff_ties (
    season_id, bracket, round_no, match_no, label, week_in_month,
    home_club_short_name, away_club_short_name, cup_code, status
  )
  VALUES (
    v_season_id, 'ch_promo_b', 1, 1, 'Championship B Semi Final — 3rd vs 6th', 1,
    public.competition_playoff_standing_club(v_season_id, 'championship_b', 3),
    public.competition_playoff_standing_club(v_season_id, 'championship_b', 6),
    'po_ch_b', 'ready'
  )
  RETURNING id INTO v_semi_b_36;
  v_created := v_created + 1;

  INSERT INTO public.competition_playoff_ties (
    season_id, bracket, round_no, match_no, label, week_in_month,
    home_club_short_name, away_club_short_name, cup_code, status
  )
  VALUES (
    v_season_id, 'ch_promo_b', 1, 2, 'Championship B Semi Final — 4th vs 5th', 1,
    public.competition_playoff_standing_club(v_season_id, 'championship_b', 4),
    public.competition_playoff_standing_club(v_season_id, 'championship_b', 5),
    'po_ch_b', 'ready'
  )
  RETURNING id INTO v_semi_b_45;
  v_created := v_created + 1;

  INSERT INTO public.competition_playoff_ties (
    season_id, bracket, round_no, match_no, label, week_in_month,
    home_source, away_source, cup_code, status
  )
  VALUES (
    v_season_id, 'ch_promo_b', 2, 1, 'Championship B Final — semi-final winners', 2,
    'winner:' || v_semi_b_36::text, 'winner:' || v_semi_b_45::text,
    'po_ch_b', 'pending'
  )
  RETURNING id INTO v_final_b;
  v_created := v_created + 1;

  -- Championships playoff final (A winner vs B winner)
  INSERT INTO public.competition_playoff_ties (
    season_id, bracket, round_no, match_no, label, week_in_month,
    home_source, away_source, cup_code, status
  )
  VALUES (
    v_season_id, 'ch_final', 1, 1, 'Championship Playoff Final — Championship A final winner vs Championship B final winner', 3,
    'winner:' || v_final_a::text, 'winner:' || v_final_b::text,
    'po_ch_final', 'pending'
  )
  RETURNING id INTO v_ch_final;
  v_created := v_created + 1;

  -- SuperLeague playoff final
  INSERT INTO public.competition_playoff_ties (
    season_id, bracket, round_no, match_no, label, week_in_month,
    home_source, away_source, cup_code, status
  )
  VALUES (
    v_season_id, 'sl_final', 1, 1, 'Super League Playoff Final — relegation playoff winner vs Championship Playoff Final winner', 3,
    'winner:' || v_sl1617::text, 'winner:' || v_ch_final::text,
    'po_sl_final', 'pending'
  );
  v_created := v_created + 1;

  -- Drop incomplete ties (missing standings clubs)
  DELETE FROM public.competition_playoff_ties t
  WHERE t.season_id = v_season_id
    AND t.status = 'ready'
    AND (t.home_club_short_name IS NULL OR t.away_club_short_name IS NULL);

  v_scheduled := public.competition_playoff_try_schedule_ready(v_season_id);

  INSERT INTO public.competition_playoff_season_state (season_id, generated_at)
  VALUES (v_season_id, now())
  ON CONFLICT (season_id) DO UPDATE
    SET generated_at = now(),
        completed_at = NULL,
        movements_applied_at = NULL;

  BEGIN
    PERFORM public.gpsl_discord_feed_enqueue_notification(
      'playoffs',
      '🏟️ PLAYOFFS — brackets are live',
      'Week 11 playoff ties have been generated (SuperLeague 16v17, Championship promotion & Shield/Bowl playoffs).',
      5793266,
      'playoffs_generated:' || v_season_id::text,
      jsonb_build_object('channel', 'notifications', 'season_id', v_season_id)
    );
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;

  RETURN jsonb_build_object(
    'ok', true,
    'season_id', v_season_id,
    'ties_created', v_created,
    'fixtures_scheduled', v_scheduled
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_generate_playoffs(bigint, boolean)
  TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.admin_competition_generate_playoffs(
  p_season_id bigint DEFAULT NULL,
  p_force boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;
  RETURN public.competition_generate_playoffs(p_season_id, p_force);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.admin_competition_generate_playoffs(bigint, boolean)
  TO authenticated;

-- Resolve winner from a played playoff fixture
CREATE OR REPLACE FUNCTION public.competition_playoff_fixture_winner(p_fixture public.competition_fixtures)
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_home int := coalesce(p_fixture.home_goals, 0);
  v_away int := coalesce(p_fixture.away_goals, 0);
BEGIN
  IF p_fixture.cup_pen_winner_club_short_name IS NOT NULL THEN
    RETURN p_fixture.cup_pen_winner_club_short_name;
  END IF;
  IF v_home > v_away THEN
    RETURN p_fixture.home_club_short_name;
  END IF;
  IF v_away > v_home THEN
    RETURN p_fixture.away_club_short_name;
  END IF;
  RETURN NULL;
END;
$function$;

CREATE OR REPLACE FUNCTION public.competition_playoff_on_fixture_played()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  t public.competition_playoff_ties%ROWTYPE;
  v_winner text;
  v_loser text;
  v_div text;
BEGIN
  IF NEW.status IS DISTINCT FROM 'played' THEN
    RETURN NEW;
  END IF;
  IF TG_OP = 'UPDATE' AND OLD.status IS NOT DISTINCT FROM 'played' THEN
    RETURN NEW;
  END IF;
  IF NEW.competition_type IS DISTINCT FROM 'cup' OR NEW.cup_code IS NULL OR NEW.cup_code NOT LIKE 'po_%' THEN
    RETURN NEW;
  END IF;

  SELECT * INTO t
  FROM public.competition_playoff_ties
  WHERE fixture_id = NEW.id
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN NEW;
  END IF;

  v_winner := public.competition_playoff_fixture_winner(NEW);
  IF v_winner IS NULL THEN
    RETURN NEW;
  END IF;

  IF v_winner = NEW.home_club_short_name THEN
    v_loser := NEW.away_club_short_name;
  ELSE
    v_loser := NEW.home_club_short_name;
  END IF;

  UPDATE public.competition_playoff_ties
  SET winner_club_short_name = v_winner,
      loser_club_short_name = v_loser,
      status = 'played'
  WHERE id = t.id;

  -- Shield/Bowl prestige qualifiers (direct upsert — trigger is not always admin session)
  IF t.bracket IN ('ch_sb_a', 'ch_sb_b') THEN
    v_div := CASE t.bracket WHEN 'ch_sb_a' THEN 'championship_a' ELSE 'championship_b' END;
    BEGIN
      INSERT INTO public.competition_cup_manual_qualifiers (
        season_id, cup_code, division, club_short_name, qualifier_role
      ) VALUES
        (NEW.season_id, 'shield', v_div, v_winner, 'shield_playoff_winner'),
        (NEW.season_id, 'bowl', v_div, v_loser, 'bowl_playoff_loser')
      ON CONFLICT (season_id, cup_code, division, qualifier_role)
      DO UPDATE SET club_short_name = excluded.club_short_name;
    EXCEPTION WHEN OTHERS THEN
      NULL;
    END;
  END IF;

  PERFORM public.competition_playoff_fill_from_sources(NEW.season_id);
  PERFORM public.competition_playoff_try_schedule_ready(NEW.season_id);

  -- Mark complete when SL final played
  IF t.bracket = 'sl_final' THEN
    UPDATE public.competition_playoff_season_state
    SET completed_at = now(),
        notes = coalesce(notes, '{}'::jsonb) || jsonb_build_object(
          'sl_final_winner', v_winner,
          'sl_final_loser', v_loser
        )
    WHERE season_id = NEW.season_id;

    BEGIN
      PERFORM public.gpsl_discord_feed_enqueue(
        'league_clinch',
        format('🏁 PLAYOFFS COMPLETE — %s win the SuperLeague playoff final', coalesce(
          (SELECT c."Club" FROM public."Clubs" c WHERE c."ShortName" = v_winner), v_winner
        )),
        'Promotion and relegation playoffs are finished. Admin can apply end-of-season movements.',
        16766720,
        'playoffs_complete:' || NEW.season_id::text,
        jsonb_build_object('channel', 'news', 'season_id', NEW.season_id)
      );
    EXCEPTION WHEN OTHERS THEN
      NULL;
    END;
  END IF;

  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_competition_playoff_fixture_played ON public.competition_fixtures;
CREATE TRIGGER trg_competition_playoff_fixture_played
  AFTER INSERT OR UPDATE OF status, home_goals, away_goals, cup_pen_winner_club_short_name
  ON public.competition_fixtures
  FOR EACH ROW
  EXECUTE FUNCTION public.competition_playoff_on_fixture_played();

-- Build movement list after playoffs complete (also records auto promo/releg from table)
CREATE OR REPLACE FUNCTION public.competition_apply_playoff_movements(
  p_season_id bigint DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season_id bigint := p_season_id;
  v_n int := 0;
  r record;
  v_sl_final public.competition_playoff_ties%ROWTYPE;
  v_sl1617 public.competition_playoff_ties%ROWTYPE;
BEGIN
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

  SELECT * INTO v_sl_final
  FROM public.competition_playoff_ties
  WHERE season_id = v_season_id AND bracket = 'sl_final'
  LIMIT 1;

  SELECT * INTO v_sl1617
  FROM public.competition_playoff_ties
  WHERE season_id = v_season_id AND bracket = 'sl_1617'
  LIMIT 1;

  IF v_sl_final.status IS DISTINCT FROM 'played' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'sl_final_not_played');
  END IF;

  DELETE FROM public.competition_season_movements WHERE season_id = v_season_id;

  -- SL 18–20 auto relegated
  FOR r IN
    SELECT club_short_name, division
    FROM public.competition_standings_public
    WHERE season_id = v_season_id
      AND division = 'superleague'
      AND table_position >= 18
  LOOP
    INSERT INTO public.competition_season_movements (
      season_id, club_short_name, from_division, to_division, reason
    ) VALUES (
      v_season_id, r.club_short_name, 'superleague', 'championship_pool', 'auto_relegation'
    );
    v_n := v_n + 1;
  END LOOP;

  -- SL 16v17 loser relegated
  IF v_sl1617.loser_club_short_name IS NOT NULL THEN
    INSERT INTO public.competition_season_movements (
      season_id, club_short_name, from_division, to_division, reason
    ) VALUES (
      v_season_id, v_sl1617.loser_club_short_name, 'superleague', 'championship_pool', 'sl_1617_loser'
    )
    ON CONFLICT (season_id, club_short_name, reason) DO NOTHING;
    v_n := v_n + 1;
  END IF;

  -- SL final: winner SuperLeague, loser Championship
  INSERT INTO public.competition_season_movements (
    season_id, club_short_name, from_division, to_division, reason
  ) VALUES (
    v_season_id, v_sl_final.winner_club_short_name,
    CASE WHEN v_sl_final.winner_club_short_name = v_sl1617.winner_club_short_name
      THEN 'superleague' ELSE 'championship_pool' END,
    'superleague', 'sl_playoff_final_winner'
  )
  ON CONFLICT (season_id, club_short_name, reason) DO NOTHING;
  v_n := v_n + 1;

  INSERT INTO public.competition_season_movements (
    season_id, club_short_name, from_division, to_division, reason
  ) VALUES (
    v_season_id, v_sl_final.loser_club_short_name,
    CASE WHEN v_sl_final.loser_club_short_name = v_sl1617.winner_club_short_name
      THEN 'superleague' ELSE 'championship_pool' END,
    'championship_pool', 'sl_playoff_final_loser'
  )
  ON CONFLICT (season_id, club_short_name, reason) DO NOTHING;
  v_n := v_n + 1;

  -- CH top 2 each division → SuperLeague
  FOR r IN
    SELECT club_short_name, division
    FROM public.competition_standings_public
    WHERE season_id = v_season_id
      AND division IN ('championship_a', 'championship_b')
      AND table_position <= 2
  LOOP
    INSERT INTO public.competition_season_movements (
      season_id, club_short_name, from_division, to_division, reason
    ) VALUES (
      v_season_id, r.club_short_name, r.division, 'superleague', 'auto_promotion'
    )
    ON CONFLICT (season_id, club_short_name, reason) DO NOTHING;
    v_n := v_n + 1;
  END LOOP;

  UPDATE public.competition_playoff_season_state
  SET movements_applied_at = now()
  WHERE season_id = v_season_id;

  BEGIN
    PERFORM public.owner_inbox_notify_all_clubs(
      'playoff_movements',
      '📋 End-of-season movements confirmed',
      'Promotion, relegation and playoff outcomes have been recorded for next season setup.',
      'playoffs.html',
      'playoff_movements:' || v_season_id::text,
      v_season_id
    );
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;

  RETURN jsonb_build_object(
    'ok', true,
    'season_id', v_season_id,
    'movements', v_n
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_apply_playoff_movements(bigint)
  TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.admin_competition_apply_playoff_movements(
  p_season_id bigint DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;
  RETURN public.competition_apply_playoff_movements(p_season_id);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.admin_competition_apply_playoff_movements(bigint)
  TO authenticated;

-- Public read API for playoffs page
CREATE OR REPLACE FUNCTION public.competition_playoffs_public(p_season_id bigint DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season_id bigint := p_season_id;
  v_ties jsonb;
  v_state public.competition_playoff_season_state%ROWTYPE;
  v_movements jsonb;
  v_cal jsonb;
BEGIN
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

  SELECT * INTO v_state FROM public.competition_playoff_season_state WHERE season_id = v_season_id;

  SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY x.sort_bracket, x.round_no, x.match_no), '[]'::jsonb)
  INTO v_ties
  FROM (
    SELECT
      t.*,
      f.status AS fixture_status,
      f.home_goals,
      f.away_goals,
      f.cup_pen_winner_club_short_name,
      hc."Club" AS home_club_name,
      ac."Club" AS away_club_name,
      CASE t.bracket
        WHEN 'sl_1617' THEN 1
        WHEN 'ch_sb_a' THEN 2
        WHEN 'ch_sb_b' THEN 3
        WHEN 'ch_promo_a' THEN 4
        WHEN 'ch_promo_b' THEN 5
        WHEN 'ch_final' THEN 6
        WHEN 'sl_final' THEN 7
        ELSE 9
      END AS sort_bracket
    FROM public.competition_playoff_ties t
    LEFT JOIN public.competition_fixtures f ON f.id = t.fixture_id
    LEFT JOIN public."Clubs" hc ON hc."ShortName" = t.home_club_short_name
    LEFT JOIN public."Clubs" ac ON ac."ShortName" = t.away_club_short_name
    WHERE t.season_id = v_season_id
  ) x;

  SELECT coalesce(jsonb_agg(to_jsonb(m) ORDER BY m.id), '[]'::jsonb)
  INTO v_movements
  FROM public.competition_season_movements m
  WHERE m.season_id = v_season_id;

  SELECT to_jsonb(c) INTO v_cal
  FROM public.competition_season_calendar c
  WHERE c.season_id = v_season_id AND c.gpsl_month = 'playoffs'
  LIMIT 1;

  RETURN jsonb_build_object(
    'ok', true,
    'season_id', v_season_id,
    'state', to_jsonb(v_state),
    'ties', v_ties,
    'movements', v_movements,
    'calendar', v_cal
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_playoffs_public(bigint)
  TO authenticated, anon;

-- Auto-generate when May league-tables job runs (month lock)
CREATE OR REPLACE FUNCTION public.competition_process_month_league_tables(
  p_season_id bigint DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season_id bigint := p_season_id;
  v_cal record;
  v_job_key text;
  v_month_label text;
  v_qid bigint;
  v_snap jsonb;
  v_processed jsonb := '[]'::jsonb;
  v_clinches jsonb;
  v_playoffs jsonb;
BEGIN
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

  FOR v_cal IN
    SELECT c.gpsl_month
    FROM public.competition_season_calendar c
    WHERE c.season_id = v_season_id
      AND c.gpsl_month IS NOT NULL
      AND c.gpsl_month <> 'playoffs'
      AND public.competition_gpsl_month_is_league_programme(c.gpsl_month)
      AND c.lock_at IS NOT NULL
      AND c.lock_at <= now()
    ORDER BY public.competition_gpsl_month_sort(c.gpsl_month)
  LOOP
    v_job_key := 'league_tables:' || v_cal.gpsl_month;

    IF EXISTS (
      SELECT 1
      FROM public.competition_season_calendar_jobs j
      WHERE j.season_id = v_season_id
        AND j.job_key = v_job_key
        AND coalesce((j.result->>'ok')::boolean, false) IS TRUE
    ) THEN
      CONTINUE;
    END IF;

    BEGIN
      v_month_label := public.competition_gpsl_month_label(v_cal.gpsl_month);
    EXCEPTION WHEN OTHERS THEN
      v_month_label := initcap(v_cal.gpsl_month);
    END;

    IF to_regprocedure('public.competition_league_tables_snapshot(bigint)') IS NULL THEN
      CONTINUE;
    END IF;

    v_snap := public.competition_league_tables_snapshot(v_season_id);

    v_qid := public.gpsl_discord_feed_enqueue(
      'tables',
      format('📊 LEAGUE TABLES — %s', coalesce(v_month_label, initcap(v_cal.gpsl_month))),
      format(
        'End of %s standings for SuperLeague, Championship A and Championship B.',
        coalesce(v_month_label, initcap(v_cal.gpsl_month))
      ),
      5793266,
      'league_tables:' || v_season_id::text || ':' || v_cal.gpsl_month,
      jsonb_build_object(
        'channel', 'tables',
        'render', true,
        'season_id', v_season_id,
        'gpsl_month', v_cal.gpsl_month,
        'month_label', v_month_label,
        'standings', coalesce(v_snap->'standings', '[]'::jsonb)
      )
    );

    INSERT INTO public.competition_season_calendar_jobs (
      season_id, job_key, gpsl_month, result
    )
    VALUES (
      v_season_id, v_job_key, v_cal.gpsl_month,
      jsonb_build_object('ok', v_qid IS NOT NULL, 'queue_id', v_qid, 'enqueued_at', now())
    )
    ON CONFLICT (season_id, job_key) DO UPDATE
      SET result = excluded.result,
          gpsl_month = excluded.gpsl_month,
          ran_at = now();

    v_processed := v_processed || jsonb_build_array(
      jsonb_build_object('gpsl_month', v_cal.gpsl_month, 'queue_id', v_qid)
    );
  END LOOP;

  -- Whenever May is locked, ensure playoff brackets exist (not only on first tables job)
  IF EXISTS (
    SELECT 1
    FROM public.competition_season_calendar c
    WHERE c.season_id = v_season_id
      AND c.gpsl_month = 'may'
      AND c.lock_at IS NOT NULL
      AND c.lock_at <= now()
  ) THEN
    BEGIN
      v_playoffs := public.competition_generate_playoffs(v_season_id, false);
    EXCEPTION WHEN OTHERS THEN
      v_playoffs := jsonb_build_object('ok', false, 'error', SQLERRM);
    END;
  END IF;

  IF to_regprocedure('public.competition_process_league_clinches(bigint)') IS NOT NULL THEN
    BEGIN
      v_clinches := public.competition_process_league_clinches(v_season_id);
    EXCEPTION WHEN OTHERS THEN
      v_clinches := jsonb_build_object('ok', false, 'error', SQLERRM);
    END;
  END IF;

  BEGIN
    PERFORM public.gpsl_discord_feed_request_flush();
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;

  RETURN jsonb_build_object(
    'ok', true,
    'season_id', v_season_id,
    'processed', v_processed,
    'clinches', v_clinches,
    'playoffs', v_playoffs
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_process_month_league_tables(bigint)
  TO authenticated, service_role;

-- Cup label helper for playoff codes (best-effort; ignore if missing)
DO $$
BEGIN
  IF to_regprocedure('public.competition_cup_fixture_label(public.competition_fixtures)') IS NOT NULL THEN
    EXECUTE $q$
      CREATE OR REPLACE FUNCTION public.competition_cup_fixture_label(p_fixture public.competition_fixtures)
      RETURNS text
      LANGUAGE plpgsql
      STABLE
      AS $f$
      DECLARE
        v_code text := lower(coalesce(p_fixture.cup_code, ''));
      BEGIN
        IF v_code LIKE 'po_%' THEN
          RETURN CASE v_code
            WHEN 'po_sl_1617' THEN 'Super League Relegation Playoff Final — 16th vs 17th'
            WHEN 'po_ch_a' THEN
              CASE coalesce(p_fixture.cup_round, 0)
                WHEN 1 THEN
                  CASE coalesce(p_fixture.cup_match, 0)
                    WHEN 1 THEN 'Championship A Semi Final — 3rd vs 6th'
                    WHEN 2 THEN 'Championship A Semi Final — 4th vs 5th'
                    ELSE 'Championship A Semi Final'
                  END
                WHEN 2 THEN 'Championship A Final — semi-final winners'
                ELSE 'Championship A promotion playoff'
              END
            WHEN 'po_ch_b' THEN
              CASE coalesce(p_fixture.cup_round, 0)
                WHEN 1 THEN
                  CASE coalesce(p_fixture.cup_match, 0)
                    WHEN 1 THEN 'Championship B Semi Final — 3rd vs 6th'
                    WHEN 2 THEN 'Championship B Semi Final — 4th vs 5th'
                    ELSE 'Championship B Semi Final'
                  END
                WHEN 2 THEN 'Championship B Final — semi-final winners'
                ELSE 'Championship B promotion playoff'
              END
            WHEN 'po_ch_sb_a' THEN 'Championship A Shield Playoff Final — 16th vs 17th'
            WHEN 'po_ch_sb_b' THEN 'Championship B Shield Playoff Final — 16th vs 17th'
            WHEN 'po_ch_final' THEN 'Championship Playoff Final — Championship A final winner vs Championship B final winner'
            WHEN 'po_sl_final' THEN 'Super League Playoff Final — relegation playoff winner vs Championship Playoff Final winner'
            ELSE 'Playoff'
          END;
        END IF;
        RETURN coalesce(
          nullif(btrim(
            CASE v_code
              WHEN 'super8' THEN 'Super8'
              WHEN 'plate' THEN 'Plate'
              WHEN 'shield' THEN 'Shield'
              WHEN 'bowl' THEN 'Bowl'
              WHEN 'league_cup' THEN 'League Cup'
              ELSE initcap(replace(v_code, '_', ' '))
            END
            || CASE WHEN p_fixture.cup_round IS NOT NULL THEN ' R' || p_fixture.cup_round::text ELSE '' END
            || CASE WHEN p_fixture.cup_match IS NOT NULL THEN ' M' || p_fixture.cup_match::text ELSE '' END
          ), ''),
          'Cup'
        );
      END;
      $f$;
    $q$;
  END IF;
EXCEPTION WHEN OTHERS THEN
  NULL;
END $$;

-- Natter: no new posts in Playoffs week (May was last programme month)
CREATE OR REPLACE FUNCTION public.natter_compose_open()
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season_id bigint;
  v_status text;
  v_month text;
BEGIN
  SELECT s.id, s.status
  INTO v_season_id, v_status
  FROM public.competition_seasons s
  WHERE s.is_current = true
  ORDER BY s.id DESC
  LIMIT 1;

  IF v_season_id IS NULL THEN
    RETURN false;
  END IF;

  IF lower(coalesce(v_status, '')) = 'preseason' THEN
    RETURN true;
  END IF;

  v_month := public.competition_active_gpsl_month(v_season_id, now());
  IF v_month IS NULL OR btrim(v_month) = '' THEN
    RETURN false;
  END IF;
  -- Playoffs week is knockout-only; Natter stays on Aug–May
  IF lower(v_month) = 'playoffs' THEN
    RETURN false;
  END IF;
  RETURN true;
END;
$function$;

-- Sport "previous month" for club news: Playoffs edition would look at May Natters
CREATE OR REPLACE FUNCTION public.gpsl_sport_previous_gpsl_month(p_month text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE public.competition_gpsl_month_sort(lower(btrim(p_month)))
    WHEN 2 THEN 'august'
    WHEN 3 THEN 'september'
    WHEN 4 THEN 'october'
    WHEN 5 THEN 'november'
    WHEN 6 THEN 'december'
    WHEN 7 THEN 'january'
    WHEN 8 THEN 'february'
    WHEN 9 THEN 'march'
    WHEN 10 THEN 'april'
    WHEN 11 THEN 'may'
    WHEN 1 THEN 'july'
    ELSE NULL
  END;
$$;

NOTIFY pgrst, 'reload schema';
