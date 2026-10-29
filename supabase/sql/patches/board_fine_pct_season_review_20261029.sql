-- =============================================================================
-- Board fine % — single source of truth for Season Review (+ call defaults)
-- =============================================================================
-- Live underperformance fine was moved 25% → 10% (board_fine_owner_pct_10_20261020).
-- Season Review still advertised 25%. This patch:
--   • stores board_fine_owner_pct on global_settings (default 10)
--   • adds board_fine_owner_pct() helper
--   • points season_review_board() at that helper
-- Safe re-run.
-- =============================================================================

ALTER TABLE public.global_settings
  ADD COLUMN IF NOT EXISTS board_fine_owner_pct numeric(5, 2);

UPDATE public.global_settings
SET board_fine_owner_pct = 10
WHERE id = 1
  AND (board_fine_owner_pct IS NULL OR board_fine_owner_pct = 25);

ALTER TABLE public.global_settings
  ALTER COLUMN board_fine_owner_pct SET DEFAULT 10;

UPDATE public.global_settings
SET board_fine_owner_pct = coalesce(board_fine_owner_pct, 10)
WHERE id = 1;

DO $$
BEGIN
  ALTER TABLE public.global_settings
    ADD CONSTRAINT global_settings_board_fine_owner_pct_chk
    CHECK (board_fine_owner_pct >= 0 AND board_fine_owner_pct <= 100);
EXCEPTION
  WHEN duplicate_object THEN NULL;
END $$;

CREATE OR REPLACE FUNCTION public.board_fine_owner_pct()
RETURNS numeric
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $f$
  SELECT greatest(
    0::numeric,
    least(
      100::numeric,
      coalesce(
        (SELECT gs.board_fine_owner_pct FROM public.global_settings gs WHERE gs.id = 1),
        10::numeric
      )
    )
  );
$f$;

REVOKE ALL ON FUNCTION public.board_fine_owner_pct() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.board_fine_owner_pct() TO authenticated;
GRANT EXECUTE ON FUNCTION public.board_fine_owner_pct() TO service_role;

COMMENT ON FUNCTION public.board_fine_owner_pct() IS
  'Owner Building Society board-fine % on club expectation miss (global_settings.board_fine_owner_pct).';

-- season_review_board: replace hard-coded 25 with the setting
DO $patch$
DECLARE
  v_def text;
BEGIN
  IF to_regprocedure('public.season_review_board()') IS NULL THEN
    RAISE NOTICE 'season_review_board missing — run season_review_projection_20261007.sql first';
    RETURN;
  END IF;

  SELECT replace(
    pg_get_functiondef('public.season_review_board()'::regprocedure),
    E'\r\n', E'\n'
  ) INTO v_def;

  IF position('''board_fine_pct'', public.board_fine_owner_pct()' IN v_def) > 0
     OR position('"board_fine_pct", public.board_fine_owner_pct()' IN v_def) > 0 THEN
    RAISE NOTICE 'season_review_board already uses board_fine_owner_pct()';
    RETURN;
  END IF;

  IF position('''board_fine_pct'', 25' IN v_def) = 0 THEN
    RAISE WARNING 'season_review_board: board_fine_pct = 25 needle not found';
    RETURN;
  END IF;

  EXECUTE replace(
    v_def,
    '''board_fine_pct'', 25',
    '''board_fine_pct'', public.board_fine_owner_pct()'
  );
  RAISE NOTICE 'season_review_board board_fine_pct wired to board_fine_owner_pct()';
END;
$patch$;

-- Underperformance call sites still passing 25 → use setting
DO $calls$
DECLARE
  r record;
  v_def text;
  v_old text;
  v_new text;
BEGIN
  v_old := replace($n$    v_fine := public.board_fine_owner_personal_pct(
      p_club_short_name,
      25,
$n$, E'\r\n', E'\n');
  v_new := replace($n$    v_fine := public.board_fine_owner_personal_pct(
      p_club_short_name,
      public.board_fine_owner_pct(),
$n$, E'\r\n', E'\n');

  FOR r IN
    SELECT p.oid::regprocedure AS sig
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.prokind = 'f'
      AND p.proname IN (
        'club_underperformance_process_club',
        'club_underperformance_apply_for_club'
      )
  LOOP
    SELECT replace(pg_get_functiondef(r.sig), E'\r\n', E'\n') INTO v_def;
    IF position(v_new IN v_def) > 0 THEN
      RAISE NOTICE '% already uses board_fine_owner_pct()', r.sig;
      CONTINUE;
    END IF;
    IF position(v_old IN v_def) = 0 THEN
      -- also try literal 10 from prior patch → still wire to setting
      v_old := replace($n$    v_fine := public.board_fine_owner_personal_pct(
      p_club_short_name,
      10,
$n$, E'\r\n', E'\n');
      IF position(v_old IN v_def) = 0 THEN
        RAISE WARNING '%: board fine pct call not found', r.sig;
        CONTINUE;
      END IF;
    END IF;
    EXECUTE replace(v_def, v_old, v_new);
    RAISE NOTICE '% board fine pct → board_fine_owner_pct()', r.sig;
  END LOOP;
END;
$calls$;

SELECT
  public.board_fine_owner_pct() AS board_fine_owner_pct,
  (SELECT board_fine_owner_pct FROM public.global_settings WHERE id = 1) AS settings_col;

NOTIFY pgrst, 'reload schema';
