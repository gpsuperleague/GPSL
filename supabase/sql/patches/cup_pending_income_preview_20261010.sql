-- =============================================================================
-- Predicted end-of-season balance: cup money for ties a club is already drawn in
--
-- competition_club_cup_pending_preview(club) lists every scheduled cup fixture
-- (both clubs known, not yet played) and what the club is guaranteed from it:
--   • prize  — appearance + round prize (paid to BOTH clubs per fixture).
--              Final: the smaller of winner / runner-up (the loser still gets
--              runner-up); if no result prizes are set, the 'final' amount.
--   • gate   — 50% share of the home club's gate at an assumed 80% fill
--              (capacity × 80% × ₿20 ÷ 2). Finals: sellout at the final venue.
-- Skips anything already paid. Future rounds not yet drawn are not counted.
--
-- Read-only function. Safe to re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.competition_club_cup_pending_preview(p_club_short_name text)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := btrim(coalesce(p_club_short_name, ''));
  v_season_id bigint;
  v_fill numeric := 0.80;
  v_price numeric := 20;
  v_final_cap int;
  v_rows jsonb := '[]'::jsonb;
  v_prize_total numeric := 0;
  v_gate_total numeric := 0;
  f public.competition_fixtures%rowtype;
  v_max_round int;
  v_stage text;
  v_is_final boolean;
  v_appear numeric;
  v_stage_amt numeric;
  v_winner numeric;
  v_runner numeric;
  v_prize numeric;
  v_cap int;
  v_gate numeric;
  v_home boolean;
BEGIN
  IF v_club = '' THEN
    RETURN jsonb_build_object('fixtures', '[]'::jsonb, 'prize_total', 0, 'gate_total', 0);
  END IF;

  SELECT s.id INTO v_season_id
  FROM public.competition_seasons s
  WHERE s.is_current = true
  ORDER BY s.id DESC
  LIMIT 1;

  IF v_season_id IS NULL THEN
    RETURN jsonb_build_object('fixtures', '[]'::jsonb, 'prize_total', 0, 'gate_total', 0);
  END IF;

  SELECT greatest(coalesce(gs.cup_final_venue_capacity, 90000), 1)
  INTO v_final_cap
  FROM public.global_settings gs
  WHERE gs.id = 1;
  v_final_cap := coalesce(v_final_cap, 90000);

  FOR f IN
    SELECT *
    FROM public.competition_fixtures x
    WHERE x.season_id = v_season_id
      AND x.competition_type = 'cup'
      AND x.status = 'scheduled'
      AND x.home_club_short_name IS NOT NULL
      AND x.away_club_short_name IS NOT NULL
      AND v_club IN (x.home_club_short_name, x.away_club_short_name)
      AND lower(coalesce(x.cup_code, '')) NOT LIKE 'po\_%' ESCAPE '\'
    ORDER BY x.cup_code, x.cup_round, coalesce(x.cup_leg, 1), x.id
  LOOP
    v_home := f.home_club_short_name = v_club;

    SELECT max(n.round_no) INTO v_max_round
    FROM public.competition_cup_bracket_nodes n
    WHERE n.season_id = f.season_id AND n.cup_code = f.cup_code;

    v_stage := public.competition_cup_round_stage(
      f.cup_code, f.cup_round, coalesce(v_max_round, f.cup_round)
    );
    v_is_final := public.competition_fixture_is_cup_final(f);

    -- Prize (skip if this club was already paid for this fixture)
    v_prize := 0;
    IF NOT EXISTS (
      SELECT 1 FROM public.competition_cup_prize_paid p
      WHERE p.fixture_id = f.id AND p.club_short_name = v_club
    ) THEN
      SELECT c.amount INTO v_appear
      FROM public.competition_cup_prize_config c
      WHERE c.season_id = f.season_id AND c.cup_code = f.cup_code AND c.stage = 'appearance';

      IF v_stage = 'final' THEN
        SELECT c.amount INTO v_winner
        FROM public.competition_cup_prize_config c
        WHERE c.season_id = f.season_id AND c.cup_code = f.cup_code AND c.stage = 'winner';
        SELECT c.amount INTO v_runner
        FROM public.competition_cup_prize_config c
        WHERE c.season_id = f.season_id AND c.cup_code = f.cup_code AND c.stage = 'runner_up';

        IF coalesce(v_winner, 0) > 0 OR coalesce(v_runner, 0) > 0 THEN
          v_stage_amt := least(coalesce(v_winner, 0), coalesce(v_runner, 0));
        ELSE
          SELECT c.amount INTO v_stage_amt
          FROM public.competition_cup_prize_config c
          WHERE c.season_id = f.season_id AND c.cup_code = f.cup_code AND c.stage = 'final';
        END IF;
      ELSE
        SELECT c.amount INTO v_stage_amt
        FROM public.competition_cup_prize_config c
        WHERE c.season_id = f.season_id AND c.cup_code = f.cup_code AND c.stage = v_stage;
      END IF;

      v_prize := greatest(coalesce(v_appear, 0), 0) + greatest(coalesce(v_stage_amt, 0), 0);
    END IF;

    -- Gate share (skip if gates for this fixture are already posted)
    v_gate := 0;
    v_cap := NULL;
    IF NOT EXISTS (
      SELECT 1 FROM public.competition_finance_ledger l
      WHERE l.fixture_id = f.id AND l.entry_type = 'gate_cup_share'
    ) THEN
      IF v_is_final THEN
        v_cap := coalesce(nullif(f.venue_capacity, 0), v_final_cap);
        v_gate := round(v_cap * 1.0 * v_price / 2.0);
      ELSE
        SELECT coalesce(c."Capacity", 0)::int INTO v_cap
        FROM public."Clubs" c
        WHERE c."ShortName" = f.home_club_short_name;
        v_gate := round(coalesce(v_cap, 0) * v_fill * v_price / 2.0);
      END IF;
    END IF;

    IF v_prize > 0 OR v_gate > 0 THEN
      v_prize_total := v_prize_total + v_prize;
      v_gate_total := v_gate_total + v_gate;
      v_rows := v_rows || jsonb_build_array(jsonb_build_object(
        'fixture_id', f.id,
        'cup_code', f.cup_code,
        'cup_round', f.cup_round,
        'cup_leg', f.cup_leg,
        'stage', v_stage,
        'is_final', v_is_final,
        'home', v_home,
        'opponent', CASE WHEN v_home THEN f.away_club_short_name ELSE f.home_club_short_name END,
        'gate_capacity', v_cap,
        'prize', v_prize,
        'gate_share', v_gate
      ));
    END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'fixtures', v_rows,
    'prize_total', v_prize_total,
    'gate_total', v_gate_total,
    'fill_pct', round(v_fill * 100),
    'price_per_seat', v_price
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_club_cup_pending_preview(text) TO authenticated;

NOTIFY pgrst, 'reload schema';

-- Report: every club with drawn-but-unplayed cup ties
SELECT r.club, r.ties, r.prize_total, r.gate_total
FROM (SELECT 1) one
LEFT JOIN (
  SELECT c."ShortName" AS club,
         jsonb_array_length(p -> 'fixtures') AS ties,
         (p ->> 'prize_total')::numeric AS prize_total,
         (p ->> 'gate_total')::numeric AS gate_total
  FROM public."Clubs" c
  CROSS JOIN LATERAL (SELECT public.competition_club_cup_pending_preview(c."ShortName") AS p) x
  WHERE jsonb_array_length(p -> 'fixtures') > 0
) r ON true
ORDER BY r.prize_total + r.gate_total DESC NULLS LAST;
