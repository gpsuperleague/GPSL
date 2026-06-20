-- =============================================================================
-- Draft settlement — don't rollback 100 signings when deferred overflow fails
--
-- Symptom: first transferengine_run_report() settles ~100, then Active count
-- stuck for hours (cron every minute makes no progress).
-- Cause: transferengine_finalize_deferred_squad_overflow() raises on one club
--        → entire transferengine_run() transaction rolls back.
--
-- Run once, then: SELECT public.transferengine_run_report();
-- =============================================================================

CREATE OR REPLACE FUNCTION public.transferengine_finalize_deferred_squad_overflow()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club  text;
  v_total int;
  v_guard int;
BEGIN
  IF coalesce(
    nullif(current_setting('gpsl.defer_squad_overflow', true), ''),
    ''
  ) <> 'on' THEN
    RETURN;
  END IF;

  FOR v_club IN
    SELECT c."ShortName"
    FROM public."Clubs" c
    WHERE public.club_squad_player_count(c."ShortName") > public.squad_max_size()
  LOOP
    BEGIN
      v_guard := 0;
      LOOP
        v_guard := v_guard + 1;
        EXIT WHEN v_guard > 15;

        v_total := public.club_squad_player_count(v_club);
        EXIT WHEN v_total <= public.squad_max_size();

        BEGIN
          PERFORM public.enforce_squad_overflow_after_signing(v_club, NULL);
        EXCEPTION WHEN OTHERS THEN
          RAISE WARNING 'deferred overflow release failed for % (squad %): %',
            v_club, v_total, SQLERRM;
          EXIT;
        END;
      END LOOP;
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'deferred overflow pass failed for %: %', v_club, SQLERRM;
    END;
  END LOOP;
END;
$function$;


-- Admin / SQL Editor: settle player draft backlog without waiting on cron
CREATE OR REPLACE FUNCTION public.admin_settle_player_draft_now(p_batch_limit int DEFAULT 100)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_before int;
  v_after int;
  v_settled int;
  v_gate jsonb;
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.is_gpsl_admin()
     AND current_user NOT IN ('postgres', 'supabase_admin', 'service_role') THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  SELECT count(*)::int INTO v_before
  FROM public."Player_Transfer_Listings"
  WHERE listing_type = 'draft' AND status = 'Active';

  IF to_regprocedure('public.transferengine_draft_settlement_gate()') IS NOT NULL THEN
    v_gate := public.transferengine_draft_settlement_gate();
  ELSE
    v_gate := NULL;
  END IF;

  PERFORM public.transferengine_run();

  SELECT count(*)::int INTO v_after
  FROM public."Player_Transfer_Listings"
  WHERE listing_type = 'draft' AND status = 'Active';

  v_settled := v_before - v_after;

  RETURN jsonb_build_object(
    'ok', true,
    'active_before', v_before,
    'active_after', v_after,
    'settled_this_run', v_settled,
    'gate', v_gate
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.admin_settle_player_draft_now(int) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_settle_player_draft_now(int) TO service_role;

NOTIFY pgrst, 'reload schema';
