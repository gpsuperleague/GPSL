-- =============================================================================
-- August ready checklist: home propose item = August only (not Sep)
--
-- Was: August & September home matches proposed
-- Now: August home matches proposed (incl. cup ties)
--
-- Rewrites gpsl_owner_ready_items in place so black-box propose skip stays.
-- Safe re-run.
-- =============================================================================

DO $patch$
DECLARE
  v_def text;
BEGIN
  IF to_regprocedure('public.gpsl_owner_ready_items(text,bigint)') IS NULL THEN
    RAISE EXCEPTION 'gpsl_owner_ready_items missing — run owner_season_ready_checklist_20261015.sql first';
  END IF;

  SELECT replace(pg_get_functiondef('public.gpsl_owner_ready_items(text,bigint)'::regprocedure), E'\r\n', E'\n')
  INTO v_def;

  -- Month filter (idempotent)
  v_def := replace(
    v_def,
    'AND lower(btrim(f.gpsl_month)) IN (''august'', ''september'')',
    'AND lower(btrim(f.gpsl_month)) = ''august'''
  );

  v_def := replace(
    v_def,
    'August + September fixtures (league + drawn cup ties) where we are home',
    'August fixtures (league + drawn cup ties) where we are home'
  );

  -- Item key
  v_def := replace(v_def, '''key'', ''aug_sep_proposed''', '''key'', ''aug_proposed''');

  -- Label (ampersand as stored in function body)
  v_def := replace(
    v_def,
    '''label'', ''August & September home matches proposed (incl. cup ties)''',
    '''label'', ''August home matches proposed (incl. cup ties)'''
  );

  EXECUTE v_def;
END;
$patch$;

NOTIFY pgrst, 'reload schema';

SELECT
  position('August home matches proposed (incl. cup ties)' IN d) > 0 AS has_new_label,
  position('August & September' IN d) = 0 AS old_label_gone,
  position('IN (''august'', ''september'')' IN d) = 0 AS old_month_filter_gone,
  position('= ''august''' IN d) > 0 AS has_august_only,
  position('''aug_proposed''' IN d) > 0 AS has_new_key
FROM (
  SELECT replace(pg_get_functiondef('public.gpsl_owner_ready_items(text,bigint)'::regprocedure), E'\r\n', E'\n') AS d
) x;
