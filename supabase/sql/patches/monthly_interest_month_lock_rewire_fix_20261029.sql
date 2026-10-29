-- Force-wire monthly interest + balance snapshot into month lock jobs.
-- Live function ends with: RETURN v_out;\n\nEND;  (blank line) — prior wire missed it.

DO $wire$
DECLARE
  v_def text;
  v_oid oid;
  v_old text;
  v_new text;
BEGIN
  v_oid := to_regprocedure('public.competition_run_month_lock_jobs(bigint,boolean,text,text)');
  IF v_oid IS NULL THEN
    RAISE EXCEPTION 'competition_run_month_lock_jobs(4-arg) missing';
  END IF;

  SELECT pg_get_functiondef(v_oid) INTO v_def;

  IF position('competition_post_monthly_interest' IN v_def) > 0
     AND position('club_balance_snapshot_gpsl_month' IN v_def) > 0 THEN
    RAISE NOTICE 'Already wired';
    RETURN;
  END IF;

  v_new :=
    E'  -- Month-end club balance snapshot (loan credit / interest base)\n'
    || E'  BEGIN\n'
    || E'    IF v_month IS NOT NULL\n'
    || E'       AND to_regprocedure(''public.club_balance_snapshot_gpsl_month(bigint,text)'') IS NOT NULL THEN\n'
    || E'      v_out := v_out || jsonb_build_object(\n'
    || E'        ''balance_snapshot'',\n'
    || E'        public.club_balance_snapshot_gpsl_month(p_season_id, v_month)\n'
    || E'      );\n'
    || E'    END IF;\n'
    || E'  EXCEPTION\n'
    || E'    WHEN OTHERS THEN\n'
    || E'      v_out := v_out || jsonb_build_object(\n'
    || E'        ''balance_snapshot'',\n'
    || E'        jsonb_build_object(''ok'', false, ''error'', SQLERRM)\n'
    || E'      );\n'
    || E'  END;\n'
    || E'\n'
    || E'  -- Monthly balance / overdraft interest\n'
    || E'  BEGIN\n'
    || E'    IF v_month IS NOT NULL\n'
    || E'       AND to_regprocedure(''public.competition_post_monthly_interest(bigint,text)'') IS NOT NULL THEN\n'
    || E'      v_out := v_out || jsonb_build_object(\n'
    || E'        ''monthly_interest'',\n'
    || E'        public.competition_post_monthly_interest(p_season_id, v_month)\n'
    || E'      );\n'
    || E'    END IF;\n'
    || E'  EXCEPTION\n'
    || E'    WHEN OTHERS THEN\n'
    || E'      v_out := v_out || jsonb_build_object(\n'
    || E'        ''monthly_interest'',\n'
    || E'        jsonb_build_object(''ok'', false, ''error'', SQLERRM)\n'
    || E'      );\n'
    || E'  END;\n'
    || E'\n'
    || E'  RETURN v_out;\n'
    || E'\n'
    || E'END;';

  IF position(E'  RETURN v_out;\n\nEND;' IN v_def) > 0 THEN
    v_old := E'  RETURN v_out;\n\nEND;';
  ELSIF position(E'  RETURN v_out;\r\n\r\nEND;' IN v_def) > 0 THEN
    v_old := E'  RETURN v_out;\r\n\r\nEND;';
  ELSIF position(E'  RETURN v_out;\nEND;' IN v_def) > 0 THEN
    v_old := E'  RETURN v_out;\nEND;';
  ELSE
    RAISE EXCEPTION 'RETURN v_out pattern not found. Tail: %', right(v_def, 500);
  END IF;

  EXECUTE replace(v_def, v_old, v_new);
  RAISE NOTICE 'Wired snapshot + monthly interest';
END;
$wire$;

SELECT
  (position('competition_post_monthly_interest' IN pg_get_functiondef(
    'public.competition_run_month_lock_jobs(bigint,boolean,text,text)'::regprocedure
  )) > 0) AS interest_wired,
  (position('club_balance_snapshot_gpsl_month' IN pg_get_functiondef(
    'public.competition_run_month_lock_jobs(bigint,boolean,text,text)'::regprocedure
  )) > 0) AS snapshot_wired;

NOTIFY pgrst, 'reload schema';
