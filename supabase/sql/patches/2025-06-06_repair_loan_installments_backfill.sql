-- =============================================================================
-- Repair: backfill 20-month loan schedules for loans taken before schedule patch
-- Run after 2025-06-05_loan_repayment_schedule.sql (or standalone if helpers missing)
-- =============================================================================

CREATE OR REPLACE FUNCTION public.competition_gpsl_month_from_sort(p_sort smallint)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE p_sort
    WHEN 1 THEN 'august'
    WHEN 2 THEN 'september'
    WHEN 3 THEN 'october'
    WHEN 4 THEN 'november'
    WHEN 5 THEN 'december'
    WHEN 6 THEN 'january'
    WHEN 7 THEN 'february'
    WHEN 8 THEN 'march'
    WHEN 9 THEN 'april'
    WHEN 10 THEN 'may'
    ELSE NULL
  END;
$$;

/** p_months_ahead: 1 = first GPSL month after drawdown month. */
CREATE OR REPLACE FUNCTION public.competition_resolve_gpsl_month_offset(
  p_base_season_id bigint,
  p_base_month text,
  p_months_ahead integer
)
RETURNS TABLE (due_season_id bigint, due_gpsl_month text)
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
BEGIN
  v_base_sort := public.competition_gpsl_month_sort(p_base_month);
  IF v_base_sort IS NULL OR p_months_ahead IS NULL OR p_months_ahead < 1 THEN
    RETURN;
  END IF;

  v_target_sort := v_base_sort + p_months_ahead;
  v_season_shift := (v_target_sort - 1) / 10;
  v_month_sort := ((v_target_sort - 1) % 10) + 1;

  due_gpsl_month := public.competition_gpsl_month_from_sort(v_month_sort);

  SELECT s.id
  INTO due_season_id
  FROM public.competition_seasons s
  WHERE s.id >= p_base_season_id
  ORDER BY s.id
  OFFSET v_season_shift
  LIMIT 1;

  IF due_season_id IS NULL THEN
    SELECT max(s.id) INTO due_season_id
    FROM public.competition_seasons s
    WHERE s.id >= p_base_season_id;
  END IF;

  RETURN NEXT;
END;
$function$;

UPDATE public.club_loans l
SET drawdown_gpsl_month = coalesce(
  l.drawdown_gpsl_month,
  public.competition_active_gpsl_month(l.season_id, l.created_at),
  'august'
)
WHERE l.drawdown_gpsl_month IS NULL;

DO $repair$
DECLARE
  r record;
  v_months smallint;
BEGIN
  FOR r IN
    SELECT l.id, l.season_id, l.principal_drawn, l.drawdown_gpsl_month, l.repayment_months
    FROM public.club_loans l
    WHERE l.status = 'active'
      AND NOT EXISTS (
        SELECT 1 FROM public.club_loan_installments i WHERE i.loan_id = l.id
      )
  LOOP
    v_months := coalesce(r.repayment_months, 20)::smallint;

    PERFORM public.club_loan_generate_installments(
      r.id,
      r.principal_drawn,
      r.season_id,
      r.drawdown_gpsl_month,
      v_months
    );
  END LOOP;
END;
$repair$;

-- Process any installments already due (all clubs; skips if balance insufficient)
DO $process$
DECLARE
  r record;
BEGIN
  FOR r IN
    SELECT DISTINCT l.club_short_name AS club
    FROM public.club_loans l
    JOIN public.club_loan_installments i ON i.loan_id = l.id
    WHERE l.status = 'active'
      AND i.status = 'pending'
  LOOP
    PERFORM public.club_loan_process_due_for_club(r.club);
  END LOOP;
END;
$process$;

NOTIFY pgrst, 'reload schema';
