-- =============================================================================
-- Test reset: season FK blockers + restart season ids at 1
--
-- Error on admin_test_reset_execute:
--   update or delete on table "competition_seasons" violates foreign key
--   constraint "fixture_match_videos_season_id_fkey"
--
-- Cause: newer tables reference competition_seasons / competition_fixtures
-- without ON DELETE, so the reset's final DELETE FROM competition_seasons is
-- blocked (match videos, friendlies gate, transfer gossip, owner shop ledger,
-- loans, stadium orders, WC cycles, …).
--
-- Fix 1: every single-column FK to competition_seasons / competition_fixtures
--        with NO ACTION / RESTRICT is rebuilt as
--          nullable column  → ON DELETE SET NULL
--          NOT NULL column  → ON DELETE CASCADE
--        Seasons are only ever deleted by the test reset.
--
-- Fix 2: when competition_seasons becomes empty (test reset), the id counter
--        restarts so the next season created is id 1.
--
-- Run once, then retry the test reset. Safe re-run (also re-run after adding
-- new tables that reference seasons/fixtures without ON DELETE).
-- =============================================================================

DO $fk$
DECLARE
  r record;
  v_rule text;
BEGIN
  FOR r IN
    SELECT
      con.conname,
      con.conrelid::regclass AS child_table,
      con.confrelid::regclass AS parent_table,
      a.attname AS child_col,
      pa.attname AS parent_col,
      a.attnotnull AS not_null
    FROM pg_constraint con
    JOIN pg_attribute a
      ON a.attrelid = con.conrelid
     AND a.attnum = con.conkey[1]
    JOIN pg_attribute pa
      ON pa.attrelid = con.confrelid
     AND pa.attnum = con.confkey[1]
    WHERE con.contype = 'f'
      AND con.confrelid IN (
        'public.competition_seasons'::regclass,
        'public.competition_fixtures'::regclass
      )
      AND con.confdeltype IN ('a', 'r')
      AND array_length(con.conkey, 1) = 1
  LOOP
    v_rule := CASE WHEN r.not_null THEN 'CASCADE' ELSE 'SET NULL' END;

    EXECUTE format('ALTER TABLE %s DROP CONSTRAINT %I', r.child_table, r.conname);
    EXECUTE format(
      'ALTER TABLE %s ADD CONSTRAINT %I FOREIGN KEY (%I) REFERENCES %s (%I) ON DELETE %s',
      r.child_table, r.conname, r.child_col, r.parent_table, r.parent_col, v_rule
    );

    RAISE NOTICE '% on %.% → ON DELETE %', r.conname, r.child_table, r.child_col, v_rule;
  END LOOP;
END;
$fk$;

-- ---------------------------------------------------------------------------
-- Restart season ids once the table is emptied
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.trg_competition_seasons_restart_ids_when_empty()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.competition_seasons) THEN
    PERFORM setval(pg_get_serial_sequence('public.competition_seasons', 'id'), 1, false);
  END IF;
  RETURN NULL;
END;
$function$;

DROP TRIGGER IF EXISTS trg_competition_seasons_restart_ids_when_empty ON public.competition_seasons;
CREATE TRIGGER trg_competition_seasons_restart_ids_when_empty
  AFTER DELETE ON public.competition_seasons
  FOR EACH STATEMENT
  EXECUTE FUNCTION public.trg_competition_seasons_restart_ids_when_empty();

-- Diagnostic ingest log keeps a bare season_id (no FK); clear it on reset so
-- old test rows don't line up with the restarted ids.
CREATE OR REPLACE FUNCTION public.trg_competition_seasons_clear_orphan_logs()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.competition_seasons)
     AND to_regclass('public.fixture_match_video_ingest_log') IS NOT NULL THEN
    DELETE FROM public.fixture_match_video_ingest_log WHERE true;
  END IF;
  RETURN NULL;
END;
$function$;

DROP TRIGGER IF EXISTS trg_competition_seasons_clear_orphan_logs ON public.competition_seasons;
CREATE TRIGGER trg_competition_seasons_clear_orphan_logs
  AFTER DELETE ON public.competition_seasons
  FOR EACH STATEMENT
  EXECUTE FUNCTION public.trg_competition_seasons_clear_orphan_logs();

NOTIFY pgrst, 'reload schema';
