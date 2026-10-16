-- =============================================================================
-- Repair: wire friendlies monthly table prizes into month lock
--
-- Live function ends with "RETURN v_out;" then a blank line then "END;"
-- (and may use CRLF). Uses regexp on the normalized ending. Then catch-up
-- pays locked months with no payout rows yet (e.g. June). Safe re-run.
--
-- Requires: friendlies_monthly_table_20261015.sql (pay functions present).
-- =============================================================================

DO $wire$
DECLARE
  v_oid oid;
  v_def text;
  v_marker text := 'gpsl_friendlies_on_gpsl_month_lock';
  v_insert text;
  v_new text;
BEGIN
  IF to_regprocedure('public.gpsl_friendlies_on_gpsl_month_lock(bigint,text)') IS NULL THEN
    RAISE EXCEPTION
      'gpsl_friendlies_on_gpsl_month_lock missing — run friendlies_monthly_table_20261015.sql first';
  END IF;

  v_oid := to_regprocedure('public.competition_run_month_lock_jobs(bigint,boolean,text,text)');
  IF v_oid IS NULL THEN
    RAISE EXCEPTION 'competition_run_month_lock_jobs(bigint,boolean,text,text) missing';
  END IF;

  v_def := pg_get_functiondef(v_oid);
  v_def := replace(replace(v_def, E'\r\n', E'\n'), E'\r', E'\n');

  IF position(v_marker IN v_def) > 0 THEN
    RAISE NOTICE 'Friendlies prizes already wired into month-lock jobs';
    RETURN;
  END IF;

  v_insert :=
    E'  -- Friendlies monthly table: owner prizes for the month that just locked\n'
    || E'  IF coalesce(v_month, '''') NOT IN ('''', ''playoffs'')\n'
    || E'     AND coalesce(nullif(v_stage, ''''), ''all'') IN (''all'', ''tables'', ''league_tables'', ''awards'', ''friendlies'')\n'
    || E'  THEN\n'
    || E'    BEGIN\n'
    || E'      IF to_regprocedure(''public.gpsl_friendlies_on_gpsl_month_lock(bigint,text)'') IS NOT NULL THEN\n'
    || E'        v_out := v_out || jsonb_build_object(\n'
    || E'          ''friendlies_prizes'',\n'
    || E'          public.gpsl_friendlies_on_gpsl_month_lock(p_season_id, v_month)\n'
    || E'        );\n'
    || E'      END IF;\n'
    || E'    EXCEPTION WHEN OTHERS THEN\n'
    || E'      v_out := v_out || jsonb_build_object(\n'
    || E'        ''friendlies_prizes'', jsonb_build_object(''ok'', false, ''error'', SQLERRM)\n'
    || E'      );\n'
    || E'    END;\n'
    || E'  END IF;\n\n';

  IF v_def !~ E'RETURN v_out;[[:space:]]*END;[[:space:]]*\\$function\\$[[:space:]]*$' THEN
    RAISE EXCEPTION
      'Could not wire friendlies prizes — RETURN v_out ending not found. Tail:%',
      chr(10) || right(v_def, 500);
  END IF;

  v_new := regexp_replace(
    v_def,
    E'RETURN v_out;[[:space:]]*END;[[:space:]]*\\$function\\$[[:space:]]*$',
    v_insert || E'  RETURN v_out;\n\nEND;\n$function$\n'
  );

  IF v_new IS NOT DISTINCT FROM v_def OR position(v_marker IN v_new) = 0 THEN
    RAISE EXCEPTION 'Wire replace did not insert friendlies marker';
  END IF;

  EXECUTE v_new;
  RAISE NOTICE 'Wired friendlies prizes into competition_run_month_lock_jobs';
END;
$wire$;

-- Catch-up: pay locked months that still have no payout rows
DO $catchup$
DECLARE
  v_season bigint;
  v_month text;
  v_lock timestamptz;
  v_result jsonb;
BEGIN
  IF to_regprocedure('public.gpsl_friendlies_pay_month_prizes_internal(bigint,text)') IS NULL THEN
    RAISE NOTICE 'Pay function missing — catch-up skipped';
    RETURN;
  END IF;

  SELECT id INTO v_season
  FROM public.competition_seasons
  WHERE is_current = true
  ORDER BY id DESC
  LIMIT 1;

  IF v_season IS NULL THEN
    RETURN;
  END IF;

  FOREACH v_month IN ARRAY ARRAY[
    'june','july','august','september','october','november','december',
    'january','february','march','april','may'
  ]
  LOOP
    SELECT cal.lock_at INTO v_lock
    FROM public.competition_season_calendar cal
    WHERE cal.season_id = v_season
      AND lower(btrim(cal.gpsl_month)) = v_month
    LIMIT 1;

    IF v_lock IS NULL OR v_lock > now() THEN
      CONTINUE;
    END IF;

    IF EXISTS (
      SELECT 1 FROM public.gpsl_friendlies_prize_payouts p
      WHERE p.season_id = v_season AND p.gpsl_month = v_month
    ) THEN
      CONTINUE;
    END IF;

    v_result := public.gpsl_friendlies_pay_month_prizes_internal(v_season, v_month);
    RAISE NOTICE 'Friendlies catch-up % → %', v_month, v_result;
  END LOOP;
END;
$catchup$;

NOTIFY pgrst, 'reload schema';

SELECT
  (position('gpsl_friendlies_on_gpsl_month_lock' IN pg_get_functiondef(
    'public.competition_run_month_lock_jobs(bigint,boolean,text,text)'::regprocedure
  )) > 0) AS wired,
  (SELECT count(*) FROM public.gpsl_friendlies_prize_payouts p
   WHERE p.gpsl_month = 'june'
     AND p.season_id = (SELECT id FROM public.competition_seasons WHERE is_current ORDER BY id DESC LIMIT 1)
  ) AS june_payout_rows,
  (SELECT jsonb_agg(jsonb_build_object(
      'place', p.place, 'club', p.club_short_name, 'amount', p.amount
    ) ORDER BY p.place)
   FROM public.gpsl_friendlies_prize_payouts p
   WHERE p.gpsl_month = 'june'
     AND p.season_id = (SELECT id FROM public.competition_seasons WHERE is_current ORDER BY id DESC LIMIT 1)
  ) AS june_winners;
