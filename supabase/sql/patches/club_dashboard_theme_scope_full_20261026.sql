-- Club dashboard theme: add theme_scope = 'full' (supporters only via save RPC).
-- Scopes: dashboard | club_pages | full
-- full = club pages + deeper accents (tables/toolbars) and root accent so nav can follow.

DO $$
DECLARE
  r record;
BEGIN
  FOR r IN
    SELECT c.conname
    FROM pg_constraint c
    JOIN pg_class t ON t.oid = c.conrelid
    JOIN pg_namespace n ON n.oid = t.relnamespace
    WHERE n.nspname = 'public'
      AND t.relname = 'club_dashboard_theme'
      AND c.contype = 'c'
      AND pg_get_constraintdef(c.oid) ILIKE '%theme_scope%'
  LOOP
    EXECUTE format(
      'ALTER TABLE public.club_dashboard_theme DROP CONSTRAINT %I',
      r.conname
    );
  END LOOP;
END $$;

ALTER TABLE public.club_dashboard_theme
  ADD CONSTRAINT club_dashboard_theme_theme_scope_check
  CHECK (theme_scope IN ('dashboard', 'club_pages', 'full'));

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
  v_uid uuid := auth.uid();
  v_short text;
  v_primary text;
  v_secondary text;
  v_border text;
  v_text text;
  v_scope text := lower(btrim(coalesce(p_theme_scope, 'dashboard')));
  v_source text := lower(btrim(coalesce(p_source_kit, 'manual')));
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not signed in';
  END IF;

  IF NOT public.owner_is_supporter_active(v_uid) THEN
    RAISE EXCEPTION 'Colour scheme is a Supporter perk — become a Ko-fi Supporter to customise colours';
  END IF;

  SELECT c."ShortName" INTO v_short
  FROM public."Clubs" c
  WHERE c.owner_id = v_uid
  LIMIT 1;

  IF v_short IS NULL THEN
    RAISE EXCEPTION 'No club linked to this account';
  END IF;

  IF v_scope NOT IN ('dashboard', 'club_pages', 'full') THEN
    RAISE EXCEPTION 'Invalid theme_scope (use dashboard, club_pages, or full)';
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
    'theme_scope', v_scope
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.club_owner_dashboard_theme_save(boolean, text, text, text, text, text, text)
  TO authenticated;
