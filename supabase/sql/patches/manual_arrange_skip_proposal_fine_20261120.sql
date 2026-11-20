-- Manual arrange has no proposal deadline.
-- Both clubs off the GPSL system: skip the no-proposal fine and the reminder.
-- Return the two November-lock charges where that had already happened.
-- No proposal or reply strikes were on a manual-arrange fixture.

DO $fines$
DECLARE
  v_def text;
  v_old text;
  v_new text;
BEGIN
  v_def := replace(
    pg_get_functiondef('public.competition_enforce_scheduling_arrangement_fines(bigint,text)'::regprocedure),
    E'\r\n', E'\n'
  );
  IF position('manual arrange proposal fine skipped' IN v_def) = 0 THEN
    v_old := replace($old$        v_tariff_code := NULL;
      END IF;
    END IF;

    IF v_tariff_code IS NULL THEN
      v_skipped := v_skipped + 1;
      CONTINUE;
    END IF;$old$, E'\r\n', E'\n');
    v_new := replace($new$        v_tariff_code := NULL;
      END IF;
    END IF;

    -- manual arrange proposal fine skipped
    IF v_tariff_code IS NOT NULL
       AND to_regprocedure('public.fixture_is_manual_black_box(bigint)') IS NOT NULL
       AND public.fixture_is_manual_black_box(v_f.id) THEN
      v_tariff_code := NULL;
    END IF;

    IF v_tariff_code IS NULL THEN
      v_skipped := v_skipped + 1;
      CONTINUE;
    END IF;$new$, E'\r\n', E'\n');
    IF position(v_old IN v_def) = 0 THEN
      RAISE EXCEPTION 'arrangement fines: manual-arrange needle not found';
    END IF;
    IF (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 THEN
      RAISE EXCEPTION 'arrangement fines: manual-arrange needle is not unique';
    END IF;
    EXECUTE replace(v_def, v_old, v_new);
  END IF;
END;
$fines$;

DO $remind$
DECLARE
  v_def text;
  v_old text;
  v_new text;
BEGIN
  v_def := replace(
    pg_get_functiondef('public.match_owner_guidance_reminders()'::regprocedure),
    E'\r\n', E'\n'
  );
  IF position('manual arrange proposal reminder skipped' IN v_def) = 0 THEN
    v_old := replace($old$      AND NOT public.match_schedule_home_has_proposed(f.id, now())
      AND NOT EXISTS (
        SELECT 1 FROM public.competition_fixture_schedule s
        WHERE s.fixture_id = f.id AND s.status = 'agreed'
      )$old$, E'\r\n', E'\n');
    v_new := replace($new$      AND NOT public.match_schedule_home_has_proposed(f.id, now())
      -- manual arrange proposal reminder skipped
      AND NOT (
        to_regprocedure('public.fixture_is_manual_black_box(bigint)') IS NOT NULL
        AND public.fixture_is_manual_black_box(f.id)
      )
      AND NOT EXISTS (
        SELECT 1 FROM public.competition_fixture_schedule s
        WHERE s.fixture_id = f.id AND s.status = 'agreed'
      )$new$, E'\r\n', E'\n');
    IF position(v_old IN v_def) = 0 THEN
      RAISE EXCEPTION 'arrangement reminders: manual-arrange needle not found';
    END IF;
    IF (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 THEN
      RAISE EXCEPTION 'arrangement reminders: manual-arrange needle is not unique';
    END IF;
    EXECUTE replace(v_def, v_old, v_new);
  END IF;
END;
$remind$;

CREATE TEMP TABLE manual_propose_refunds (
  fine_id bigint,
  fixture_id bigint,
  club text,
  amount numeric,
  ledger_id bigint
);

DO $refund$
DECLARE
  v_row record;
  v_bank int;
  v_led numeric;
  v_total numeric := 0;
  v_accounts int;
  v_strikes int;
  v_opp text;
BEGIN
  SELECT count(*) INTO v_strikes
  FROM (
    SELECT s.fixture_id
    FROM public.competition_fixture_proposal_strikes s
    JOIN public.competition_fixtures f ON f.id = s.fixture_id
    WHERE s.ease_in_void IS NOT TRUE
      AND NOT public.club_gpsl_match_system_on(f.home_club_short_name, f.season_id, f.gpsl_month)
      AND NOT public.club_gpsl_match_system_on(f.away_club_short_name, f.season_id, f.gpsl_month)
    UNION ALL
    SELECT s.fixture_id
    FROM public.competition_fixture_reply_strikes s
    JOIN public.competition_fixtures f ON f.id = s.fixture_id
    WHERE s.ease_in_void IS NOT TRUE
      AND NOT public.club_gpsl_match_system_on(f.home_club_short_name, f.season_id, f.gpsl_month)
      AND NOT public.club_gpsl_match_system_on(f.away_club_short_name, f.season_id, f.gpsl_month)
  ) q;

  IF v_strikes <> 0 THEN
    RAISE EXCEPTION 'manual arrange fixtures still have % strikes', v_strikes;
  END IF;

  FOR v_row IN
    SELECT
      a.id AS fine_id,
      a.ledger_id,
      a.amount,
      a.club_short_name,
      a.fixture_id,
      f.matchday,
      f.gpsl_month,
      f.season_id,
      f.away_club_short_name
    FROM public.competition_fine_applied a
    JOIN public.competition_fixtures f ON f.id = a.fixture_id
    WHERE a.tariff_code IN ('match_mgmt_no_proposal', 'match_late_arrangement')
      AND a.ledger_id IS NOT NULL
      AND a.amount > 0
      AND NOT public.club_gpsl_match_system_on(f.home_club_short_name, f.season_id, f.gpsl_month)
      AND NOT public.club_gpsl_match_system_on(f.away_club_short_name, f.season_id, f.gpsl_month)
      AND (
        SELECT p.set_at
        FROM public.club_match_system_preference p
        JOIN public."Clubs" c ON c."ShortName" = p.club_short_name
        WHERE p.club_short_name = f.home_club_short_name
          AND p.season_id = f.season_id
          AND p.gpsl_system_on = false
          AND p.set_by_owner_id IS NOT DISTINCT FROM c.owner_id
          AND p.half = CASE
            WHEN public.gpsl_month_match_system_half(f.gpsl_month) = 'h2'
             AND EXISTS (
               SELECT 1
               FROM public.club_match_system_preference p2
               JOIN public."Clubs" c2 ON c2."ShortName" = p2.club_short_name
               WHERE p2.club_short_name = f.home_club_short_name
                 AND p2.season_id = f.season_id
                 AND p2.half = 'h2'
                 AND p2.set_by_owner_id IS NOT DISTINCT FROM c2.owner_id
             ) THEN 'h2'
            ELSE 'h1'
          END
      ) <= a.applied_at
      AND (
        SELECT p.set_at
        FROM public.club_match_system_preference p
        JOIN public."Clubs" c ON c."ShortName" = p.club_short_name
        WHERE p.club_short_name = f.away_club_short_name
          AND p.season_id = f.season_id
          AND p.gpsl_system_on = false
          AND p.set_by_owner_id IS NOT DISTINCT FROM c.owner_id
          AND p.half = CASE
            WHEN public.gpsl_month_match_system_half(f.gpsl_month) = 'h2'
             AND EXISTS (
               SELECT 1
               FROM public.club_match_system_preference p2
               JOIN public."Clubs" c2 ON c2."ShortName" = p2.club_short_name
               WHERE p2.club_short_name = f.away_club_short_name
                 AND p2.season_id = f.season_id
                 AND p2.half = 'h2'
                 AND p2.set_by_owner_id IS NOT DISTINCT FROM c2.owner_id
             ) THEN 'h2'
            ELSE 'h1'
          END
      ) <= a.applied_at
    ORDER BY a.id
  LOOP
    SELECT count(*) INTO v_bank
    FROM public.bank_ledger b
    WHERE b.club_ledger_id = v_row.ledger_id
      AND b.amount = v_row.amount
      AND b.club_short_name = v_row.club_short_name;

    IF v_bank <> 1 THEN
      RAISE EXCEPTION 'bank rows % for ledger %', v_bank, v_row.ledger_id;
    END IF;

    SELECT l.amount INTO v_led
    FROM public.competition_finance_ledger l
    WHERE l.id = v_row.ledger_id
      AND l.club_short_name = v_row.club_short_name
      AND l.fixture_id = v_row.fixture_id
      AND l.entry_type = 'gov_fine_compensation';

    IF v_led IS DISTINCT FROM -v_row.amount THEN
      RAISE EXCEPTION 'ledger % amount %', v_row.ledger_id, v_led;
    END IF;

    PERFORM public.competition_credit_club_balance(v_row.club_short_name, v_row.amount);

    DELETE FROM public.bank_ledger b
    WHERE b.club_ledger_id = v_row.ledger_id
      AND b.amount = v_row.amount;

    DELETE FROM public.competition_fine_applied a
    WHERE a.id = v_row.fine_id
      AND a.ledger_id = v_row.ledger_id;

    DELETE FROM public.competition_finance_ledger l
    WHERE l.id = v_row.ledger_id;

    v_total := v_total + v_row.amount;

    v_opp := coalesce(
      public.club_display_name(v_row.away_club_short_name),
      v_row.away_club_short_name
    );

    PERFORM public.owner_inbox_send(
      'fine_applied',
      'No-proposal fine returned',
      format(
        'MD%s vs %s is manual arrange. Both clubs are off the GPSL system, so there is no proposal deadline. The %s charge from the November lock is back on the club balance.',
        v_row.matchday,
        v_opp,
        to_char(v_row.amount, 'FM999,999,999')
      ),
      v_row.club_short_name,
      NULL,
      v_row.fixture_id,
      NULL, NULL, NULL,
      'fixtures.html',
      'manual_propose_returned:' || v_row.fixture_id::text,
      v_row.gpsl_month,
      v_row.season_id,
      NULL
    );

    INSERT INTO manual_propose_refunds (fine_id, fixture_id, club, amount, ledger_id)
    VALUES (v_row.fine_id, v_row.fixture_id, v_row.club_short_name, v_row.amount, v_row.ledger_id);
  END LOOP;

  IF v_total > 0 THEN
    SELECT count(*) INTO v_accounts FROM public.gpsl_bank_account;
    IF v_accounts <> 1 THEN
      RAISE EXCEPTION 'gpsl bank accounts %', v_accounts;
    END IF;
    UPDATE public.gpsl_bank_account
    SET reserves = reserves - v_total;
  END IF;
END;
$refund$;

SELECT jsonb_build_object(
  'fine_skipped', position(
    'manual arrange proposal fine skipped' IN pg_get_functiondef(
      'public.competition_enforce_scheduling_arrangement_fines(bigint,text)'::regprocedure
    )
  ) > 0,
  'reminder_skipped', position(
    'manual arrange proposal reminder skipped' IN pg_get_functiondef(
      'public.match_owner_guidance_reminders()'::regprocedure
    )
  ) > 0,
  'refunds', (
    SELECT coalesce(jsonb_agg(jsonb_build_object(
      'fine_id', r.fine_id,
      'fixture', r.fixture_id,
      'club', r.club,
      'amount', r.amount,
      'ledger', r.ledger_id
    ) ORDER BY r.fine_id), '[]'::jsonb)
    FROM manual_propose_refunds r
  ),
  'fines_left', (
    SELECT count(*)
    FROM public.competition_fine_applied a
    WHERE a.id IN (2669113, 2669116)
       OR a.ledger_id IN (845952, 845955)
  ),
  'ledgers_left', (
    SELECT count(*)
    FROM public.competition_finance_ledger l
    WHERE l.id IN (845952, 845955)
  ),
  'balances', (
    SELECT jsonb_object_agg(c.club_name, c.balance)
    FROM public."Club_Finances" c
    WHERE c.club_name IN ('CAP', 'VIL', 'SAN')
  ),
  'manual_strikes', (
    SELECT count(*)
    FROM (
      SELECT s.fixture_id
      FROM public.competition_fixture_proposal_strikes s
      JOIN public.competition_fixtures f ON f.id = s.fixture_id
      WHERE s.ease_in_void IS NOT TRUE
        AND NOT public.club_gpsl_match_system_on(f.home_club_short_name, f.season_id, f.gpsl_month)
        AND NOT public.club_gpsl_match_system_on(f.away_club_short_name, f.season_id, f.gpsl_month)
      UNION ALL
      SELECT s.fixture_id
      FROM public.competition_fixture_reply_strikes s
      JOIN public.competition_fixtures f ON f.id = s.fixture_id
      WHERE s.ease_in_void IS NOT TRUE
        AND NOT public.club_gpsl_match_system_on(f.home_club_short_name, f.season_id, f.gpsl_month)
        AND NOT public.club_gpsl_match_system_on(f.away_club_short_name, f.season_id, f.gpsl_month)
    ) q
  )
);
