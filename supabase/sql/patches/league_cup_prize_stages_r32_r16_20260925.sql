-- =============================================================================
-- League Cup prize stages: split Last 32 / Last 16 (were both "r2")
--
-- Actual League Cup rounds:
--   Last 64 → r1
--   Last 32 → r32   (NEW — was incorrectly sharing r2)
--   Last 16 → r16   (NEW — was incorrectly sharing r2)
--   QF / SF / Runner-up / Winner
--
-- Safe re-run.
-- =============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- 1) Allow r32 / r16 on config + schedule
-- ---------------------------------------------------------------------------
ALTER TABLE public.competition_cup_prize_config
  DROP CONSTRAINT IF EXISTS competition_cup_prize_config_stage_check;

ALTER TABLE public.competition_cup_prize_config
  ADD CONSTRAINT competition_cup_prize_config_stage_check
  CHECK (
    stage IN (
      'appearance',
      'r1',
      'r2',
      'r32',
      'r16',
      'qf',
      'sf',
      'final',
      'winner',
      'runner_up'
    )
  );

ALTER TABLE public.competition_cup_round_schedule
  DROP CONSTRAINT IF EXISTS competition_cup_round_schedule_stage_check;

ALTER TABLE public.competition_cup_round_schedule
  ADD CONSTRAINT competition_cup_round_schedule_stage_check
  CHECK (
    stage IN (
      'appearance',
      'r1',
      'r2',
      'r32',
      'r16',
      'qf',
      'sf',
      'final',
      'winner'
    )
  );

-- ---------------------------------------------------------------------------
-- 2) League Cup schedule: R2 = Last 32 (r32), R3 = Last 16 (r16)
-- ---------------------------------------------------------------------------
UPDATE public.competition_cup_round_schedule
SET stage = 'r32', round_label = 'Last 32'
WHERE cup_code = 'league_cup' AND round_no = 2;

UPDATE public.competition_cup_round_schedule
SET stage = 'r16', round_label = 'Last 16'
WHERE cup_code = 'league_cup' AND round_no = 3;

UPDATE public.competition_cup_round_schedule
SET stage = 'r1', round_label = 'Last 64'
WHERE cup_code = 'league_cup' AND round_no = 1;

-- ---------------------------------------------------------------------------
-- 3) Migrate League Cup config: copy old shared r2 amount → r32 + r16
-- ---------------------------------------------------------------------------
INSERT INTO public.competition_cup_prize_config (season_id, cup_code, stage, amount)
SELECT c.season_id, c.cup_code, 'r32', c.amount
FROM public.competition_cup_prize_config c
WHERE c.cup_code = 'league_cup'
  AND c.stage = 'r2'
  AND c.amount > 0
ON CONFLICT (season_id, cup_code, stage) DO NOTHING;

INSERT INTO public.competition_cup_prize_config (season_id, cup_code, stage, amount)
SELECT c.season_id, c.cup_code, 'r16', c.amount
FROM public.competition_cup_prize_config c
WHERE c.cup_code = 'league_cup'
  AND c.stage = 'r2'
  AND c.amount > 0
ON CONFLICT (season_id, cup_code, stage) DO NOTHING;

-- Drop obsolete league_cup r2 rows (Shield/Plate keep r2)
DELETE FROM public.competition_cup_prize_config
WHERE cup_code = 'league_cup' AND stage = 'r2';

-- ---------------------------------------------------------------------------
-- 4) Retarget already-paid League Cup rows so backfill won't double-pay
-- ---------------------------------------------------------------------------
UPDATE public.competition_cup_prize_paid p
SET stage = 'r32'
FROM public.competition_fixtures f
WHERE p.fixture_id = f.id
  AND f.competition_type = 'cup'
  AND lower(coalesce(f.cup_code, '')) = 'league_cup'
  AND f.cup_round = 2
  AND p.stage = 'r2';

UPDATE public.competition_cup_prize_paid p
SET stage = 'r16'
FROM public.competition_fixtures f
WHERE p.fixture_id = f.id
  AND f.competition_type = 'cup'
  AND lower(coalesce(f.cup_code, '')) = 'league_cup'
  AND f.cup_round = 3
  AND p.stage = 'r2';

-- ---------------------------------------------------------------------------
-- 5) Stage label helper + admin set validation
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.competition_cup_prize_stage_label(p_stage text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE lower(coalesce(p_stage, ''))
    WHEN 'appearance' THEN 'Appearance'
    WHEN 'r1' THEN 'Last 64 / Round 1'
    WHEN 'r2' THEN 'Last 16 / Round 2'
    WHEN 'r32' THEN 'Last 32'
    WHEN 'r16' THEN 'Last 16'
    WHEN 'qf' THEN 'Quarter-final'
    WHEN 'sf' THEN 'Semi-final'
    WHEN 'final' THEN 'Final'
    WHEN 'winner' THEN 'Winner'
    WHEN 'runner_up' THEN 'Runner-up'
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
    'appearance', 'r1', 'r2', 'r32', 'r16', 'qf', 'sf', 'final', 'winner', 'runner_up'
  ) THEN
    RAISE EXCEPTION
      'Invalid stage %. Use: appearance, r1, r2, r32, r16, qf, sf, winner, runner_up (final legacy)',
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

-- Expand award override allowed stages (r32 / r16)
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
    'appearance', 'r1', 'r2', 'r32', 'r16', 'qf', 'sf', 'final', 'winner', 'runner_up'
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

COMMENT ON FUNCTION public.competition_cup_prize_stage_label(text) IS
  'Human label for cup prize stages (includes League Cup Last 64/32/16).';

NOTIFY pgrst, 'reload schema';

COMMIT;
