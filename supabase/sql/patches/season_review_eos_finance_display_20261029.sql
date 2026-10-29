-- =============================================================================
-- Season Review: after EOS, closing balance = live ledger (not stale pre_close)
-- =============================================================================
-- When eos_posted, season_review_board left closing = pre_close (often much worse
-- than balance_now) while skipping FFP simulation — UI then showed
-- "Projected close −₿136m" + "above the FFP line" with no punishments.
--
-- Fix: on the posted path, set closing := balance_now and still surface FFP when
-- an eos_ffp_charge was paid (fine amount included).
-- Safe re-run.
-- =============================================================================

DO $patch$
DECLARE
  v_def text;
  v_old text;
  v_new text;
BEGIN
  IF to_regprocedure('public.season_review_board()') IS NULL THEN
    RAISE NOTICE 'season_review_board missing — skip';
    RETURN;
  END IF;

  SELECT replace(
    pg_get_functiondef('public.season_review_board()'::regprocedure),
    E'\r\n', E'\n'
  ) INTO v_def;

  v_old := replace($n$      ELSE
        v_ffp := EXISTS (
          SELECT 1 FROM public.competition_season_charge_paid cp
          WHERE cp.season_id = v_season_id
            AND cp.club_short_name = v_c.club_short_name
            AND cp.charge_type = 'eos_ffp_charge'
        );
      END IF;
$n$, E'\r\n', E'\n');

  v_new := replace($n$      ELSE
        -- Actual post-close ledger (pre_close is only a historical snapshot)
        v_bal := v_snap.balance_now;
        v_ffp := EXISTS (
          SELECT 1 FROM public.competition_season_charge_paid cp
          WHERE cp.season_id = v_season_id
            AND cp.club_short_name = v_c.club_short_name
            AND cp.charge_type = 'eos_ffp_charge'
        );
      END IF;
$n$, E'\r\n', E'\n');

  IF position('Actual post-close ledger' IN v_def) > 0 THEN
    RAISE NOTICE 'season_review_board already uses balance_now when eos_posted';
  ELSIF position(v_old IN v_def) = 0 THEN
    RAISE WARNING 'season_review_board: eos_posted FFP branch needle not found';
  ELSE
    v_def := replace(v_def, v_old, v_new);
    RAISE NOTICE 'season_review_board: eos_posted closing → balance_now';
  END IF;

  -- Include fine amount when FFP charge was posted (was 0 when eos_posted)
  IF position('''ffp_fine'', CASE WHEN v_ffp THEN v_fine ELSE 0 END' IN v_def) > 0 THEN
    RAISE NOTICE 'ffp_fine already includes posted charges';
  ELSIF position('''ffp_fine'', CASE WHEN v_ffp AND NOT v_snap.eos_posted THEN v_fine ELSE 0 END' IN v_def) > 0 THEN
    v_def := replace(
      v_def,
      '''ffp_fine'', CASE WHEN v_ffp AND NOT v_snap.eos_posted THEN v_fine ELSE 0 END',
      '''ffp_fine'', CASE WHEN v_ffp THEN v_fine ELSE 0 END'
    );
    RAISE NOTICE 'season_review_board: ffp_fine shown when charge posted';
  ELSE
    RAISE WARNING 'season_review_board: ffp_fine CASE needle not found';
  END IF;

  EXECUTE v_def;
END;
$patch$;

NOTIFY pgrst, 'reload schema';
