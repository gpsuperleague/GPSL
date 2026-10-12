-- =============================================================================
-- Admin → Fines: delete a tariff from the catalogue (2026-10-12)
-- =============================================================================
-- admin_delete_fine_tariff(code):
--   * used by automatic fines (code appears in a public function) → blocked;
--     untick it under "Fine types" instead
--   * fines already applied under it → deactivated (history keeps its code)
--   * otherwise → deleted
-- Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.admin_delete_fine_tariff(p_code text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_code text := btrim(coalesce(p_code, ''));
  v_used_by text[];
  v_applied int;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM public.competition_fine_tariff WHERE code = v_code) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_found');
  END IF;

  SELECT array_agg(DISTINCT p.proname ORDER BY p.proname)
  INTO v_used_by
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.prokind = 'f'
    AND p.prosrc LIKE '%''' || v_code || '''%'
    AND p.proname NOT IN ('admin_delete_fine_tariff', 'competition_admin_seed_fine_tariffs');

  IF v_used_by IS NOT NULL THEN
    RETURN jsonb_build_object(
      'ok', false, 'reason', 'used_by_system', 'code', v_code, 'used_by', to_jsonb(v_used_by)
    );
  END IF;

  SELECT count(*) INTO v_applied
  FROM public.competition_fine_applied WHERE tariff_code = v_code;

  IF v_applied > 0 THEN
    UPDATE public.competition_fine_tariff
    SET is_active = false, updated_at = now()
    WHERE code = v_code;
    RETURN jsonb_build_object('ok', true, 'action', 'deactivated', 'code', v_code, 'applied_count', v_applied);
  END IF;

  DELETE FROM public.competition_fine_tariff WHERE code = v_code;
  RETURN jsonb_build_object('ok', true, 'action', 'deleted', 'code', v_code);
END;
$fn$;

REVOKE ALL ON FUNCTION public.admin_delete_fine_tariff(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_delete_fine_tariff(text) TO authenticated;

NOTIFY pgrst, 'reload schema';

-- Report: which tariffs could be deleted outright
SELECT
  t.code,
  t.label,
  t.is_active,
  (SELECT count(*) FROM public.competition_fine_applied a WHERE a.tariff_code = t.code) AS times_applied,
  (SELECT string_agg(DISTINCT p.proname, ', ')
   FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.prokind = 'f'
     AND p.prosrc LIKE '%''' || t.code || '''%'
     AND p.proname NOT IN ('admin_delete_fine_tariff', 'competition_admin_seed_fine_tariffs')) AS used_by_system
FROM public.competition_fine_tariff t
ORDER BY t.category, t.sort_order, t.code;
