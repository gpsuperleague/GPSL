-- Handpick approve: sign wishlist in chunks of 8 (admin_sign_free_agents_at_mv cap).
-- Previous one-shot approve failed with batch_too_large for 9+ players — marked nothing,
-- spent nothing, left submission pending. Safe re-run.

CREATE OR REPLACE FUNCTION public.admin_handpick_approve_submission(
  p_submission_id bigint,
  p_dry_run boolean DEFAULT true,
  p_skip_player_sign boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
SET statement_timeout = '180s'
AS $function$
DECLARE
  v_row public.club_handpick_submissions%ROWTYPE;
  v_handpick boolean;
  v_sign jsonb;
  v_mgr jsonb;
  v_fee numeric;
  v_ids text[];
  v_chunk text[];
  v_i int;
  v_batch jsonb;
  v_signed jsonb := '[]'::jsonb;
  v_skipped jsonb := '[]'::jsonb;
  v_fees numeric := 0;
  v_est_tax numeric := 0;
  v_tax_pct numeric := 0;
  v_chunk_size int := 8;
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  SELECT * INTO v_row
  FROM public.club_handpick_submissions
  WHERE id = p_submission_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_found');
  END IF;

  IF v_row.status IS DISTINCT FROM 'pending' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_pending', 'status', v_row.status);
  END IF;

  SELECT coalesce(c.handpick_intake, false) INTO v_handpick
  FROM public."Clubs" c
  WHERE c."ShortName" = v_row.club_short_name;

  IF NOT coalesce(v_handpick, false) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'club_not_in_handpick');
  END IF;

  v_ids := coalesce(v_row.player_ids, ARRAY[]::text[]);

  IF coalesce(array_length(v_ids, 1), 0) > 0
     AND NOT coalesce(p_skip_player_sign, false) THEN
    IF to_regprocedure('public.admin_sign_free_agents_at_mv(text,text[],boolean)') IS NULL THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'sign_rpc_missing');
    END IF;

    -- Dry-run: one call (cap only applies to live sign)
    IF coalesce(p_dry_run, true) THEN
      v_sign := public.admin_sign_free_agents_at_mv(
        v_row.club_short_name,
        v_ids,
        true
      );
      IF NOT coalesce((v_sign->>'ok')::boolean, false) THEN
        RETURN jsonb_build_object(
          'ok', false,
          'reason', 'sign_failed',
          'sign_result', v_sign
        );
      END IF;
    ELSE
      v_i := 1;
      WHILE v_i <= coalesce(array_length(v_ids, 1), 0) LOOP
        v_chunk := v_ids[v_i : least(v_i + v_chunk_size - 1, array_length(v_ids, 1))];
        v_batch := public.admin_sign_free_agents_at_mv(
          v_row.club_short_name,
          v_chunk,
          false
        );
        IF NOT coalesce((v_batch->>'ok')::boolean, false) THEN
          RETURN jsonb_build_object(
            'ok', false,
            'reason', 'sign_failed',
            'sign_result', v_batch,
            'failed_at_offset', v_i,
            'chunk', to_jsonb(v_chunk)
          );
        END IF;

        v_signed := v_signed || coalesce(v_batch->'signed', '[]'::jsonb);
        v_skipped := v_skipped || coalesce(v_batch->'skipped', '[]'::jsonb);
        v_fees := v_fees + coalesce((v_batch->>'fees_total')::numeric, 0);
        v_est_tax := v_est_tax + coalesce((v_batch->>'est_income_tax_total')::numeric, 0);
        v_tax_pct := coalesce((v_batch->>'income_tax_pct')::numeric, v_tax_pct);

        v_i := v_i + v_chunk_size;
      END LOOP;

      v_sign := jsonb_build_object(
        'ok', true,
        'dry_run', false,
        'club', v_row.club_short_name,
        'income_tax_pct', v_tax_pct,
        'signed_count', jsonb_array_length(v_signed),
        'skipped_count', jsonb_array_length(v_skipped),
        'fees_total', v_fees,
        'est_income_tax_total', v_est_tax,
        'est_total_cost', v_fees + v_est_tax,
        'signed', v_signed,
        'skipped', v_skipped,
        'batched', true,
        'chunk_size', v_chunk_size
      );
    END IF;
  ELSIF coalesce(p_skip_player_sign, false)
        AND coalesce(array_length(v_ids, 1), 0) > 0 THEN
    v_sign := jsonb_build_object(
      'ok', true,
      'skipped_sign', true,
      'signed_count', 0,
      'skipped_count', 0,
      'note', 'Player sign skipped (already signed by caller)'
    );
  ELSE
    v_sign := jsonb_build_object('ok', true, 'signed_count', 0, 'skipped_count', 0);
  END IF;

  IF v_row.manager_id IS NOT NULL THEN
    IF coalesce(p_dry_run, true) THEN
      SELECT coalesce(m.market_value, 0)::numeric INTO v_fee
      FROM public."Managers" m WHERE m.id = v_row.manager_id;
      v_mgr := jsonb_build_object(
        'ok', true,
        'dry_run', true,
        'manager_id', v_row.manager_id,
        'est_fee', coalesce(v_fee, 0)
      );
    ELSE
      BEGIN
        v_mgr := public.manager_assign_to_club(
          v_row.manager_id,
          v_row.club_short_name,
          2::smallint,
          NULL::numeric,
          true,
          jsonb_build_object('source', 'handpick_approve', 'submission_id', p_submission_id)
        );
      EXCEPTION WHEN OTHERS THEN
        v_mgr := jsonb_build_object('ok', false, 'error', SQLERRM);
      END;
    END IF;
  END IF;

  IF NOT coalesce(p_dry_run, true) THEN
    UPDATE public.club_handpick_submissions
    SET status = 'approved',
        reviewed_at = now(),
        reviewed_by = auth.uid(),
        sign_result = jsonb_build_object('players', v_sign, 'manager', v_mgr)
    WHERE id = p_submission_id;

    DELETE FROM public.club_handpick_basket
    WHERE club_short_name = v_row.club_short_name
      AND (
        coalesce(array_length(v_row.player_ids, 1), 0) = 0
        OR player_id = ANY (v_row.player_ids)
      );
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'dry_run', coalesce(p_dry_run, true),
    'submission_id', p_submission_id,
    'club', v_row.club_short_name,
    'players', v_sign,
    'manager', v_mgr,
    'status', CASE WHEN coalesce(p_dry_run, true) THEN 'pending' ELSE 'approved' END
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.admin_handpick_approve_submission(bigint, boolean)
  FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_handpick_approve_submission(bigint, boolean, boolean)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_handpick_approve_submission(bigint, boolean)
  TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_handpick_approve_submission(bigint, boolean, boolean)
  TO authenticated;

NOTIFY pgrst, 'reload schema';

SELECT
  to_regprocedure('public.admin_handpick_approve_submission(bigint,boolean)') IS NOT NULL AS approve_2arg,
  to_regprocedure('public.admin_handpick_approve_submission(bigint,boolean,boolean)') IS NOT NULL AS approve_3arg;
