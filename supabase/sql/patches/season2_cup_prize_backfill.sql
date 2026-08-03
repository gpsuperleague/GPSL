-- =============================================================================
-- Season 2 cup prize backfill
--
-- Use when cup prize amounts were set mid-season (or copied late) and earlier
-- played cup fixtures never received prize_cup credits.
--
-- Idempotent: already-paid fixture/club/stage rows are skipped.
--
-- BEFORE RUNNING:
--   1) Set Season 2 amounts in Admin → Prize Money → Cup Prize Money
--      OR leave blank and this script will copy Season 1 → Season 2 if S2 empty.
--   2) Prefer also re-running cup_prize_winner_runner_up.sql so finals pay
--      winner / runner_up correctly (not the older shared-final pay path).
--
-- Safe re-run.
-- =============================================================================

-- Improved backfill: finals count winner/runner_up/final as configured
CREATE OR REPLACE FUNCTION public.competition_admin_backfill_cup_fixture_prizes(
  p_gpsl_month text DEFAULT NULL,
  p_cup_code text DEFAULT NULL,
  p_season_id bigint DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season_id bigint;
  v_month text := nullif(lower(btrim(coalesce(p_gpsl_month, ''))), '');
  v_cup text := nullif(lower(btrim(coalesce(p_cup_code, ''))), '');
  v_fixture record;
  v_paid_before int;
  v_paid_after int;
  v_processed int := 0;
  v_credited int := 0;
  v_skipped_no_config int := 0;
  v_stage text;
  v_max_round int;
  v_has_config boolean;
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.is_gpsl_admin()
     AND current_user NOT IN ('postgres', 'supabase_admin', 'service_role') THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  v_season_id := coalesce(
    p_season_id,
    (SELECT id FROM public.competition_seasons WHERE is_current = true ORDER BY id DESC LIMIT 1)
  );

  IF v_season_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_season');
  END IF;

  FOR v_fixture IN
    SELECT f.*
    FROM public.competition_fixtures f
    WHERE f.season_id = v_season_id
      AND f.competition_type = 'cup'
      AND f.status = 'played'
      AND f.home_goals IS NOT NULL
      AND f.away_goals IS NOT NULL
      AND (v_month IS NULL OR lower(f.gpsl_month) = v_month)
      AND (v_cup IS NULL OR lower(f.cup_code) = v_cup)
      -- Skip playoff codes (not cup prize config)
      AND lower(coalesce(f.cup_code, '')) NOT LIKE 'po\_%' ESCAPE '\'
    ORDER BY f.gpsl_month, f.cup_code, f.cup_round, coalesce(f.cup_leg, 1), f.id
  LOOP
    v_processed := v_processed + 1;

    SELECT count(*)::int
    INTO v_paid_before
    FROM public.competition_cup_prize_paid p
    WHERE p.fixture_id = v_fixture.id;

    SELECT max(n.round_no) INTO v_max_round
    FROM public.competition_cup_bracket_nodes n
    WHERE n.season_id = v_fixture.season_id
      AND n.cup_code = v_fixture.cup_code;

    v_stage := public.competition_cup_round_stage(
      v_fixture.cup_code,
      v_fixture.cup_round,
      coalesce(v_max_round, v_fixture.cup_round)
    );

    SELECT EXISTS (
      SELECT 1
      FROM public.competition_cup_prize_config c
      WHERE c.season_id = v_fixture.season_id
        AND c.cup_code = v_fixture.cup_code
        AND c.amount > 0
        AND (
          c.stage = 'appearance'
          OR c.stage = v_stage
          OR (
            v_stage = 'final'
            AND c.stage IN ('final', 'winner', 'runner_up')
          )
        )
    )
    INTO v_has_config;

    IF NOT coalesce(v_has_config, false) THEN
      v_skipped_no_config := v_skipped_no_config + 1;
      CONTINUE;
    END IF;

    PERFORM public.competition_pay_cup_fixture_prizes(v_fixture.id);

    SELECT count(*)::int
    INTO v_paid_after
    FROM public.competition_cup_prize_paid p
    WHERE p.fixture_id = v_fixture.id;

    IF v_paid_after > v_paid_before THEN
      v_credited := v_credited + 1;
    END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true,
    'season_id', v_season_id,
    'gpsl_month', v_month,
    'cup_code', v_cup,
    'fixtures_processed', v_processed,
    'fixtures_newly_credited', v_credited,
    'fixtures_skipped_no_config', v_skipped_no_config
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_admin_backfill_cup_fixture_prizes(text, text, bigint)
  TO authenticated;

-- ---------------------------------------------------------------------------
-- One-shot Season 2 runner
-- ---------------------------------------------------------------------------
DO $season2$
DECLARE
  v_s2 bigint;
  v_s1 bigint;
  v_s2_label text;
  v_cfg_count int;
  v_copied int := 0;
  v_result jsonb;
  v_paid_total numeric;
  v_paid_rows int;
BEGIN
  SELECT id, label INTO v_s2, v_s2_label
  FROM public.competition_seasons
  WHERE lower(btrim(label)) IN ('2', 'season 2', 's2')
     OR label = '2'
  ORDER BY id DESC
  LIMIT 1;

  IF v_s2 IS NULL THEN
    -- Fallback: current season if labelled like season 2 elsewhere
    SELECT id, label INTO v_s2, v_s2_label
    FROM public.competition_seasons
    WHERE is_current = true
    ORDER BY id DESC
    LIMIT 1;
    RAISE NOTICE 'No season labelled 2 found — using current season id=% label=%',
      v_s2, v_s2_label;
  ELSE
    RAISE NOTICE 'Season 2 resolved: id=% label=%', v_s2, v_s2_label;
  END IF;

  IF v_s2 IS NULL THEN
    RAISE EXCEPTION 'Could not resolve Season 2';
  END IF;

  SELECT count(*)::int INTO v_cfg_count
  FROM public.competition_cup_prize_config
  WHERE season_id = v_s2 AND amount > 0;

  RAISE NOTICE 'Season 2 cup prize config rows with amount>0: %', v_cfg_count;

  IF v_cfg_count = 0 THEN
    SELECT id INTO v_s1
    FROM public.competition_seasons
    WHERE id IS DISTINCT FROM v_s2
      AND (
        lower(btrim(label)) IN ('1', 'season 1', 's1')
        OR label = '1'
      )
    ORDER BY id DESC
    LIMIT 1;

    IF v_s1 IS NULL THEN
      SELECT id INTO v_s1
      FROM public.competition_seasons
      WHERE id < v_s2
      ORDER BY id DESC
      LIMIT 1;
    END IF;

    IF v_s1 IS NULL THEN
      RAISE EXCEPTION
        'Season 2 has no cup prize config. Set amounts in Admin → Cup Prize Money, or ensure Season 1 exists to copy from.';
    END IF;

    IF to_regprocedure('public.competition_admin_copy_cup_prizes(bigint,bigint)') IS NULL THEN
      RAISE EXCEPTION
        'competition_admin_copy_cup_prizes missing — set Season 2 prizes in Admin UI first.';
    END IF;

    PERFORM public.competition_admin_copy_cup_prizes(v_s1, v_s2);

    SELECT count(*)::int INTO v_copied
    FROM public.competition_cup_prize_config
    WHERE season_id = v_s2 AND amount > 0;

    RAISE NOTICE 'Copied cup prizes from season id=% → Season 2. Config rows now: %',
      v_s1, v_copied;

    IF v_copied = 0 THEN
      RAISE EXCEPTION
        'Copy produced 0 amounts. Set Season 2 (or Season 1) prizes in Admin → Cup Prize Money, then re-run this script.';
    END IF;
  END IF;

  -- Show config snapshot
  RAISE NOTICE '--- Season 2 cup prize config ---';
  RAISE NOTICE '%', (
    SELECT string_agg(
      format('%s / %s = ₿%s', cup_code, stage, trim(to_char(amount, '999,999,999,999'))),
      E'\n'
      ORDER BY cup_code, stage
    )
    FROM public.competition_cup_prize_config
    WHERE season_id = v_s2 AND amount > 0
  );

  v_result := public.competition_admin_backfill_cup_fixture_prizes(NULL, NULL, v_s2);
  RAISE NOTICE 'Backfill result: %', v_result;

  SELECT count(*)::int, coalesce(sum(amount), 0)
  INTO v_paid_rows, v_paid_total
  FROM public.competition_cup_prize_paid p
  JOIN public.competition_fixtures f ON f.id = p.fixture_id
  WHERE f.season_id = v_s2;

  RAISE NOTICE 'Season 2 cup_prize_paid rows=% total_amount=₿%',
    v_paid_rows, trim(to_char(v_paid_total, '999,999,999,999'));
END;
$season2$;

NOTIFY pgrst, 'reload schema';

-- Optional checks after run:
-- SELECT cup_code, stage, amount FROM competition_cup_prize_config
-- WHERE season_id = (SELECT id FROM competition_seasons WHERE label IN ('2','Season 2') LIMIT 1)
-- ORDER BY 1,2;
--
-- SELECT f.cup_code, f.gpsl_month, f.cup_round, p.club_short_name, p.stage, p.amount
-- FROM competition_cup_prize_paid p
-- JOIN competition_fixtures f ON f.id = p.fixture_id
-- WHERE f.season_id = (SELECT id FROM competition_seasons WHERE label IN ('2','Season 2') LIMIT 1)
-- ORDER BY f.cup_code, f.cup_round, p.stage;
