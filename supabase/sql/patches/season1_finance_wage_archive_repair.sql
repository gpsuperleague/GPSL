-- =============================================================================
-- Season 1 finance archive: restore wages / 34+ / star tax into the snapshot
--
-- Root cause (not a wipe): Close Season checklist ordered
--   1) Archive season stats & awards  ← finance snapshot taken HERE
--   2) Close Finances                ← wages posted AFTER archive
-- So live Season 1 accounts showed wages, then Season 2 switched the UI to the
-- stale archive (no wage lines) — figures looked like they "disappeared".
--
-- Stadium infra cleanup patches only delete entry_type = infra_purchase.
-- They do not remove wage lines.
--
-- This patch:
--   1) If charge_paid exists but ledger line missing → insert ledger only
--      (no cash debit — balances already charged at Close Finances)
--   2) Always re-snapshot competition_club_finance_season_archive for Season "1"
--   3) Make Close Finances re-snapshot finances after posting (future-proof)
--
-- Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.competition_admin_close_finances(
  p_season_id bigint DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season_id bigint;
  v_wages jsonb;
  v_debt int := 0;
  v_ffp int := 0;
  v_credit int := 0;
  v_finance_archived int := 0;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
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
    RAISE EXCEPTION 'No current season';
  END IF;

  -- 1) Season wage bills (players, manager salary, 34+, star tax)
  v_wages := public.competition_admin_post_season_wage_bills(v_season_id);

  -- 2) Debt interest on overdrawn accounts (after wages)
  v_debt := public.competition_post_eos_debt_interest(v_season_id);

  -- 3) FFP on clubs at/below −threshold (after debt interest)
  v_ffp := public.competition_post_eos_ffp_charges(v_season_id);

  -- 4) Credit interest on positive balances
  v_credit := public.competition_post_eos_balance_interest(v_season_id);

  -- 5) Refresh finance archive so Season accounts include wages even if
  --    "Archive season stats" ran earlier in the checklist.
  IF to_regprocedure('public.competition_archive_club_finances_for_season(bigint)') IS NOT NULL THEN
    v_finance_archived := public.competition_archive_club_finances_for_season(v_season_id);
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'season_id', v_season_id,
    'wages', v_wages,
    'debt_interest_clubs', v_debt,
    'ffp_clubs', v_ffp,
    'balance_interest_clubs', v_credit,
    'finance_archive_clubs', v_finance_archived
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_admin_close_finances(bigint) TO authenticated;

DO $repair$
DECLARE
  v_season record;
  v_paid record;
  v_inserted int := 0;
  v_archived int := 0;
  v_wage_ledger int := 0;
  v_entry text;
  v_desc text;
BEGIN
  FOR v_season IN
    SELECT s.id, s.label
    FROM public.competition_seasons s
    WHERE coalesce(s.is_current, false) = false
      AND (
        s.label IN ('1', 'Season 1')
        OR EXISTS (
          SELECT 1
          FROM public.competition_season_charge_paid p
          WHERE p.season_id = s.id
            AND p.charge_type IN (
              'wage_squad',
              'wage_renewal_34plus',
              'wage_star_tax',
              'staff_manager_salary'
            )
        )
        OR EXISTS (
          SELECT 1
          FROM public.competition_finance_ledger l
          WHERE l.season_id = s.id
            AND l.entry_type IN (
              'wage_squad',
              'wage_renewal_34plus',
              'wage_star_tax',
              'staff_manager_salary'
            )
        )
      )
    ORDER BY
      CASE WHEN s.label IN ('1', 'Season 1') THEN 0 ELSE 1 END,
      s.id
  LOOP
    FOR v_paid IN
      SELECT
        p.season_id,
        p.club_short_name,
        p.charge_type,
        p.amount,
        p.metadata,
        p.created_at
      FROM public.competition_season_charge_paid p
      WHERE p.season_id = v_season.id
        AND p.charge_type IN (
          'wage_squad',
          'wage_renewal_34plus',
          'wage_star_tax',
          'staff_manager_salary'
        )
        AND NOT EXISTS (
          SELECT 1
          FROM public.competition_finance_ledger l
          WHERE l.season_id = p.season_id
            AND l.club_short_name = p.club_short_name
            AND l.entry_type = p.charge_type
        )
    LOOP
      v_entry := v_paid.charge_type;
      v_desc := CASE v_entry
        WHEN 'wage_squad' THEN 'Season squad wages (archive repair)'
        WHEN 'wage_renewal_34plus' THEN '34+ rating fee (archive repair)'
        WHEN 'wage_star_tax' THEN 'Star tax (archive repair)'
        WHEN 'staff_manager_salary' THEN 'Season manager salary (archive repair)'
        ELSE v_entry
      END;

      INSERT INTO public.competition_finance_ledger (
        season_id,
        fixture_id,
        club_short_name,
        entry_type,
        amount,
        description,
        metadata,
        created_at
      )
      VALUES (
        v_paid.season_id,
        NULL,
        v_paid.club_short_name,
        v_entry,
        -abs(coalesce(v_paid.amount, 0)),
        v_desc,
        coalesce(v_paid.metadata, '{}'::jsonb) || jsonb_build_object('archive_repair', true),
        coalesce(v_paid.created_at, now())
      );

      v_inserted := v_inserted + 1;
    END LOOP;

    SELECT count(*)::int
    INTO v_wage_ledger
    FROM public.competition_finance_ledger l
    WHERE l.season_id = v_season.id
      AND l.entry_type IN (
        'wage_squad',
        'wage_renewal_34plus',
        'wage_star_tax',
        'staff_manager_salary'
      );

    IF to_regprocedure('public.competition_archive_club_finances_for_season(bigint)') IS NOT NULL THEN
      v_archived := v_archived
        + public.competition_archive_club_finances_for_season(v_season.id);
    END IF;

    RAISE NOTICE
      'Season % (id=%): wage ledger rows=%; charge_paid→ledger inserts=%; archive refresh done',
      v_season.label, v_season.id, v_wage_ledger, v_inserted;
  END LOOP;

  RAISE NOTICE
    'Done. Ledger inserts from charge_paid=%; re-open Season 1 finances after hard-refresh.',
    v_inserted;
END;
$repair$;

NOTIFY pgrst, 'reload schema';
