-- =============================================================================
-- Aubameyang duplicate card: WOL reversal + WOL free pick (2026-10-12)
-- =============================================================================
-- GPDB had two cards for the same player:
--   40323    "P. E. Aubameyang"  → TIG (listing #3028, history #28261)
--   83926403 "Pierre Aubameyang" → WOL (listing #3030, history #28263)
-- Both settled in the same run on Sat 10 Oct 19:00; TIG's was processed first.
-- TIG keep him. For WOL:
--   1) Refund every ledger line from the purchase (fee + income tax),
--      including the central bank leg where there was one.
--   2) Drop the card from WOL's matchday squad / designations, release it,
--      mark listing #3030 not completed, remove WOL's Transfer_History row.
--   3) Retire card 83926403 as legacy so it can never be signed again.
--   4) Grant WOL one free pick (any free agent at market value — GPDB button).
--
-- Needs draft_kovacic_reverse_tig_crv_free_pick_20261012.sql (draft_free_picks).
-- Safe re-run: each step checks whether it is already done.
-- =============================================================================

CREATE TEMP TABLE IF NOT EXISTS _aub_log (step int, detail text) ON COMMIT PRESERVE ROWS;
TRUNCATE _aub_log;

DO $aub$
DECLARE
  v_pid  text := '83926403';
  v_keep text := '40323';
  v_club text := 'WOL';
  v_h    record;
  v_l    record;
  v_team text;
  v_n    int;
  v_refunded numeric := 0;
BEGIN
  IF to_regclass('public.draft_free_picks') IS NULL THEN
    RAISE EXCEPTION 'Run draft_kovacic_reverse_tig_crv_free_pick_20261012.sql first (creates draft_free_picks)';
  END IF;

  SELECT upper(nullif(btrim(coalesce("Contracted_Team"::text, '')), '')) INTO v_team
  FROM public."Players" WHERE "Konami_ID"::text = v_pid;

  SELECT h.* INTO v_h
  FROM public."Transfer_History" h
  WHERE h.player_id::text = v_pid AND upper(h.buyer_club_id) = v_club
  ORDER BY h.id DESC
  LIMIT 1;

  -- 1) refund WOL
  IF v_h.id IS NOT NULL THEN
    FOR v_l IN
      SELECT l.*
      FROM public.competition_finance_ledger l
      WHERE upper(l.club_short_name) = v_club
        AND l.metadata->>'transfer_history_id' = v_h.id::text
        AND l.amount < 0
        AND NOT EXISTS (
          SELECT 1 FROM public.competition_finance_ledger r
          WHERE r.metadata->>'refund_of_ledger_id' = l.id::text
        )
    LOOP
      PERFORM public.post_club_ledger(
        v_l.club_short_name,
        v_l.entry_type,
        -v_l.amount,
        'Refund (duplicate card reversed by admin): ' || coalesce(v_l.description, v_l.entry_type),
        jsonb_build_object(
          'refund_of_ledger_id', v_l.id,
          'refund_of_transfer_history_id', v_h.id,
          'reversed_history', to_jsonb(v_h),
          'player_id', v_pid,
          'admin_reversal', true
        ),
        v_l.season_id,
        NULL,
        EXISTS (SELECT 1 FROM public.bank_ledger b WHERE b.club_ledger_id = v_l.id),
        true
      );
      v_refunded := v_refunded + (-v_l.amount);
    END LOOP;
    INSERT INTO _aub_log VALUES (1, format('WOL refunded ₿%s (history #%s, fee ₿%s)',
      to_char(v_refunded, 'FM999,999,999,990'), v_h.id, to_char(v_h.fee, 'FM999,999,999,990')));
  ELSE
    INSERT INTO _aub_log VALUES (1, 'No WOL purchase history found (already reversed?)');
  END IF;

  -- 2) out of WOL's squad
  IF to_regclass('public.club_matchday_squad_player') IS NOT NULL THEN
    DELETE FROM public.club_matchday_squad_player WHERE player_id = v_pid;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    IF v_n > 0 THEN
      INSERT INTO _aub_log VALUES (2, format('Removed from %s saved matchday squad row(s)', v_n));
    END IF;
  END IF;
  IF to_regclass('public.club_squad_player_designations') IS NOT NULL THEN
    DELETE FROM public.club_squad_player_designations WHERE player_id = v_pid;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    IF v_n > 0 THEN
      INSERT INTO _aub_log VALUES (2, format('Removed %s squad designation(s)', v_n));
    END IF;
  END IF;

  IF v_team = v_club THEN
    PERFORM public.player_release_from_club(v_pid);
    INSERT INTO _aub_log VALUES (2, 'Card 83926403 released from WOL');
  ELSE
    INSERT INTO _aub_log VALUES (2, 'Card not at WOL (now: ' || coalesce(v_team, 'free agent') || ')');
  END IF;

  IF v_h.id IS NOT NULL THEN
    UPDATE public."Player_Transfer_Listings"
    SET transfer_completed = false, winning_bid = NULL, winning_club = NULL, status = 'Closed'
    WHERE id = v_h.listing_id;

    BEGIN
      DELETE FROM public."Transfer_History" WHERE id = v_h.id;
      INSERT INTO _aub_log VALUES (2, format('WOL history #%s removed, listing #%s marked not completed', v_h.id, v_h.listing_id));
    EXCEPTION WHEN OTHERS THEN
      UPDATE public."Transfer_History" SET transfer_sale_note = 'admin_reversed' WHERE id = v_h.id;
      INSERT INTO _aub_log VALUES (2, format('WOL history #%s kept (referenced) and marked admin_reversed: %s', v_h.id, SQLERRM));
    END;
  END IF;

  DELETE FROM public.player_draft_max_bids WHERE btrim(player_id) = v_pid;

  -- 3) retire the duplicate card
  UPDATE public."Players"
  SET pesdb_unavailable = true
  WHERE "Konami_ID"::text = v_pid
    AND coalesce(pesdb_unavailable, false) = false;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  INSERT INTO _aub_log VALUES (3, CASE WHEN v_n > 0
    THEN 'Card 83926403 marked legacy (duplicate of 40323) — cannot be signed'
    ELSE 'Card 83926403 already legacy' END);

  -- 4) WOL free pick
  INSERT INTO public.draft_free_picks (club_short_name, reason)
  VALUES (v_club, 'aubameyang_duplicate_20261012')
  ON CONFLICT (club_short_name, reason) DO NOTHING;
  INSERT INTO _aub_log VALUES (4, 'WOL free pick granted (unused picks: ' ||
    (SELECT count(*) FROM public.draft_free_picks WHERE club_short_name = v_club AND used_at IS NULL) || ')');
END
$aub$;

NOTIFY pgrst, 'reload schema';

SELECT step, detail FROM _aub_log
UNION ALL
SELECT 9, format('Card 40323 at %s | card 83926403 at %s (legacy %s) | WOL balance ₿%s | WOL permanent squad %s',
  coalesce((SELECT "Contracted_Team"::text FROM public."Players" WHERE "Konami_ID"::text = '40323'), 'free agent'),
  coalesce((SELECT nullif(btrim("Contracted_Team"::text), '') FROM public."Players" WHERE "Konami_ID"::text = '83926403'), 'free agent'),
  (SELECT coalesce(pesdb_unavailable, false) FROM public."Players" WHERE "Konami_ID"::text = '83926403'),
  to_char((SELECT balance FROM public."Club_Finances" WHERE club_name = 'WOL'), 'FM999,999,999,990'),
  public.club_permanent_squad_count('WOL'))
ORDER BY 1;
