-- =============================================================================
-- Ko-fi supporter perk gates (re-assert) — 2026-09-22
-- =============================================================================
-- Run this if non-supporters can still set profile badges or dashboard colours.
-- Safe to re-run. Also clears leftover grace windows from earlier admin unsets.
-- =============================================================================

-- Clear stale month-end grace so admin-unset accounts are inactive immediately.
UPDATE public.gpsl_owner_registry
SET supporter_grace_until = NULL
WHERE coalesce(is_supporter, false) = false
  AND supporter_grace_until IS NOT NULL;

-- ---------------------------------------------------------------------------
-- Badge path: supporters only (clear still allowed)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.owner_registry_set_badge_path(p_path text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_path text := nullif(btrim(p_path), '');
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not signed in';
  END IF;

  PERFORM public.owner_registry_ensure_self();

  IF v_path IS NOT NULL AND NOT public.owner_is_supporter_active(v_uid) THEN
    RAISE EXCEPTION 'Profile image is a Supporter perk — become a Ko-fi Supporter to set a badge';
  END IF;

  IF v_path IS NOT NULL AND split_part(v_path, '/', 1) <> v_uid::text THEN
    RAISE EXCEPTION 'Badge path must be under your owner folder';
  END IF;

  UPDATE public.gpsl_owner_registry
  SET badge_path = v_path,
      badge_updated_at = CASE WHEN v_path IS NULL THEN NULL ELSE now() END
  WHERE owner_id = v_uid;

  RETURN jsonb_build_object('ok', true, 'badge_path', v_path);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.owner_registry_set_badge_path(text) TO authenticated;

-- ---------------------------------------------------------------------------
-- Dashboard colours: supporters only
-- ---------------------------------------------------------------------------
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
    'theme_scope', v_scope
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.club_owner_dashboard_theme_save(boolean, text, text, text, text, text, text)
  TO authenticated;

-- Admin unset must cut perks immediately (no leftover grace).
CREATE OR REPLACE FUNCTION public.admin_owner_set_supporter(
  p_owner_id uuid,
  p_is_supporter boolean,
  p_note text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_uid uuid := p_owner_id;
  v_was boolean;
  v_active boolean;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'owner_id required';
  END IF;

  INSERT INTO public.gpsl_owner_registry (owner_id, status, status_changed_at)
  VALUES (v_uid, 'on_break', now())
  ON CONFLICT (owner_id) DO NOTHING;

  SELECT r.is_supporter INTO v_was
  FROM public.gpsl_owner_registry r
  WHERE r.owner_id = v_uid;

  IF coalesce(p_is_supporter, false) THEN
    UPDATE public.gpsl_owner_registry
    SET is_supporter = true,
        supporter_since = coalesce(supporter_since, now()),
        supporter_unset_at = NULL,
        supporter_grace_until = NULL,
        supporter_note = coalesce(nullif(btrim(p_note), ''), supporter_note)
    WHERE owner_id = v_uid;
  ELSE
    UPDATE public.gpsl_owner_registry
    SET is_supporter = false,
        supporter_unset_at = now(),
        supporter_grace_until = NULL,
        supporter_note = coalesce(nullif(btrim(p_note), ''), supporter_note)
    WHERE owner_id = v_uid;
  END IF;

  v_active := public.owner_is_supporter_active(v_uid);

  IF NOT v_active THEN
    PERFORM public.supporter_disable_club_theme(v_uid);
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'owner_id', v_uid,
    'is_supporter', coalesce(p_is_supporter, false),
    'supporter_active', v_active,
    'supporter_grace_until', (
      SELECT supporter_grace_until FROM public.gpsl_owner_registry WHERE owner_id = v_uid
    ),
    'was_supporter', coalesce(v_was, false)
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.admin_owner_set_supporter(uuid, boolean, text) TO authenticated;

NOTIFY pgrst, 'reload schema';
