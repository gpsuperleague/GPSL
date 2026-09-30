-- =============================================================================
-- Supporter monthly payments (Season owner board → "Paid" column)
--
--   gpsl_supporter_payments: one row per owner per paid month (year + 1–12).
--   Board shows the current UK year by default — on 1 January it rolls over to
--   a fresh, empty year automatically. Past years stay on record (year picker).
--   "Clear year" deletes one owner's ticks for a year (manual reset).
--
--   Record-keeping only: does NOT switch the Supporter flag on/off.
--
-- Safe re-run.
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.gpsl_supporter_payments (
  owner_id uuid NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  pay_year int NOT NULL CHECK (pay_year BETWEEN 2020 AND 2100),
  pay_month int NOT NULL CHECK (pay_month BETWEEN 1 AND 12),
  marked_at timestamptz NOT NULL DEFAULT now(),
  marked_by uuid REFERENCES auth.users (id) ON DELETE SET NULL,
  PRIMARY KEY (owner_id, pay_year, pay_month)
);

CREATE INDEX IF NOT EXISTS gpsl_supporter_payments_year_idx
  ON public.gpsl_supporter_payments (pay_year);

ALTER TABLE public.gpsl_supporter_payments ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.gpsl_supporter_payments FROM anon, authenticated;

-- ---------------------------------------------------------------------------
-- Board read: { "<owner_id>": [1,2,5,...], ... } for one year
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_supporter_payments_map(p_year int DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_year int := coalesce(
    p_year,
    extract(year FROM (now() AT TIME ZONE 'Europe/London'))::int
  );
  v_map jsonb;
  v_years jsonb;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  SELECT coalesce(jsonb_object_agg(owner_id::text, months), '{}'::jsonb)
  INTO v_map
  FROM (
    SELECT p.owner_id, jsonb_agg(p.pay_month ORDER BY p.pay_month) AS months
    FROM public.gpsl_supporter_payments p
    WHERE p.pay_year = v_year
    GROUP BY p.owner_id
  ) x;

  SELECT coalesce(jsonb_agg(y ORDER BY y DESC), '[]'::jsonb)
  INTO v_years
  FROM (SELECT DISTINCT pay_year AS y FROM public.gpsl_supporter_payments) q;

  RETURN jsonb_build_object(
    'year', v_year,
    'current_year', extract(year FROM (now() AT TIME ZONE 'Europe/London'))::int,
    'current_month', extract(month FROM (now() AT TIME ZONE 'Europe/London'))::int,
    'years_with_data', v_years,
    'paid', v_map
  );
END;
$function$;

-- ---------------------------------------------------------------------------
-- Tick / untick one month
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_supporter_payment_set(
  p_owner_id uuid,
  p_year int,
  p_month int,
  p_paid boolean
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_months jsonb;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;
  IF p_owner_id IS NULL OR p_year IS NULL OR p_month IS NULL THEN
    RAISE EXCEPTION 'owner, year and month required';
  END IF;

  IF coalesce(p_paid, false) THEN
    INSERT INTO public.gpsl_supporter_payments (owner_id, pay_year, pay_month, marked_by)
    VALUES (p_owner_id, p_year, p_month, auth.uid())
    ON CONFLICT (owner_id, pay_year, pay_month) DO NOTHING;
  ELSE
    DELETE FROM public.gpsl_supporter_payments
    WHERE owner_id = p_owner_id AND pay_year = p_year AND pay_month = p_month;
  END IF;

  SELECT coalesce(jsonb_agg(pay_month ORDER BY pay_month), '[]'::jsonb)
  INTO v_months
  FROM public.gpsl_supporter_payments
  WHERE owner_id = p_owner_id AND pay_year = p_year;

  RETURN jsonb_build_object('ok', true, 'owner_id', p_owner_id, 'year', p_year, 'months', v_months);
END;
$function$;

-- ---------------------------------------------------------------------------
-- Reset: clear one owner's year, or everyone's year when p_owner_id is NULL
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_supporter_payments_clear_year(
  p_year int,
  p_owner_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_n int;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;
  IF p_year IS NULL THEN
    RAISE EXCEPTION 'year required';
  END IF;

  DELETE FROM public.gpsl_supporter_payments
  WHERE pay_year = p_year
    AND (p_owner_id IS NULL OR owner_id = p_owner_id);
  GET DIAGNOSTICS v_n = ROW_COUNT;

  RETURN jsonb_build_object('ok', true, 'year', p_year, 'owner_id', p_owner_id, 'cleared', v_n);
END;
$function$;

REVOKE ALL ON FUNCTION public.admin_supporter_payments_map(int) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_supporter_payment_set(uuid, int, int, boolean) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_supporter_payments_clear_year(int, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_supporter_payments_map(int) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_supporter_payment_set(uuid, int, int, boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_supporter_payments_clear_year(int, uuid) TO authenticated;

NOTIFY pgrst, 'reload schema';
