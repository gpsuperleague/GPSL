-- =============================================================================
-- Why is draft settlement stuck mid-backlog?
-- Run: SELECT public.transferengine_diagnose_stuck_drafts(10);
-- =============================================================================

CREATE OR REPLACE FUNCTION public.transferengine_diagnose_stuck_drafts(p_sample int DEFAULT 10)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_listing record;
  v_limit int := greatest(coalesce(p_sample, 10), 1);
  v_samples jsonb := '[]'::jsonb;
  v_try jsonb;
  v_gate jsonb;
  v_finish timestamptz;
  v_error_counts jsonb := '{}'::jsonb;
  v_key text;
BEGIN
  SELECT draft_random_finish_time INTO v_finish
  FROM public.global_settings WHERE id = 1;

  IF to_regprocedure('public.transferengine_draft_settlement_gate()') IS NOT NULL THEN
    v_gate := public.transferengine_draft_settlement_gate();
  END IF;

  FOR v_listing IN
    SELECT l.id, l.player_id, l.current_highest_bidder, l.current_highest_bid
    FROM public."Player_Transfer_Listings" l
    WHERE l.listing_type = 'draft'
      AND l.status = 'Active'
    ORDER BY l.id
    LIMIT v_limit
  LOOP
    BEGIN
      SAVEPOINT probe_one;
      BEGIN
        PERFORM public.transferengine_accept_draft_sale(v_listing.id);

        v_try := jsonb_build_object(
          'listing_id', v_listing.id,
          'player_id', v_listing.player_id,
          'buyer', v_listing.current_highest_bidder,
          'ok', EXISTS (
            SELECT 1
            FROM public."Player_Transfer_Listings" l
            WHERE l.id = v_listing.id
              AND l.status = 'Closed'
              AND l.transfer_completed = true
          ),
          'dry_run', true
        );

        ROLLBACK TO SAVEPOINT probe_one;
      EXCEPTION WHEN OTHERS THEN
        ROLLBACK TO SAVEPOINT probe_one;
        v_try := jsonb_build_object(
          'listing_id', v_listing.id,
          'player_id', v_listing.player_id,
          'buyer', v_listing.current_highest_bidder,
          'ok', false,
          'error', SQLERRM,
          'sqlstate', SQLSTATE,
          'dry_run', true
        );
      END;
    END;

    v_samples := v_samples || jsonb_build_array(v_try);

    IF coalesce(v_try->>'ok', 'false') = 'false' AND v_try ? 'error' THEN
      v_key := left(coalesce(v_try->>'error', 'unknown'), 120);
      v_error_counts := v_error_counts || jsonb_build_object(
        v_key,
        coalesce((v_error_counts->>v_key)::int, 0) + 1
      );
    END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'draft_random_finish_time', v_finish,
    'gate', v_gate,
    'counts', jsonb_build_object(
      'active', (
        SELECT count(*)::int FROM public."Player_Transfer_Listings" l
        WHERE l.listing_type = 'draft' AND l.status = 'Active'
      ),
      'closed_completed', (
        SELECT count(*)::int FROM public."Player_Transfer_Listings" l
        WHERE l.listing_type = 'draft' AND l.status = 'Closed' AND l.transfer_completed = true
      ),
      'active_no_leader', (
        SELECT count(*)::int FROM public."Player_Transfer_Listings" l
        WHERE l.listing_type = 'draft' AND l.status = 'Active'
          AND l.current_highest_bidder IS NULL
      ),
      'active_ready', (
        SELECT count(*)::int
        FROM public."Player_Transfer_Listings" l
        JOIN public."Players" p ON p."Konami_ID"::text = l.player_id::text
        WHERE l.listing_type = 'draft' AND l.status = 'Active'
          AND l.current_highest_bidder IS NOT NULL
          AND (p."Contracted_Team" IS NULL OR btrim(p."Contracted_Team"::text) = '')
          AND EXISTS (
            SELECT 1 FROM public."Club_Finances" f
            WHERE f.club_name = btrim(l.current_highest_bidder::text)
          )
      ),
      'clubs_over_squad_max', (
        SELECT count(*)::int
        FROM public."Clubs" c
        WHERE public.club_squad_player_count(c."ShortName") > public.squad_max_size()
      )
    ),
    'top_buyers_tonight', (
      SELECT coalesce(jsonb_agg(row_to_json(t) ORDER BY t.signings DESC), '[]'::jsonb)
      FROM (
        SELECT h.buyer_club_id, count(*)::int AS signings
        FROM public."Transfer_History" h
        WHERE h.seller_club_id IS NULL
          AND v_finish IS NOT NULL
          AND h.transfer_time >= v_finish
        GROUP BY h.buyer_club_id
        ORDER BY count(*) DESC
        LIMIT 10
      ) t
    ),
    'sample_probed', v_limit,
    'error_summary', v_error_counts,
    'samples', v_samples,
    'hint',
      CASE
        WHEN v_gate IS NOT NULL AND coalesce((v_gate->>'will_settle_players')::boolean, false) = false
          THEN 'Gate closed — check will_settle_players / blocked_by_7pm_transfer_list'
        WHEN jsonb_object_length(v_error_counts) > 0
          THEN 'Sample listings failed — see error_summary and samples (try_accept mutates on success)'
        ELSE 'Gate open and sample had no errors — cron may not be running; run transferengine_run_report()'
      END,
    'note', 'samples use dry_run savepoints — they do not commit signings'
  );
END;
$function$;


CREATE OR REPLACE FUNCTION public.transferengine_settle_player_draft_listings_report(
  p_batch_limit int DEFAULT 100
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_listing public."Player_Transfer_Listings"%rowtype;
  v_settled int := 0;
  v_failed int := 0;
  v_limit int := greatest(coalesce(p_batch_limit, 100), 1);
  v_errors jsonb := '[]'::jsonb;
  v_err text;
BEGIN
  FOR v_listing IN
    SELECT *
    FROM public."Player_Transfer_Listings"
    WHERE listing_type = 'draft'
      AND status = 'Active'
    ORDER BY id
    LIMIT v_limit
  LOOP
    BEGIN
      PERFORM public.transferengine_accept_draft_sale(v_listing.id);
      IF EXISTS (
        SELECT 1
        FROM public."Player_Transfer_Listings" l
        WHERE l.id = v_listing.id
          AND l.status = 'Closed'
          AND l.transfer_completed = true
      ) THEN
        v_settled := v_settled + 1;
      ELSE
        v_failed := v_failed + 1;
      END IF;
    EXCEPTION WHEN OTHERS THEN
      v_failed := v_failed + 1;
      v_err := SQLERRM;
      IF jsonb_array_length(v_errors) < 15 THEN
        v_errors := v_errors || jsonb_build_array(jsonb_build_object(
          'listing_id', v_listing.id,
          'player_id', v_listing.player_id,
          'buyer', v_listing.current_highest_bidder,
          'error', v_err
        ));
      END IF;
    END;
  END LOOP;

  RETURN jsonb_build_object(
    'settled', v_settled,
    'failed', v_failed,
    'batch_limit', v_limit,
    'errors', v_errors,
    'active_remaining', (
      SELECT count(*)::int FROM public."Player_Transfer_Listings" l
      WHERE l.listing_type = 'draft' AND l.status = 'Active'
    )
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.transferengine_diagnose_stuck_drafts(int) TO authenticated;
GRANT EXECUTE ON FUNCTION public.transferengine_diagnose_stuck_drafts(int) TO service_role;
GRANT EXECUTE ON FUNCTION public.transferengine_settle_player_draft_listings_report(int) TO authenticated;
GRANT EXECUTE ON FUNCTION public.transferengine_settle_player_draft_listings_report(int) TO service_role;

NOTIFY pgrst, 'reload schema';
