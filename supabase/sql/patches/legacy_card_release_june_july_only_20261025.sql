-- =============================================================================
-- Legacy card MV release — owners only in GPSL June / July (2026-10-25)
-- =============================================================================
-- Owners may release a squad legacy card for market value only while the
-- active GPSL month is June or July (post–pesdb sync window).
-- Outside that window: cards still show as legacy; release is refused.
-- Admin release (admin_legacy_card_refund) stays available any time.
-- Depends on: legacy_card_release_market_value_20261025.sql
-- Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.legacy_card_release_window_open()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT public.competition_gpsl_month_is_preseason(
    public.competition_active_gpsl_month(public.current_gpsl_season_id(), now())
  );
$$;

COMMENT ON FUNCTION public.legacy_card_release_window_open() IS
  'True when active GPSL month is June or July — owner legacy MV release window.';

GRANT EXECUTE ON FUNCTION public.legacy_card_release_window_open() TO authenticated;

CREATE OR REPLACE FUNCTION public.club_legacy_cards(p_club_short_name text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := public.my_club_shortname();
  v_window boolean := public.legacy_card_release_window_open();
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;
  IF p_club_short_name IS NOT NULL AND public.is_gpsl_admin() THEN
    v_club := p_club_short_name;
  END IF;
  IF v_club IS NULL OR btrim(v_club) = '' THEN
    RETURN jsonb_build_object(
      'club', NULL,
      'cards', '[]'::jsonb,
      'release_window_open', v_window,
      'can_release', false
    );
  END IF;
  RETURN jsonb_build_object(
    'club', v_club,
    'is_owner', v_club = public.my_club_shortname(),
    'cards', public.legacy_cards_rows(v_club),
    'release_window_open', v_window,
    'can_release', v_window
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.club_legacy_cards(text) TO authenticated;

CREATE OR REPLACE FUNCTION public.player_legacy_card_refund(p_player_id text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := public.my_club_shortname();
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;
  IF v_club IS NULL OR btrim(v_club) = '' THEN
    RAISE EXCEPTION 'No club linked to this account';
  END IF;
  IF NOT public.legacy_card_release_window_open() THEN
    RAISE EXCEPTION
      'Legacy cards can only be released for market value in GPSL June and July';
  END IF;
  RETURN public.legacy_card_refund_internal(p_player_id, v_club, false);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.player_legacy_card_refund(text) TO authenticated;

COMMENT ON FUNCTION public.player_legacy_card_refund(text) IS
  'Owner: release a legacy card for market value in GPSL June/July only. No release quota. Unsignable legacy free agent.';
