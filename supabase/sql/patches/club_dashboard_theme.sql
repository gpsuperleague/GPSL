-- =============================================================================
-- Club dashboard theme — owner-chosen accent colours for dashboard.html
-- Run once in Supabase SQL Editor.
-- UI: club_details.html (owners pick / suggest from kit), dashboard.html (apply)
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.club_dashboard_theme (
  club_short_name text NOT NULL PRIMARY KEY
    REFERENCES public."Clubs" ("ShortName") ON DELETE CASCADE,
  enabled boolean NOT NULL DEFAULT false,
  color_primary text,
  color_secondary text,
  color_border text,
  source_kit text NOT NULL DEFAULT 'manual'
    CHECK (source_kit IN ('home', 'away', 'third', 'manual')),
  updated_at timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.club_dashboard_theme IS
  'Per-club dashboard accent colours (GPSL dark base unchanged).';

ALTER TABLE public.club_dashboard_theme ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS club_dashboard_theme_select ON public.club_dashboard_theme;
CREATE POLICY club_dashboard_theme_select ON public.club_dashboard_theme
  FOR SELECT TO authenticated
  USING (
    club_short_name = public.my_club_shortname()
    OR public.is_gpsl_admin()
  );

GRANT SELECT ON public.club_dashboard_theme TO authenticated;

CREATE OR REPLACE FUNCTION public._normalize_theme_hex(p_color text)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE
AS $function$
DECLARE
  v text := lower(btrim(coalesce(p_color, '')));
BEGIN
  IF v = '' THEN
    RETURN NULL;
  END IF;
  IF v ~ '^#[0-9a-f]{6}$' THEN
    RETURN v;
  END IF;
  RAISE EXCEPTION 'Invalid colour % (use #rrggbb)', p_color;
END;
$function$;

CREATE OR REPLACE FUNCTION public.club_owner_dashboard_theme_save(
  p_enabled boolean,
  p_color_primary text,
  p_color_secondary text,
  p_color_border text,
  p_source_kit text DEFAULT 'manual'
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_short text;
  v_primary text;
  v_secondary text;
  v_border text;
  v_source text := lower(btrim(coalesce(p_source_kit, 'manual')));
BEGIN
  SELECT c."ShortName" INTO v_short
  FROM public."Clubs" c
  WHERE c.owner_id = auth.uid()
  LIMIT 1;

  IF v_short IS NULL THEN
    RAISE EXCEPTION 'No club linked to this account';
  END IF;

  IF v_source NOT IN ('home', 'away', 'third', 'manual') THEN
    RAISE EXCEPTION 'Invalid source_kit';
  END IF;

  IF coalesce(p_enabled, false) THEN
    v_primary := public._normalize_theme_hex(p_color_primary);
    v_secondary := public._normalize_theme_hex(p_color_secondary);
    v_border := public._normalize_theme_hex(p_color_border);
    IF v_primary IS NULL OR v_secondary IS NULL OR v_border IS NULL THEN
      RAISE EXCEPTION 'All three colours are required when theme is enabled';
    END IF;
  ELSE
    v_primary := public._normalize_theme_hex(p_color_primary);
    v_secondary := public._normalize_theme_hex(p_color_secondary);
    v_border := public._normalize_theme_hex(p_color_border);
  END IF;

  INSERT INTO public.club_dashboard_theme (
    club_short_name,
    enabled,
    color_primary,
    color_secondary,
    color_border,
    source_kit,
    updated_at
  )
  VALUES (
    v_short,
    coalesce(p_enabled, false),
    v_primary,
    v_secondary,
    v_border,
    v_source,
    now()
  )
  ON CONFLICT (club_short_name) DO UPDATE
  SET enabled = excluded.enabled,
      color_primary = excluded.color_primary,
      color_secondary = excluded.color_secondary,
      color_border = excluded.color_border,
      source_kit = excluded.source_kit,
      updated_at = now();

  RETURN jsonb_build_object(
    'ok', true,
    'club_short_name', v_short,
    'enabled', coalesce(p_enabled, false),
    'color_primary', v_primary,
    'color_secondary', v_secondary,
    'color_border', v_border,
    'source_kit', v_source
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.club_owner_dashboard_theme_save(boolean, text, text, text, text)
  TO authenticated;

NOTIFY pgrst, 'reload schema';
