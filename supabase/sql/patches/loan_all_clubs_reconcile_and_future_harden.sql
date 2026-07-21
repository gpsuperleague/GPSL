-- =============================================================================
-- All-clubs reconcile + harden schedule season resolution for the future
--
-- Prerequisites: loan_fix_game_season_number.sql already applied (JUB done).
-- This:
--   1) Resolves due_season_id by game season LABEL number (not DB ordinal)
--   2) Reconciles EVERY club (reopen over-collected instalments)
--   3) Reports remaining underpaid loans (0 paid when 10 expected) — those
--      need a separate S1 restore decision (cash already refunded earlier)
-- =============================================================================

-- Resolve "season + N game years" via label numbers (1→2→3), not row_number
CREATE OR REPLACE FUNCTION public.competition_resolve_gpsl_month_offset(
  p_base_season_id bigint,
  p_base_month text,
  p_months_ahead integer
)
RETURNS TABLE (
  due_season_id bigint,
  due_gpsl_month text,
  due_season_offset integer
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_base_sort smallint;
  v_target_sort integer;
  v_season_shift integer;
  v_month_sort smallint;
  v_base_game integer;
BEGIN
  v_base_sort := public.competition_gpsl_month_sort(p_base_month);
  IF v_base_sort IS NULL OR p_months_ahead IS NULL OR p_months_ahead < 1 THEN
    RETURN;
  END IF;

  v_target_sort := v_base_sort + p_months_ahead;
  v_season_shift := (v_target_sort - 1) / 10;
  v_month_sort := ((v_target_sort - 1) % 10) + 1;
  due_season_offset := v_season_shift;
  due_gpsl_month := public.competition_gpsl_month_from_sort(v_month_sort);

  v_base_game := public.club_loan_game_season_number(p_base_season_id);
  IF v_base_game IS NOT NULL THEN
    SELECT s.id
    INTO due_season_id
    FROM public.competition_seasons s
    WHERE public.club_loan_game_season_number(s.id) = v_base_game + v_season_shift
    ORDER BY s.id
    LIMIT 1;
  END IF;

  IF due_season_id IS NULL THEN
    SELECT s.id
    INTO due_season_id
    FROM public.competition_seasons s
    WHERE s.id >= p_base_season_id
    ORDER BY s.id
    OFFSET v_season_shift
    LIMIT 1;
  END IF;

  IF due_season_id IS NULL THEN
    due_season_id := p_base_season_id;
  END IF;

  RETURN NEXT;
END;
$function$;

CREATE OR REPLACE FUNCTION public.club_loan_due_season_label(
  p_base_season_id bigint,
  p_season_offset integer
)
RETURNS text
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT coalesce(
    (
      SELECT s.label
      FROM public.competition_seasons s
      WHERE public.club_loan_game_season_number(s.id)
          = public.club_loan_game_season_number(p_base_season_id)
            + greatest(p_season_offset, 0)
      ORDER BY s.id
      LIMIT 1
    ),
    (
      SELECT (public.club_loan_game_season_number(p_base_season_id)
              + greatest(p_season_offset, 0))::text
      WHERE public.club_loan_game_season_number(p_base_season_id) IS NOT NULL
    ),
    format('GPSL year +%s', greatest(p_season_offset, 0) + 1)
  );
$$;

-- All clubs
SELECT public.club_loan_reconcile_expected_schedule(NULL) AS all_clubs_reconcile;

-- Status after reconcile (June S2 targets)
WITH cur AS (
  SELECT id AS season_id
  FROM public.competition_seasons
  WHERE is_current = true
  ORDER BY id DESC
  LIMIT 1
)
SELECT
  l.id AS loan_id,
  l.club_short_name,
  l.drawdown_gpsl_month,
  l.outstanding_principal,
  (SELECT count(*) FROM public.club_loan_installments i
    WHERE i.loan_id = l.id AND i.status = 'paid') AS paid_rows,
  public.club_loan_expected_paid_count(
    l.season_id, l.drawdown_gpsl_month, coalesce(l.repayment_months, 20),
    c.season_id, 'june'
  ) AS expected_paid,
  CASE
    WHEN (SELECT count(*) FROM public.club_loan_installments i
            WHERE i.loan_id = l.id AND i.status = 'paid')
         > public.club_loan_expected_paid_count(
             l.season_id, l.drawdown_gpsl_month, coalesce(l.repayment_months, 20),
             c.season_id, 'june'
           )
      THEN 'STILL_OVERPAID'
    WHEN (SELECT count(*) FROM public.club_loan_installments i
            WHERE i.loan_id = l.id AND i.status = 'paid')
         < public.club_loan_expected_paid_count(
             l.season_id, l.drawdown_gpsl_month, coalesce(l.repayment_months, 20),
             c.season_id, 'june'
           )
      THEN 'UNDERPAID_NEEDS_S1_RESTORE'
    ELSE 'OK'
  END AS status
FROM public.club_loans l
CROSS JOIN cur c
WHERE l.status IN ('active', 'paid')
ORDER BY status DESC, l.club_short_name, l.id;

NOTIFY pgrst, 'reload schema';
