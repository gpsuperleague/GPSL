-- =============================================================================
-- Fix player market value triggers — use gpsl_pv_* (player_value_calcs.js)
-- =============================================================================
-- ROOT CAUSE: trg_player_value → apply_calc_value() overwrote market_value on
-- every INSERT/UPDATE using legacy calc_value(). Direct SET in recalc scripts
-- was ignored (RETURNING still showed old MV).
--
-- PREREQUISITE: player_value_recalc_functions.sql (gpsl_pv_* helpers).
--
-- This patch REPLACES apply_calc_value() only. Keeps:
--   trg_player_value              — recalc MV + Calc_Potential on write
--   trg_set_maximum_reserve_price — MRP = 1.5 x MV (unchanged)
--
-- After running: use player_value_recalc_apply.sql (touches Rating to fire trigger).
-- =============================================================================

CREATE OR REPLACE FUNCTION public.apply_calc_value()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public
AS $function$
DECLARE
  v_rating integer;
  v_pes_max integer;
  v_age integer;
BEGIN
  v_rating := public.gpsl_pv_int(NEW."Rating"::text);
  v_pes_max := coalesce(
    public.gpsl_pv_int(NEW."Potential"::text),
    v_rating
  );
  v_age := public.gpsl_pv_int(NEW."Age"::text);

  IF v_rating IS NULL THEN
    RETURN NEW;
  END IF;

  NEW."Calc_Potential" := public.gpsl_pv_calc_potential(v_rating, v_pes_max, v_age);
  NEW."market_value" := public.gpsl_pv_market_value(
    v_rating,
    v_pes_max,
    v_age,
    NEW."Position"::text
  );

  RETURN NEW;
END;
$function$;

COMMENT ON FUNCTION public.apply_calc_value() IS
  'BEFORE INSERT/UPDATE on Players: Calc_Potential + market_value via gpsl_pv_* (Excel J2 + GPSL base extension).';

-- Legacy calc_value had a different return type — must drop before replace.
DROP FUNCTION IF EXISTS public.calc_value(integer, integer, integer, text);

CREATE OR REPLACE FUNCTION public.calc_value(
  p_rating integer,
  p_potential integer,
  p_age integer,
  p_position text
)
RETURNS numeric
LANGUAGE sql
IMMUTABLE
SET search_path = public
AS $$
  SELECT public.gpsl_pv_market_value(
    p_rating,
    coalesce(p_potential, p_rating),
    p_age,
    p_position
  );
$$;

NOTIFY pgrst, 'reload schema';

-- Smoke: touch one row — trigger should set MV ~₿42.4M for 79 CB age 24
UPDATE public."Players" p
SET "Rating" = p."Rating"
WHERE btrim(p."Konami_ID"::text) = '136184'
RETURNING
  p."Konami_ID",
  p."Name",
  p."Rating",
  p."Calc_Potential",
  p.market_value,
  p."Maximum_Reserve_Price";
