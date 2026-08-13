-- =============================================================================
-- Player draft incident — diagnose + resume (2026-08-13)
--
-- Symptom report:
--   • Only some draft deals assigned players
--   • Finances / fees appear not to have posted
--   • Clubs over squad max (28); overflow releases / fines may have stalled
--
-- Run EACH section in Supabase SQL Editor (as postgres / service role).
-- Paste JSON / result grids back before applying repair steps.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- A) Snapshot: gate, backlog, over-squad, this-window signings vs ledger
-- ---------------------------------------------------------------------------
SELECT public.transferengine_diagnose_stuck_drafts(15);

SELECT public.transferengine_diagnose_draft_backlog();

SELECT public.transferengine_draft_settlement_gate();

-- This draft window
SELECT
  g.draft_auction_enabled,
  g.manager_draft_auction_enabled,
  g.draft_auction_start_time AT TIME ZONE 'Europe/London' AS draft_start_uk,
  g.draft_random_finish_time AT TIME ZONE 'Europe/London' AS finish_uk,
  now() AT TIME ZONE 'Europe/London' AS now_uk,
  (
    SELECT status FROM public.competition_seasons
    WHERE is_current = true ORDER BY id DESC LIMIT 1
  ) AS season_status
FROM public.global_settings g
WHERE g.id = 1;

-- Listing status mix for THIS auction
SELECT
  l.status,
  l.transfer_completed,
  count(*) AS listings,
  count(*) FILTER (WHERE l.current_highest_bidder IS NOT NULL) AS with_leader
FROM public."Player_Transfer_Listings" l
CROSS JOIN public.global_settings g
WHERE g.id = 1
  AND l.listing_type = 'draft'
  AND l.created_at >= g.draft_auction_start_time
GROUP BY 1, 2
ORDER BY 1, 2;

-- Clubs over 28 right now
SELECT
  c."ShortName",
  public.club_squad_player_count(c."ShortName") AS squad_size,
  public.squad_max_size() AS squad_max,
  f.balance
FROM public."Clubs" c
LEFT JOIN public."Club_Finances" f ON f.club_name = c."ShortName"
WHERE public.club_squad_player_count(c."ShortName") > public.squad_max_size()
ORDER BY squad_size DESC, c."ShortName";

-- This draft: Transfer_History vs ledger purchase lines
WITH win AS (
  SELECT draft_random_finish_time AS finish, draft_auction_start_time AS start_at
  FROM public.global_settings WHERE id = 1
),
hist AS (
  SELECT h.*
  FROM public."Transfer_History" h
  CROSS JOIN win w
  WHERE h.seller_club_id IS NULL
    AND w.finish IS NOT NULL
    AND h.transfer_time >= w.finish
)
SELECT
  (SELECT count(*) FROM hist) AS history_rows,
  (SELECT coalesce(sum(fee), 0) FROM hist) AS history_fee_total,
  (
    SELECT count(*)
    FROM public.competition_finance_ledger l
    CROSS JOIN win w
    WHERE l.entry_type = 'transfer_purchase'
      AND w.finish IS NOT NULL
      AND l.created_at >= w.finish
  ) AS ledger_purchase_rows,
  (
    SELECT coalesce(sum(abs(l.amount)), 0)
    FROM public.competition_finance_ledger l
    CROSS JOIN win w
    WHERE l.entry_type = 'transfer_purchase'
      AND w.finish IS NOT NULL
      AND l.created_at >= w.finish
  ) AS ledger_purchase_abs_total;

-- Signed players whose listing is Closed/completed but NO matching purchase ledger
SELECT
  h.id AS history_id,
  h.transfer_time AT TIME ZONE 'Europe/London' AS signed_uk,
  h.buyer_club_id,
  p."Name",
  h.fee,
  h.listing_id,
  EXISTS (
    SELECT 1
    FROM public.competition_finance_ledger l
    WHERE l.metadata->>'transfer_history_id' = h.id::text
      AND l.entry_type = 'transfer_purchase'
  ) AS has_purchase_ledger
FROM public."Transfer_History" h
LEFT JOIN public."Players" p ON p."Konami_ID"::text = h.player_id::text
CROSS JOIN public.global_settings g
WHERE g.id = 1
  AND h.seller_club_id IS NULL
  AND g.draft_random_finish_time IS NOT NULL
  AND h.transfer_time >= g.draft_random_finish_time
  AND NOT EXISTS (
    SELECT 1
    FROM public.competition_finance_ledger l
    WHERE l.metadata->>'transfer_history_id' = h.id::text
      AND l.entry_type = 'transfer_purchase'
  )
ORDER BY h.transfer_time
LIMIT 80;

-- Players at clubs with Closed completed listing but NO Transfer_History (assign without fee)
SELECT
  l.id AS listing_id,
  l.player_id,
  p."Name",
  l.winning_club,
  l.winning_bid,
  p."Contracted_Team",
  l.transfer_completed
FROM public."Player_Transfer_Listings" l
JOIN public."Players" p ON p."Konami_ID"::text = l.player_id::text
CROSS JOIN public.global_settings g
WHERE g.id = 1
  AND l.listing_type = 'draft'
  AND l.created_at >= g.draft_auction_start_time
  AND l.status = 'Closed'
  AND coalesce(l.transfer_completed, false) = true
  AND p."Contracted_Team" IS NOT NULL
  AND btrim(p."Contracted_Team") <> ''
  AND NOT EXISTS (
    SELECT 1
    FROM public."Transfer_History" h
    WHERE h.listing_id = l.id
       OR (
         h.seller_club_id IS NULL
         AND h.player_id::text = l.player_id::text
         AND h.buyer_club_id = p."Contracted_Team"
         AND h.transfer_time >= g.draft_random_finish_time
       )
  )
ORDER BY l.id
LIMIT 80;

-- Active leftovers (still need settlement)
SELECT
  count(*) AS active_draft,
  count(*) FILTER (
    WHERE l.current_highest_bidder IS NOT NULL
      AND (p."Contracted_Team" IS NULL OR btrim(p."Contracted_Team") = '')
  ) AS active_ready_fa,
  count(*) FILTER (
    WHERE p."Contracted_Team" IS NOT NULL AND btrim(p."Contracted_Team") <> ''
  ) AS active_but_player_already_signed
FROM public."Player_Transfer_Listings" l
LEFT JOIN public."Players" p ON p."Konami_ID"::text = l.player_id::text
CROSS JOIN public.global_settings g
WHERE g.id = 1
  AND l.listing_type = 'draft'
  AND l.created_at >= g.draft_auction_start_time
  AND l.status = 'Active';

-- Probe why the next Active listing fails (surfaces overflow / ledger / season errors)
SELECT public.transferengine_diagnose_stuck_drafts(10);
-- Optional single-listing probe:
-- SELECT public.transferengine_try_accept_draft_sale(
--   (SELECT id FROM public."Player_Transfer_Listings"
--    WHERE listing_type = 'draft' AND status = 'Active'
--    ORDER BY id LIMIT 1)
-- );


-- ---------------------------------------------------------------------------
-- B) Repair helpers (deploy once, then call)
-- ---------------------------------------------------------------------------

-- Posts missing draft purchase ledgers AND applies Club_Finances balance
-- (unlike backfill_transfer_finance_ledger which uses apply_balance=false).
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

-- ---------------------------------------------------------------------------
-- C) Apply order (after A looks sane)
-- ---------------------------------------------------------------------------
-- 1. Deploy this file (helpers above).
-- 2. Deploy if needed:
--      draft_settlement_finalize_resilience.sql
--      draft_settlement_ledger_season_fix.sql
-- 3. SELECT public.admin_repair_draft_missing_purchase_ledgers(true);
--    SELECT public.admin_repair_draft_missing_purchase_ledgers(false);
-- 4. SELECT public.admin_enforce_all_squad_overflow(true);
--    SELECT public.admin_enforce_all_squad_overflow(false);
-- 5. SELECT public.transferengine_settle_player_draft_listings_report(50);
--    Repeat until active_remaining = 0.
-- 6. SELECT public.transferengine_run_report();
-- 7. Re-check section A counts (history vs ledger, over-squad = 0).
