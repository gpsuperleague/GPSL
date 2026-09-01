-- Allow mods to toggle Test/Live season ticks (page is mod-scoped).
-- Also clears confirmed_*_season_at when unticked (on-board list).
-- Safe re-run.

CREATE OR REPLACE FUNCTION public.admin_waiting_list_set_season_confirmed(
  p_owner_id uuid,
  p_which text,
  p_confirmed boolean
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_which text := lower(btrim(coalesce(p_which, '')));
  v_confirmed boolean := coalesce(p_confirmed, false);
BEGIN
  IF NOT (
    public.is_gpsl_admin()
    OR EXISTS (SELECT 1 FROM public.gpsl_site_mods m WHERE m.user_id = auth.uid())
  ) THEN
    RAISE EXCEPTION 'Admin or mod only';
  END IF;

  IF p_owner_id IS NULL THEN
    RAISE EXCEPTION 'owner_id required';
  END IF;

  IF v_which NOT IN ('test', 'live') THEN
    RAISE EXCEPTION 'p_which must be test or live';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.gpsl_owner_registry r WHERE r.owner_id = p_owner_id
  ) THEN
    RAISE EXCEPTION 'Owner not found in registry';
  END IF;

  IF v_which = 'test' THEN
    IF v_confirmed THEN
      UPDATE public.gpsl_owner_registry
      SET
        confirmed_test_season = true,
        confirmed_test_season_at = coalesce(confirmed_test_season_at, now())
      WHERE owner_id = p_owner_id;
    ELSE
      UPDATE public.gpsl_owner_registry
      SET
        confirmed_test_season = false,
        confirmed_test_season_at = null
      WHERE owner_id = p_owner_id;
    END IF;
  ELSE
    IF v_confirmed THEN
      UPDATE public.gpsl_owner_registry
      SET
        confirmed_live_season = true,
        confirmed_live_season_at = coalesce(confirmed_live_season_at, now())
      WHERE owner_id = p_owner_id;
    ELSE
      UPDATE public.gpsl_owner_registry
      SET
        confirmed_live_season = false,
        confirmed_live_season_at = null
      WHERE owner_id = p_owner_id;
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'owner_id', p_owner_id,
    'which', v_which,
    'confirmed', v_confirmed
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.admin_waiting_list_set_season_confirmed(uuid, text, boolean) TO authenticated;

NOTIFY pgrst, 'reload schema';
