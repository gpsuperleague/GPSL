-- =============================================================================
-- Diagnose: Gnabry still ₿7M after player_value_potential_cliff_fix_20261008.sql
-- Read-only. One result row per Gnabry row.
-- =============================================================================

SELECT
  p."Konami_ID",
  p."Name",
  p."Rating",
  p."Potential",
  p."Age",
  p."Position",
  p."Calc_Potential"                                   AS stored_calc,
  p.market_value                                       AS stored_mv,
  p."Maximum_Reserve_Price"                            AS stored_mrp,
  public.gpsl_pv_calc_potential(
    public.gpsl_pv_int(p."Rating"::text),
    coalesce(public.gpsl_pv_int(p."Potential"::text), public.gpsl_pv_int(p."Rating"::text)),
    public.gpsl_pv_int(p."Age"::text)
  )                                                    AS live_calc,
  public.gpsl_pv_market_value(
    public.gpsl_pv_int(p."Rating"::text),
    coalesce(public.gpsl_pv_int(p."Potential"::text), public.gpsl_pv_int(p."Rating"::text)),
    public.gpsl_pv_int(p."Age"::text),
    p."Position"::text
  )                                                    AS live_mv,
  (SELECT string_agg(pg_get_function_identity_arguments(f.oid), ' | ')
     FROM pg_proc f JOIN pg_namespace n ON n.oid = f.pronamespace
    WHERE n.nspname = 'public' AND f.proname = 'gpsl_pv_calc_potential')
                                                       AS calc_potential_overloads,
  (SELECT string_agg(pg_get_function_identity_arguments(f.oid), ' | ')
     FROM pg_proc f JOIN pg_namespace n ON n.oid = f.pronamespace
    WHERE n.nspname = 'public' AND f.proname = 'gpsl_pv_market_value')
                                                       AS market_value_overloads,
  (SELECT bool_or(pg_get_functiondef(f.oid) ILIKE '%greatest(%p_pes_max%')
     FROM pg_proc f JOIN pg_namespace n ON n.oid = f.pronamespace
    WHERE n.nspname = 'public' AND f.proname = 'gpsl_pv_calc_potential')
                                                       AS fix_installed,
  (SELECT string_agg(t.tgname || ':' || t.tgfoid::regproc::text, ' | ' ORDER BY t.tgname)
     FROM pg_trigger t
    WHERE t.tgrelid = 'public."Players"'::regclass AND NOT t.tgisinternal)
                                                       AS players_triggers,
  (SELECT count(*) FROM public."Players" x WHERE x."Name" ILIKE '%gnabry%')
                                                       AS gnabry_rows
FROM public."Players" p
WHERE p."Name" ILIKE '%gnabry%';
