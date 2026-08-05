-- =============================================================================
-- Next Gen Youth — admin-editable Goal.com NXGN source URL
-- Run if you already applied nextgen_youth_mv_boost.sql before this section
-- was added. Safe re-run.
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.nextgen_youth_settings (
  id smallint PRIMARY KEY DEFAULT 1 CHECK (id = 1),
  source_url text,
  updated_at timestamptz NOT NULL DEFAULT now(),
  updated_by uuid REFERENCES auth.users (id)
);

COMMENT ON TABLE public.nextgen_youth_settings IS
  'Singleton settings for Next Gen Youth (Goal NXGN source URL).';

INSERT INTO public.nextgen_youth_settings (id, source_url)
VALUES (
  1,
  'https://www.goal.com/en/lists/nxgn-2026-best-teenage-wonderkids-football/blt2f8486395140dacd'
)
ON CONFLICT (id) DO NOTHING;

ALTER TABLE public.nextgen_youth_settings ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS nextgen_youth_settings_select ON public.nextgen_youth_settings;
CREATE POLICY nextgen_youth_settings_select ON public.nextgen_youth_settings
  FOR SELECT TO authenticated USING (true);

DROP POLICY IF EXISTS nextgen_youth_settings_admin ON public.nextgen_youth_settings;
CREATE POLICY nextgen_youth_settings_admin ON public.nextgen_youth_settings
  FOR ALL TO authenticated
  USING (public.is_gpsl_admin())
  WITH CHECK (public.is_gpsl_admin());

GRANT SELECT ON public.nextgen_youth_settings TO authenticated;

CREATE OR REPLACE FUNCTION public.nextgen_youth_settings_get()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_row public.nextgen_youth_settings%ROWTYPE;
BEGIN
  SELECT * INTO v_row FROM public.nextgen_youth_settings WHERE id = 1;
  RETURN jsonb_build_object(
    'source_url', v_row.source_url,
    'updated_at', v_row.updated_at
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_nextgen_youth_settings_set(
  p_source_url text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_url text := nullif(btrim(coalesce(p_source_url, '')), '');
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF v_url IS NOT NULL AND v_url !~* '^https?://' THEN
    RAISE EXCEPTION 'Source URL must start with http:// or https://';
  END IF;

  INSERT INTO public.nextgen_youth_settings (id, source_url, updated_at, updated_by)
  VALUES (1, v_url, now(), auth.uid())
  ON CONFLICT (id) DO UPDATE
  SET
    source_url = excluded.source_url,
    updated_at = excluded.updated_at,
    updated_by = excluded.updated_by;

  RETURN public.nextgen_youth_settings_get();
END;
$function$;

GRANT EXECUTE ON FUNCTION public.nextgen_youth_settings_get() TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_nextgen_youth_settings_set(text) TO authenticated;
