-- =============================================================================
-- Include manager season salary in Post season wage bills / Close Finances.
-- Amount = Managers.weekly_wage × 52 (weekly is MV × manager_wage_pct / 100 / 52).
-- Safe to re-run. Requires competition_wages_taxes.sql (staff_manager_salary type).
-- =============================================================================

ALTER TABLE public.competition_season_charge_paid
  DROP CONSTRAINT IF EXISTS competition_season_charge_paid_charge_type_check;

ALTER TABLE public.competition_season_charge_paid
  ADD CONSTRAINT competition_season_charge_paid_charge_type_check
  CHECK (
    charge_type IN (
      'wage_squad',
      'wage_renewal_34plus',
      'wage_star_tax',
      'staff_manager_salary',
      'gov_emergency_tax',
      'gov_income_tax',
      'eos_ffp_charge',
      'eos_debt_interest',
      'eos_balance_interest'
    )
  );

CREATE OR REPLACE FUNCTION public.competition_club_manager_salary_total(
  p_club_short_name text
)
RETURNS numeric
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_weekly numeric;
BEGIN
  SELECT coalesce(m.weekly_wage, 0)::numeric
  INTO v_weekly
  FROM public."Clubs" c
  LEFT JOIN public."Managers" m ON m.id = c.manager_id
  WHERE c."ShortName" = p_club_short_name;

  RETURN round(coalesce(v_weekly, 0) * 52, 0);
END;
$function$;

CREATE OR REPLACE FUNCTION public.competition_post_club_manager_salary(
  p_season_id bigint,
  p_club_short_name text
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_amount numeric;
  v_weekly numeric;
  v_manager_id bigint;
  v_manager_name text;
BEGIN
  SELECT m.id, m.name, coalesce(m.weekly_wage, 0)::numeric
  INTO v_manager_id, v_manager_name, v_weekly
  FROM public."Clubs" c
  LEFT JOIN public."Managers" m ON m.id = c.manager_id
  WHERE c."ShortName" = p_club_short_name;

  IF v_manager_id IS NULL THEN
    RETURN false;
  END IF;

  v_amount := round(coalesce(v_weekly, 0) * 52, 0);
  IF v_amount <= 0 THEN
    RETURN false;
  END IF;

  RETURN public.competition_post_club_charge(
    p_season_id,
    p_club_short_name,
    'staff_manager_salary',
    v_amount,
    format('Season manager salary — %s', coalesce(v_manager_name, 'manager')),
    jsonb_build_object(
      'manager_id', v_manager_id,
      'weekly_wage', v_weekly,
      'weeks', 52,
      'season_salary', v_amount
    )
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.competition_club_upkeep_preview(p_club_short_name text)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := btrim(p_club_short_name);
  v_me text := public.my_club_shortname();
  v_season_id bigint;
  v_s public.global_settings;
  v_wage numeric;
  v_34 int;
  v_star int;
  v_34_amt numeric;
  v_star_amt numeric;
  v_tac numeric;
BEGIN
  IF v_club IS NULL OR v_club = '' THEN
    RAISE EXCEPTION 'Club required';
  END IF;

  IF NOT public.is_gpsl_admin() AND (v_me IS NULL OR v_me <> v_club) THEN
    RAISE EXCEPTION 'Not allowed';
  END IF;

  SELECT id INTO v_season_id
  FROM public.competition_seasons
  WHERE is_current = true
  ORDER BY id DESC
  LIMIT 1;

  v_s := (SELECT g FROM public.global_settings g WHERE g.id = 1);
  v_wage := public.competition_club_wage_bill_total(v_club, v_season_id);
  v_34 := public.competition_club_34plus_count(v_club);
  v_star := public.competition_club_star_tax_count(v_club);
  v_34_amt := round(v_34 * coalesce(v_s.wage_34plus_per_player, 0), 0);
  v_star_amt := round(v_star * coalesce(v_s.star_tax_per_player, 0), 0);
  v_tac := public.competition_club_emergency_tac_amount(v_club);

  RETURN jsonb_build_object(
    'season_id', v_season_id,
    'club_short_name', v_club,
    'wage_bill', v_wage,
    'manager_salary', public.competition_club_manager_salary_total(v_club),
    'players_34plus', v_34,
    'amount_34plus', v_34_amt,
    'players_star_tax', v_star,
    'amount_star_tax', v_star_amt,
    'emergency_tac_amount', v_tac,
    'settings', jsonb_build_object(
      'wage_34plus_min_rating', v_s.wage_34plus_min_rating,
      'wage_34plus_per_player', v_s.wage_34plus_per_player,
      'star_tax_min_rating', v_s.star_tax_min_rating,
      'star_tax_per_player', v_s.star_tax_per_player,
      'emergency_tac_pct', v_s.emergency_tac_pct,
      'emergency_tac_threshold', v_s.emergency_tac_threshold
    )
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.competition_post_club_season_upkeep(
  p_season_id bigint,
  p_club_short_name text
)
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_n int := 0;
BEGIN
  IF public.competition_post_club_wage_bill(p_season_id, p_club_short_name) THEN
    v_n := v_n + 1;
  END IF;
  IF public.competition_post_club_manager_salary(p_season_id, p_club_short_name) THEN
    v_n := v_n + 1;
  END IF;
  IF public.competition_post_club_34plus_tax(p_season_id, p_club_short_name) THEN
    v_n := v_n + 1;
  END IF;
  IF public.competition_post_club_star_tax(p_season_id, p_club_short_name) THEN
    v_n := v_n + 1;
  END IF;
  RETURN v_n;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_club_manager_salary_total(text) TO authenticated;
