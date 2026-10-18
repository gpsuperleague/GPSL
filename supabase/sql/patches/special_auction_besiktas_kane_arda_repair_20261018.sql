-- =============================================================================
-- Repair: Besiktas Mystery Snap — reverse Arda Güler MV release + reopen Kane
--
-- What went wrong:
--   Settle assigned Kane immediately → squad overflow auto-released Arda (highest
--   rated) for MV. Winner then clicked Take cash → Kane released + Kane MV credited.
--
-- This patch (idempotent where possible):
--   1) Claw back Kane take-cash credit
--   2) Ensure Kane is FA + back on auction exclusions (draft blocked)
--   3) Claw back Arda overflow / keep-prep MV credit; re-sign Arda to BES
--   4) Soft-reverse related Transfer_History rows
--   5) Re-open winner prize options on the Kane special auction
--
-- Run AFTER special_auction_prize_defer_sign_20261018.sql
-- =============================================================================

CREATE TEMP TABLE IF NOT EXISTS _bes_kane_log (step int, detail text) ON COMMIT PRESERVE ROWS;
TRUNCATE _bes_kane_log;

DO $repair$
DECLARE
  v_club text := 'BES';
  v_kane text;
  v_arda text;
  v_auction_id bigint;
  v_h record;
  v_l record;
  v_team text;
  v_n int;
  v_claw numeric;
  v_season_id bigint;
  v_wage numeric;
BEGIN
  SELECT id INTO v_season_id
  FROM public.competition_seasons
  WHERE is_current = true
  ORDER BY id DESC
  LIMIT 1;

  SELECT p."Konami_ID"::text INTO v_kane
  FROM public."Players" p
  WHERE p."Name" ILIKE '%Harry%Kane%'
     OR (p."Name" ILIKE '%Kane%' AND p."Name" ILIKE '%Harry%')
  ORDER BY CASE WHEN p."Name" ILIKE 'Harry Kane' THEN 0 ELSE 1 END, p."Konami_ID"
  LIMIT 1;

  IF v_kane IS NULL THEN
    SELECT a.prize_player_id INTO v_kane
    FROM public.special_auctions a
    WHERE upper(btrim(coalesce(a.winning_club_id, ''))) = v_club
      AND a.prize_type = 'player'
      AND a.status = 'settled'
    ORDER BY a.updated_at DESC NULLS LAST, a.id DESC
    LIMIT 1;
  END IF;

  IF v_kane IS NULL THEN
    RAISE EXCEPTION 'Could not find Harry Kane / BES prize player id';
  END IF;

  SELECT p."Konami_ID"::text INTO v_arda
  FROM public."Players" p
  WHERE p."Name" ILIKE '%Arda%G_l_r%'
     OR p."Name" ILIKE '%Arda Guler%'
     OR p."Name" ILIKE '%Arda Güler%'
  ORDER BY CASE
    WHEN upper(btrim(coalesce(p."Contracted_Team", ''))) = v_club THEN 0
    WHEN p."Contracted_Team" IS NULL THEN 1
    ELSE 2
  END, p."Konami_ID"
  LIMIT 1;

  IF v_arda IS NULL THEN
    RAISE EXCEPTION 'Could not find Arda Güler player id';
  END IF;

  SELECT a.id INTO v_auction_id
  FROM public.special_auctions a
  WHERE upper(btrim(coalesce(a.winning_club_id, ''))) = v_club
    AND a.prize_type = 'player'
    AND a.prize_player_id = v_kane
    AND a.status = 'settled'
  ORDER BY a.updated_at DESC NULLS LAST, a.id DESC
  LIMIT 1;

  IF v_auction_id IS NULL THEN
    SELECT a.id INTO v_auction_id
    FROM public.special_auctions a
    WHERE upper(btrim(coalesce(a.winning_club_id, ''))) = v_club
      AND a.prize_type = 'player'
      AND a.status = 'settled'
    ORDER BY a.updated_at DESC NULLS LAST, a.id DESC
    LIMIT 1;
  END IF;

  INSERT INTO _bes_kane_log VALUES (
    0,
    format('Kane=%s Arda=%s auction=%s club=%s',
      v_kane, v_arda, coalesce(v_auction_id::text, 'none'), v_club)
  );

  -- 1) Claw back Kane take-cash credits (special_auction_prize / take_cash)
  v_claw := 0;
  FOR v_l IN
    SELECT l.*
    FROM public.competition_finance_ledger l
    WHERE upper(btrim(l.club_short_name)) = v_club
      AND l.amount > 0
      AND (
        (
          coalesce(l.metadata->>'action', '') = 'take_cash'
          AND coalesce(l.metadata->>'player_id', '') = v_kane
        )
        OR (
          coalesce(l.metadata->>'special_auction_id', '') = coalesce(v_auction_id::text, '')
          AND coalesce(l.metadata->>'action', '') = 'take_cash'
        )
        OR (
          l.entry_type = 'special_auction_prize'
          AND l.description ILIKE '%taken as cash%'
          AND l.description ILIKE '%' || coalesce(
            (SELECT p."Name" FROM public."Players" p WHERE p."Konami_ID"::text = v_kane),
            'Kane'
          ) || '%'
          AND l.created_at > now() - interval '14 days'
        )
      )
      AND NOT EXISTS (
        SELECT 1 FROM public.competition_finance_ledger r
        WHERE r.metadata->>'refund_of_ledger_id' = l.id::text
           OR r.metadata->>'clawback_of_ledger_id' = l.id::text
      )
  LOOP
    PERFORM public.post_club_ledger(
      v_l.club_short_name,
      v_l.entry_type,
      -v_l.amount,
      'Clawback (Kane take-cash reversed — prize options reopened): ' || coalesce(v_l.description, v_l.entry_type),
      jsonb_build_object(
        'clawback_of_ledger_id', v_l.id,
        'admin_reversal', true,
        'special_auction_id', v_auction_id,
        'player_id', v_kane,
        'reason', 'besiktas_kane_arda_repair_20261018'
      ),
      coalesce(v_l.season_id, v_season_id),
      NULL,
      EXISTS (SELECT 1 FROM public.bank_ledger b WHERE b.club_ledger_id = v_l.id),
      true
    );
    v_claw := v_claw + v_l.amount;
  END LOOP;
  INSERT INTO _bes_kane_log VALUES (1, format('Kane take-cash clawed back ₿%s', to_char(v_claw, 'FM999,999,999,990')));

  -- 2) Kane must be FA + reserved for the reopened prize claim
  SELECT nullif(btrim(coalesce("Contracted_Team"::text, '')), '') INTO v_team
  FROM public."Players" WHERE "Konami_ID"::text = v_kane;

  IF v_team IS NOT NULL AND upper(btrim(v_team)) = v_club THEN
    PERFORM public.player_release_from_club(v_kane);
    INSERT INTO _bes_kane_log VALUES (2, 'Kane released from BES (was still contracted)');
  ELSIF v_team IS NOT NULL THEN
    INSERT INTO _bes_kane_log VALUES (2, format('WARNING: Kane contracted to %s — left as-is', v_team));
  ELSE
    INSERT INTO _bes_kane_log VALUES (2, 'Kane already free agent');
  END IF;

  IF to_regprocedure('public.player_clear_foreign_contract_lock(text)') IS NOT NULL THEN
    PERFORM public.player_clear_foreign_contract_lock(v_kane);
  END IF;

  INSERT INTO public.auction_exclusion_players (player_id, player_name, note)
  SELECT v_kane, p."Name", 'special auction prize — reopened after Besiktas repair'
  FROM public."Players" p
  WHERE p."Konami_ID"::text = v_kane
  ON CONFLICT (player_id) DO UPDATE
    SET note = EXCLUDED.note,
        player_name = COALESCE(EXCLUDED.player_name, auction_exclusion_players.player_name);

  -- Soft-reverse Kane → BES special_auction history
  FOR v_h IN
    SELECT h.*
    FROM public."Transfer_History" h
    WHERE h.player_id::text = v_kane
      AND upper(btrim(h.buyer_club_id::text)) = v_club
      AND coalesce(h.transfer_sale_note, '') IN ('special_auction', 'admin_reversed')
      AND coalesce(h.transfer_sale_note, '') IS DISTINCT FROM 'admin_reversed'
    ORDER BY h.id DESC
  LOOP
    UPDATE public."Transfer_History"
    SET transfer_sale_note = 'admin_reversed',
        foreign_buyer_name = coalesce(foreign_buyer_name, '') || ' [reversed 20261018]'
    WHERE id = v_h.id
      AND coalesce(transfer_sale_note, '') <> 'admin_reversed';
    GET DIAGNOSTICS v_n = ROW_COUNT;
    IF v_n > 0 THEN
      INSERT INTO _bes_kane_log VALUES (2, format('Kane Transfer_History #%s marked admin_reversed', v_h.id));
    END IF;
  END LOOP;

  -- 3) Reverse Arda MV release (overflow or keep-prep) and re-sign to BES
  v_claw := 0;
  FOR v_h IN
    SELECT h.*
    FROM public."Transfer_History" h
    WHERE h.player_id::text = v_arda
      AND upper(btrim(h.seller_club_id::text)) = v_club
      AND upper(btrim(coalesce(h.buyer_club_id::text, ''))) IN ('FOREIGN', 'FA', '')
      AND coalesce(h.transfer_sale_note, '') IN (
        'squad_overflow',
        'special_auction_keep_prep',
        'admin_reversed'
      )
      AND h.transfer_time > now() - interval '14 days'
    ORDER BY h.id DESC
    LIMIT 3
  LOOP
    IF coalesce(v_h.transfer_sale_note, '') = 'admin_reversed' THEN
      CONTINUE;
    END IF;

    -- Claw back MV credit posted for this history (or fee amount if no ledger)
    FOR v_l IN
      SELECT l.*
      FROM public.competition_finance_ledger l
      WHERE upper(btrim(l.club_short_name)) = v_club
        AND l.amount > 0
        AND (
          l.metadata->>'transfer_history_id' = v_h.id::text
          OR (
            l.created_at BETWEEN v_h.transfer_time - interval '2 minutes'
                             AND v_h.transfer_time + interval '10 minutes'
            AND l.amount = v_h.fee
            AND (
              l.description ILIKE '%' || coalesce(v_h.foreign_buyer_name, 'overflow') || '%'
              OR l.description ILIKE '%Arda%'
              OR l.entry_type ILIKE '%transfer%'
            )
          )
        )
        AND NOT EXISTS (
          SELECT 1 FROM public.competition_finance_ledger r
          WHERE r.metadata->>'clawback_of_ledger_id' = l.id::text
             OR r.metadata->>'refund_of_ledger_id' = l.id::text
        )
    LOOP
      PERFORM public.post_club_ledger(
        v_l.club_short_name,
        v_l.entry_type,
        -v_l.amount,
        'Clawback (Arda Güler MV release reversed): ' || coalesce(v_l.description, v_l.entry_type),
        jsonb_build_object(
          'clawback_of_ledger_id', v_l.id,
          'clawback_of_transfer_history_id', v_h.id,
          'admin_reversal', true,
          'player_id', v_arda,
          'reason', 'besiktas_kane_arda_repair_20261018'
        ),
        coalesce(v_l.season_id, v_season_id),
        NULL,
        EXISTS (SELECT 1 FROM public.bank_ledger b WHERE b.club_ledger_id = v_l.id),
        true
      );
      v_claw := v_claw + v_l.amount;
    END LOOP;

    IF v_claw = 0 AND coalesce(v_h.fee, 0) > 0 THEN
      -- Direct balance clawback if ledger link missing
      UPDATE public."Club_Finances"
      SET balance = balance - v_h.fee
      WHERE club_name = v_club;
      v_claw := v_claw + v_h.fee;
      INSERT INTO _bes_kane_log VALUES (3, format('Arda fee clawed via Club_Finances ₿%s (history #%s)', v_h.fee, v_h.id));
    END IF;

    UPDATE public."Transfer_History"
    SET transfer_sale_note = 'admin_reversed',
        foreign_buyer_name = coalesce(foreign_buyer_name, '') || ' [reversed 20261018]'
    WHERE id = v_h.id;

    INSERT INTO _bes_kane_log VALUES (3, format('Arda history #%s reversed (note was %s)', v_h.id, v_h.transfer_sale_note));
  END LOOP;

  IF v_claw > 0 THEN
    INSERT INTO _bes_kane_log VALUES (3, format('Arda MV clawed back total ₿%s', to_char(v_claw, 'FM999,999,999,990')));
  END IF;

  SELECT nullif(btrim(coalesce("Contracted_Team"::text, '')), '') INTO v_team
  FROM public."Players" WHERE "Konami_ID"::text = v_arda;

  IF v_team IS NULL OR upper(btrim(v_team)) IS DISTINCT FROM v_club THEN
    IF to_regprocedure('public.player_clear_foreign_contract_lock(text)') IS NOT NULL THEN
      PERFORM public.player_clear_foreign_contract_lock(v_arda);
    END IF;

    -- Defer overflow while restoring — BES should be back under 28 without Kane
    PERFORM public.player_assign_to_club(v_arda, v_club, NULL::numeric, true);

    -- Restore a sensible wage if blank
    SELECT contract_wage INTO v_wage
    FROM public."Players" WHERE "Konami_ID"::text = v_arda;
    IF coalesce(v_wage, 0) <= 0 THEN
      UPDATE public."Players"
      SET contract_wage = round(coalesce(public.calculate_player_wage_for_club(v_arda, v_club), 0), 0)
      WHERE "Konami_ID"::text = v_arda;
    END IF;

    INSERT INTO _bes_kane_log VALUES (3, format('Arda re-signed to %s', v_club));
  ELSE
    INSERT INTO _bes_kane_log VALUES (3, 'Arda already at BES');
  END IF;

  -- 4) Re-open Kane prize options
  IF v_auction_id IS NULL THEN
    RAISE EXCEPTION 'No settled BES player special auction found to reopen';
  END IF;

  UPDATE public.special_auctions
  SET winner_prize_pending = true,
      winner_prize_resolved = false,
      winner_keep_prep_done = false,
      winner_keep_prep_player_id = NULL,
      updated_at = now()
  WHERE id = v_auction_id;

  INSERT INTO _bes_kane_log VALUES (
    4,
    format('Auction #%s reopened (pending=true resolved=false)', v_auction_id)
  );
END
$repair$;

NOTIFY pgrst, 'reload schema';

SELECT step, detail FROM _bes_kane_log ORDER BY step, detail;
