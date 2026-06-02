-- =============================================================================
-- Player wage % of market value — admin-set per division tier (SuperLeague / Championship)
-- Run once in Supabase SQL Editor.
-- Used for standard / calculated wage (contracts spec + GPDB display).
-- =============================================================================

ALTER TABLE public.global_settings
  ADD COLUMN IF NOT EXISTS wage_pct_superleague numeric(6, 3) NOT NULL DEFAULT 5.000,
  ADD COLUMN IF NOT EXISTS wage_pct_championship numeric(6, 3) NOT NULL DEFAULT 4.000;

COMMENT ON COLUMN public.global_settings.wage_pct_superleague IS
  'Standard wage as % of player market_value for clubs in SuperLeague (current competition season).';

COMMENT ON COLUMN public.global_settings.wage_pct_championship IS
  'Standard wage as % of market_value for Championship A/B clubs.';

-- Owners read via public view (no secret draft times already stripped in view)
DROP VIEW IF EXISTS public.global_settings_public;

CREATE VIEW public.global_settings_public
WITH (security_invoker = false)
AS
SELECT
  id,
  transfer_window_open,
  draft_auction_enabled,
  draft_auction_start_time,
  updated_at,
  wage_pct_superleague,
  wage_pct_championship
FROM public.global_settings;

GRANT SELECT ON public.global_settings_public TO authenticated;
GRANT SELECT ON public.global_settings_public TO anon;

-- Admin may update global_settings (wage % and existing fields if using direct update)
DROP POLICY IF EXISTS global_settings_update_admin ON public.global_settings;
CREATE POLICY global_settings_update_admin ON public.global_settings
  FOR UPDATE
  TO authenticated
  USING (public.is_gpsl_admin())
  WITH CHECK (public.is_gpsl_admin());

-- ---------------------------------------------------------------------------
-- Wage from market value + club division (current active competition season)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.competition_club_division_tier(
  p_club_short_name text,
  p_season_id bigint DEFAULT NULL
)
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season_id bigint;
  v_division text;
BEGIN
  IF p_club_short_name IS NULL OR p_club_short_name = '' THEN
    RETURN 'championship';
  END IF;

  IF p_season_id IS NULL THEN
    SELECT id INTO v_season_id
    FROM public.competition_seasons
    WHERE is_current = true AND status = 'active'
    LIMIT 1;
  ELSE
    v_season_id := p_season_id;
  END IF;

  IF v_season_id IS NULL THEN
    RETURN 'championship';
  END IF;

  SELECT ccs.division INTO v_division
  FROM public.competition_club_seasons ccs
  WHERE ccs.season_id = v_season_id
    AND ccs.club_short_name = p_club_short_name;

  IF v_division = 'superleague' THEN
    RETURN 'superleague';
  END IF;

  RETURN 'championship';
END;
$function$;

CREATE OR REPLACE FUNCTION public.calculate_standard_player_wage(
  p_market_value numeric,
  p_division_tier text DEFAULT 'championship'
)
RETURNS numeric
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_mv numeric := greatest(coalesce(p_market_value, 0), 0);
  v_sl numeric;
  v_ch numeric;
  v_pct numeric;
BEGIN
  SELECT wage_pct_superleague, wage_pct_championship
  INTO v_sl, v_ch
  FROM public.global_settings
  WHERE id = 1;

  v_sl := coalesce(v_sl, 5);
  v_ch := coalesce(v_ch, 4);

  v_pct := CASE
    WHEN p_division_tier = 'superleague' THEN v_sl
    ELSE v_ch
  END;

  RETURN round(v_mv * v_pct / 100.0, 0);
END;
$function$;

CREATE OR REPLACE FUNCTION public.calculate_player_wage_for_club(
  p_player_id text,
  p_club_short_name text
)
RETURNS numeric
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_mv numeric;
  v_tier text;
BEGIN
  SELECT p."market_value" INTO v_mv
  FROM public."Players" p
  WHERE p."Konami_ID"::text = p_player_id;

  IF NOT FOUND THEN
    RETURN 0;
  END IF;

  v_tier := public.competition_club_division_tier(p_club_short_name);

  RETURN public.calculate_standard_player_wage(v_mv, v_tier);
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_update_wage_settings(
  p_wage_pct_superleague numeric,
  p_wage_pct_championship numeric
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF p_wage_pct_superleague IS NULL OR p_wage_pct_superleague < 0 OR p_wage_pct_superleague > 100 THEN
    RAISE EXCEPTION 'SuperLeague wage %% must be between 0 and 100';
  END IF;

  IF p_wage_pct_championship IS NULL OR p_wage_pct_championship < 0 OR p_wage_pct_championship > 100 THEN
    RAISE EXCEPTION 'Championship wage %% must be between 0 and 100';
  END IF;

  UPDATE public.global_settings
  SET
    wage_pct_superleague = round(p_wage_pct_superleague, 3),
    wage_pct_championship = round(p_wage_pct_championship, 3),
    updated_at = now()
  WHERE id = 1;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.admin_update_wage_settings(numeric, numeric) TO authenticated;
GRANT EXECUTE ON FUNCTION public.calculate_standard_player_wage(numeric, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.calculate_player_wage_for_club(text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.competition_club_division_tier(text, bigint) TO authenticated;
