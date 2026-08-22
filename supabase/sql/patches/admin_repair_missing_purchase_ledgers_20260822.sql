-- =============================================================================
-- Backfill activity-ledger purchase lines for Transfer_History gaps
-- (incl. admin_test_populate_squad signings)
--
-- Populate already calls post_transfer_ledger_for_history — if some rows never
-- landed on competition_finance_ledger, use this repair.
--
-- Diagnose (any club / all clubs):
--   SELECT * FROM public.admin_transfer_history_missing_purchase_ledgers('MCI');
--   SELECT * FROM public.admin_transfer_history_missing_purchase_ledgers(NULL);
--
-- Dry-run then apply:
--   SELECT public.admin_repair_missing_purchase_ledgers(true,  'MCI', true);
--   SELECT public.admin_repair_missing_purchase_ledgers(false, 'MCI', true);
--
-- p_apply_balance:
--   true  = also debit Club_Finances (use if money was never taken)
--   false = ledger line only, no further debit (use if balance already reduced)
--
-- Safe re-run (idempotent via transfer_history_id metadata).
-- =============================================================================

CREATE OR REPLACE FUNCTION public.admin_transfer_history_missing_purchase_ledgers(
  p_club_short_name text DEFAULT NULL
)
RETURNS TABLE (
  history_id bigint,
  buyer_club_id text,
  player_id text,
  player_name text,
  fee numeric,
  transfer_time timestamptz,
  transfer_sale_note text,
  has_purchase_ledger boolean
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := nullif(btrim(coalesce(p_club_short_name, '')), '');
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.is_gpsl_admin()
     AND current_user NOT IN ('postgres', 'supabase_admin', 'service_role') THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  RETURN QUERY
  SELECT
    h.id,
    h.buyer_club_id::text,
    h.player_id::text,
    coalesce(p."Name"::text, 'Player ' || h.player_id::text),
    h.fee::numeric,
    h.transfer_time,
    h.transfer_sale_note::text,
    EXISTS (
      SELECT 1
      FROM public.competition_finance_ledger l
      WHERE l.metadata->>'transfer_history_id' = h.id::text
        AND l.entry_type = 'transfer_purchase'
    ) AS has_purchase_ledger
  FROM public."Transfer_History" h
  LEFT JOIN public."Players" p ON p."Konami_ID"::text = h.player_id::text
  WHERE h.buyer_club_id IS NOT NULL
    AND btrim(h.buyer_club_id::text) <> ''
    AND h.buyer_club_id <> 'FOREIGN'
    AND (v_club IS NULL OR h.buyer_club_id = v_club)
    AND NOT EXISTS (
      SELECT 1
      FROM public.competition_finance_ledger l
      WHERE l.metadata->>'transfer_history_id' = h.id::text
        AND l.entry_type = 'transfer_purchase'
    )
  ORDER BY h.transfer_time DESC, h.id DESC;
END;
$function$;

COMMENT ON FUNCTION public.admin_transfer_history_missing_purchase_ledgers(text) IS
  'Admin: Transfer_History buys with no competition_finance_ledger transfer_purchase row.';

CREATE OR REPLACE FUNCTION public.admin_repair_missing_purchase_ledgers(
  p_dry_run boolean DEFAULT true,
  p_club_short_name text DEFAULT NULL,
  p_apply_balance boolean DEFAULT true,
  p_notes_only text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := nullif(btrim(coalesce(p_club_short_name, '')), '');
  v_note_filter text := nullif(btrim(coalesce(p_notes_only, '')), '');
  v_h record;
  v_posted int := 0;
  v_skipped int := 0;
  v_errors jsonb := '[]'::jsonb;
  v_ids bigint[] := ARRAY[]::bigint[];
  v_notes jsonb := '[]'::jsonb;
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.is_gpsl_admin()
     AND current_user NOT IN ('postgres', 'supabase_admin', 'service_role') THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  FOR v_h IN
    SELECT
      h.id,
      h.buyer_club_id,
      h.fee,
      h.player_id,
      h.transfer_sale_note
    FROM public."Transfer_History" h
    WHERE h.buyer_club_id IS NOT NULL
      AND btrim(h.buyer_club_id::text) <> ''
      AND h.buyer_club_id <> 'FOREIGN'
      AND (v_club IS NULL OR h.buyer_club_id = v_club)
      AND (
        v_note_filter IS NULL
        OR coalesce(h.transfer_sale_note, '') = v_note_filter
      )
      AND NOT EXISTS (
        SELECT 1
        FROM public.competition_finance_ledger l
        WHERE l.metadata->>'transfer_history_id' = h.id::text
          AND l.entry_type = 'transfer_purchase'
      )
    ORDER BY h.transfer_time, h.id
  LOOP
    BEGIN
      IF p_dry_run THEN
        v_posted := v_posted + 1;
        v_ids := v_ids || v_h.id;
        IF jsonb_array_length(v_notes) < 40 THEN
          v_notes := v_notes || jsonb_build_array(jsonb_build_object(
            'history_id', v_h.id,
            'buyer', v_h.buyer_club_id,
            'fee', v_h.fee,
            'note', v_h.transfer_sale_note
          ));
        END IF;
      ELSE
        PERFORM public.post_transfer_ledger_for_history(v_h.id, coalesce(p_apply_balance, true));
        IF EXISTS (
          SELECT 1
          FROM public.competition_finance_ledger l
          WHERE l.metadata->>'transfer_history_id' = v_h.id::text
            AND l.entry_type = 'transfer_purchase'
        ) THEN
          v_posted := v_posted + 1;
          v_ids := v_ids || v_h.id;
        ELSE
          v_skipped := v_skipped + 1;
        END IF;
      END IF;
    EXCEPTION WHEN OTHERS THEN
      v_skipped := v_skipped + 1;
      IF jsonb_array_length(v_errors) < 20 THEN
        v_errors := v_errors || jsonb_build_array(jsonb_build_object(
          'history_id', v_h.id,
          'buyer', v_h.buyer_club_id,
          'fee', v_h.fee,
          'error', SQLERRM
        ));
      END IF;
    END;
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true,
    'dry_run', p_dry_run,
    'club', v_club,
    'note_filter', v_note_filter,
    'apply_balance', coalesce(p_apply_balance, true),
    'would_or_did_post', v_posted,
    'skipped_or_failed', v_skipped,
    'history_ids', to_jsonb(v_ids),
    'sample', v_notes,
    'errors', v_errors,
    'hint', CASE
      WHEN p_dry_run THEN
        'Re-run with p_dry_run := false to post. If club cash was already debited for these buys, use p_apply_balance := false.'
      WHEN coalesce(p_apply_balance, true) THEN
        'Posted transfer_purchase lines and debited Club_Finances where applicable.'
      ELSE
        'Posted transfer_purchase lines only (no further balance debit).'
    END
  );
END;
$function$;

COMMENT ON FUNCTION public.admin_repair_missing_purchase_ledgers(boolean, text, boolean, text) IS
  'Admin: backfill transfer_purchase ledger rows for Transfer_History buys missing them (optional note filter e.g. admin_test_populate_squad).';

GRANT EXECUTE ON FUNCTION public.admin_transfer_history_missing_purchase_ledgers(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_repair_missing_purchase_ledgers(boolean, text, boolean, text) TO authenticated;

NOTIFY pgrst, 'reload schema';
