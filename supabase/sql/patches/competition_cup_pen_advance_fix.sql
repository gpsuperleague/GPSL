-- =============================================================================
-- Fix: cup pen shootout winners must advance in the bracket (Shield etc.)
--
-- Bug: competition_cup_on_fixture_played returned early when home_goals =
-- away_goals, ignoring cup_pen_winner_club_short_name. Deploy Month correctly
-- stored the pen winner (e.g. Chelsea beat Sporting on pens) but never set
-- bracket winner / filled the next round → "Kasimpasa awaiting opponent".
--
-- Also keeps two-leg aggregate + pen fallback (Super8 / Bowl).
-- Safe re-run. Then Force fill bracket on Shield (and any other affected cup).
-- =============================================================================

CREATE OR REPLACE FUNCTION public.competition_cup_on_fixture_played(p_fixture_id bigint)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_fixture public.competition_fixtures;
  v_node public.competition_cup_bracket_nodes;
  v_leg1_node public.competition_cup_bracket_nodes;
  v_leg1_fixture public.competition_fixtures;
  v_winner text;
  v_tie_home text;
  v_tie_away text;
  v_pen text;
BEGIN
  SELECT * INTO v_fixture
  FROM public.competition_fixtures
  WHERE id = p_fixture_id;

  IF NOT FOUND OR v_fixture.competition_type <> 'cup' THEN
    RETURN;
  END IF;

  IF v_fixture.home_goals IS NULL OR v_fixture.away_goals IS NULL THEN
    RETURN;
  END IF;

  SELECT * INTO v_node
  FROM public.competition_cup_bracket_nodes
  WHERE fixture_id = p_fixture_id;

  IF NOT FOUND THEN
    -- Still pay prizes if config exists
    PERFORM public.competition_pay_cup_fixture_prizes(p_fixture_id);
    RETURN;
  END IF;

  v_pen := nullif(btrim(coalesce(v_fixture.cup_pen_winner_club_short_name, '')), '');

  -- -------------------------------------------------------------------------
  -- Two-legged: this fixture is leg 2
  -- -------------------------------------------------------------------------
  IF v_node.leg1_node_id IS NOT NULL THEN
    SELECT * INTO v_leg1_node
    FROM public.competition_cup_bracket_nodes
    WHERE id = v_node.leg1_node_id;

    SELECT * INTO v_leg1_fixture
    FROM public.competition_fixtures
    WHERE id = v_leg1_node.fixture_id;

    IF v_leg1_fixture.id IS NULL OR v_leg1_fixture.status <> 'played'
       OR v_leg1_fixture.home_goals IS NULL OR v_leg1_fixture.away_goals IS NULL THEN
      PERFORM public.competition_pay_cup_fixture_prizes(p_fixture_id);
      RETURN;
    END IF;

    v_tie_home := v_leg1_node.home_club_short_name;
    v_tie_away := v_leg1_node.away_club_short_name;

    v_winner := public.competition_cup_two_leg_winner(
      v_leg1_fixture.home_goals,
      v_leg1_fixture.away_goals,
      v_fixture.home_goals,
      v_fixture.away_goals,
      v_tie_home,
      v_tie_away,
      v_fixture.home_club_short_name,
      v_fixture.away_club_short_name
    );

    IF v_winner IS NULL THEN
      v_winner := v_pen;
    END IF;

    IF v_winner IS NULL THEN
      v_winner := nullif(btrim(coalesce(v_leg1_fixture.cup_pen_winner_club_short_name, '')), '');
    END IF;

    IF v_winner IS NULL THEN
      PERFORM public.competition_pay_cup_fixture_prizes(p_fixture_id);
      RETURN;
    END IF;

    UPDATE public.competition_cup_bracket_nodes
    SET winner_club_short_name = v_winner
    WHERE id = v_node.id;

    PERFORM public.competition_cup_advance_node_winner(v_node.id);
    PERFORM public.competition_pay_cup_fixture_prizes(p_fixture_id);
    RETURN;
  END IF;

  -- -------------------------------------------------------------------------
  -- Two-legged: this fixture is leg 1 only — wait for leg 2
  -- -------------------------------------------------------------------------
  IF EXISTS (
    SELECT 1
    FROM public.competition_cup_bracket_nodes leg2
    WHERE leg2.leg1_node_id = v_node.id
  ) THEN
    PERFORM public.competition_pay_cup_fixture_prizes(p_fixture_id);
    RETURN;
  END IF;

  -- -------------------------------------------------------------------------
  -- Single-leg (Shield / Plate / League Cup rounds): score or pens
  -- -------------------------------------------------------------------------
  IF v_fixture.home_goals > v_fixture.away_goals THEN
    v_winner := v_fixture.home_club_short_name;
  ELSIF v_fixture.away_goals > v_fixture.home_goals THEN
    v_winner := v_fixture.away_club_short_name;
  ELSIF v_pen IS NOT NULL THEN
    v_winner := v_pen;
  ELSE
    -- Level and no pen winner yet — cannot advance
    PERFORM public.competition_pay_cup_fixture_prizes(p_fixture_id);
    RETURN;
  END IF;

  UPDATE public.competition_cup_bracket_nodes
  SET winner_club_short_name = v_winner
  WHERE id = v_node.id;

  PERFORM public.competition_cup_advance_node_winner(v_node.id);
  PERFORM public.competition_pay_cup_fixture_prizes(p_fixture_id);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_cup_on_fixture_played(bigint) TO authenticated;

NOTIFY pgrst, 'reload schema';

-- Repair existing Shield (and any cup) after applying:
--   SELECT public.competition_cup_repair_force_fill(NULL, 'shield');
-- Or Admin → Setup Cups → Shield → Force fill bracket
