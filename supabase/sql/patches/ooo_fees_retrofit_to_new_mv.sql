-- =============================================================================
-- APPLY: retrofit One of our Own fees to current market values
-- =============================================================================
-- Prerequisite: Players.market_value already recalculated.
--
-- For each club_one_of_our_own_draws row in the current season where
--   fee <> round(Players.market_value):
--   • Transfer_History.fee              → new MV
--   • club_one_of_our_own_draws.fee      → new MV
--   • competition_finance_ledger amount → -new MV (OooO transfer_purchase)
--   • Club_Finances.balance             -= (new_fee - old_fee)
--       (fee drop → club refunded; fee rise → club charged more)
--   • gpsl_bank_account.reserves        += (new_fee - old_fee)
--   • linked bank_ledger.amount         → +new MV
--
-- Idempotent: skips rows already at new MV.
-- Does not change Season_Signed, wage, designations, or MRP.
--
-- Preview first: ooo_fees_retrofit_to_new_mv_preview.sql
-- =============================================================================

DO $$
DECLARE
  r record;
  v_season_id bigint;
  v_season_label text;
  v_old_fee numeric;
  v_new_fee numeric;
  v_delta numeric;
  v_ledger_id bigint;
  v_n int;
  v_updated int := 0;
  v_skipped int := 0;
  v_missing_ledger int := 0;
  v_missing_history int := 0;
  v_total_delta numeric := 0;
BEGIN
  SELECT s.id, s.label
  INTO v_season_id, v_season_label
  FROM public.competition_seasons s
  WHERE s.is_current = true
  ORDER BY s.id DESC
  LIMIT 1;

  IF v_season_id IS NULL THEN
    RAISE EXCEPTION 'No current competition season';
  END IF;

  RAISE NOTICE 'Retrofitting OooO fees for season % (%)', v_season_id, coalesce(v_season_label, '?');

  FOR r IN
    SELECT
      d.id AS draw_id,
      d.club_short_name,
      btrim(d.player_id::text) AS player_id,
      d.fee::numeric AS draw_fee,
      d.transfer_history_id,
      coalesce(p."Name"::text, d.player_id::text) AS player_name,
      round(coalesce(nullif(btrim(p.market_value::text), '')::numeric, 0)) AS player_mv,
      h.id AS history_id,
      h.fee::numeric AS history_fee
    FROM public.club_one_of_our_own_draws d
    JOIN public."Players" p
      ON btrim(p."Konami_ID"::text) = btrim(d.player_id::text)
    LEFT JOIN public."Transfer_History" h ON h.id = d.transfer_history_id
    WHERE d.season_id = v_season_id
    ORDER BY d.id
  LOOP
    v_new_fee := r.player_mv;
    v_old_fee := coalesce(r.draw_fee, r.history_fee);

    IF v_new_fee IS NULL OR v_new_fee <= 0 THEN
      RAISE NOTICE 'Skip % (%) — no positive market value', r.player_name, r.player_id;
      v_skipped := v_skipped + 1;
      CONTINUE;
    END IF;

    IF v_old_fee IS NULL THEN
      RAISE NOTICE 'Skip % (%) — no stored fee', r.player_name, r.player_id;
      v_skipped := v_skipped + 1;
      CONTINUE;
    END IF;

    IF v_old_fee = v_new_fee
       AND (r.history_fee IS NULL OR r.history_fee = v_new_fee) THEN
      v_skipped := v_skipped + 1;
      CONTINUE;
    END IF;

    v_delta := v_new_fee - v_old_fee;

    -- Draw record
    UPDATE public.club_one_of_our_own_draws d
    SET fee = v_new_fee
    WHERE d.id = r.draw_id
      AND d.fee IS DISTINCT FROM v_new_fee;

    -- Transfer history
    IF r.history_id IS NOT NULL THEN
      UPDATE public."Transfer_History" h
      SET fee = v_new_fee
      WHERE h.id = r.history_id
        AND h.fee IS DISTINCT FROM v_new_fee;
    ELSE
      v_missing_history := v_missing_history + 1;
      RAISE NOTICE 'Warn % — draw has no Transfer_History row', r.player_name;
    END IF;

    -- Club ledger line (in-place)
    v_ledger_id := NULL;
    SELECT l.id
    INTO v_ledger_id
    FROM public.competition_finance_ledger l
    WHERE l.entry_type = 'transfer_purchase'
      AND coalesce(l.metadata->>'one_of_our_own', '') IN ('true', 't', '1')
      AND (
        (r.history_id IS NOT NULL AND l.metadata->>'transfer_history_id' = r.history_id::text)
        OR (
          l.club_short_name = r.club_short_name
          AND l.metadata->>'player_id' = r.player_id
        )
      )
    ORDER BY l.id
    LIMIT 1;

    IF v_ledger_id IS NOT NULL THEN
      UPDATE public.competition_finance_ledger l
      SET
        amount = -v_new_fee,
        description = 'One of our Own draw: ' || r.player_name
      WHERE l.id = v_ledger_id;

      UPDATE public.bank_ledger b
      SET
        amount = v_new_fee,
        description = 'One of our Own draw: ' || r.player_name
      WHERE b.club_ledger_id = v_ledger_id;
      GET DIAGNOSTICS v_n = ROW_COUNT;
      IF v_n = 0 THEN
        -- Create missing bank mirror if original post lost it
        INSERT INTO public.bank_ledger (
          entry_type, amount, description, club_short_name, club_ledger_id, metadata
        )
        SELECT
          l.entry_type,
          v_new_fee,
          l.description,
          l.club_short_name,
          l.id,
          coalesce(l.metadata, '{}'::jsonb)
        FROM public.competition_finance_ledger l
        WHERE l.id = v_ledger_id;
      END IF;
    ELSE
      v_missing_ledger := v_missing_ledger + 1;
      RAISE NOTICE 'Warn % (%) — no OooO transfer_purchase ledger found', r.player_name, r.club_short_name;
    END IF;

    -- Club balance: originally −old_fee; should be −new_fee → apply −delta
    IF v_delta <> 0 THEN
      UPDATE public."Club_Finances" cf
      SET balance = coalesce(cf.balance, 0) - v_delta
      WHERE cf.club_name = r.club_short_name;

      IF NOT FOUND THEN
        RAISE NOTICE 'Warn % — Club_Finances missing for %', r.player_name, r.club_short_name;
      END IF;

      -- Bank: originally +old_fee into reserves; should be +new_fee → apply +delta
      UPDATE public.gpsl_bank_account
      SET reserves = coalesce(reserves, 0) + v_delta,
          updated_at = now()
      WHERE id = 1;
    END IF;

    v_updated := v_updated + 1;
    v_total_delta := v_total_delta + v_delta;

    RAISE NOTICE
      'OooO % → % : fee % → % (delta %), club %',
      r.player_name,
      r.club_short_name,
      to_char(v_old_fee, 'FM999,999,999,999'),
      to_char(v_new_fee, 'FM999,999,999,999'),
      to_char(v_delta, 'FM999,999,999,999'),
      r.club_short_name;
  END LOOP;

  RAISE NOTICE
    'Done season %. updated=% skipped=% missing_history=% missing_ledger=% total_fee_delta=%',
    v_season_id, v_updated, v_skipped, v_missing_history, v_missing_ledger,
    to_char(v_total_delta, 'FM999,999,999,999');
END $$;

NOTIFY pgrst, 'reload schema';

-- Verify: OooO draws still mismatched vs Players MV (should be 0)
WITH cur AS (
  SELECT id AS season_id
  FROM public.competition_seasons
  WHERE is_current = true
  ORDER BY id DESC
  LIMIT 1
)
SELECT
  d.club_short_name,
  p."Name",
  d.player_id,
  d.fee AS draw_fee,
  round(coalesce(nullif(btrim(p.market_value::text), '')::numeric, 0)) AS player_mv,
  h.fee AS history_fee,
  l.amount AS ledger_amount
FROM public.club_one_of_our_own_draws d
JOIN cur ON cur.season_id = d.season_id
JOIN public."Players" p
  ON btrim(p."Konami_ID"::text) = btrim(d.player_id::text)
LEFT JOIN public."Transfer_History" h ON h.id = d.transfer_history_id
LEFT JOIN LATERAL (
  SELECT lg.amount
  FROM public.competition_finance_ledger lg
  WHERE lg.entry_type = 'transfer_purchase'
    AND coalesce(lg.metadata->>'one_of_our_own', '') IN ('true', 't', '1')
    AND lg.metadata->>'transfer_history_id' = d.transfer_history_id::text
  ORDER BY lg.id
  LIMIT 1
) l ON true
WHERE d.fee IS DISTINCT FROM round(coalesce(nullif(btrim(p.market_value::text), '')::numeric, 0))
   OR h.fee IS DISTINCT FROM round(coalesce(nullif(btrim(p.market_value::text), '')::numeric, 0))
   OR l.amount IS DISTINCT FROM -round(coalesce(nullif(btrim(p.market_value::text), '')::numeric, 0))
ORDER BY p."Name";

-- Sample of current-season OooO fees after retrofit
WITH cur AS (
  SELECT id AS season_id
  FROM public.competition_seasons
  WHERE is_current = true
  ORDER BY id DESC
  LIMIT 1
)
SELECT
  d.club_short_name,
  p."Name",
  d.fee AS draw_fee,
  round(coalesce(nullif(btrim(p.market_value::text), '')::numeric, 0)) AS player_mv,
  h.fee AS history_fee,
  cf.balance AS club_balance
FROM public.club_one_of_our_own_draws d
JOIN cur ON cur.season_id = d.season_id
JOIN public."Players" p
  ON btrim(p."Konami_ID"::text) = btrim(d.player_id::text)
LEFT JOIN public."Transfer_History" h ON h.id = d.transfer_history_id
LEFT JOIN public."Club_Finances" cf ON cf.club_name = d.club_short_name
ORDER BY d.club_short_name;
