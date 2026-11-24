-- Super 8 and Bowl (season 2 groups): extra prize stages.
-- Appearance is still paid per match to both clubs.
-- A loss has no stage and pays nothing extra.
-- group_win / group_draw are extras on the two-match tie.
-- group_qualify / group_exit are paid when the group is settled.
-- sf, winner, and runner_up stay as they are.
-- Season 1 knockout schedule is not changed here.

BEGIN;

ALTER TABLE public.competition_cup_prize_config
  DROP CONSTRAINT IF EXISTS competition_cup_prize_config_stage_check;

ALTER TABLE public.competition_cup_prize_config
  ADD CONSTRAINT competition_cup_prize_config_stage_check
  CHECK (
    stage = ANY (
      ARRAY[
        'appearance',
        'r1',
        'r2',
        'r32',
        'r16',
        'qf',
        'sf',
        'final',
        'winner',
        'runner_up',
        'group_win',
        'group_draw',
        'group_qualify',
        'group_exit'
      ]::text[]
    )
  );

CREATE OR REPLACE FUNCTION public.competition_cup_prize_stage_label(p_stage text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE lower(coalesce(p_stage, ''))
    WHEN 'appearance' THEN 'Appearance (each match)'
    WHEN 'r1' THEN 'Last 64 / Round 1'
    WHEN 'r2' THEN 'Last 16 / Round 2'
    WHEN 'r32' THEN 'Last 32'
    WHEN 'r16' THEN 'Last 16'
    WHEN 'qf' THEN 'Quarter-final'
    WHEN 'sf' THEN 'Semi-final appearance'
    WHEN 'final' THEN 'Final'
    WHEN 'winner' THEN 'Winner'
    WHEN 'runner_up' THEN 'Runner-up'
    WHEN 'group_win' THEN 'Group win (extra)'
    WHEN 'group_draw' THEN 'Group draw (extra)'
    WHEN 'group_qualify' THEN 'Qualify from group'
    WHEN 'group_exit' THEN 'Did not qualify'
    ELSE coalesce(p_stage, '')
  END;
$$;

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
    'appearance', 'r1', 'r2', 'r32', 'r16', 'qf', 'sf', 'final',
    'winner', 'runner_up',
    'group_win', 'group_draw', 'group_qualify', 'group_exit'
  ) THEN
    RAISE EXCEPTION
      'Invalid stage %. Use: appearance, r1, r2, r32, r16, qf, sf, winner, runner_up, group_win, group_draw, group_qualify, group_exit',
      p_stage;
  END IF;

  IF p_cup_code = 'league_cup' AND p_stage = 'r2' THEN
    RAISE EXCEPTION
      'League Cup no longer uses stage r2. Use r1 (Last 64), r32 (Last 32), r16 (Last 16).';
  END IF;

  INSERT INTO public.competition_cup_prize_config (season_id, cup_code, stage, amount)
  VALUES (p_season_id, p_cup_code, p_stage, coalesce(p_amount, 0))
  ON CONFLICT (season_id, cup_code, stage)
  DO UPDATE SET amount = excluded.amount;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_admin_set_cup_prize(bigint, text, text, numeric)
  TO authenticated;

-- Manual award must accept the new stages too.
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

  IF p_club_short_name NOT IN (v_fixture.home_club_short_name, v_fixture.away_club_short_name) THEN
    RAISE EXCEPTION 'Club % is not in fixture %', p_club_short_name, p_fixture_id;
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
    'appearance', 'r1', 'r2', 'r32', 'r16', 'qf', 'sf', 'final',
    'winner', 'runner_up',
    'group_win', 'group_draw', 'group_qualify', 'group_exit'
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
  v_stage_label := public.competition_cup_prize_stage_label(v_stage);
  v_desc := format(
    '%s %s — %s (admin award)%s',
    v_cup_label,
    v_stage_label,
    public.competition_cup_fixture_label(v_fixture),
    CASE WHEN nullif(btrim(p_note), '') IS NULL THEN '' ELSE ' — ' || btrim(p_note) END
  );

  v_paid := public.competition_cup_credit_round_prize(
    p_fixture_id,
    p_club_short_name,
    v_stage,
    v_amount,
    v_desc,
    jsonb_build_object(
      'cup_code', v_fixture.cup_code,
      'stage', v_stage,
      'admin_award', true,
      'note', p_note
    )
  );

  RETURN jsonb_build_object(
    'ok', v_paid,
    'amount', v_amount,
    'stage', v_stage,
    'club_short_name', p_club_short_name,
    'fixture_id', p_fixture_id
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_admin_award_cup_round_prize(bigint, text, text, text)
  TO authenticated;

-- Eight clubs, best previous finish first.
-- Group A: 1st with 6th, 7th, 8th.
-- Group B: 2nd with 3rd, 4th, 5th.
CREATE TABLE IF NOT EXISTS public.competition_cup_group_members (
  season_id bigint NOT NULL,
  cup_code text NOT NULL,
  group_code text NOT NULL CHECK (group_code IN ('A', 'B')),
  club_short_name text NOT NULL,
  seed_rank smallint NOT NULL CHECK (seed_rank BETWEEN 1 AND 8),
  PRIMARY KEY (season_id, cup_code, club_short_name),
  UNIQUE (season_id, cup_code, seed_rank)
);

COMMENT ON TABLE public.competition_cup_group_members IS
  'Super 8 / Bowl group draw. Rank 1 is the best previous finish. A = 1,6,7,8. B = 2,3,4,5.';

CREATE OR REPLACE FUNCTION public.competition_admin_assign_cup_groups(
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
  v_i int;
  v_group text;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF p_cup_code NOT IN ('super8', 'bowl') THEN
    RAISE EXCEPTION 'Group draw is only for super8 and bowl';
  END IF;

  IF p_clubs IS NULL OR array_length(p_clubs, 1) <> 8 THEN
    RAISE EXCEPTION 'Need exactly 8 clubs, best previous finish first';
  END IF;

  DELETE FROM public.competition_cup_group_members
  WHERE season_id = p_season_id AND cup_code = p_cup_code;

  FOR v_i IN 1..8 LOOP
    v_group := CASE WHEN v_i IN (1, 6, 7, 8) THEN 'A' ELSE 'B' END;
    INSERT INTO public.competition_cup_group_members (
      season_id, cup_code, group_code, club_short_name, seed_rank
    ) VALUES (
      p_season_id, p_cup_code, v_group, p_clubs[v_i], v_i
    );
  END LOOP;

  RETURN jsonb_build_object(
    'season_id', p_season_id,
    'cup_code', p_cup_code,
    'group_a', ARRAY[p_clubs[1], p_clubs[6], p_clubs[7], p_clubs[8]],
    'group_b', ARRAY[p_clubs[2], p_clubs[3], p_clubs[4], p_clubs[5]]
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_admin_assign_cup_groups(bigint, text, text[])
  TO authenticated;

-- Two matches are one tie. 3 points for the aggregate win, 1 each if level.
-- If the aggregate is level, more away goals takes the 3 points.
-- If away goals are also level, it stays a draw.
CREATE OR REPLACE FUNCTION public.competition_cup_group_tie_result(
  p_home_leg1 int,
  p_away_leg1 int,
  p_home_leg2 int,
  p_away_leg2 int
)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE
    WHEN (p_home_leg1 + p_away_leg2) > (p_away_leg1 + p_home_leg2) THEN 'home'
    WHEN (p_home_leg1 + p_away_leg2) < (p_away_leg1 + p_home_leg2) THEN 'away'
    WHEN p_away_leg1 > p_away_leg2 THEN 'away'
    WHEN p_away_leg2 > p_away_leg1 THEN 'home'
    ELSE 'draw'
  END;
$$;

COMMENT ON FUNCTION public.competition_cup_group_tie_result(int, int, int, int) IS
  'Leg 1 is the first club at home. Leg 2 is the return. Away goals break a level aggregate. A level away-goals tie stays a draw.';

NOTIFY pgrst, 'reload schema';

COMMIT;
