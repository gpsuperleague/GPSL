-- Take back Building Society prizes from the test pub quizzes.
-- Quizzes 8 and 9 stay finished, but they are marked as tests so the
-- public board does not show them, and they will not pay out again.
-- Safe re-run.

DO $wipe$
DECLARE
  r record;
  n int := 0;
BEGIN
  FOR r IN
    SELECT l.id, l.owner_id, l.amount
    FROM public.owner_finance_ledger l
    WHERE l.metadata->>'source' = 'pub_quiz'
    FOR UPDATE
  LOOP
    UPDATE public.owner_wallets w
    SET balance = round(w.balance - r.amount, 2),
        updated_at = now()
    WHERE w.owner_id = r.owner_id;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'No wallet for owner %', r.owner_id;
    END IF;
    DELETE FROM public.owner_finance_ledger WHERE id = r.id;
    n := n + 1;
  END LOOP;

  IF n <> 0 AND n <> 6 THEN
    RAISE EXCEPTION 'Unexpected pub quiz payout count: %', n;
  END IF;

  UPDATE public.gpsl_pub_quiz
  SET is_test = true,
      updated_at = now()
  WHERE id IN (8, 9)
    AND prizes_paid_at IS NOT NULL;
END;
$wipe$;

SELECT
  (SELECT count(*) FROM public.owner_finance_ledger WHERE metadata->>'source' = 'pub_quiz') AS payouts_left,
  (SELECT count(*) FROM public.gpsl_pub_quiz WHERE id IN (8, 9) AND is_test AND prizes_paid_at IS NOT NULL) AS tests_marked;
