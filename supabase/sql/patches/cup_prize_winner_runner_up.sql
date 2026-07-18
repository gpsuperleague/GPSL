-- =============================================================================
-- Cup finals: winner + runner_up prize stages (instead of shared "final" fee).
-- Earlier rounds (r1/r2/qf/sf) still pay the same amount to both clubs.
-- Legacy "final" config still pays both clubs if winner/runner_up are unset.
-- Safe to re-run.
-- =============================================================================

ALTER TABLE public.competition_cup_prize_config
  DROP CONSTRAINT IF EXISTS competition_cup_prize_config_stage_check;

ALTER TABLE public.competition_cup_prize_config
  ADD CONSTRAINT competition_cup_prize_config_stage_check
  CHECK (
    stage IN (
      'appearance',
      'r1',
      'r2',
      'qf',
      'sf',
      'final',
      'winner',
      'runner_up'
    )
  );

-- Migrate existing Final amounts → Winner when Winner is missing
INSERT INTO public.competition_cup_prize_config (season_id, cup_code, stage, amount)
SELECT c.season_id, c.cup_code, 'winner', c.amount
FROM public.competition_cup_prize_config c
WHERE c.stage = 'final'
  AND c.amount > 0
  AND NOT EXISTS (
    SELECT 1
    FROM public.competition_cup_prize_config w
    WHERE w.season_id = c.season_id
      AND w.cup_code = c.cup_code
      AND w.stage = 'winner'
  )
ON CONFLICT (season_id, cup_code, stage) DO NOTHING;

-- Drop legacy Final rows once Winner exists for that cup/season
-- (safe: finals now pay winner / runner_up; Final was only a fallback)
DELETE FROM public.competition_cup_prize_config f
WHERE f.stage = 'final'
  AND EXISTS (
    SELECT 1
    FROM public.competition_cup_prize_config w
    WHERE w.season_id = f.season_id
      AND w.cup_code = f.cup_code
      AND w.stage = 'winner'
  );

CREATE OR REPLACE FUNCTION public.competition_admin_set_cup_prize(
  p_season_id bigint,
  p_cup_code text,
  p_stage text,
  p_amount numeric
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF p_stage NOT IN (
    'appearance', 'r1', 'r2', 'qf', 'sf', 'final', 'winner', 'runner_up'
  ) THEN
    RAISE EXCEPTION
      'Invalid stage %. Use: appearance, r1, r2, qf, sf, winner, runner_up (final kept for legacy)',
      p_stage;
  END IF;

  INSERT INTO public.competition_cup_prize_config (season_id, cup_code, stage, amount)
  VALUES (p_season_id, p_cup_code, p_stage, coalesce(p_amount, 0))
  ON CONFLICT (season_id, cup_code, stage)
  DO UPDATE SET amount = excluded.amount;
END;
$function$;

CREATE OR REPLACE FUNCTION public.competition_pay_cup_fixture_prizes(p_fixture_id bigint)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_fixture public.competition_fixtures;
  v_max_round int;
  v_stage text;
  v_amount numeric;
  v_winner_amt numeric;
  v_runner_amt numeric;
  v_club text;
  v_winner text;
  v_loser text;
  v_cup_label text;
  v_stage_label text;
  v_has_result_prize boolean := false;
BEGIN
  SELECT * INTO v_fixture
  FROM public.competition_fixtures
  WHERE id = p_fixture_id AND competition_type = 'cup';

  IF NOT FOUND THEN
    RETURN;
  END IF;

  IF v_fixture.home_goals IS NOT DISTINCT FROM v_fixture.away_goals
     AND coalesce(btrim(v_fixture.cup_pen_winner_club_short_name), '') = '' THEN
    RETURN;
  END IF;

  SELECT max(round_no) INTO v_max_round
  FROM public.competition_cup_bracket_nodes
  WHERE season_id = v_fixture.season_id AND cup_code = v_fixture.cup_code;

  v_stage := public.competition_cup_round_stage(
    v_fixture.cup_code,
    v_fixture.cup_round,
    coalesce(v_max_round, v_fixture.cup_round)
  );

  v_cup_label := upper(replace(coalesce(v_fixture.cup_code, 'cup'), '_', ' '));
  v_stage_label := CASE v_stage
    WHEN 'r1' THEN 'Round 1'
    WHEN 'r2' THEN 'Round 2'
    WHEN 'qf' THEN 'Quarter-final'
    WHEN 'sf' THEN 'Semi-final'
    WHEN 'final' THEN 'Final'
    ELSE v_stage
  END;

  FOREACH v_club IN ARRAY ARRAY[v_fixture.home_club_short_name, v_fixture.away_club_short_name]
  LOOP
    SELECT amount INTO v_amount
    FROM public.competition_cup_prize_config
    WHERE season_id = v_fixture.season_id
      AND cup_code = v_fixture.cup_code
      AND stage = 'appearance';

    IF v_amount IS NOT NULL AND v_amount > 0 THEN
      PERFORM public.competition_cup_credit_round_prize(
        p_fixture_id,
        v_club,
        'appearance',
        v_amount,
        format('%s appearance — %s', v_cup_label, public.competition_cup_fixture_label(v_fixture)),
        jsonb_build_object('cup_code', v_fixture.cup_code, 'stage', 'appearance')
      );
    END IF;
  END LOOP;

  IF v_stage = 'final' THEN
    IF coalesce(btrim(v_fixture.cup_pen_winner_club_short_name), '') <> '' THEN
      v_winner := btrim(v_fixture.cup_pen_winner_club_short_name);
    ELSIF v_fixture.home_goals > v_fixture.away_goals THEN
      v_winner := v_fixture.home_club_short_name;
    ELSIF v_fixture.away_goals > v_fixture.home_goals THEN
      v_winner := v_fixture.away_club_short_name;
    ELSE
      RETURN;
    END IF;

    IF v_winner = v_fixture.home_club_short_name THEN
      v_loser := v_fixture.away_club_short_name;
    ELSE
      v_loser := v_fixture.home_club_short_name;
    END IF;

    SELECT amount INTO v_winner_amt
    FROM public.competition_cup_prize_config
    WHERE season_id = v_fixture.season_id
      AND cup_code = v_fixture.cup_code
      AND stage = 'winner';

    SELECT amount INTO v_runner_amt
    FROM public.competition_cup_prize_config
    WHERE season_id = v_fixture.season_id
      AND cup_code = v_fixture.cup_code
      AND stage = 'runner_up';

    IF v_winner_amt IS NOT NULL AND v_winner_amt > 0 THEN
      v_has_result_prize := true;
      PERFORM public.competition_cup_credit_round_prize(
        p_fixture_id,
        v_winner,
        'winner',
        v_winner_amt,
        format('%s Winner — %s', v_cup_label, public.competition_cup_fixture_label(v_fixture)),
        jsonb_build_object('cup_code', v_fixture.cup_code, 'stage', 'winner')
      );
    END IF;

    IF v_runner_amt IS NOT NULL AND v_runner_amt > 0 THEN
      v_has_result_prize := true;
      PERFORM public.competition_cup_credit_round_prize(
        p_fixture_id,
        v_loser,
        'runner_up',
        v_runner_amt,
        format('%s Runner-up — %s', v_cup_label, public.competition_cup_fixture_label(v_fixture)),
        jsonb_build_object('cup_code', v_fixture.cup_code, 'stage', 'runner_up')
      );
    END IF;

    -- Legacy: shared Final amount to both clubs if winner/runner_up not configured
    IF NOT v_has_result_prize THEN
      SELECT amount INTO v_amount
      FROM public.competition_cup_prize_config
      WHERE season_id = v_fixture.season_id
        AND cup_code = v_fixture.cup_code
        AND stage = 'final';

      IF v_amount IS NOT NULL AND v_amount > 0 THEN
        FOREACH v_club IN ARRAY ARRAY[v_fixture.home_club_short_name, v_fixture.away_club_short_name]
        LOOP
          PERFORM public.competition_cup_credit_round_prize(
            p_fixture_id,
            v_club,
            'final',
            v_amount,
            format('%s Final — %s', v_cup_label, public.competition_cup_fixture_label(v_fixture)),
            jsonb_build_object('cup_code', v_fixture.cup_code, 'stage', 'final')
          );
        END LOOP;
      END IF;
    END IF;

    RETURN;
  END IF;

  -- Non-final rounds: same amount to both clubs
  SELECT amount INTO v_amount
  FROM public.competition_cup_prize_config
  WHERE season_id = v_fixture.season_id
    AND cup_code = v_fixture.cup_code
    AND stage = v_stage;

  IF v_amount IS NOT NULL AND v_amount > 0 THEN
    FOREACH v_club IN ARRAY ARRAY[v_fixture.home_club_short_name, v_fixture.away_club_short_name]
    LOOP
      PERFORM public.competition_cup_credit_round_prize(
        p_fixture_id,
        v_club,
        v_stage,
        v_amount,
        format('%s %s — %s', v_cup_label, v_stage_label, public.competition_cup_fixture_label(v_fixture)),
        jsonb_build_object('cup_code', v_fixture.cup_code, 'stage', v_stage)
      );
    END LOOP;
  END IF;
END;
$function$;

CREATE OR REPLACE FUNCTION public.competition_admin_award_cup_round_prize(
  p_fixture_id bigint,
  p_club_short_name text,
  p_stage text DEFAULT NULL,
  p_note text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_fixture public.competition_fixtures;
  v_max_round int;
  v_stage text;
  v_amount numeric;
  v_cup_label text;
  v_stage_label text;
  v_desc text;
  v_paid boolean;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  SELECT * INTO v_fixture
  FROM public.competition_fixtures
  WHERE id = p_fixture_id AND competition_type = 'cup';

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Cup fixture % not found', p_fixture_id;
  END IF;

  IF p_stage IS NOT NULL AND btrim(p_stage) <> '' THEN
    v_stage := btrim(p_stage);
  ELSE
    SELECT max(round_no) INTO v_max_round
    FROM public.competition_cup_bracket_nodes
    WHERE season_id = v_fixture.season_id AND cup_code = v_fixture.cup_code;

    v_stage := public.competition_cup_round_stage(
      v_fixture.cup_code,
      v_fixture.cup_round,
      coalesce(v_max_round, v_fixture.cup_round)
    );
  END IF;

  IF v_stage NOT IN (
    'appearance', 'r1', 'r2', 'qf', 'sf', 'final', 'winner', 'runner_up'
  ) THEN
    RAISE EXCEPTION 'Invalid stage %', v_stage;
  END IF;

  SELECT amount INTO v_amount
  FROM public.competition_cup_prize_config
  WHERE season_id = v_fixture.season_id
    AND cup_code = v_fixture.cup_code
    AND stage = v_stage;

  IF v_amount IS NULL OR v_amount <= 0 THEN
    RAISE EXCEPTION 'No prize configured for % / % / stage %',
      v_fixture.cup_code, v_fixture.season_id, v_stage;
  END IF;

  v_cup_label := upper(replace(coalesce(v_fixture.cup_code, 'cup'), '_', ' '));
  v_stage_label := CASE v_stage
    WHEN 'r1' THEN 'Round 1'
    WHEN 'r2' THEN 'Round 2'
    WHEN 'qf' THEN 'Quarter-final'
    WHEN 'sf' THEN 'Semi-final'
    WHEN 'final' THEN 'Final'
    WHEN 'winner' THEN 'Winner'
    WHEN 'runner_up' THEN 'Runner-up'
    WHEN 'appearance' THEN 'Appearance'
    ELSE v_stage
  END;

  v_desc := format('%s %s — %s (admin award)', v_cup_label, v_stage_label, public.competition_cup_fixture_label(v_fixture));
  IF p_note IS NOT NULL AND btrim(p_note) <> '' THEN
    v_desc := v_desc || ' — ' || btrim(p_note);
  END IF;

  v_paid := public.competition_cup_credit_round_prize(
    p_fixture_id,
    p_club_short_name,
    v_stage,
    v_amount,
    v_desc,
    jsonb_build_object(
      'cup_code', v_fixture.cup_code,
      'stage', v_stage,
      'admin_override', true,
      'note', p_note
    )
  );

  RETURN jsonb_build_object(
    'fixture_id', p_fixture_id,
    'club_short_name', p_club_short_name,
    'stage', v_stage,
    'amount', v_amount,
    'paid', v_paid
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_admin_set_cup_prize(bigint, text, text, numeric) TO authenticated;
GRANT EXECUTE ON FUNCTION public.competition_admin_award_cup_round_prize(bigint, text, text, text) TO authenticated;

NOTIFY pgrst, 'reload schema';
