-- =============================================================================
-- Allow multiple fines/compensations on the same fixture
--
-- Root cause: competition_finance_ledger had
--   UNIQUE (fixture_id, club_short_name, entry_type)
-- intended for one gate (etc.) per club per match. All fines use
-- entry_type = 'gov_fine_compensation', so a second fine on the same fixture
-- (e.g. scheduling fine + ineligible player) fails with 409 Conflict.
--
-- Fix: keep uniqueness only for one-shot match finance types; exclude fines.
-- Safe re-run.
-- =============================================================================

ALTER TABLE public.competition_finance_ledger
  DROP CONSTRAINT IF EXISTS competition_finance_ledger_fixture_unique;

DROP INDEX IF EXISTS public.competition_finance_ledger_fixture_unique;
DROP INDEX IF EXISTS public.competition_finance_ledger_fixture_once_idx;

-- One gate / TV / prize row per club per fixture (original intent)
CREATE UNIQUE INDEX competition_finance_ledger_fixture_once_idx
  ON public.competition_finance_ledger (fixture_id, club_short_name, entry_type)
  WHERE fixture_id IS NOT NULL
    AND entry_type IN (
      'gate_league_home',
      'gate_cup_share',
      'prize',
      'prize_cup',
      'tv_revenue'
    );

COMMENT ON INDEX public.competition_finance_ledger_fixture_once_idx IS
  'One gate/TV/prize ledger row per club per fixture. Fines (gov_fine_compensation) intentionally excluded so multiple tariffs can link to the same match.';
