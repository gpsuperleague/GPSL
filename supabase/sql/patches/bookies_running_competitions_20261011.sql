-- =============================================================================
-- Bookies: only competitions that are actually running can be bet on
--
-- A market is "running" when its draw exists this season:
--   • League champion markets  → league fixtures drawn for that division
--   • Cup winner markets       → cup fixtures drawn for that cup
--                                (only clubs in that cup's draw can be backed)
--   • Top scorer (all divs)    → any league fixtures drawn
--   • League Cup top scorer    → League Cup drawn
--   • Prestige cups top scorer → any of Super 8 / Plate / Shield / Bowl drawn
--   • World Cup top scorer     → international fixtures exist this season
-- Not running → greyed out on the Bookies page and bets are rejected.
-- Enforced by a BEFORE INSERT trigger on bookies_bets. Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.bookies_market_state(p_market_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  m public.bookies_markets%rowtype;
  v_code text;
  v_div text;
  v_cup text;
  v_running boolean := true;
  v_reason text := NULL;
  v_clubs text[] := NULL;
BEGIN
  SELECT * INTO m FROM public.bookies_markets WHERE id = p_market_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('market_id', p_market_id, 'running', false, 'reason', 'Market not found');
  END IF;

  v_code := lower(coalesce(m.market_code, ''));
  v_div := nullif(btrim(coalesce(m.metadata->>'division', '')), '');

  IF v_code LIKE 'league_%' AND v_div IS NOT NULL THEN
    v_running := EXISTS (
      SELECT 1 FROM public.competition_fixtures f
      WHERE f.season_id = m.season_id
        AND coalesce(f.competition_type, 'league') = 'league'
        AND f.division = v_div
    );
    v_reason := CASE WHEN v_running THEN NULL ELSE 'League not drawn yet' END;

  ELSIF v_code LIKE 'cup_%' THEN
    v_cup := substring(v_code FROM 5);
    SELECT array_agg(DISTINCT upper(x))
    INTO v_clubs
    FROM (
      SELECT f.home_club_short_name AS x FROM public.competition_fixtures f
      WHERE f.season_id = m.season_id AND f.competition_type = 'cup'
        AND lower(coalesce(f.cup_code, '')) = v_cup
      UNION ALL
      SELECT f.away_club_short_name FROM public.competition_fixtures f
      WHERE f.season_id = m.season_id AND f.competition_type = 'cup'
        AND lower(coalesce(f.cup_code, '')) = v_cup
    ) s
    WHERE nullif(btrim(coalesce(x, '')), '') IS NOT NULL;
    v_running := coalesce(cardinality(v_clubs), 0) > 0;
    v_reason := CASE WHEN v_running THEN NULL ELSE 'Cup draw not made yet' END;

  ELSIF v_code = 'scorer_overall' THEN
    v_running := EXISTS (
      SELECT 1 FROM public.competition_fixtures f
      WHERE f.season_id = m.season_id
        AND coalesce(f.competition_type, 'league') = 'league'
    );
    v_reason := CASE WHEN v_running THEN NULL ELSE 'Leagues not drawn yet' END;

  ELSIF v_code = 'scorer_league_cup' THEN
    v_running := EXISTS (
      SELECT 1 FROM public.competition_fixtures f
      WHERE f.season_id = m.season_id AND f.competition_type = 'cup'
        AND lower(coalesce(f.cup_code, '')) = 'league_cup'
    );
    v_reason := CASE WHEN v_running THEN NULL ELSE 'League Cup draw not made yet' END;

  ELSIF v_code = 'scorer_prestige' THEN
    v_running := EXISTS (
      SELECT 1 FROM public.competition_fixtures f
      WHERE f.season_id = m.season_id AND f.competition_type = 'cup'
        AND lower(coalesce(f.cup_code, '')) IN ('super8', 'plate', 'shield', 'bowl')
    );
    v_reason := CASE WHEN v_running THEN NULL ELSE 'Prestige cup draws not made yet' END;

  ELSIF v_code = 'scorer_world_cup' THEN
    IF to_regclass('public.international_fixtures') IS NOT NULL THEN
      EXECUTE 'SELECT EXISTS (SELECT 1 FROM public.international_fixtures WHERE season_id = $1)'
        INTO v_running USING m.season_id;
    ELSE
      v_running := false;
    END IF;
    v_reason := CASE WHEN v_running THEN NULL ELSE 'World Cup not running this season' END;
  END IF;

  RETURN jsonb_build_object(
    'market_id', m.id,
    'running', coalesce(v_running, false),
    'reason', v_reason,
    'cup_clubs', to_jsonb(v_clubs)
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.bookies_market_state(bigint) FROM PUBLIC;

-- Page: states for every current-season market
CREATE OR REPLACE FUNCTION public.bookies_market_states()
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
  SELECT coalesce(jsonb_agg(public.bookies_market_state(m.id) ORDER BY m.id), '[]'::jsonb)
  FROM public.bookies_markets m
  WHERE m.season_id = (
    SELECT id FROM public.competition_seasons WHERE is_current = true ORDER BY id DESC LIMIT 1
  );
$function$;

GRANT EXECUTE ON FUNCTION public.bookies_market_states() TO authenticated;

CREATE OR REPLACE FUNCTION public.trg_bookies_bets_block_not_running()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_state jsonb;
  v_key text;
BEGIN
  v_state := public.bookies_market_state(NEW.market_id);
  IF NOT coalesce((v_state->>'running')::boolean, false) THEN
    RAISE EXCEPTION 'This competition isn''t running yet (%) — betting opens once the draw is made',
      coalesce(v_state->>'reason', 'not drawn');
  END IF;

  IF jsonb_typeof(v_state->'cup_clubs') = 'array' THEN
    SELECT upper(btrim(s.selection_key)) INTO v_key
    FROM public.bookies_selections s WHERE s.id = NEW.selection_id;
    IF NOT (v_state->'cup_clubs') ? v_key THEN
      RAISE EXCEPTION 'That club isn''t in this cup''s draw';
    END IF;
  END IF;

  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS bookies_bets_01_block_not_running ON public.bookies_bets;
CREATE TRIGGER bookies_bets_01_block_not_running
  BEFORE INSERT ON public.bookies_bets
  FOR EACH ROW EXECUTE FUNCTION public.trg_bookies_bets_block_not_running();

NOTIFY pgrst, 'reload schema';

-- Report: each market and whether it's open for betting now
SELECT m.id, m.title, m.status,
       (s.st->>'running')::boolean AS running,
       s.st->>'reason' AS reason,
       jsonb_array_length(coalesce(s.st->'cup_clubs', '[]'::jsonb)) AS cup_clubs_in_draw
FROM public.bookies_markets m
CROSS JOIN LATERAL (SELECT public.bookies_market_state(m.id) AS st) s
WHERE m.season_id = (SELECT id FROM public.competition_seasons WHERE is_current = true ORDER BY id DESC LIMIT 1)
ORDER BY m.id;
