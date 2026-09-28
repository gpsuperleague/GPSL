-- =============================================================================
-- Re-settle league prizes after changing the prize table mid/late season.
--
-- League prizes auto-pay when a division hits 38/38 and are recorded in
-- competition_league_prize_paid, so editing competition_league_prize_config
-- afterwards changes nothing. This posts the difference (new config amount for
-- the club's PAID table position − amount already paid) as a prize_league
-- ledger line via the central bank, and updates the paid row.
--
-- If Close Finances already ran, EOS debt interest / balance interest were
-- charged on a balance that included the old prize. With p_true_up_interest,
-- those charges are recalculated from their stored balance_snapshot + delta.
-- FFP is never changed automatically (it also triggers player releases) —
-- clubs whose FFP status would flip are flagged for manual review.
--
-- Run BEFORE End Season (the archive snapshots the ledger at End Season).
-- Preview: SELECT public.competition_admin_resettle_league_prizes(NULL, NULL, true);
-- Apply:   SELECT public.competition_admin_resettle_league_prizes(NULL, NULL, false);
-- Safe re-run: once paid amounts match the config, deltas are 0.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.competition_admin_resettle_league_prizes(
  p_season_id bigint DEFAULT NULL,
  p_division text DEFAULT NULL,
  p_dry_run boolean DEFAULT true,
  p_true_up_interest boolean DEFAULT true
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season_id bigint;
  v_row record;
  v_new numeric;
  v_delta numeric;
  v_div_label text;
  v_charge record;
  v_snap numeric;
  v_rate numeric;
  v_new_snap numeric;
  v_new_interest numeric;
  v_interest_delta numeric;
  v_debt_interest_new numeric;
  v_ffp_threshold numeric;
  v_has_ffp boolean;
  v_flags text[];
  v_rows jsonb := '[]'::jsonb;
  v_total_delta numeric := 0;
  v_total_interest numeric := 0;
  v_changed int := 0;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF p_division IS NOT NULL
     AND p_division NOT IN ('superleague', 'championship_a', 'championship_b') THEN
    RAISE EXCEPTION 'Invalid division';
  END IF;

  IF p_season_id IS NULL THEN
    SELECT id INTO v_season_id
    FROM public.competition_seasons
    WHERE is_current = true
    ORDER BY id DESC
    LIMIT 1;
  ELSE
    v_season_id := p_season_id;
  END IF;

  IF v_season_id IS NULL THEN
    RAISE EXCEPTION 'No season';
  END IF;

  SELECT greatest(coalesce(b.eos_ffp_debt_threshold, 100000000), 0)
  INTO v_ffp_threshold
  FROM public.gpsl_bank_account b
  WHERE b.id = 1;
  v_ffp_threshold := coalesce(v_ffp_threshold, 100000000);

  FOR v_row IN
    SELECT pp.division, pp.club_short_name, pp.table_position, pp.amount AS paid_amount
    FROM public.competition_league_prize_paid pp
    WHERE pp.season_id = v_season_id
      AND (p_division IS NULL OR pp.division = p_division)
    ORDER BY pp.division, pp.table_position
    FOR UPDATE OF pp
  LOOP
    SELECT coalesce(pc.amount, 0) INTO v_new
    FROM public.competition_league_prize_config pc
    WHERE pc.season_id = v_season_id
      AND pc.division = v_row.division
      AND pc.position = v_row.table_position;
    v_new := coalesce(v_new, 0);
    v_delta := round(v_new - v_row.paid_amount, 0);
    v_flags := ARRAY[]::text[];
    v_interest_delta := 0;

    IF abs(v_delta) < 1 THEN
      CONTINUE;
    END IF;

    IF v_new <= 0 THEN
      v_rows := v_rows || jsonb_build_object(
        'club', v_row.club_short_name,
        'division', v_row.division,
        'position', v_row.table_position,
        'paid_amount', v_row.paid_amount,
        'new_amount', v_new,
        'delta', 0,
        'interest_delta', 0,
        'net_effect', 0,
        'flags', jsonb_build_array('Skipped — new prize for this position is ₿0 (set at least ₿1)'::text)
      );
      CONTINUE;
    END IF;

    v_div_label := CASE v_row.division
      WHEN 'superleague' THEN 'SuperLeague'
      WHEN 'championship_a' THEN 'Championship A'
      WHEN 'championship_b' THEN 'Championship B'
      ELSE v_row.division
    END;

    IF NOT p_dry_run THEN
      PERFORM public.post_club_ledger(
        v_row.club_short_name,
        'prize_league',
        v_delta,
        format(
          '%s league prize adjustment — position %s (₿%s → ₿%s)',
          v_div_label,
          v_row.table_position,
          to_char(v_row.paid_amount, 'FM999,999,999,999'),
          to_char(v_new, 'FM999,999,999,999')
        ),
        jsonb_build_object(
          'division', v_row.division,
          'table_position', v_row.table_position,
          'resettle', true,
          'previous_amount', v_row.paid_amount,
          'new_amount', v_new
        ),
        v_season_id,
        NULL,
        true,
        true
      );

      UPDATE public.competition_league_prize_paid
      SET amount = v_new
      WHERE season_id = v_season_id
        AND division = v_row.division
        AND club_short_name = v_row.club_short_name;
    END IF;

    v_debt_interest_new := NULL;

    -- EOS interest true-up (only if Close Finances already charged it)
    IF p_true_up_interest THEN
      FOR v_charge IN
        SELECT
          cp.charge_type,
          coalesce(nullif(cp.metadata ->> 'effective_amount', '')::numeric, cp.amount) AS amount,
          cp.metadata
        FROM public.competition_season_charge_paid cp
        WHERE cp.season_id = v_season_id
          AND cp.club_short_name = v_row.club_short_name
          AND cp.charge_type IN ('eos_debt_interest', 'eos_balance_interest')
        FOR UPDATE OF cp
      LOOP
        v_snap := nullif(v_charge.metadata ->> 'balance_snapshot', '')::numeric;
        v_rate := nullif(v_charge.metadata ->> 'rate_pct', '')::numeric;
        IF v_snap IS NULL OR v_rate IS NULL THEN
          v_flags := array_append(v_flags, format('%s has no balance snapshot — not trued up', v_charge.charge_type));
          CONTINUE;
        END IF;

        v_new_snap := v_snap + v_delta;

        IF v_charge.charge_type = 'eos_debt_interest' THEN
          v_new_interest := round(greatest(0, -v_new_snap) * v_rate / 100.0, 0);
          v_debt_interest_new := v_new_interest;
          -- Debt interest is a cost: more interest = more negative for the club
          v_interest_delta := v_interest_delta - (v_new_interest - v_charge.amount);
          IF v_new_snap >= 0 THEN
            v_flags := array_append(v_flags, 'Now in credit at close — balance interest not added automatically'::text);
          END IF;
        ELSE
          v_new_interest := round(greatest(0, v_new_snap) * v_rate / 100.0, 0);
          v_interest_delta := v_interest_delta + (v_new_interest - v_charge.amount);
          IF v_new_snap < 0 THEN
            v_flags := array_append(v_flags, 'Now overdrawn at close — debt interest not added automatically'::text);
          END IF;
        END IF;

        IF NOT p_dry_run AND abs(v_new_interest - v_charge.amount) >= 1 THEN
          PERFORM public.post_club_ledger(
            v_row.club_short_name,
            v_charge.charge_type,
            CASE
              WHEN v_charge.charge_type = 'eos_debt_interest'
                THEN -(v_new_interest - v_charge.amount)
              ELSE (v_new_interest - v_charge.amount)
            END,
            format(
              '%s adjustment after league prize change (₿%s → ₿%s)',
              CASE v_charge.charge_type
                WHEN 'eos_debt_interest' THEN 'End of season debt interest'
                ELSE 'End of season balance interest'
              END,
              to_char(v_charge.amount, 'FM999,999,999,999'),
              to_char(v_new_interest, 'FM999,999,999,999')
            ),
            jsonb_build_object(
              'resettle', true,
              'previous_amount', v_charge.amount,
              'new_amount', v_new_interest,
              'balance_snapshot', v_new_snap,
              'rate_pct', v_rate
            ),
            v_season_id,
            NULL,
            true,
            true
          );
        END IF;

        IF NOT p_dry_run THEN
          UPDATE public.competition_season_charge_paid
          SET amount = CASE WHEN v_new_interest > 0 THEN v_new_interest ELSE amount END,
              metadata = coalesce(metadata, '{}'::jsonb)
                || jsonb_build_object(
                  'balance_snapshot', v_new_snap,
                  'effective_amount', v_new_interest,
                  'resettled', true
                )
          WHERE season_id = v_season_id
            AND club_short_name = v_row.club_short_name
            AND charge_type = v_charge.charge_type;
        END IF;
      END LOOP;

      -- FFP review flag (never changed automatically)
      SELECT EXISTS (
        SELECT 1 FROM public.competition_season_charge_paid
        WHERE season_id = v_season_id
          AND club_short_name = v_row.club_short_name
          AND charge_type = 'eos_ffp_charge'
      ) INTO v_has_ffp;

      SELECT nullif(cp.metadata ->> 'balance_snapshot', '')::numeric
      INTO v_snap
      FROM public.competition_season_charge_paid cp
      WHERE cp.season_id = v_season_id
        AND cp.club_short_name = v_row.club_short_name
        AND cp.charge_type = 'eos_debt_interest';

      IF v_snap IS NOT NULL THEN
        -- After apply, snapshot above is already the new one; in dry run it is the old one.
        v_new_snap := CASE WHEN p_dry_run THEN v_snap + v_delta ELSE v_snap END;
        v_new_snap := v_new_snap - coalesce(v_debt_interest_new, 0);
        IF v_has_ffp AND v_new_snap > -v_ffp_threshold THEN
          v_flags := array_append(v_flags, 'FFP was charged but would no longer trigger — review manually'::text);
        ELSIF NOT v_has_ffp AND v_new_snap <= -v_ffp_threshold THEN
          v_flags := array_append(v_flags, 'FFP was not charged but would now trigger — review manually'::text);
        END IF;
      END IF;
    END IF;

    v_total_delta := v_total_delta + v_delta;
    v_total_interest := v_total_interest + v_interest_delta;
    v_changed := v_changed + 1;

    v_rows := v_rows || jsonb_build_object(
      'club', v_row.club_short_name,
      'division', v_row.division,
      'position', v_row.table_position,
      'paid_amount', v_row.paid_amount,
      'new_amount', v_new,
      'delta', v_delta,
      'interest_delta', v_interest_delta,
      'net_effect', v_delta + v_interest_delta,
      'flags', to_jsonb(v_flags)
    );
  END LOOP;

  IF NOT p_dry_run AND v_changed > 0
     AND to_regprocedure('public.competition_archive_club_finances_for_season(bigint)') IS NOT NULL THEN
    PERFORM public.competition_archive_club_finances_for_season(v_season_id);
  END IF;

  RETURN jsonb_build_object(
    'season_id', v_season_id,
    'dry_run', p_dry_run,
    'clubs_changed', v_changed,
    'total_prize_delta', v_total_delta,
    'total_interest_delta', v_total_interest,
    'rows', v_rows
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_admin_resettle_league_prizes(bigint, text, boolean, boolean)
  TO authenticated;

NOTIFY pgrst, 'reload schema';
