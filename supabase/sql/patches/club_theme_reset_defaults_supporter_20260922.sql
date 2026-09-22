-- =============================================================================
-- Reset ALL club colour schemes to GPSL defaults (supporter exclusivity)
-- 2026-09-22
-- =============================================================================
-- Pre-supporter custom colours stay applied until wiped. Run once in Supabase.
-- Safe to re-run. Active supporters can re-enable colours afterwards.
-- =============================================================================

UPDATE public.club_dashboard_theme
SET
  enabled = false,
  color_primary = '#ff9900',
  color_secondary = '#1a1a1a',
  color_border = '#333333',
  color_text = '#ff9900',
  theme_scope = 'dashboard',
  source_kit = 'manual',
  updated_at = now();

-- Defence in depth: load path only returns an active theme for supporter owners.
CREATE OR REPLACE FUNCTION public.club_dashboard_theme_get(p_club_short text)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_short text := upper(btrim(coalesce(p_club_short, '')));
  v_owner uuid;
  v_row public.club_dashboard_theme%ROWTYPE;
  v_active boolean := false;
BEGIN
  IF v_short = '' THEN
    RETURN jsonb_build_object(
      'ok', true,
      'enabled', false,
      'color_primary', '#ff9900',
      'color_secondary', '#1a1a1a',
      'color_border', '#333333',
      'color_text', '#ff9900',
      'theme_scope', 'dashboard',
      'source_kit', 'manual'
    );
  END IF;

  SELECT c.owner_id INTO v_owner
  FROM public."Clubs" c
  WHERE c."ShortName" = v_short
  LIMIT 1;

  IF v_owner IS NOT NULL
     AND to_regprocedure('public.owner_is_supporter_active(uuid)') IS NOT NULL THEN
    v_active := public.owner_is_supporter_active(v_owner);
  END IF;

  SELECT t.* INTO v_row
  FROM public.club_dashboard_theme t
  WHERE t.club_short_name = v_short;

  IF NOT FOUND OR NOT coalesce(v_row.enabled, false) OR NOT v_active THEN
    RETURN jsonb_build_object(
      'ok', true,
      'club_short_name', nullif(v_short, ''),
      'enabled', false,
      'color_primary', coalesce(v_row.color_primary, '#ff9900'),
      'color_secondary', coalesce(v_row.color_secondary, '#1a1a1a'),
      'color_border', coalesce(v_row.color_border, '#333333'),
      'color_text', coalesce(v_row.color_text, '#ff9900'),
      'theme_scope', coalesce(v_row.theme_scope, 'dashboard'),
      'source_kit', coalesce(v_row.source_kit, 'manual'),
      'supporter_locked', NOT v_active
    );
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'club_short_name', v_short,
    'enabled', true,
    'color_primary', v_row.color_primary,
    'color_secondary', v_row.color_secondary,
    'color_border', v_row.color_border,
    'color_text', v_row.color_text,
    'theme_scope', v_row.theme_scope,
    'source_kit', v_row.source_kit,
    'supporter_locked', false
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.club_dashboard_theme_get(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.club_dashboard_theme_get(text) TO anon;

NOTIFY pgrst, 'reload schema';
