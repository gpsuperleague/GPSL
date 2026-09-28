-- =============================================================================
-- Stadium fill: flat season-start % for every club (default 90%)
--
-- Sets each club's display / season-start fill to the same value before the
-- season goes live. From then on the normal model applies unchanged: each
-- GPSL month the display fill drifts (stadium_monthly_drift_pct) toward the
-- club's season target (prestige base ± performance band).
--
-- Run BEFORE Start season (go live). competition_activate_season snapshots the
-- start fill from this value. Do not press "Apply seed to start fill"
-- afterwards — that would replace it with prestige-based values.
--
-- Run once in Supabase SQL Editor, then use the button on Admin → Club
-- attendance (or: SELECT public.admin_stadium_set_flat_start_fill(90);).
-- =============================================================================

CREATE OR REPLACE FUNCTION public.admin_stadium_set_flat_start_fill(p_pct numeric DEFAULT 90)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_min numeric;
  v_max numeric;
  v_pct numeric;
  v_count int;
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  SELECT g.stadium_min_fill_pct, g.stadium_max_display_fill_pct
  INTO v_min, v_max
  FROM public.global_settings g
  WHERE g.id = 1;

  v_pct := round(coalesce(p_pct, 90), 2);
  IF v_pct < coalesce(v_min, 0) OR v_pct > coalesce(v_max, 115) THEN
    RAISE EXCEPTION 'Start fill must be between % and %', coalesce(v_min, 0), coalesce(v_max, 115);
  END IF;

  -- Clear season/month markers so the next sync snapshots this as season start
  UPDATE public."Clubs" c
  SET stadium_display_fill_pct = v_pct,
      stadium_season_start_fill_pct = v_pct,
      stadium_fill_target_pct = NULL,
      stadium_fill_last_month = NULL,
      stadium_fill_season_id = NULL,
      stadium_fill_updated_at = now()
  WHERE c."ShortName" <> 'FOREIGN';

  GET DIAGNOSTICS v_count = ROW_COUNT;

  RETURN jsonb_build_object('ok', true, 'clubs_updated', v_count, 'start_fill_pct', v_pct);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.admin_stadium_set_flat_start_fill(numeric) TO authenticated;

NOTIFY pgrst, 'reload schema';
