-- A replay reset was refunding the fine that had just been approved, then
-- deleting the finance line. Fines stay on the club. Gate money still reverses.
-- Boca's instructions fine is put back. Corinthians' matchroom fine is charged
-- again, because that same reset had refunded it.
-- Safe re-run.

DO $keep$
DECLARE
  v_def text;
  v_old text;
  v_new text;
BEGIN
  v_def := replace(
    pg_get_functiondef('public.admin_fixture_reset_for_replay(bigint,text,text)'::regprocedure),
    E'\r\n', E'\n'
  );
  IF position('fines stay on a replay' IN v_def) > 0 THEN
    RETURN;
  END IF;
  v_old := replace($old$  FOR v_ledger IN
    SELECT id, club_short_name, amount
    FROM public.competition_finance_ledger
    WHERE fixture_id = v_fid
  LOOP$old$, E'\r\n', E'\n');
  v_new := replace($new$  -- fines stay on a replay
  FOR v_ledger IN
    SELECT id, club_short_name, amount
    FROM public.competition_finance_ledger
    WHERE fixture_id = v_fid
      AND entry_type IS DISTINCT FROM 'gov_fine_compensation'
  LOOP$new$, E'\r\n', E'\n');
  IF position(v_old IN v_def) = 0 THEN
    RAISE EXCEPTION 'replay finance loop not found';
  END IF;
  EXECUTE replace(v_def, v_old, v_new);
END;
$keep$;

INSERT INTO public.competition_finance_ledger (
  id, season_id, fixture_id, club_short_name, entry_type, amount,
  description, metadata, created_at
) OVERRIDING SYSTEM VALUE
SELECT
  563367, 1, 9060, 'BOC', 'gov_fine_compensation', -2500000,
  format(
    'Fine — [TACTICS] Individual Player Instructions used — Instructions not shown (not possible to see if used or not). Setup sequence starts at 14:44. — MD%s vs %s',
    f.matchday,
    coalesce(public.club_display_name(f.home_club_short_name), f.home_club_short_name)
  ),
  jsonb_build_object(
    'tariff_code', 'non_display_player_instructions',
    'direction', 'fine',
    'category', 'matchday'
  ),
  '2026-11-16 17:02:52.183521+00'::timestamptz
FROM public.competition_fixtures f
WHERE f.id = 9060
  AND NOT EXISTS (SELECT 1 FROM public.competition_finance_ledger l WHERE l.id = 563367);

UPDATE public.competition_fine_applied a
SET ledger_id = 563367,
    description = l.description
FROM public.competition_finance_ledger l
WHERE a.id = 2433111
  AND l.id = 563367
  AND (a.ledger_id IS DISTINCT FROM 563367 OR a.description IS DISTINCT FROM l.description);

-- Replay had credited these amounts back. Charge them again. No second bank leg.
DO $charge$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.competition_finance_ledger
    WHERE id = 563367 AND amount = -2500000
      AND coalesce(metadata->>'replay_recharged', '') = '1'
  ) THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.competition_finance_ledger WHERE id = 563367 AND amount = -2500000
    ) THEN
      RAISE EXCEPTION 'Boca fine line missing';
    END IF;
    PERFORM public.competition_credit_club_balance('BOC', -2500000);
    UPDATE public.competition_finance_ledger
    SET metadata = coalesce(metadata, '{}'::jsonb) || '{"replay_recharged":"1"}'::jsonb
    WHERE id = 563367;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.competition_finance_ledger
    WHERE id = 563049 AND amount = -1500000
      AND coalesce(metadata->>'replay_recharged', '') = '1'
  ) THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.competition_finance_ledger WHERE id = 563049 AND amount = -1500000
    ) THEN
      RAISE EXCEPTION 'Corinthians fine line missing';
    END IF;
    PERFORM public.competition_credit_club_balance('COR', -1500000);
    UPDATE public.competition_finance_ledger
    SET metadata = coalesce(metadata, '{}'::jsonb) || '{"replay_recharged":"1"}'::jsonb
    WHERE id = 563049;
  END IF;
END;
$charge$;

DELETE FROM public.bank_ledger b
WHERE b.club_ledger_id IN (563367, 563049)
  AND b.id NOT IN (529769, 529454);

SELECT jsonb_build_object(
  'keeps_fines', position(
    'fines stay on a replay'
    IN pg_get_functiondef('public.admin_fixture_reset_for_replay(bigint,text,text)'::regprocedure)
  ) > 0,
  'boc', (
    SELECT l.description FROM public.competition_finance_ledger l WHERE l.id = 563367
  ),
  'boc_bank', (
    SELECT count(*) FROM public.bank_ledger b WHERE b.club_ledger_id = 563367
  ),
  'cor_bank', (
    SELECT count(*) FROM public.bank_ledger b WHERE b.club_ledger_id = 563049
  ),
  'fixture', (
    SELECT jsonb_build_object('status', f.status, 'hg', f.home_goals, 'ag', f.away_goals, 'reset', f.admin_replay_reset_at)
    FROM public.competition_fixtures f WHERE f.id = 9060
  )
);
