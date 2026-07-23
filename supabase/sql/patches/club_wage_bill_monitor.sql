-- =============================================================================
-- Wage bill monitoring: manager salary via contracted_club + total on upkeep preview.
-- Used by Squad + Finances summary (competition_club_upkeep_preview).
-- Safe re-run. Requires competition_wages_taxes.sql / manager_season_salary_wage_bills.sql.
-- =============================================================================

ALTER TABLE public."Managers"
  ADD COLUMN IF NOT EXISTS weekly_wage bigint NOT NULL DEFAULT 0;

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
  -- Prefer active contract; fall back to Clubs.manager_id if still linked.
  SELECT coalesce(m.weekly_wage, 0)::numeric
  INTO v_weekly
  FROM public."Managers" m
  WHERE nullif(btrim(m.contracted_club), '') = p_club_short_name
  ORDER BY m.id
  LIMIT 1;

  IF v_weekly IS NULL THEN
    SELECT coalesce(m.weekly_wage, 0)::numeric
    INTO v_weekly
    FROM public."Clubs" c
    LEFT JOIN public."Managers" m ON m.id = c.manager_id
    WHERE c."ShortName" = p_club_short_name;
  END IF;

  RETURN round(coalesce(v_weekly, 0) * 52, 0);
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
  v_mgr numeric;
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
  v_mgr := public.competition_club_manager_salary_total(v_club);
  v_34 := public.competition_club_34plus_count(v_club);
  v_star := public.competition_club_star_tax_count(v_club);
  v_34_amt := round(v_34 * coalesce(v_s.wage_34plus_per_player, 0), 0);
  v_star_amt := round(v_star * coalesce(v_s.star_tax_per_player, 0), 0);
  v_tac := public.competition_club_emergency_tac_amount(v_club);

  RETURN jsonb_build_object(
    'season_id', v_season_id,
    'club_short_name', v_club,
    'wage_bill', v_wage,
    'player_wage_bill', v_wage,
    'manager_salary', v_mgr,
    'total_wage_bill', round(coalesce(v_wage, 0) + coalesce(v_mgr, 0), 0),
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

GRANT EXECUTE ON FUNCTION public.competition_club_manager_salary_total(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.competition_club_upkeep_preview(text) TO authenticated;

NOTIFY pgrst, 'reload schema';
