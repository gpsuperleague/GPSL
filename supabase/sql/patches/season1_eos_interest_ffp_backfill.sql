-- =============================================================================
-- Season 1 EOS backfill: debt interest, FFP, balance interest (ledger + archive)
--
-- WHY Season 1 still shows ₿0:
--   Close Finances during Season 1 only posted wage bills. Debt interest, FFP,
--   and 0.5% balance interest were added later for Season 2 and were never
--   applied to Season 1. Archive repair cannot restore rows that never existed.
--
-- This backfill reconstructs what Close Finances would have posted:
--   balance = archive opening + sum(Season 1 ledger except EOS types)
--   then debt interest → FFP → balance interest (same order as live Close Finances)
--
-- Does NOT change Club_Finances (Season 2 cash unchanged). Display / archive only.
-- Balance interest stays ₿0 for clubs that finished Season 1 negative (correct).
-- Safe re-run via competition_season_charge_paid.
-- =============================================================================

DO $backfill$
DECLARE
  v_sid bigint;
  v_label text;
  v_club text;
  v_opening numeric;
  v_pre_eos numeric;
  v_bal numeric;
  v_debt numeric;
  v_ffp numeric;
  v_credit numeric;
  v_rate_debt numeric;
  v_rate_credit numeric;
  v_ffp_threshold numeric;
  v_ffp_fine numeric;
  v_debt_n int := 0;
  v_ffp_n int := 0;
  v_credit_n int := 0;
  v_archived int := 0;
BEGIN
  SELECT s.id, s.label
  INTO v_sid, v_label
  FROM public.competition_seasons s
  WHERE s.label IN ('1', 'Season 1')
  ORDER BY CASE WHEN s.label = '1' THEN 0 ELSE 1 END, s.id DESC
  LIMIT 1;

  IF v_sid IS NULL THEN
    RAISE EXCEPTION 'Season 1 not found';
  END IF;

  SELECT
    coalesce(nullif(b.eos_debt_interest_pct, 0), b.policy_interest_rate_pct, 5.00),
    greatest(coalesce(b.eos_balance_interest_pct, 0.50), 0) / 100.0,
    greatest(coalesce(b.eos_ffp_debt_threshold, 100000000), 0),
    greatest(coalesce(b.eos_ffp_flat_fine, 10000000), 0)
  INTO v_rate_debt, v_rate_credit, v_ffp_threshold, v_ffp_fine
  FROM public.gpsl_bank_account b
  WHERE b.id = 1;

  v_rate_debt := greatest(coalesce(v_rate_debt, 5.00), 0) / 100.0;
  v_rate_credit := coalesce(v_rate_credit, 0.005);
  v_ffp_threshold := coalesce(v_ffp_threshold, 100000000);
  v_ffp_fine := coalesce(v_ffp_fine, 10000000);

  FOR v_club IN
    SELECT DISTINCT u.club_short_name
    FROM (
      SELECT ccs.club_short_name
      FROM public.competition_club_seasons ccs
      WHERE ccs.season_id = v_sid
        AND ccs.division IN ('superleague', 'championship_a', 'championship_b')
      UNION
      SELECT a.club_short_name
      FROM public.competition_club_finance_season_archive a
      WHERE a.season_id = v_sid
      UNION
      SELECT l.club_short_name
      FROM public.competition_finance_ledger l
      WHERE l.season_id = v_sid
    ) u
    WHERE u.club_short_name IS NOT NULL
      AND u.club_short_name <> 'FOREIGN'
    ORDER BY 1
  LOOP
    SELECT a.opening_balance
    INTO v_opening
    FROM public.competition_club_finance_season_archive a
    WHERE a.season_id = v_sid
      AND a.club_short_name = v_club;

    IF v_opening IS NULL THEN
      SELECT nullif((l.metadata->>'starting_budget')::numeric, 0)
      INTO v_opening
      FROM public.competition_finance_ledger l
      WHERE l.club_short_name = v_club
        AND l.entry_type = 'infra_purchase'
      ORDER BY l.created_at ASC
      LIMIT 1;
    END IF;

    v_opening := coalesce(v_opening, 0);

    SELECT coalesce(sum(l.amount), 0)
    INTO v_pre_eos
    FROM public.competition_finance_ledger l
    WHERE l.season_id = v_sid
      AND l.club_short_name = v_club
      AND l.entry_type NOT IN (
        'eos_debt_interest', 'eos_ffp_charge', 'eos_balance_interest'
      );

    v_bal := v_opening + v_pre_eos;

    -- 1) Debt interest
    IF v_bal < 0
       AND NOT EXISTS (
         SELECT 1 FROM public.competition_season_charge_paid p
         WHERE p.season_id = v_sid
           AND p.club_short_name = v_club
           AND p.charge_type = 'eos_debt_interest'
       )
    THEN
      v_debt := round(abs(v_bal) * v_rate_debt, 0);
      IF v_debt > 0 THEN
        INSERT INTO public.competition_finance_ledger (
          season_id, club_short_name, entry_type, amount, description, metadata
        ) VALUES (
          v_sid, v_club, 'eos_debt_interest', -v_debt,
          format(
            'End of season debt interest — %s%% on overdraft ₿%s (Season 1 backfill)',
            to_char(v_rate_debt * 100, 'FM999990.###'),
            to_char(abs(v_bal), 'FM999,999,999,999')
          ),
          jsonb_build_object(
            'balance_snapshot', v_bal,
            'rate_pct', v_rate_debt * 100,
            'season1_backfill', true,
            'cash_applied', false
          )
        );

        INSERT INTO public.competition_season_charge_paid (
          season_id, club_short_name, charge_type, amount, metadata
        ) VALUES (
          v_sid, v_club, 'eos_debt_interest', v_debt,
          jsonb_build_object(
            'balance_snapshot', v_bal,
            'rate_pct', v_rate_debt * 100,
            'season1_backfill', true,
            'cash_applied', false
          )
        );

        v_debt_n := v_debt_n + 1;
      END IF;
    END IF;

    -- Balance after debt (include any existing debt lines)
    SELECT v_opening + v_pre_eos + coalesce(sum(l.amount), 0)
    INTO v_bal
    FROM public.competition_finance_ledger l
    WHERE l.season_id = v_sid
      AND l.club_short_name = v_club
      AND l.entry_type = 'eos_debt_interest';

    -- 2) FFP
    IF v_bal <= -v_ffp_threshold
       AND NOT EXISTS (
         SELECT 1 FROM public.competition_season_charge_paid p
         WHERE p.season_id = v_sid
           AND p.club_short_name = v_club
           AND p.charge_type = 'eos_ffp_charge'
       )
    THEN
      v_ffp := v_ffp_fine;
      IF v_ffp > 0 THEN
        INSERT INTO public.competition_finance_ledger (
          season_id, club_short_name, entry_type, amount, description, metadata
        ) VALUES (
          v_sid, v_club, 'eos_ffp_charge', -v_ffp,
          format(
            'FFP charge — balance ₿%s ≤ −₿%s (Season 1 backfill)',
            to_char(v_bal, 'FM999,999,999,999'),
            to_char(v_ffp_threshold, 'FM999,999,999,999')
          ),
          jsonb_build_object(
            'balance_snapshot', v_bal,
            'threshold', v_ffp_threshold,
            'fine', v_ffp,
            'season1_backfill', true,
            'cash_applied', false
          )
        );

        INSERT INTO public.competition_season_charge_paid (
          season_id, club_short_name, charge_type, amount, metadata
        ) VALUES (
          v_sid, v_club, 'eos_ffp_charge', v_ffp,
          jsonb_build_object(
            'balance_snapshot', v_bal,
            'season1_backfill', true,
            'cash_applied', false
          )
        );

        v_ffp_n := v_ffp_n + 1;
      END IF;
    END IF;

    -- Balance after FFP
    SELECT v_opening + v_pre_eos + coalesce(sum(l.amount), 0)
    INTO v_bal
    FROM public.competition_finance_ledger l
    WHERE l.season_id = v_sid
      AND l.club_short_name = v_club
      AND l.entry_type IN ('eos_debt_interest', 'eos_ffp_charge');

    -- 3) Balance interest (positive only — negative clubs correctly stay ₿0)
    IF v_bal > 0
       AND NOT EXISTS (
         SELECT 1 FROM public.competition_season_charge_paid p
         WHERE p.season_id = v_sid
           AND p.club_short_name = v_club
           AND p.charge_type = 'eos_balance_interest'
       )
    THEN
      v_credit := round(v_bal * v_rate_credit, 0);
      IF v_credit > 0 THEN
        INSERT INTO public.competition_finance_ledger (
          season_id, club_short_name, entry_type, amount, description, metadata
        ) VALUES (
          v_sid, v_club, 'eos_balance_interest', v_credit,
          format(
            'End of season balance interest — %s%% on ₿%s (Season 1 backfill)',
            to_char(v_rate_credit * 100, 'FM999990.###'),
            to_char(v_bal, 'FM999,999,999,999')
          ),
          jsonb_build_object(
            'balance_snapshot', v_bal,
            'rate_pct', v_rate_credit * 100,
            'season1_backfill', true,
            'cash_applied', false
          )
        );

        INSERT INTO public.competition_season_charge_paid (
          season_id, club_short_name, charge_type, amount, metadata
        ) VALUES (
          v_sid, v_club, 'eos_balance_interest', v_credit,
          jsonb_build_object(
            'balance_snapshot', v_bal,
            'season1_backfill', true,
            'cash_applied', false
          )
        );

        v_credit_n := v_credit_n + 1;
      END IF;
    END IF;
  END LOOP;

  IF to_regprocedure('public.competition_archive_club_finances_for_season(bigint)') IS NOT NULL THEN
    v_archived := public.competition_archive_club_finances_for_season(v_sid);
  END IF;

  RAISE NOTICE
    'Season 1 EOS backfill (%) id=%: debt=% clubs; FFP=% clubs; balance interest=% clubs; archive=% clubs. Season 2 cash unchanged.',
    v_label, v_sid, v_debt_n, v_ffp_n, v_credit_n, v_archived;
END;
$backfill$;

SELECT
  l.entry_type,
  count(*) AS clubs,
  round(sum(l.amount)) AS total_amount
FROM public.competition_finance_ledger l
JOIN public.competition_seasons s ON s.id = l.season_id
WHERE s.label IN ('1', 'Season 1')
  AND l.entry_type IN ('eos_debt_interest', 'eos_ffp_charge', 'eos_balance_interest')
GROUP BY l.entry_type
ORDER BY l.entry_type;

NOTIFY pgrst, 'reload schema';
