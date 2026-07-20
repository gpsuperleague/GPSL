-- =============================================================================
-- Season 1 wages: diagnose + repair finance archive (v2)
--
-- Why Season 1 still shows ฿0 wages:
--   Archive ran BEFORE Close Finances, so the snapshot had no wage lines.
--   Re-archive later used *today's* Club_Finances balance as "closing", which
--   corrupts opening/running totals and still won't invent missing wage rows.
--
-- This patch:
--   1) Fixes competition_archive_club_finances_for_season for past seasons
--      (refresh ledger/totals; keep original opening/closing when present)
--   2) Restores wage ledger lines from charge_paid if missing (no cash debit)
--   3) Moves wages posted onto the current season back to Season 1 when
--      charge_paid proves they belong to Season 1
--   4) Re-snapshots Season 1 and prints a diagnose grid
--
-- Run once in Supabase SQL Editor. Safe re-run.
-- Paste the result grid here if wages are still blank.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.competition_archive_club_finances_for_season(
  p_season_id bigint
)
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season public.competition_seasons%rowtype;
  v_club text;
  v_income numeric(14, 2);
  v_cost numeric(14, 2);
  v_net numeric(14, 2);
  v_closing numeric(14, 2);
  v_opening numeric(14, 2);
  v_prev_opening numeric(14, 2);
  v_prev_closing numeric(14, 2);
  v_lines jsonb;
  v_count int := 0;
  v_is_current boolean;
BEGIN
  SELECT * INTO v_season
  FROM public.competition_seasons
  WHERE id = p_season_id;

  IF NOT FOUND THEN
    RETURN 0;
  END IF;

  v_is_current := coalesce(v_season.is_current, false);

  FOR v_club IN
    SELECT DISTINCT u.club_short_name
    FROM (
      SELECT l.club_short_name
      FROM public.competition_finance_ledger l
      WHERE l.season_id = p_season_id
      UNION
      SELECT a.club_short_name
      FROM public.competition_club_season_archive a
      WHERE a.season_id = p_season_id
      UNION
      SELECT f.club_short_name
      FROM public.competition_club_finance_season_archive f
      WHERE f.season_id = p_season_id
      UNION
      SELECT ccs.club_short_name
      FROM public.competition_club_seasons ccs
      WHERE ccs.season_id = p_season_id
    ) u
    WHERE u.club_short_name IS NOT NULL
      AND u.club_short_name <> 'FOREIGN'
    ORDER BY u.club_short_name
  LOOP
    SELECT
      coalesce(sum(
        CASE
          WHEN public.competition_finance_entry_is_income(l.entry_type, l.amount)
            THEN l.amount
          ELSE 0
        END
      ), 0),
      coalesce(sum(
        CASE
          WHEN public.competition_finance_entry_is_income(l.entry_type, l.amount)
            THEN 0
          ELSE abs(l.amount)
        END
      ), 0)
    INTO v_income, v_cost
    FROM public.competition_finance_ledger l
    WHERE l.season_id = p_season_id
      AND l.club_short_name = v_club;

    v_net := v_income - v_cost;

    SELECT a.opening_balance, a.closing_balance
    INTO v_prev_opening, v_prev_closing
    FROM public.competition_club_finance_season_archive a
    WHERE a.season_id = p_season_id
      AND a.club_short_name = v_club;

    IF v_is_current THEN
      -- Live season end: closing = cash now; opening inferred from net
      SELECT cf.balance
      INTO v_closing
      FROM public."Club_Finances" cf
      WHERE cf.club_name = v_club;

      v_closing := coalesce(v_closing, 0);
      v_opening := v_closing - v_net;
    ELSIF v_prev_closing IS NOT NULL THEN
      -- Past season refresh: keep original cash snapshot; only refresh lines/totals
      v_closing := v_prev_closing;
      v_opening := coalesce(v_prev_opening, v_prev_closing - v_net);
    ELSE
      -- No prior archive: do not use today's balance. Infer from ledger only.
      v_opening := 0;
      v_closing := v_net;
    END IF;

    SELECT coalesce(
      jsonb_agg(
        jsonb_build_object(
          'id', l.id,
          'season_id', l.season_id,
          'fixture_id', l.fixture_id,
          'club_short_name', l.club_short_name,
          'entry_type', l.entry_type,
          'amount', l.amount,
          'description', l.description,
          'metadata', l.metadata,
          'created_at', l.created_at,
          'matchday', f.matchday,
          'competition_type', f.competition_type,
          'home_club_short_name', f.home_club_short_name,
          'away_club_short_name', f.away_club_short_name
        )
        ORDER BY l.created_at DESC
      ),
      '[]'::jsonb
    )
    INTO v_lines
    FROM public.competition_finance_ledger l
    LEFT JOIN public.competition_fixtures f ON f.id = l.fixture_id
    WHERE l.season_id = p_season_id
      AND l.club_short_name = v_club;

    INSERT INTO public.competition_club_finance_season_archive (
      season_id,
      season_label,
      club_short_name,
      opening_balance,
      closing_balance,
      income_total,
      cost_total,
      net_total,
      ledger_lines
    )
    VALUES (
      v_season.id,
      v_season.label,
      v_club,
      v_opening,
      v_closing,
      v_income,
      v_cost,
      v_net,
      v_lines
    )
    ON CONFLICT (season_id, club_short_name)
    DO UPDATE SET
      season_label = excluded.season_label,
      opening_balance = excluded.opening_balance,
      closing_balance = excluded.closing_balance,
      income_total = excluded.income_total,
      cost_total = excluded.cost_total,
      net_total = excluded.net_total,
      ledger_lines = excluded.ledger_lines,
      archived_at = now();

    v_count := v_count + 1;
  END LOOP;

  RETURN v_count;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_archive_club_finances_for_season(bigint) TO authenticated;

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
  SELECT 'ledger_wages'::text, l.entry_type::text, count(*)::bigint
  FROM public.competition_finance_ledger l
  WHERE l.season_id = v_sid
    AND l.entry_type IN (
      'wage_squad', 'wage_renewal_34plus', 'wage_star_tax', 'staff_manager_salary'
    )
  GROUP BY l.entry_type
  ORDER BY l.entry_type;

  RETURN QUERY
  SELECT 'charge_paid'::text, p.charge_type::text, count(*)::bigint
  FROM public.competition_season_charge_paid p
  WHERE p.season_id = v_sid
    AND p.charge_type IN (
      'wage_squad', 'wage_renewal_34plus', 'wage_star_tax', 'staff_manager_salary'
    )
  GROUP BY p.charge_type
  ORDER BY p.charge_type;

  RETURN QUERY
  SELECT 'archive_rows'::text, 'clubs'::text, count(*)::bigint
  FROM public.competition_club_finance_season_archive a
  WHERE a.season_id = v_sid;

  RETURN QUERY
  SELECT 'archive_json_wages'::text, e.entry_type, count(*)::bigint
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

  RETURN QUERY
  SELECT 'wages_on_current_season'::text, l.entry_type::text, count(*)::bigint
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

  RAISE NOTICE
    'BEFORE: Season % id=% | ledger wages=% | charge_paid=% | current_season_id=%',
    v_label, v_sid, v_ledger_wages, v_paid_wages, v_current;

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

  IF v_current IS NOT NULL AND v_current <> v_sid THEN
    FOR v_row IN
      SELECT l.id
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

  v_archived := public.competition_archive_club_finances_for_season(v_sid);

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
    'AFTER: inserted=% moved=% archive_clubs=% | ledger wages=% | archive json wages=%',
    v_inserted, v_moved, v_archived, v_ledger_wages, v_archive_wages;

  IF v_ledger_wages = 0 AND v_paid_wages = 0 THEN
    RAISE NOTICE
      'NO WAGE SOURCE DATA for Season 1 (ledger + charge_paid empty). Cannot rebuild figures — Close Finances data is gone from the DB.';
  END IF;
END;
$repair$;

-- Result grid — paste this back if still blank
SELECT * FROM public.admin_diagnose_season_wage_archive('1');

NOTIFY pgrst, 'reload schema';
