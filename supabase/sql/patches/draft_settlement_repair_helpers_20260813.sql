-- =============================================================================
-- Deploy once: draft settlement repair helpers (2026-08-13)
--
-- After deploy:
--   SELECT public.admin_repair_draft_missing_purchase_ledgers(true);
--   SELECT public.admin_repair_draft_missing_purchase_ledgers(false);
--   SELECT public.admin_enforce_all_squad_overflow(true);
--   SELECT public.admin_enforce_all_squad_overflow(false);
-- =============================================================================

CREATE OR REPLACE FUNCTION public.admin_repair_draft_missing_purchase_ledgers(
  p_dry_run boolean DEFAULT true
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_finish timestamptz;
  v_h record;
  v_posted int := 0;
  v_skipped int := 0;
  v_errors jsonb := '[]'::jsonb;
  v_ids bigint[] := ARRAY[]::bigint[];
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.is_gpsl_admin()
     AND current_user NOT IN ('postgres', 'supabase_admin', 'service_role') THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  SELECT draft_random_finish_time INTO v_finish
  FROM public.global_settings WHERE id = 1;

  IF v_finish IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'draft_random_finish_time is null');
  END IF;

  FOR v_h IN
    SELECT h.id, h.buyer_club_id, h.fee, h.player_id
    FROM public."Transfer_History" h
    WHERE h.seller_club_id IS NULL
      AND h.transfer_time >= v_finish
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
      ELSE
        PERFORM public.post_transfer_ledger_for_history(v_h.id, true);
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
    'would_or_did_post', v_posted,
    'skipped_or_failed', v_skipped,
    'history_ids', to_jsonb(v_ids),
    'errors', v_errors,
    'hint', CASE
      WHEN p_dry_run THEN 'Re-run with admin_repair_draft_missing_purchase_ledgers(false) to apply'
      ELSE 'Balances debited via post_transfer_ledger_for_history(..., true)'
    END
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_enforce_all_squad_overflow(p_dry_run boolean DEFAULT true)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  r record;
  v_guard int;
  v_before int;
  v_after int;
  v_clubs jsonb := '[]'::jsonb;
  v_errors jsonb := '[]'::jsonb;
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.is_gpsl_admin()
     AND current_user NOT IN ('postgres', 'supabase_admin', 'service_role') THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  FOR r IN
    SELECT c."ShortName" AS club
    FROM public."Clubs" c
    WHERE public.club_squad_player_count(c."ShortName") > public.squad_max_size()
    ORDER BY c."ShortName"
  LOOP
    v_before := public.club_squad_player_count(r.club);
    IF NOT p_dry_run THEN
      v_guard := 0;
      LOOP
        v_guard := v_guard + 1;
        EXIT WHEN v_guard > 20;
        EXIT WHEN public.club_squad_player_count(r.club) <= public.squad_max_size();
        BEGIN
          PERFORM public.enforce_squad_overflow_after_signing(r.club, NULL);
        EXCEPTION WHEN OTHERS THEN
          IF jsonb_array_length(v_errors) < 20 THEN
            v_errors := v_errors || jsonb_build_array(jsonb_build_object(
              'club', r.club,
              'error', SQLERRM
            ));
          END IF;
          EXIT;
        END;
      END LOOP;
    END IF;
    v_after := public.club_squad_player_count(r.club);
    v_clubs := v_clubs || jsonb_build_array(jsonb_build_object(
      'club', r.club,
      'before', v_before,
      'after', v_after,
      'still_over', v_after > public.squad_max_size()
    ));
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true,
    'dry_run', p_dry_run,
    'squad_max', public.squad_max_size(),
    'clubs', v_clubs,
    'errors', v_errors
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.admin_repair_draft_missing_purchase_ledgers(boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_repair_draft_missing_purchase_ledgers(boolean) TO service_role;
GRANT EXECUTE ON FUNCTION public.admin_enforce_all_squad_overflow(boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_enforce_all_squad_overflow(boolean) TO service_role;

NOTIFY pgrst, 'reload schema';
