-- Bank 20 (quiz 30): take back the place prizes, then ₿1,000 thank you
-- to each owner who answered. Safe re-run.

DO $thanks$
DECLARE
  r record;
  n int := 0;
  played int;
  thanks int;
BEGIN
  SELECT count(DISTINCT a.owner_id) INTO played
  FROM public.gpsl_pub_quiz_answer a
  JOIN public.gpsl_pub_quiz_question qq ON qq.id = a.question_id
  JOIN public.gpsl_pub_quiz_round rd ON rd.id = qq.round_id
  WHERE rd.quiz_id = 30;
  IF played <> 4 THEN
    RAISE EXCEPTION 'Expected 4 players on quiz 30, found %', played;
  END IF;

  FOR r IN
    SELECT l.id, l.owner_id, l.amount
    FROM public.owner_finance_ledger l
    WHERE l.metadata->>'source' = 'pub_quiz'
      AND l.metadata->>'quiz_id' = '30'
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
  IF n <> 0 AND n <> 4 THEN
    RAISE EXCEPTION 'Unexpected quiz 30 payout count: %', n;
  END IF;

  SELECT count(*) INTO thanks
  FROM public.owner_finance_ledger l
  WHERE l.metadata->>'source' = 'pub_quiz_thanks'
    AND l.metadata->>'quiz_id' = '30';
  IF thanks = 0 THEN
    FOR r IN
      SELECT DISTINCT a.owner_id
      FROM public.gpsl_pub_quiz_answer a
      JOIN public.gpsl_pub_quiz_question qq ON qq.id = a.question_id
      JOIN public.gpsl_pub_quiz_round rd ON rd.id = qq.round_id
      WHERE rd.quiz_id = 30
    LOOP
      PERFORM public.owner_wallet_ensure(r.owner_id);
      PERFORM public._post_owner_ledger_internal(
        r.owner_id,
        'prize',
        1000,
        'Pub quiz — thank you',
        jsonb_build_object('source', 'pub_quiz_thanks', 'quiz_id', 30),
        NULL,
        true
      );
    END LOOP;
  ELSIF thanks <> 4 THEN
    RAISE EXCEPTION 'Unexpected thank you count: %', thanks;
  END IF;

  UPDATE public.gpsl_pub_quiz
  SET prize_1 = 0,
      prize_2 = 0,
      prize_3 = 0,
      prize_rest = 0,
      updated_at = now()
  WHERE id = 30
    AND prizes_paid_at IS NOT NULL;
END;
$thanks$;

SELECT l.owner_id, l.amount, l.description
FROM public.owner_finance_ledger l
WHERE l.metadata->>'quiz_id' = '30'
  AND l.metadata->>'source' IN ('pub_quiz', 'pub_quiz_thanks')
ORDER BY l.id;
