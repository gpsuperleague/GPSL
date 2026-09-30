-- =============================================================================
-- Owner "Season" panel showed Testing / Live Season 1 as OUT for everyone.
--
-- owner_onboarding_require_club_interest_20260921.sql and
-- ko_fi_supporters_20260922.sql redefined owner_registry_get_self() without
-- confirmed_test_season / confirmed_live_season (added 20260901), so the
-- owner panel read them as missing → Out, while the admin Season owner board
-- (which reads gpsl_owner_registry directly) showed the real ticks.
--
-- Patches the live function in place (keeps supporter / interest fields).
-- Safe re-run.
-- =============================================================================

DO $$
DECLARE
  v_def text;
  v_new text;
BEGIN
  IF to_regprocedure('public.owner_registry_get_self()') IS NULL THEN
    RAISE NOTICE 'owner_registry_get_self() not found — nothing to do';
    RETURN;
  END IF;

  v_def := pg_get_functiondef('public.owner_registry_get_self()'::regprocedure);

  IF v_def ~ 'confirmed_live_season' THEN
    RAISE NOTICE 'owner_registry_get_self() already returns season ticks';
    RETURN;
  END IF;

  v_new := regexp_replace(
    v_def,
    '''authenticated'',\s*true,',
    '''authenticated'', true,
    ''confirmed_test_season'', coalesce(v_row.confirmed_test_season, false),
    ''confirmed_live_season'', coalesce(v_row.confirmed_live_season, false),'
  );

  IF v_new = v_def THEN
    RAISE EXCEPTION 'Could not find the RETURN payload in owner_registry_get_self()';
  END IF;

  EXECUTE v_new;
  RAISE NOTICE 'owner_registry_get_self() now returns confirmed_test_season / confirmed_live_season';
END $$;

NOTIFY pgrst, 'reload schema';
