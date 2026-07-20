-- =============================================================================
-- Season 1 wages: diagnose + force-repair finance archive
--
-- Run in Supabase SQL Editor. Read the Notices AND the result grid.
-- Safe re-run. Does not debit Club_Finances.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1) Report (also returned as a result set)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_diagnose_season_wage_archive(
  p_season_label text DEFAULT '1'
)
RETURNS TABLE (
  section text,
  detail text,
  n bigint
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_sid bigint;
  v_label text;
BEGIN
  SELECT s.id, s.label
  INTO v_sid, v_label
  FROM public.competition_seasons s
  WHERE s.label = p_season_label
  ORDER BY s.id DESC
  LIMIT 1;

  IF v_sid IS NULL THEN
    SELECT s.id, s.label
    INTO v_sid, v_label
    FROM public.competition_seasons s
    WHERE s.label ILIKE '%' || p_season_label || '%'
    ORDER BY s.id DESC
    LIMIT 1;
  END IF;

  section := 'season';
  detail := format('label=%s id=%s', coalesce(v_label, '?'), coalesce(v_sid::text, 'NOT FOUND'));
  n := coalesce(v_sid, 0);
  RETURN NEXT;

  IF v_sid IS NULL THEN
    RETURN;
  END IF;

  RETURN QUERY
  SELECT
    'ledger_wages'::text,
    l.entry_type::text,
    count(*)::bigint
  FROM public.competition_finance_ledger l
  WHERE l.season_id = v_sid
    AND l.entry_type IN (
      'wage_squad', 'wage_renewal_34plus', 'wage_star_tax', 'staff_manager_salary'
    )
  GROUP BY l.entry_type
  ORDER BY l.entry_type;

  IF NOT FOUND THEN
    section := 'ledger_wages';
    detail := 'none';
    n := 0;
    RETURN NEXT;
  END IF;

  RETURN QUERY
  SELECT
    'charge_paid'::text,
    p.charge_type::text,
    count(*)::bigint
  FROM public.competition_season_charge_paid p
  WHERE p.season_id = v_sid
    AND p.charge_type IN (
      'wage_squad', 'wage_renewal_34plus', 'wage_star_tax', 'staff_manager_salary'
    )
  GROUP BY p.charge_type
  ORDER BY p.charge_type;

  RETURN QUERY
  SELECT
    'archive_rows'::text,
    'clubs'::text,
    count(*)::bigint
  FROM public.competition_club_finance_season_archive a
  WHERE a.season_id = v_sid;

  RETURN QUERY
  SELECT
    'archive_json_wages'::text,
    e.entry_type,
    count(*)::bigint
  FROM public.competition_club_finance_season_archive a
  CROSS JOIN LATERAL (
    SELECT nullif(x.elem->>'entry_type', '') AS entry_type
    FROM jsonb_array_elements(coalesce(a.ledger_lines, '[]'::jsonb)) AS x(elem)
  ) e
  WHERE a.season_id = v_sid
    AND e.entry_type IN (
      'wage_squad', 'wage_renewal_34plus', 'wage_star_tax', 'staff_manager_salary'
    )
  GROUP BY e.entry_type
  ORDER BY e.entry_type;

  -- Wages that may have been posted onto the *current* season by mistake
  RETURN QUERY
  SELECT
    'wages_on_current_season'::text,
    l.entry_type::text,
    count(*)::bigint
  FROM public.competition_finance_ledger l
  JOIN public.competition_seasons s ON s.id = l.season_id AND s.is_current = true
  WHERE l.entry_type IN (
      'wage_squad', 'wage_renewal_34plus', 'wage_star_tax', 'staff_manager_salary'
    )
  GROUP BY l.entry_type
  ORDER BY l.entry_type;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.admin_diagnose_season_wage_archive(text) TO authenticated;

-- ---------------------------------------------------------------------------
-- 2) Repair
-- ---------------------------------------------------------------------------
DO $repair$
DECLARE
  v_sid bigint;
  v_label text;
  v_current bigint;
  v_paid record;
  v_row record;
  v_inserted int := 0;
  v_moved int := 0;
  v_archived int := 0;
  v_ledger_wages int := 0;
  v_paid_wages int := 0;
  v_archive_wages int := 0;
  v_entry text;
  v_desc text;
BEGIN
  SELECT s.id, s.label
  INTO v_sid, v_label
  FROM public.competition_seasons s
  WHERE s.label IN ('1', 'Season 1')
  ORDER BY CASE WHEN s.label = '1' THEN 0 ELSE 1 END, s.id DESC
  LIMIT 1;

  IF v_sid IS NULL THEN
    RAISE EXCEPTION 'Could not find Season 1 (label 1 / Season 1)';
  END IF;

  SELECT s.id INTO v_current
  FROM public.competition_seasons s
  WHERE s.is_current = true
  ORDER BY s.id DESC
  LIMIT 1;

  SELECT count(*)::int INTO v_ledger_wages
  FROM public.competition_finance_ledger l
  WHERE l.season_id = v_sid
    AND l.entry_type IN (
      'wage_squad', 'wage_renewal_34plus', 'wage_star_tax', 'staff_manager_salary'
    );

  SELECT count(*)::int INTO v_paid_wages
  FROM public.competition_season_charge_paid p
  WHERE p.season_id = v_sid
    AND p.charge_type IN (
      'wage_squad', 'wage_renewal_34plus', 'wage_star_tax', 'staff_manager_salary'
    );

  SELECT count(*)::int INTO v_archive_wages
  FROM public.competition_club_finance_season_archive a
  CROSS JOIN LATERAL jsonb_array_elements(coalesce(a.ledger_lines, '[]'::jsonb)) x(elem)
  WHERE a.season_id = v_sid
    AND x.elem->>'entry_type' IN (
      'wage_squad', 'wage_renewal_34plus', 'wage_star_tax', 'staff_manager_salary'
    );

  RAISE NOTICE
    'Season % id=% | ledger wages=% | charge_paid=% | archive json wages=% | current_season_id=%',
    v_label, v_sid, v_ledger_wages, v_paid_wages, v_archive_wages, v_current;

  -- A) Restore ledger from charge_paid (cash already taken — no balance change)
  FOR v_paid IN
    SELECT *
    FROM public.competition_season_charge_paid p
    WHERE p.season_id = v_sid
      AND p.charge_type IN (
        'wage_squad', 'wage_renewal_34plus', 'wage_star_tax', 'staff_manager_salary'
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
      season_id, fixture_id, club_short_name, entry_type, amount, description, metadata, created_at
    )
    VALUES (
      v_sid,
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

  -- B) If Close Finances ran after Season 2 was current, wages may sit on current season
  --    while charge_paid is keyed to Season 1. Move those ledger rows back (no cash change).
  IF v_current IS NOT NULL AND v_current <> v_sid THEN
    FOR v_row IN
      SELECT l.id, l.club_short_name, l.entry_type
      FROM public.competition_finance_ledger l
      WHERE l.season_id = v_current
        AND l.entry_type IN (
          'wage_squad', 'wage_renewal_34plus', 'wage_star_tax', 'staff_manager_salary'
        )
        AND EXISTS (
          SELECT 1
          FROM public.competition_season_charge_paid p
          WHERE p.season_id = v_sid
            AND p.club_short_name = l.club_short_name
            AND p.charge_type = l.entry_type
        )
        AND NOT EXISTS (
          SELECT 1
          FROM public.competition_finance_ledger x
          WHERE x.season_id = v_sid
            AND x.club_short_name = l.club_short_name
            AND x.entry_type = l.entry_type
        )
    LOOP
      UPDATE public.competition_finance_ledger
      SET season_id = v_sid,
          metadata = coalesce(metadata, '{}'::jsonb)
            || jsonb_build_object('moved_from_season_id', v_current, 'archive_repair', true)
      WHERE id = v_row.id;
      v_moved := v_moved + 1;
    END LOOP;
  END IF;

  -- C) Always re-snapshot Season 1 finance archive from ledger
  IF to_regprocedure('public.competition_archive_club_finances_for_season(bigint)') IS NOT NULL THEN
    v_archived := public.competition_archive_club_finances_for_season(v_sid);
  END IF;

  SELECT count(*)::int INTO v_ledger_wages
  FROM public.competition_finance_ledger l
  WHERE l.season_id = v_sid
    AND l.entry_type IN (
      'wage_squad', 'wage_renewal_34plus', 'wage_star_tax', 'staff_manager_salary'
    );

  SELECT count(*)::int INTO v_archive_wages
  FROM public.competition_club_finance_season_archive a
  CROSS JOIN LATERAL jsonb_array_elements(coalesce(a.ledger_lines, '[]'::jsonb)) x(elem)
  WHERE a.season_id = v_sid
    AND x.elem->>'entry_type' IN (
      'wage_squad', 'wage_renewal_34plus', 'wage_star_tax', 'staff_manager_salary'
    );

  RAISE NOTICE
    'Repair done: inserted=% moved_from_current=% archive_clubs=% | ledger wages now=% | archive json wages now=%',
    v_inserted, v_moved, v_archived, v_ledger_wages, v_archive_wages;

  IF v_ledger_wages = 0 AND v_paid_wages = 0 THEN
    RAISE NOTICE
      'NO WAGE DATA FOUND for Season 1. Close Finances rows are gone from both ledger and charge_paid — cannot reconstruct amounts. Check Notices from SELECT diagnose below.';
  ELSIF v_archive_wages = 0 AND v_ledger_wages > 0 THEN
    RAISE WARNING
      'Ledger has wages but archive JSON still empty — competition_archive_club_finances_for_season may have failed.';
  END IF;
END;
$repair$;

-- Show diagnose grid after repair
SELECT * FROM public.admin_diagnose_season_wage_archive('1');

NOTIFY pgrst, 'reload schema';
