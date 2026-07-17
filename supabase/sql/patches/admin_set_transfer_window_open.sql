-- =============================================================================
-- Admin RPC: set transfer window open/closed
--
-- Direct UPDATE on global_settings is revoked for authenticated (owners use
-- global_settings_public). The remote update-global-settings edge fn is returning
-- 400, so the UI fell back to a 403 UPDATE.
--
-- This SECURITY DEFINER RPC is the supported path + Discord notify.
-- Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.admin_set_transfer_window_open(p_open boolean)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_before boolean;
  v_after boolean;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  SELECT transfer_window_open INTO v_before
  FROM public.global_settings
  WHERE id = 1
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_global_settings');
  END IF;

  UPDATE public.global_settings
  SET transfer_window_open = coalesce(p_open, false),
      updated_at = now()
  WHERE id = 1
  RETURNING transfer_window_open INTO v_after;

  -- Discord notify is handled by trg_gpsl_discord_feed_transfer_window (AFTER UPDATE)

  RETURN jsonb_build_object(
    'ok', true,
    'transfer_window_open', v_after,
    'changed', v_after IS DISTINCT FROM v_before
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.admin_set_transfer_window_open(boolean) TO authenticated;

-- Make Discord transfer-window trigger never block the settings save
CREATE OR REPLACE FUNCTION public.gpsl_discord_feed_on_transfer_window()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF TG_OP = 'UPDATE'
     AND NEW.transfer_window_open IS DISTINCT FROM OLD.transfer_window_open THEN
    BEGIN
      IF to_regprocedure('public.gpsl_discord_notify_transfer_window(boolean)') IS NOT NULL THEN
        PERFORM public.gpsl_discord_notify_transfer_window(
          NEW.transfer_window_open IS TRUE
        );
      END IF;
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'trg transfer window Discord notify failed: %', SQLERRM;
    END;
  END IF;
  RETURN NEW;
END;
$function$;

-- Ensure trigger exists (no-op if already created)
DROP TRIGGER IF EXISTS trg_gpsl_discord_feed_transfer_window ON public.global_settings;
CREATE TRIGGER trg_gpsl_discord_feed_transfer_window
  AFTER UPDATE OF transfer_window_open ON public.global_settings
  FOR EACH ROW
  EXECUTE FUNCTION public.gpsl_discord_feed_on_transfer_window();

NOTIFY pgrst, 'reload schema';
