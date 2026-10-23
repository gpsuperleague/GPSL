-- =============================================================================
-- August ready checklist: proposal *replies* = August only (not future months)
--
-- Was: any negotiating fixture waiting on your reply (Sep/Nov/…)
-- Now: August fixtures only — matches home-propose scoping.
--
-- Rewrites gpsl_owner_ready_items in place so black-box reply skip stays.
-- Safe re-run.
-- =============================================================================

DO $patch$
DECLARE
  v_def text;
  v_old_replies text;
  v_new_replies text;
BEGIN
  IF to_regprocedure('public.gpsl_owner_ready_items(text,bigint)') IS NULL THEN
    RAISE EXCEPTION 'gpsl_owner_ready_items missing — run owner_season_ready_checklist_20261015.sql first';
  END IF;

  SELECT replace(pg_get_functiondef('public.gpsl_owner_ready_items(text,bigint)'::regprocedure), E'\r\n', E'\n')
  INTO v_def;

  -- Already August-scoped replies?
  IF position('INTO v_replies' IN v_def) > 0
     AND position('gpsl_month' IN
       substring(v_def from position('INTO v_replies' IN v_def) for 700)) > 0 THEN
    RAISE NOTICE 'ready replies already August-scoped';
  ELSE
    v_old_replies := replace($n$  SELECT count(*)::int INTO v_replies
  FROM public.competition_fixtures f
  JOIN public.competition_fixture_schedule s ON s.fixture_id = f.id
  WHERE f.season_id = p_season
    AND f.status = 'scheduled'
    AND s.status = 'negotiating'
    AND upper(btrim(coalesce(s.response_required_club_short_name, ''))) = v_club
    AND NOT (
      to_regprocedure('public.fixture_is_manual_black_box(bigint)') IS NOT NULL
      AND public.fixture_is_manual_black_box(f.id)
    );
$n$, E'\r\n', E'\n');

    v_new_replies := replace($n$  SELECT count(*)::int INTO v_replies
  FROM public.competition_fixtures f
  JOIN public.competition_fixture_schedule s ON s.fixture_id = f.id
  WHERE f.season_id = p_season
    AND f.status = 'scheduled'
    AND s.status = 'negotiating'
    AND lower(btrim(coalesce(f.gpsl_month, ''))) = 'august'
    AND upper(btrim(coalesce(s.response_required_club_short_name, ''))) = v_club
    AND NOT (
      to_regprocedure('public.fixture_is_manual_black_box(bigint)') IS NOT NULL
      AND public.fixture_is_manual_black_box(f.id)
    );
$n$, E'\r\n', E'\n');

    IF position(v_old_replies IN v_def) = 0 THEN
      RAISE EXCEPTION 'ready replies needle not found — aborting (function body changed)';
    END IF;

    v_def := replace(v_def, v_old_replies, v_new_replies);
    RAISE NOTICE 'ready replies August filter applied';
  END IF;

  -- Label
  v_def := replace(
    v_def,
    '''label'', ''Replied to every match proposal sent to you''',
    '''label'', ''Replied to every August match proposal sent to you'''
  );

  EXECUTE v_def;
END;
$patch$;

NOTIFY pgrst, 'reload schema';

-- Verify Monaco (and label / filter)
SELECT
  position('Replied to every August match proposal sent to you' IN d) > 0 AS has_new_label,
  position('Replied to every match proposal sent to you' IN d) = 0 AS old_label_gone,
  position('INTO v_replies' IN d) > 0
    AND position('gpsl_month' IN substring(d from position('INTO v_replies' IN d) for 700)) > 0
    AS replies_month_filtered
FROM (
  SELECT replace(pg_get_functiondef('public.gpsl_owner_ready_items(text,bigint)'::regprocedure), E'\r\n', E'\n') AS d
) x;

SELECT
  i->>'key' AS key,
  (i->>'done')::boolean AS done,
  i->>'label' AS label,
  i->>'detail' AS detail
FROM jsonb_array_elements(
  public.gpsl_owner_ready_items(
    'MON',
    (SELECT id FROM competition_seasons WHERE is_current LIMIT 1)
  )
) i
WHERE i->>'key' IN ('aug_proposed', 'replies')
ORDER BY i->>'key';
