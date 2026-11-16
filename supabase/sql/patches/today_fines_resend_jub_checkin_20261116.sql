-- Resend today's fine notes in the match format.
-- September MD6 AC Milan vs Jubilo: both checked in, check-in fine and strike removed.
-- Safe to refuse a second run: the fine must still be open.

DO $jub$
DECLARE
  v_ledger bigint;
  v_amount numeric;
  v_bank numeric;
BEGIN
  SELECT a.ledger_id, a.amount
  INTO v_ledger, v_amount
  FROM public.competition_fine_applied a
  WHERE a.id = 2417940
    AND a.fixture_id = 9017
    AND a.club_short_name = 'ACM'
    AND a.tariff_code = 'match_strike'
    AND NOT coalesce(a.waived, false);

  IF NOT FOUND THEN
    RAISE EXCEPTION 'AC Milan check-in fine on fixture 9017 is not open';
  END IF;

  IF v_amount IS DISTINCT FROM 500000 THEN
    RAISE EXCEPTION 'Unexpected fine amount %', v_amount;
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.competition_finance_ledger l
    WHERE l.id = v_ledger
      AND l.club_short_name = 'ACM'
      AND l.amount = -500000
      AND l.entry_type = 'gov_fine_compensation'
  ) THEN
    RAISE EXCEPTION 'Ledger % does not match the AC Milan fine', v_ledger;
  END IF;

  PERFORM public.competition_credit_club_balance('ACM', 500000);

  SELECT coalesce(sum(b.amount), 0) INTO v_bank
  FROM public.bank_ledger b
  WHERE b.club_ledger_id = v_ledger;

  UPDATE public.gpsl_bank_account
  SET reserves = reserves - v_bank,
      updated_at = now()
  WHERE id = 1;

  DELETE FROM public.bank_ledger b WHERE b.club_ledger_id = v_ledger;
  DELETE FROM public.competition_finance_ledger l WHERE l.id = v_ledger;

  UPDATE public.competition_fine_applied
  SET waived = true,
      ledger_id = NULL,
      note = 'Missed check-in — removed 2026-11-16. Both clubs checked in for the result.'
  WHERE id = 2417940;

  UPDATE public.competition_fixture_no_show_events
  SET ease_in_void = true
  WHERE fixture_id = 9017
    AND club_short_name = 'ACM'
    AND NOT coalesce(ease_in_void, false);

  UPDATE public.competition_owner_season_strikes
  SET strike_count = greatest(0, strike_count - 1),
      updated_at = now()
  WHERE season_id = 1
    AND owner_id = '9bfe5b15-2280-4c4a-8ae3-48a68cbcd637';

  UPDATE public.competition_inbox
  SET archived_at = coalesce(archived_at, now()),
      read_at = coalesce(read_at, now())
  WHERE id IN (2445642, 2445643);

  UPDATE public.competition_fixture_play_now_session
  SET status = 'expired',
      updated_at = now()
  WHERE fixture_id = 9017
    AND status IN ('open', 'both_ready');

  INSERT INTO public.competition_fixture_checkin (fixture_id, club_short_name, checked_in_at)
  VALUES
    (9017, 'ACM', now()),
    (9017, 'JUB', now())
  ON CONFLICT (fixture_id, club_short_name) DO NOTHING;

  UPDATE public.competition_fixture_schedule
  SET admin_result_unlock_at = now(),
      admin_result_unlock_note = 'Both clubs checked in. Check-in fine on this fixture removed.',
      updated_at = now()
  WHERE fixture_id = 9017;

  PERFORM public.owner_inbox_send(
    'fine_applied',
    'Check-in fine removed',
    E'September MD6 — AC Milan vs Jubilo Iwata\nThe ₿500,000 missed check-in charge has been removed. Both clubs can enter the result.',
    'ACM',
    NULL, 9017, NULL, NULL, NULL,
    'matchday.html?fixture=9017',
    'fine_removed:9017',
    'september', 1, NULL
  );
END;
$jub$;

DO $resend$
DECLARE
  v_id bigint;
BEGIN
  DELETE FROM public.competition_inbox
  WHERE dedupe_key IN ('fine:2401665', 'fine:2410596', 'fine:2410597');

  FOREACH v_id IN ARRAY ARRAY[2401665, 2410596, 2410597]::bigint[]
  LOOP
    IF public.owner_inbox_notify_fine_applied(v_id) IS NULL THEN
      RAISE EXCEPTION 'Fine % was not resent', v_id;
    END IF;
  END LOOP;
END;
$resend$;

SELECT jsonb_build_object(
  'acm_waived', (
    SELECT a.waived FROM public.competition_fine_applied a WHERE a.id = 2417940
  ),
  'acm_strikes', (
    SELECT s.strike_count
    FROM public.competition_owner_season_strikes s
    WHERE s.season_id = 1
      AND s.owner_id = '9bfe5b15-2280-4c4a-8ae3-48a68cbcd637'
  ),
  'checked_in', (
    SELECT coalesce(jsonb_agg(c.club_short_name ORDER BY c.club_short_name), '[]'::jsonb)
    FROM public.competition_fixture_checkin c
    WHERE c.fixture_id = 9017
  ),
  'view', (
    SELECT jsonb_build_object(
      'home_in', v.home_checked_in,
      'away_in', v.away_checked_in,
      'kick', v.agreed_kickoff_at,
      'sched', v.schedule_status
    )
    FROM public.competition_fixtures_public v
    WHERE v.id = 9017
  ),
  'resent', (
    SELECT coalesce(jsonb_agg(jsonb_build_object(
      'club', i.recipient_club_short_name,
      'title', i.title,
      'body', left(i.body, 140),
      'unread', i.read_at IS NULL
    ) ORDER BY i.id), '[]'::jsonb)
    FROM public.competition_inbox i
    WHERE i.dedupe_key IN ('fine:2401665', 'fine:2410596', 'fine:2410597')
  )
);
