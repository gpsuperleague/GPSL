-- =============================================================================
-- Yellow accumulation: every 5 season yellows → 2-match ban (was every 8).
-- Leaders "toward next ban" period follows the same 5.
-- Cards already recorded are not re-banned. The next yellow that lands on
-- 5, 10, 15, … issues the ban.
-- Safe re-run.
-- =============================================================================

DO $patch$
DECLARE
  v_def text;
  v_new text;
BEGIN
  v_def := pg_get_functiondef(
    'public.competition_process_match_discipline(bigint,bigint,text,jsonb)'::regprocedure
  );
  v_def := replace(v_def, E'\r\n', E'\n');

  IF position('(v_y_count / 5) * 5' IN v_def) > 0
     AND position('(v_prev_count / 5)' IN v_def) > 0 THEN
    RAISE NOTICE 'yellow ban already every 5';
  ELSE
    IF position('(v_y_count / 8) * 8' IN v_def) = 0
       OR position('(v_y_count / 8) > (v_prev_count / 8)' IN v_def) = 0 THEN
      RAISE EXCEPTION 'yellow ban threshold block not found';
    END IF;
    v_new := replace(v_def, '(v_y_count / 8) * 8', '(v_y_count / 5) * 5');
    v_new := replace(
      v_new,
      '(v_y_count / 8) > (v_prev_count / 8)',
      '(v_y_count / 5) > (v_prev_count / 5)'
    );
    EXECUTE v_new;
  END IF;

  v_def := pg_get_functiondef(
    'public.competition_league_discipline_leaders(bigint,text,int)'::regprocedure
  );
  v_def := replace(v_def, E'\r\n', E'\n');

  IF position('5 AS yellow_period_size' IN v_def) > 0
     AND position('(c.yellow_cards % 5)' IN v_def) > 0 THEN
    RAISE NOTICE 'discipline leaders period already 5';
  ELSE
    IF position('8 AS yellow_period_size' IN v_def) = 0
       OR position('(c.yellow_cards % 8)' IN v_def) = 0 THEN
      RAISE EXCEPTION 'discipline leaders period block not found';
    END IF;
    v_new := replace(v_def, '(c.yellow_cards % 8)', '(c.yellow_cards % 5)');
    v_new := replace(v_new, '8 AS yellow_period_size', '5 AS yellow_period_size');
    EXECUTE v_new;
  END IF;
END
$patch$;

NOTIFY pgrst, 'reload schema';
