-- =============================================================================
-- Discord role sync driven by GPSL status (safe / non-blocking)
--
-- Mapping:
--   • GPSL registry (member / active / on_break / archived / …) → Member
--   • Clubs.owner_id set → Owner (+ Member)
--   • No registry (visitor / Discord-only) → Visitor
--
-- Edge function: discord-sync-roles
-- Secrets (Edge Functions → Secrets):
--   DISCORD_BOT_TOKEN, DISCORD_GUILD_ID  (already used)
--   DISCORD_ROLE_MEMBER_ID
--   DISCORD_ROLE_OWNER_ID
--   DISCORD_ROLE_VISITOR_ID
--   DISCORD_FEED_INVOKE_KEY (reuse existing cron/feed key for pg_net)
--
-- Discord setup:
--   1. Create Visitor / Member / Owner roles
--   2. Bot role must sit ABOVE those three and have Manage Roles
--   3. Paste role snowflake IDs into the three secrets above
--   4. Deploy edge function discord-sync-roles
--
-- Triggers call pg_net asynchronously and swallow errors so assign/archive
-- never fails if Discord is down or secrets are missing.
--
-- Safe re-run.
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.gpsl_discord_roles_settings (
  id smallint PRIMARY KEY DEFAULT 1 CHECK (id = 1),
  edge_function_url text,
  invoke_key text,
  enabled boolean NOT NULL DEFAULT true,
  last_request_at timestamptz,
  last_error text,
  updated_at timestamptz NOT NULL DEFAULT now()
);

INSERT INTO public.gpsl_discord_roles_settings (id)
VALUES (1)
ON CONFLICT (id) DO NOTHING;

REVOKE ALL ON TABLE public.gpsl_discord_roles_settings FROM PUBLIC, anon, authenticated;
GRANT SELECT, UPDATE ON TABLE public.gpsl_discord_roles_settings TO service_role;
GRANT ALL ON TABLE public.gpsl_discord_roles_settings TO postgres;

-- Boot URL + invoke key from existing Discord feed settings when present
DO $boot$
DECLARE
  v_key text;
  v_feed_url text;
  v_roles_url text :=
    'https://omyyogfumrjoaweuawjn.supabase.co/functions/v1/discord-sync-roles';
BEGIN
  BEGIN
    SELECT nullif(btrim(invoke_key), ''), nullif(btrim(edge_function_url), '')
    INTO v_key, v_feed_url
    FROM public.gpsl_discord_feed_settings
    WHERE id = 1;
  EXCEPTION WHEN undefined_table THEN
    v_key := NULL;
    v_feed_url := NULL;
  END;

  IF v_key IS NULL THEN
    BEGIN
      SELECT nullif(btrim(invoke_key), '') INTO v_key
      FROM public.gpsl_discord_friendlies_settings WHERE id = 1;
    EXCEPTION WHEN undefined_table THEN
      v_key := NULL;
    END;
  END IF;

  IF v_feed_url IS NOT NULL AND position('/functions/v1/' IN v_feed_url) > 0 THEN
    v_roles_url := regexp_replace(
      v_feed_url,
      '/functions/v1/[^/?#]+.*$',
      '/functions/v1/discord-sync-roles'
    );
  END IF;

  UPDATE public.gpsl_discord_roles_settings
  SET
    edge_function_url = coalesce(nullif(btrim(edge_function_url), ''), v_roles_url),
    invoke_key = coalesce(nullif(btrim(invoke_key), ''), v_key),
    updated_at = now()
  WHERE id = 1;
END
$boot$;

CREATE OR REPLACE FUNCTION public.gpsl_discord_roles_request_sync(
  p_owner_id uuid DEFAULT NULL,
  p_discord_user_id text DEFAULT NULL
)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions, net
AS $function$
DECLARE
  v_url text;
  v_key text;
  v_enabled boolean;
  v_req_id bigint;
  v_discord text := nullif(btrim(coalesce(p_discord_user_id, '')), '');
BEGIN
  IF p_owner_id IS NULL AND v_discord IS NULL THEN
    RETURN NULL;
  END IF;

  SELECT s.edge_function_url, s.invoke_key, s.enabled
  INTO v_url, v_key, v_enabled
  FROM public.gpsl_discord_roles_settings s
  WHERE s.id = 1;

  IF NOT coalesce(v_enabled, false)
     OR nullif(btrim(v_url), '') IS NULL
     OR nullif(btrim(v_key), '') IS NULL THEN
    UPDATE public.gpsl_discord_roles_settings
    SET last_error = 'disabled or missing edge_function_url / invoke_key',
        last_request_at = now(),
        updated_at = now()
    WHERE id = 1;
    RETURN NULL;
  END IF;

  v_req_id := net.http_post(
    url := v_url,
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'apikey', v_key,
      'Authorization', 'Bearer ' || v_key,
      'x-discord-feed-key', v_key
    ),
    body := jsonb_build_object(
      'action', 'sync_one',
      'owner_id', p_owner_id,
      'discord_user_id', v_discord,
      'source', 'gpsl_discord_roles_request_sync'
    ),
    timeout_milliseconds := 20000
  );

  UPDATE public.gpsl_discord_roles_settings
  SET last_request_at = now(),
      last_error = NULL,
      updated_at = now()
  WHERE id = 1;

  RETURN v_req_id;
EXCEPTION
  WHEN undefined_function THEN
    UPDATE public.gpsl_discord_roles_settings
    SET last_error = 'pg_net missing — enable extension',
        last_request_at = now(),
        updated_at = now()
    WHERE id = 1;
    RETURN NULL;
  WHEN OTHERS THEN
    UPDATE public.gpsl_discord_roles_settings
    SET last_error = left(SQLERRM, 500),
        last_request_at = now(),
        updated_at = now()
    WHERE id = 1;
    RETURN NULL;
END;
$function$;

REVOKE ALL ON FUNCTION public.gpsl_discord_roles_request_sync(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.gpsl_discord_roles_request_sync(uuid, text)
  TO postgres, service_role;

-- Admin: kick a one-shot sync (also used from Discord members page via RPC)
CREATE OR REPLACE FUNCTION public.admin_discord_roles_sync_owner(
  p_owner_id uuid DEFAULT NULL,
  p_discord_user_id text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_req bigint;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  v_req := public.gpsl_discord_roles_request_sync(p_owner_id, p_discord_user_id);
  RETURN jsonb_build_object(
    'ok', true,
    'requested', v_req IS NOT NULL,
    'request_id', v_req
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.admin_discord_roles_sync_owner(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_discord_roles_sync_owner(uuid, text)
  TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.admin_discord_roles_sync_linked(
  p_limit int DEFAULT 40
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions, net
AS $function$
DECLARE
  v_url text;
  v_key text;
  v_enabled boolean;
  v_req_id bigint;
  v_limit int := greatest(1, least(coalesce(p_limit, 40), 200));
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  SELECT s.edge_function_url, s.invoke_key, s.enabled
  INTO v_url, v_key, v_enabled
  FROM public.gpsl_discord_roles_settings s
  WHERE s.id = 1;

  IF NOT coalesce(v_enabled, false)
     OR nullif(btrim(v_url), '') IS NULL
     OR nullif(btrim(v_key), '') IS NULL THEN
    RETURN jsonb_build_object(
      'ok', false,
      'error', 'Role sync disabled or missing edge_function_url / invoke_key'
    );
  END IF;

  v_req_id := net.http_post(
    url := v_url,
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'apikey', v_key,
      'Authorization', 'Bearer ' || v_key,
      'x-discord-feed-key', v_key
    ),
    body := jsonb_build_object(
      'action', 'sync_linked',
      'limit', v_limit,
      'source', 'admin_discord_roles_sync_linked'
    ),
    timeout_milliseconds := 60000
  );

  UPDATE public.gpsl_discord_roles_settings
  SET last_request_at = now(), last_error = NULL, updated_at = now()
  WHERE id = 1;

  RETURN jsonb_build_object('ok', true, 'request_id', v_req_id, 'limit', v_limit);
EXCEPTION
  WHEN undefined_function THEN
    RETURN jsonb_build_object('ok', false, 'error', 'pg_net missing');
  WHEN OTHERS THEN
    RETURN jsonb_build_object('ok', false, 'error', left(SQLERRM, 500));
END;
$function$;

REVOKE ALL ON FUNCTION public.admin_discord_roles_sync_linked(int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_discord_roles_sync_linked(int)
  TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Triggers (never raise — Discord sync must not block GPSL writes)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.gpsl_discord_roles_on_club_owner_change()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  BEGIN
    IF TG_OP = 'UPDATE' AND OLD.owner_id IS NOT NULL
       AND OLD.owner_id IS DISTINCT FROM NEW.owner_id THEN
      PERFORM public.gpsl_discord_roles_request_sync(OLD.owner_id, NULL);
    END IF;
    IF NEW.owner_id IS NOT NULL
       AND (TG_OP = 'INSERT' OR OLD.owner_id IS DISTINCT FROM NEW.owner_id) THEN
      PERFORM public.gpsl_discord_roles_request_sync(NEW.owner_id, NULL);
    END IF;
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'discord role sync (club owner change) failed: %', SQLERRM;
  END;
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_gpsl_discord_roles_club_owner ON public."Clubs";
CREATE TRIGGER trg_gpsl_discord_roles_club_owner
  AFTER INSERT OR UPDATE OF owner_id ON public."Clubs"
  FOR EACH ROW
  EXECUTE FUNCTION public.gpsl_discord_roles_on_club_owner_change();

CREATE OR REPLACE FUNCTION public.gpsl_discord_roles_on_registry_change()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  BEGIN
    IF TG_OP = 'UPDATE'
       AND OLD.discord_user_id IS DISTINCT FROM NEW.discord_user_id
       AND nullif(btrim(coalesce(OLD.discord_user_id, '')), '') IS NOT NULL THEN
      -- Old Discord id no longer linked → visitor
      PERFORM public.gpsl_discord_roles_request_sync(
        NULL, OLD.discord_user_id
      );
    END IF;
    IF nullif(btrim(coalesce(NEW.discord_user_id, '')), '') IS NOT NULL
       OR NEW.owner_id IS NOT NULL THEN
      PERFORM public.gpsl_discord_roles_request_sync(NEW.owner_id, NEW.discord_user_id);
    END IF;
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'discord role sync (registry change) failed: %', SQLERRM;
  END;
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_gpsl_discord_roles_registry ON public.gpsl_owner_registry;
CREATE TRIGGER trg_gpsl_discord_roles_registry
  AFTER INSERT OR UPDATE OF status, discord_user_id, owner_id
  ON public.gpsl_owner_registry
  FOR EACH ROW
  EXECUTE FUNCTION public.gpsl_discord_roles_on_registry_change();

NOTIFY pgrst, 'reload schema';

SELECT
  edge_function_url,
  invoke_key IS NOT NULL AS has_invoke_key,
  enabled
FROM public.gpsl_discord_roles_settings
WHERE id = 1;
