-- =============================================================================
-- Ko-fi supporter renewal due date (+ 3-day leeway)
-- =============================================================================
-- Admin sets supporter_renewal_due_on = next payment-by date.
-- Status (Europe/London):
--   ok       = today <= due
--   leeway   = today in (due, due+3]
--   overdue  = today > due+3
--   unset    = no date
-- Manual month ticks (gpsl_supporter_payments) unchanged.
-- Annual: bump due +12 months (or set any future date).
-- Safe re-run.
-- =============================================================================

ALTER TABLE public.gpsl_owner_registry
  ADD COLUMN IF NOT EXISTS supporter_renewal_due_on date;

COMMENT ON COLUMN public.gpsl_owner_registry.supporter_renewal_due_on IS
  'Next Ko-fi payment due date (Europe/London calendar day). 3-day leeway after this before overdue.';

CREATE OR REPLACE FUNCTION public.supporter_renewal_leeway_days()
RETURNS int
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT 3;
$$;

CREATE OR REPLACE FUNCTION public.supporter_renewal_status(p_due date)
RETURNS text
LANGUAGE sql
STABLE
AS $$
  SELECT CASE
    WHEN p_due IS NULL THEN 'unset'
    WHEN public.supporter_london_today() <= p_due THEN 'ok'
    WHEN public.supporter_london_today()
           <= (p_due + public.supporter_renewal_leeway_days()) THEN 'leeway'
    ELSE 'overdue'
  END;
$$;

CREATE OR REPLACE FUNCTION public.supporter_renewal_leeway_until(p_due date)
RETURNS date
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE
    WHEN p_due IS NULL THEN NULL
    ELSE p_due + public.supporter_renewal_leeway_days()
  END;
$$;

CREATE OR REPLACE FUNCTION public.admin_supporter_renewal_set(
  p_owner_id uuid,
  p_due_on date
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_due date := p_due_on;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;
  IF p_owner_id IS NULL THEN
    RAISE EXCEPTION 'owner required';
  END IF;

  INSERT INTO public.gpsl_owner_registry (owner_id, supporter_renewal_due_on)
  VALUES (p_owner_id, v_due)
  ON CONFLICT (owner_id) DO UPDATE
  SET supporter_renewal_due_on = v_due;

  RETURN jsonb_build_object(
    'ok', true,
    'owner_id', p_owner_id,
    'supporter_renewal_due_on', v_due,
    'renewal_leeway_until', public.supporter_renewal_leeway_until(v_due),
    'renewal_status', public.supporter_renewal_status(v_due),
    'leeway_days', public.supporter_renewal_leeway_days()
  );
END;
$function$;

-- Bump due by N months from max(current due, today). Use 1 after a monthly
-- payment, 12 after an annual sub.
CREATE OR REPLACE FUNCTION public.admin_supporter_renewal_bump(
  p_owner_id uuid,
  p_months int DEFAULT 1
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_today date := public.supporter_london_today();
  v_cur date;
  v_base date;
  v_new date;
  v_months int := greatest(coalesce(p_months, 1), 1);
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;
  IF p_owner_id IS NULL THEN
    RAISE EXCEPTION 'owner required';
  END IF;

  SELECT r.supporter_renewal_due_on INTO v_cur
  FROM public.gpsl_owner_registry r
  WHERE r.owner_id = p_owner_id;

  v_base := greatest(coalesce(v_cur, v_today), v_today);
  v_new := (v_base + make_interval(months => v_months))::date;

  INSERT INTO public.gpsl_owner_registry (owner_id, supporter_renewal_due_on)
  VALUES (p_owner_id, v_new)
  ON CONFLICT (owner_id) DO UPDATE
  SET supporter_renewal_due_on = v_new;

  RETURN jsonb_build_object(
    'ok', true,
    'owner_id', p_owner_id,
    'supporter_renewal_due_on', v_new,
    'renewal_leeway_until', public.supporter_renewal_leeway_until(v_new),
    'renewal_status', public.supporter_renewal_status(v_new),
    'bumped_months', v_months,
    'previous_due_on', v_cur,
    'leeway_days', public.supporter_renewal_leeway_days()
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_owner_supporter_map()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  RETURN coalesce(
    (
      SELECT jsonb_object_agg(
        r.owner_id::text,
        jsonb_build_object(
          'is_supporter', r.is_supporter,
          'supporter_active', public.owner_is_supporter_active(r.owner_id),
          'supporter_grace_until', r.supporter_grace_until,
          'supporter_since', r.supporter_since,
          'supporter_note', r.supporter_note,
          'supporter_renewal_due_on', r.supporter_renewal_due_on,
          'renewal_leeway_until', public.supporter_renewal_leeway_until(r.supporter_renewal_due_on),
          'renewal_status', public.supporter_renewal_status(r.supporter_renewal_due_on),
          'leeway_days', public.supporter_renewal_leeway_days()
        )
      )
      FROM public.gpsl_owner_registry r
      WHERE r.is_supporter
         OR r.supporter_grace_until IS NOT NULL
         OR r.supporter_since IS NOT NULL
         OR r.supporter_renewal_due_on IS NOT NULL
    ),
    '{}'::jsonb
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.supporter_renewal_leeway_days() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.supporter_renewal_status(date) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.supporter_renewal_leeway_until(date) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.admin_supporter_renewal_set(uuid, date) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_supporter_renewal_bump(uuid, int) FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.supporter_renewal_leeway_days() TO authenticated;
GRANT EXECUTE ON FUNCTION public.supporter_renewal_status(date) TO authenticated;
GRANT EXECUTE ON FUNCTION public.supporter_renewal_leeway_until(date) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_supporter_renewal_set(uuid, date) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_supporter_renewal_bump(uuid, int) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_owner_supporter_map() TO authenticated;

NOTIFY pgrst, 'reload schema';
