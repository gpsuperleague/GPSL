-- =============================================================================
-- Re-settle season upkeep AFTER Close Finances (before End Season).
--
-- Close Finances posts each upkeep charge once (competition_season_charge_paid
-- blocks re-posting). This recalculates the charges from the current squad /
-- settings and posts only the difference:
--   wage_squad                 — player wage bill
--   wage_fan_favourite_subsidy — Central Bank 50% of the Fan Favourite's wage
--   staff_manager_salary       — manager weekly × 52
--   wage_renewal_34plus        — 34+ age fee
--   wage_star_tax              — star tax
--
-- p_wage_basis:
--   'contract' — same as Close Finances: stored Players.contract_wage, falling
--                back to wage % × MV only where no contract wage is stored.
--   'wage_pct' — reprice every player at the CURRENT admin wage % × MV
--                (use after changing Wage %; stored contract wages are ignored
--                for this season's bill but NOT overwritten).
--
-- With p_true_up_interest, EOS debt / balance interest are recalculated from
-- their stored balance_snapshot + the club's net change. FFP is never changed
-- automatically — clubs whose FFP result would flip are flagged.
--
-- Only clubs whose wage bill was already posted this season are touched.
-- Preview: SELECT public.competition_admin_resettle_season_upkeep(NULL, NULL, true);
-- Apply:   SELECT public.competition_admin_resettle_season_upkeep(NULL, NULL, false);
-- Safe re-run: differences become ₿0 once applied.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Shared: true-up EOS debt / balance interest for a change in close balance
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.competition_resettle_eos_interest_for_delta(
  p_season_id bigint,
  p_club_short_name text,
  p_delta numeric,
  p_dry_run boolean DEFAULT true
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_charge record;
  v_snap numeric;
  v_rate numeric;
  v_new_snap numeric;
  v_new_interest numeric;
  v_interest_delta numeric := 0;
  v_debt_interest_new numeric;
  v_debt_snap_new numeric;
  v_has_ffp boolean;
  v_ffp_threshold numeric;
  v_flags text[] := ARRAY[]::text[];
BEGIN
  IF p_delta IS NULL OR abs(p_delta) < 1 THEN
    RETURN jsonb_build_object('interest_delta', 0, 'flags', '[]'::jsonb);
  END IF;

  FOR v_charge IN
    SELECT
      cp.charge_type,
      coalesce(nullif(cp.metadata ->> 'effective_amount', '')::numeric, cp.amount) AS amount,
      cp.metadata
    FROM public.competition_season_charge_paid cp
    WHERE cp.season_id = p_season_id
      AND cp.club_short_name = p_club_short_name
      AND cp.charge_type IN ('eos_debt_interest', 'eos_balance_interest')
    FOR UPDATE OF cp
  LOOP
    v_snap := nullif(v_charge.metadata ->> 'balance_snapshot', '')::numeric;
    v_rate := nullif(v_charge.metadata ->> 'rate_pct', '')::numeric;
    IF v_snap IS NULL OR v_rate IS NULL THEN
      v_flags := array_append(v_flags, format('%s has no balance snapshot — not trued up', v_charge.charge_type));
      CONTINUE;
    END IF;

    v_new_snap := v_snap + p_delta;

    IF v_charge.charge_type = 'eos_debt_interest' THEN
      v_new_interest := round(greatest(0, -v_new_snap) * v_rate / 100.0, 0);
      v_debt_interest_new := v_new_interest;
      v_debt_snap_new := v_new_snap;
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

    IF NOT p_dry_run THEN
      IF abs(v_new_interest - v_charge.amount) >= 1 THEN
        PERFORM public.post_club_ledger(
          p_club_short_name,
          v_charge.charge_type,
          CASE
            WHEN v_charge.charge_type = 'eos_debt_interest'
              THEN -(v_new_interest - v_charge.amount)
            ELSE (v_new_interest - v_charge.amount)
          END,
          format(
            '%s adjustment after re-settle (₿%s → ₿%s)',
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
          p_season_id,
          NULL,
          true,
          true
        );
      END IF;

      UPDATE public.competition_season_charge_paid
      SET amount = CASE WHEN v_new_interest > 0 THEN v_new_interest ELSE amount END,
          metadata = coalesce(metadata, '{}'::jsonb)
            || jsonb_build_object(
              'balance_snapshot', v_new_snap,
              'effective_amount', v_new_interest,
              'resettled', true
            )
      WHERE season_id = p_season_id
        AND club_short_name = p_club_short_name
        AND charge_type = v_charge.charge_type;
    END IF;
  END LOOP;

  IF v_debt_snap_new IS NOT NULL THEN
    SELECT greatest(coalesce(b.eos_ffp_debt_threshold, 100000000), 0)
    INTO v_ffp_threshold
    FROM public.gpsl_bank_account b
    WHERE b.id = 1;
    v_ffp_threshold := coalesce(v_ffp_threshold, 100000000);

    SELECT EXISTS (
      SELECT 1 FROM public.competition_season_charge_paid
      WHERE season_id = p_season_id
        AND club_short_name = p_club_short_name
        AND charge_type = 'eos_ffp_charge'
    ) INTO v_has_ffp;

    IF v_has_ffp AND (v_debt_snap_new - coalesce(v_debt_interest_new, 0)) > -v_ffp_threshold THEN
      v_flags := array_append(v_flags, 'FFP was charged but would no longer trigger — review manually'::text);
    ELSIF NOT v_has_ffp AND (v_debt_snap_new - coalesce(v_debt_interest_new, 0)) <= -v_ffp_threshold THEN
      v_flags := array_append(v_flags, 'FFP was not charged but would now trigger — review manually'::text);
    END IF;
  END IF;

  RETURN jsonb_build_object('interest_delta', v_interest_delta, 'flags', to_jsonb(v_flags));
END;
$function$;

-- ---------------------------------------------------------------------------
-- Admin: re-settle wages / manager salary / 34+ / star tax / FF subsidy
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.competition_admin_resettle_season_upkeep(
  p_season_id bigint DEFAULT NULL,
  p_division text DEFAULT NULL,
  p_dry_run boolean DEFAULT true,
  p_true_up_interest boolean DEFAULT true,
  p_wage_basis text DEFAULT 'contract'
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season_id bigint;
  v_club record;
  v_s public.global_settings;
  v_ff record;
  v_line record;
  v_old numeric;
  v_new numeric;
  v_diff numeric;
  v_club_delta numeric;
  v_lines jsonb;
  v_interest jsonb;
  v_flags jsonb;
  v_rows jsonb := '[]'::jsonb;
  v_total_delta numeric := 0;
  v_total_interest numeric := 0;
  v_changed int := 0;
  v_count int;
  v_is_credit boolean;
  v_label text;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF p_division IS NOT NULL
     AND p_division NOT IN ('superleague', 'championship_a', 'championship_b') THEN
    RAISE EXCEPTION 'Invalid division';
  END IF;

  IF coalesce(p_wage_basis, 'contract') NOT IN ('contract', 'wage_pct') THEN
    RAISE EXCEPTION 'wage basis must be contract or wage_pct';
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

  v_s := (SELECT g FROM public.global_settings g WHERE g.id = 1);

  FOR v_club IN
    SELECT ccs.club_short_name, ccs.division
    FROM public.competition_club_seasons ccs
    WHERE ccs.season_id = v_season_id
      AND ccs.division IN ('superleague', 'championship_a', 'championship_b')
      AND (p_division IS NULL OR ccs.division = p_division)
      AND EXISTS (
        SELECT 1 FROM public.competition_season_charge_paid cp
        WHERE cp.season_id = v_season_id
          AND cp.club_short_name = ccs.club_short_name
          AND cp.charge_type = 'wage_squad'
      )
    ORDER BY ccs.division, ccs.club_short_name
  LOOP
    v_club_delta := 0;
    v_lines := '[]'::jsonb;

    FOR v_line IN
      SELECT * FROM (VALUES
        ('wage_squad'::text, 'Wages'::text, false),
        ('wage_fan_favourite_subsidy', 'Fan Favourite subsidy', true),
        ('staff_manager_salary', 'Manager salary', false),
        ('wage_renewal_34plus', '34+ age fee', false),
        ('wage_star_tax', 'Star tax', false)
      ) AS t(charge_type, label, is_credit)
    LOOP
      v_is_credit := v_line.is_credit;
      v_label := v_line.label;

      SELECT coalesce(nullif(cp.metadata ->> 'effective_amount', '')::numeric, cp.amount)
      INTO v_old
      FROM public.competition_season_charge_paid cp
      WHERE cp.season_id = v_season_id
        AND cp.club_short_name = v_club.club_short_name
        AND cp.charge_type = v_line.charge_type
      FOR UPDATE OF cp;
      v_old := coalesce(v_old, 0);

      v_count := NULL;
      IF v_line.charge_type = 'wage_squad' THEN
        IF p_wage_basis = 'wage_pct' THEN
          SELECT round(coalesce(sum(
            public.calculate_player_wage_for_club(p."Konami_ID"::text, v_club.club_short_name)
          ), 0), 0), count(*)::int
          INTO v_new, v_count
          FROM public."Players" p
          WHERE p."Contracted_Team" = v_club.club_short_name;
        ELSE
          v_new := public.competition_club_wage_bill_total(v_club.club_short_name, v_season_id);
          SELECT count(*)::int INTO v_count
          FROM public."Players" p
          WHERE p."Contracted_Team" = v_club.club_short_name;
        END IF;
      ELSIF v_line.charge_type = 'wage_fan_favourite_subsidy' THEN
        SELECT * INTO v_ff
        FROM public.club_squad_fan_favourite_wage_half(v_club.club_short_name)
        LIMIT 1;
        IF v_ff.player_id IS NULL THEN
          v_new := 0;
        ELSIF p_wage_basis = 'wage_pct' THEN
          v_new := round(
            coalesce(public.calculate_player_wage_for_club(v_ff.player_id::text, v_club.club_short_name), 0) / 2.0,
            0
          );
        ELSE
          v_new := round(coalesce(v_ff.subsidy_half, 0), 0);
        END IF;
      ELSIF v_line.charge_type = 'staff_manager_salary' THEN
        v_new := public.competition_club_manager_salary_total(v_club.club_short_name);
      ELSIF v_line.charge_type = 'wage_renewal_34plus' THEN
        v_count := public.competition_club_34plus_count(v_club.club_short_name);
        v_new := round(v_count * coalesce(v_s.wage_34plus_per_player, 0), 0);
      ELSE
        v_count := public.competition_club_star_tax_count(v_club.club_short_name);
        v_new := round(v_count * coalesce(v_s.star_tax_per_player, 0), 0);
      END IF;
      v_new := coalesce(v_new, 0);

      v_diff := round(v_new - v_old, 0);
      IF abs(v_diff) < 1 THEN
        CONTINUE;
      END IF;

      -- Club cash effect: costs reduce balance, the FF subsidy adds to it.
      v_club_delta := v_club_delta + CASE WHEN v_is_credit THEN v_diff ELSE -v_diff END;

      v_lines := v_lines || jsonb_build_object(
        'type', v_line.charge_type,
        'label', v_label,
        'old', v_old,
        'new', v_new,
        'club_effect', CASE WHEN v_is_credit THEN v_diff ELSE -v_diff END,
        'count', v_count
      );

      IF NOT p_dry_run THEN
        PERFORM public.post_club_ledger(
          v_club.club_short_name,
          v_line.charge_type,
          CASE WHEN v_is_credit THEN v_diff ELSE -v_diff END,
          format(
            '%s re-settle (₿%s → ₿%s)%s',
            v_label,
            to_char(v_old, 'FM999,999,999,999'),
            to_char(v_new, 'FM999,999,999,999'),
            CASE WHEN v_line.charge_type = 'wage_squad' AND p_wage_basis = 'wage_pct'
              THEN ' at current wage %' ELSE '' END
          ),
          jsonb_build_object(
            'resettle', true,
            'previous_amount', v_old,
            'new_amount', v_new,
            'wage_basis', p_wage_basis,
            'player_count', v_count
          ),
          v_season_id,
          NULL,
          public.finance_entry_via_central_bank(v_line.charge_type),
          true
        );

        IF EXISTS (
          SELECT 1 FROM public.competition_season_charge_paid
          WHERE season_id = v_season_id
            AND club_short_name = v_club.club_short_name
            AND charge_type = v_line.charge_type
        ) THEN
          UPDATE public.competition_season_charge_paid
          SET amount = CASE WHEN v_new > 0 THEN v_new ELSE amount END,
              metadata = coalesce(metadata, '{}'::jsonb)
                || jsonb_build_object('effective_amount', v_new, 'resettled', true)
          WHERE season_id = v_season_id
            AND club_short_name = v_club.club_short_name
            AND charge_type = v_line.charge_type;
        ELSIF v_new > 0 THEN
          INSERT INTO public.competition_season_charge_paid (
            season_id, club_short_name, charge_type, amount, metadata
          )
          VALUES (
            v_season_id, v_club.club_short_name, v_line.charge_type, v_new,
            jsonb_build_object('effective_amount', v_new, 'resettled', true)
          );
        END IF;
      END IF;
    END LOOP;

    IF jsonb_array_length(v_lines) = 0 THEN
      CONTINUE;
    END IF;

    IF p_true_up_interest THEN
      v_interest := public.competition_resettle_eos_interest_for_delta(
        v_season_id, v_club.club_short_name, v_club_delta, p_dry_run
      );
    ELSE
      v_interest := jsonb_build_object('interest_delta', 0, 'flags', '[]'::jsonb);
    END IF;
    v_flags := coalesce(v_interest -> 'flags', '[]'::jsonb);

    IF EXISTS (
      SELECT 1 FROM public.competition_season_charge_paid
      WHERE season_id = v_season_id
        AND club_short_name = v_club.club_short_name
        AND charge_type = 'eos_ffp_charge'
    ) THEN
      v_flags := v_flags || jsonb_build_array(
        'FFP club — players released at close are no longer in the squad, so their wages would be refunded. Check before applying.'::text
      );
    END IF;

    v_total_delta := v_total_delta + v_club_delta;
    v_total_interest := v_total_interest + coalesce((v_interest ->> 'interest_delta')::numeric, 0);
    v_changed := v_changed + 1;

    v_rows := v_rows || jsonb_build_object(
      'club', v_club.club_short_name,
      'division', v_club.division,
      'lines', v_lines,
      'upkeep_delta', v_club_delta,
      'interest_delta', coalesce((v_interest ->> 'interest_delta')::numeric, 0),
      'net_effect', v_club_delta + coalesce((v_interest ->> 'interest_delta')::numeric, 0),
      'flags', v_flags
    );
  END LOOP;

  IF NOT p_dry_run AND v_changed > 0
     AND to_regprocedure('public.competition_archive_club_finances_for_season(bigint)') IS NOT NULL THEN
    PERFORM public.competition_archive_club_finances_for_season(v_season_id);
  END IF;

  RETURN jsonb_build_object(
    'season_id', v_season_id,
    'dry_run', p_dry_run,
    'wage_basis', p_wage_basis,
    'clubs_changed', v_changed,
    'total_upkeep_delta', v_total_delta,
    'total_interest_delta', v_total_interest,
    'rows', v_rows
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_resettle_eos_interest_for_delta(bigint, text, numeric, boolean)
  TO authenticated;
GRANT EXECUTE ON FUNCTION public.competition_admin_resettle_season_upkeep(bigint, text, boolean, boolean, text)
  TO authenticated;

NOTIFY pgrst, 'reload schema';
