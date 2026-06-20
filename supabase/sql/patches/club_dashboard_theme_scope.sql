-- =============================================================================
-- Club dashboard theme — where club colours apply (dashboard vs club pages)
-- Run once in Supabase SQL Editor (after club_dashboard_theme_tile_text.sql).
-- theme_scope: dashboard | club_pages  (top nav always stays GPSL orange)
-- =============================================================================

ALTER TABLE public.club_dashboard_theme
  ADD COLUMN IF NOT EXISTS theme_scope text NOT NULL DEFAULT 'dashboard'
    CHECK (theme_scope IN ('dashboard', 'club_pages'));

CREATE OR REPLACE FUNCTION public.club_owner_dashboard_theme_save(
  p_enabled boolean,
  p_color_primary text,
  p_color_secondary text,
  p_color_border text,
  p_color_text text,
  p_theme_scope text DEFAULT 'dashboard',
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
  v_text text;
  v_scope text := lower(btrim(coalesce(p_theme_scope, 'dashboard')));
  v_source text := lower(btrim(coalesce(p_source_kit, 'manual')));
BEGIN
  SELECT c."ShortName" INTO v_short
  FROM public."Clubs" c
  WHERE c.owner_id = auth.uid()
  LIMIT 1;

  IF v_short IS NULL THEN
    RAISE EXCEPTION 'No club linked to this account';
  END IF;

  IF v_scope NOT IN ('dashboard', 'club_pages') THEN
    RAISE EXCEPTION 'Invalid theme_scope (use dashboard or club_pages)';
  END IF;

  IF v_source NOT IN ('home', 'away', 'third', 'manual') THEN
    RAISE EXCEPTION 'Invalid source_kit';
  END IF;

  IF coalesce(p_enabled, false) THEN
    v_primary := public._normalize_theme_hex(p_color_primary);
    v_secondary := public._normalize_theme_hex(p_color_secondary);
    v_border := public._normalize_theme_hex(p_color_border);
    v_text := public._normalize_theme_hex(p_color_text);
    IF v_primary IS NULL OR v_secondary IS NULL OR v_border IS NULL OR v_text IS NULL THEN
      RAISE EXCEPTION 'All four colours are required when theme is enabled';
    END IF;
  ELSE
    v_primary := public._normalize_theme_hex(p_color_primary);
    v_secondary := public._normalize_theme_hex(p_color_secondary);
    v_border := public._normalize_theme_hex(p_color_border);
    v_text := public._normalize_theme_hex(p_color_text);
  END IF;

  INSERT INTO public.club_dashboard_theme (
    club_short_name,
    enabled,
    color_primary,
    color_secondary,
    color_border,
    color_text,
    theme_scope,
    source_kit,
    updated_at
  )
  VALUES (
    v_short,
    coalesce(p_enabled, false),
    v_primary,
    v_secondary,
    v_border,
    v_text,
    v_scope,
    v_source,
    now()
  )
  ON CONFLICT (club_short_name) DO UPDATE
  SET enabled = excluded.enabled,
      color_primary = excluded.color_primary,
      color_secondary = excluded.color_secondary,
      color_border = excluded.color_border,
      color_text = excluded.color_text,
      theme_scope = excluded.theme_scope,
      source_kit = excluded.source_kit,
      updated_at = now();

  RETURN jsonb_build_object(
    'ok', true,
    'club_short_name', v_short,
    'enabled', coalesce(p_enabled, false),
    'color_primary', v_primary,
    'color_secondary', v_secondary,
    'color_border', v_border,
    'color_text', v_text,
    'theme_scope', v_scope,
    'source_kit', v_source
  );
END;
$function$;

DROP FUNCTION IF EXISTS public.club_owner_dashboard_theme_save(boolean, text, text, text, text, text);

GRANT EXECUTE ON FUNCTION public.club_owner_dashboard_theme_save(boolean, text, text, text, text, text, text)
  TO authenticated;

NOTIFY pgrst, 'reload schema';
