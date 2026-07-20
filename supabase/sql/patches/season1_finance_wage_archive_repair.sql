-- =============================================================================
-- Season 1 finance archive: repair missing wage / 34+ / star tax ledger lines
--
-- Symptom: Season accounts archive shows ฿0 for wages / 34+ / star tax even
-- though Close Finances may have recorded charges in competition_season_charge_paid.
--
-- Also: URL season=4 vs label "1" is expected (DB id ≠ label). Client now uses
-- labels in ?season=; this patch only repairs ledger + re-snapshots archives.
--
-- Safe: inserts missing ledger lines from charge_paid WITHOUT re-debiting cash.
-- Then re-runs finance archive snapshot for the season.
-- Safe re-run.
-- =============================================================================

DO $repair$
DECLARE
  v_season record;
  v_paid record;
  v_inserted int := 0;
  v_archived int := 0;
  v_entry text;
  v_desc text;
BEGIN
  -- Prefer human Season "1"; fall back to any completed non-current season
  -- that has charge_paid rows but missing matching ledger lines.
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

    IF to_regprocedure('public.competition_archive_club_finances_for_season(bigint)') IS NOT NULL THEN
      v_archived := v_archived
        + public.competition_archive_club_finances_for_season(v_season.id);
    END IF;

    RAISE NOTICE 'Season % (id=%): repaired wage ledger lines so far total inserts=%; archive clubs touched cumulative=%',
      v_season.label, v_season.id, v_inserted, v_archived;
  END LOOP;

  RAISE NOTICE 'Wage ledger repair complete: % ledger line(s) inserted; finance archives refreshed',
    v_inserted;

  IF v_inserted = 0 THEN
    RAISE NOTICE
      'No charge_paid→ledger gaps found. If Season 1 still shows ฿0 wages, Close Finances / Post season wage bills was never run for that season (competition_season_charge_paid empty). Do NOT re-post wages now — that would debit Season 2 cash from current squads.';
  END IF;
END;
$repair$;

NOTIFY pgrst, 'reload schema';
