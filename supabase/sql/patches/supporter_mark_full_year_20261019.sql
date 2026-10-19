-- =============================================================================
-- Supporter payments: mark a full year paid (annual subscription)
--
-- Used from Season owner board → Paid modal → "Mark full year paid".
-- Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.admin_supporter_payment_set_year(
  p_owner_id uuid,
  p_year int,
  p_paid boolean DEFAULT true
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_months jsonb;
  v_m int;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;
  IF p_owner_id IS NULL OR p_year IS NULL THEN
    RAISE EXCEPTION 'owner and year required';
  END IF;
  IF p_year < 2020 OR p_year > 2100 THEN
    RAISE EXCEPTION 'year out of range';
  END IF;

  IF coalesce(p_paid, true) THEN
    FOR v_m IN 1..12 LOOP
      INSERT INTO public.gpsl_supporter_payments (owner_id, pay_year, pay_month, marked_by)
      VALUES (p_owner_id, p_year, v_m, auth.uid())
      ON CONFLICT (owner_id, pay_year, pay_month) DO NOTHING;
    END LOOP;
  ELSE
    DELETE FROM public.gpsl_supporter_payments
    WHERE owner_id = p_owner_id AND pay_year = p_year;
  END IF;

  SELECT coalesce(jsonb_agg(pay_month ORDER BY pay_month), '[]'::jsonb)
  INTO v_months
  FROM public.gpsl_supporter_payments
  WHERE owner_id = p_owner_id AND pay_year = p_year;

  RETURN jsonb_build_object(
    'ok', true,
    'owner_id', p_owner_id,
    'year', p_year,
    'months', v_months,
    'full_year', jsonb_array_length(v_months) = 12
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.admin_supporter_payment_set_year(uuid, int, boolean)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_supporter_payment_set_year(uuid, int, boolean)
  TO authenticated;

NOTIFY pgrst, 'reload schema';
