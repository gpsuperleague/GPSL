-- =============================================================================
-- Discord translation for non-English owners (2026-10-12)
-- =============================================================================
-- * Owners pick a language on Owner Details (or /language in Discord).
-- * Right-click a Discord message → Apps → Translate: private reply in that
--   language (handled by the discord-translate edge function).
-- * Natter league posts (GPSL Admin / SuperLeague / Championship) and any feed
--   item with metadata.translate_dm = true are DM'd, translated, to owners who
--   picked a language. Channels stay English.
-- Uses the discord-sky-feed URL + invoke key already stored in
-- gpsl_discord_feed_settings (URL swapped to discord-translate).
-- Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.gpsl_translate_language_codes()
RETURNS text[]
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT ARRAY[
    'AR','BG','CS','DA','DE','EL','ES','ET','FI','FR','HU','ID','IT','JA','KO',
    'LT','LV','NB','NL','PL','PT-BR','PT-PT','RO','RU','SK','SL','SV','TR','UK','ZH'
  ]::text[];
$$;

GRANT EXECUTE ON FUNCTION public.gpsl_translate_language_codes() TO authenticated, service_role;

ALTER TABLE public.gpsl_owner_registry
  ADD COLUMN IF NOT EXISTS preferred_language text,
  ADD COLUMN IF NOT EXISTS translate_dm_announcements boolean NOT NULL DEFAULT true;

ALTER TABLE public.gpsl_owner_registry
  DROP CONSTRAINT IF EXISTS gpsl_owner_registry_preferred_language_check;
ALTER TABLE public.gpsl_owner_registry
  ADD CONSTRAINT gpsl_owner_registry_preferred_language_check CHECK (
    preferred_language IS NULL
    OR preferred_language = ANY (public.gpsl_translate_language_codes())
  );

COMMENT ON COLUMN public.gpsl_owner_registry.preferred_language IS
  'DeepL target code (e.g. ES, PT-BR). NULL = English / translation off.';

-- Discord users set via /language (covers owners whose Discord id is not linked yet)
CREATE TABLE IF NOT EXISTS public.gpsl_discord_language_pref (
  discord_user_id text PRIMARY KEY,
  language text CHECK (language IS NULL OR language = ANY (public.gpsl_translate_language_codes())),
  updated_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.gpsl_discord_language_pref ENABLE ROW LEVEL SECURITY;
GRANT ALL ON public.gpsl_discord_language_pref TO service_role;

-- Announcement DM queue
CREATE TABLE IF NOT EXISTS public.gpsl_discord_translate_dm_queue (
  id bigserial PRIMARY KEY,
  feed_queue_id bigint UNIQUE,
  headline text NOT NULL,
  body text,
  status text NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending', 'sending', 'sent', 'error')),
  attempts int NOT NULL DEFAULT 0,
  recipients int,
  delivered int,
  failed int,
  last_error text,
  created_at timestamptz NOT NULL DEFAULT now(),
  claimed_at timestamptz,
  processed_at timestamptz
);

CREATE INDEX IF NOT EXISTS gpsl_discord_translate_dm_queue_status_idx
  ON public.gpsl_discord_translate_dm_queue (status, id);

ALTER TABLE public.gpsl_discord_translate_dm_queue ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS gpsl_discord_translate_dm_queue_admin ON public.gpsl_discord_translate_dm_queue;
CREATE POLICY gpsl_discord_translate_dm_queue_admin
  ON public.gpsl_discord_translate_dm_queue
  FOR SELECT TO authenticated
  USING (public.is_gpsl_admin());

GRANT SELECT ON public.gpsl_discord_translate_dm_queue TO authenticated;
GRANT ALL ON public.gpsl_discord_translate_dm_queue TO service_role;
GRANT USAGE, SELECT ON SEQUENCE public.gpsl_discord_translate_dm_queue_id_seq TO service_role;

-- ---------------------------------------------------------------------------
-- Normalise a language input ('es', 'PT-BR', 'en', '') → code or NULL (off)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.gpsl_translate_normalize_language(p_language text)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE
AS $function$
DECLARE
  v text := upper(btrim(coalesce(p_language, '')));
BEGIN
  IF v IN ('', 'EN', 'EN-GB', 'EN-US', 'OFF', 'NONE') THEN
    RETURN NULL;
  END IF;
  IF v = 'PT' THEN v := 'PT-PT'; END IF;
  IF v IN ('ZH-HANS', 'ZH-CN') THEN v := 'ZH'; END IF;
  IF v = 'NO' THEN v := 'NB'; END IF;
  IF NOT (v = ANY (public.gpsl_translate_language_codes())) THEN
    RAISE EXCEPTION 'Unsupported language: %', p_language;
  END IF;
  RETURN v;
END;
$function$;

-- ---------------------------------------------------------------------------
-- Site: owner reads / sets their language
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.my_owner_language_get()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  r record;
BEGIN
  IF v_uid IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_authenticated');
  END IF;

  SELECT g.preferred_language, g.translate_dm_announcements, g.discord_user_id
  INTO r
  FROM public.gpsl_owner_registry g
  WHERE g.owner_id = v_uid;

  RETURN jsonb_build_object(
    'ok', true,
    'language', r.preferred_language,
    'dm_announcements', coalesce(r.translate_dm_announcements, true),
    'discord_linked', r.discord_user_id IS NOT NULL
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.my_owner_language_get() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.my_owner_language_get() TO authenticated;

CREATE OR REPLACE FUNCTION public.my_owner_language_set(
  p_language text,
  p_dm_announcements boolean DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_lang text;
  v_discord text;
BEGIN
  IF v_uid IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_authenticated');
  END IF;

  BEGIN
    v_lang := public.gpsl_translate_normalize_language(p_language);
  EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'bad_language');
  END;

  PERFORM public.owner_registry_ensure_self();

  UPDATE public.gpsl_owner_registry
  SET preferred_language = v_lang,
      translate_dm_announcements = coalesce(p_dm_announcements, translate_dm_announcements)
  WHERE owner_id = v_uid
  RETURNING discord_user_id INTO v_discord;

  IF v_discord IS NOT NULL THEN
    INSERT INTO public.gpsl_discord_language_pref (discord_user_id, language, updated_at)
    VALUES (v_discord, v_lang, now())
    ON CONFLICT (discord_user_id) DO UPDATE
      SET language = EXCLUDED.language, updated_at = now();
  END IF;

  RETURN jsonb_build_object('ok', true, 'language', v_lang);
END;
$function$;

REVOKE ALL ON FUNCTION public.my_owner_language_set(text, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.my_owner_language_set(text, boolean) TO authenticated;

-- ---------------------------------------------------------------------------
-- Edge function (service_role): lookup / set by Discord user id
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.gpsl_discord_language_for_user(p_discord_user_id text)
RETURNS text
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT coalesce(
    (SELECT g.preferred_language
     FROM public.gpsl_owner_registry g
     WHERE g.discord_user_id = p_discord_user_id
     LIMIT 1),
    (SELECT p.language
     FROM public.gpsl_discord_language_pref p
     WHERE p.discord_user_id = p_discord_user_id)
  );
$$;

REVOKE ALL ON FUNCTION public.gpsl_discord_language_for_user(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.gpsl_discord_language_for_user(text) TO service_role;

CREATE OR REPLACE FUNCTION public.gpsl_discord_language_set(
  p_discord_user_id text,
  p_language text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_lang text;
  v_owner_rows int;
BEGIN
  IF p_discord_user_id IS NULL OR p_discord_user_id !~ '^\d{15,22}$' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'bad_user');
  END IF;

  BEGIN
    v_lang := public.gpsl_translate_normalize_language(p_language);
  EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'bad_language');
  END;

  INSERT INTO public.gpsl_discord_language_pref (discord_user_id, language, updated_at)
  VALUES (p_discord_user_id, v_lang, now())
  ON CONFLICT (discord_user_id) DO UPDATE
    SET language = EXCLUDED.language, updated_at = now();

  UPDATE public.gpsl_owner_registry
  SET preferred_language = v_lang
  WHERE discord_user_id = p_discord_user_id;
  GET DIAGNOSTICS v_owner_rows = ROW_COUNT;

  RETURN jsonb_build_object('ok', true, 'language', v_lang, 'owner_linked', v_owner_rows > 0);
END;
$function$;

REVOKE ALL ON FUNCTION public.gpsl_discord_language_set(text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.gpsl_discord_language_set(text, text) TO service_role;

-- Owners who get translated announcement DMs
CREATE OR REPLACE FUNCTION public.gpsl_discord_translate_recipients()
RETURNS TABLE (owner_id uuid, discord_user_id text, owner_tag text, language text)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    g.owner_id,
    g.discord_user_id,
    coalesce(c.owner_tag, nullif(btrim(g.owner_tag), '')),
    g.preferred_language
  FROM public.gpsl_owner_registry g
  LEFT JOIN LATERAL (
    SELECT nullif(btrim(cl.owner), '') AS owner_tag
    FROM public."Clubs" cl
    WHERE cl.owner_id = g.owner_id
    LIMIT 1
  ) c ON true
  WHERE g.preferred_language IS NOT NULL
    AND g.translate_dm_announcements
    AND g.status = 'active';
$$;

REVOKE ALL ON FUNCTION public.gpsl_discord_translate_recipients() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.gpsl_discord_translate_recipients() TO service_role;

-- Claim queued announcements (stale 'sending' rows reclaimed after 10 min)
CREATE OR REPLACE FUNCTION public.gpsl_discord_translate_dm_claim(p_limit int DEFAULT 3)
RETURNS SETOF public.gpsl_discord_translate_dm_queue
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  UPDATE public.gpsl_discord_translate_dm_queue q
  SET status = 'sending',
      claimed_at = now(),
      attempts = q.attempts + 1
  WHERE q.id IN (
    SELECT x.id
    FROM public.gpsl_discord_translate_dm_queue x
    WHERE x.status = 'pending'
       OR (x.status = 'sending' AND x.claimed_at < now() - interval '10 minutes')
    ORDER BY x.id
    LIMIT greatest(1, least(coalesce(p_limit, 3), 10))
    FOR UPDATE SKIP LOCKED
  )
  RETURNING q.*;
$$;

REVOKE ALL ON FUNCTION public.gpsl_discord_translate_dm_claim(int) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.gpsl_discord_translate_dm_claim(int) TO service_role;

-- ---------------------------------------------------------------------------
-- Call the discord-translate edge function (reuses the sky-feed URL + key)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.gpsl_discord_translate_function_url()
RETURNS text
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT CASE
    WHEN s.edge_function_url ILIKE '%/discord-sky-feed%'
      THEN replace(s.edge_function_url, 'discord-sky-feed', 'discord-translate')
  END
  FROM public.gpsl_discord_feed_settings s
  WHERE s.id = 1;
$$;

REVOKE ALL ON FUNCTION public.gpsl_discord_translate_function_url() FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.gpsl_discord_translate_request(p_action text DEFAULT 'flush_dms')
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions, net
AS $function$
DECLARE
  v_url text := public.gpsl_discord_translate_function_url();
  v_key text;
  v_req bigint;
BEGIN
  SELECT s.invoke_key INTO v_key
  FROM public.gpsl_discord_feed_settings s
  WHERE s.id = 1;

  IF v_url IS NULL OR nullif(btrim(coalesce(v_key, '')), '') IS NULL THEN
    RETURN NULL;
  END IF;

  IF p_action = 'flush_dms' AND NOT EXISTS (
    SELECT 1 FROM public.gpsl_discord_translate_dm_queue
    WHERE status = 'pending'
       OR (status = 'sending' AND claimed_at < now() - interval '10 minutes')
  ) THEN
    RETURN NULL;
  END IF;

  SELECT net.http_post(
    url := v_url,
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || v_key
    ),
    body := jsonb_build_object('action', p_action),
    timeout_milliseconds := 55000
  ) INTO v_req;
  RETURN v_req;
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING 'gpsl_discord_translate_request(%) failed: %', p_action, SQLERRM;
  RETURN NULL;
END;
$function$;

REVOKE ALL ON FUNCTION public.gpsl_discord_translate_request(text) FROM PUBLIC, anon, authenticated;

-- Admin: (re)register the Discord commands (Translate, /language, /english)
CREATE OR REPLACE FUNCTION public.admin_discord_translate_register_commands()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_req bigint;
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.is_gpsl_admin() THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'admin_only');
  END IF;
  IF public.gpsl_discord_translate_function_url() IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'discord_feed_url_not_set');
  END IF;
  v_req := public.gpsl_discord_translate_request('register_commands');
  RETURN jsonb_build_object('ok', v_req IS NOT NULL, 'request_id', v_req);
END;
$function$;

REVOKE ALL ON FUNCTION public.admin_discord_translate_register_commands() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_discord_translate_register_commands() TO authenticated;

-- ---------------------------------------------------------------------------
-- Feed queue → DM queue (Natter league posts, or metadata.translate_dm)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.gpsl_discord_feed_translate_dm_trg()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF (NEW.event_type = 'natter' AND nullif(NEW.metadata->>'author_kind', '') IS NOT NULL)
     OR coalesce(NEW.metadata->>'translate_dm', '') = 'true' THEN
    BEGIN
      INSERT INTO public.gpsl_discord_translate_dm_queue (feed_queue_id, headline, body)
      VALUES (NEW.id, NEW.headline, NEW.body)
      ON CONFLICT (feed_queue_id) DO NOTHING;
      PERFORM public.gpsl_discord_translate_request('flush_dms');
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'translate DM enqueue for feed % failed: %', NEW.id, SQLERRM;
    END;
  END IF;
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS gpsl_discord_feed_translate_dm ON public.gpsl_discord_feed_queue;
CREATE TRIGGER gpsl_discord_feed_translate_dm
  AFTER INSERT ON public.gpsl_discord_feed_queue
  FOR EACH ROW
  EXECUTE FUNCTION public.gpsl_discord_feed_translate_dm_trg();

-- Retry sweep every 10 minutes
DO $do$
DECLARE
  v_job record;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    RAISE WARNING 'pg_cron not enabled — translated DMs only send on new posts';
    RETURN;
  END IF;

  FOR v_job IN
    SELECT jobid FROM cron.job WHERE jobname = 'gpsl-discord-translate-dms'
  LOOP
    PERFORM cron.unschedule(v_job.jobid);
  END LOOP;

  PERFORM cron.schedule(
    'gpsl-discord-translate-dms',
    '*/10 * * * *',
    $$SELECT public.gpsl_discord_translate_request('flush_dms');$$
  );
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING 'Could not schedule translate DM cron: %', SQLERRM;
END;
$do$;

NOTIFY pgrst, 'reload schema';

SELECT
  public.gpsl_discord_translate_function_url() AS translate_function_url,
  (SELECT count(*) FROM public.gpsl_owner_registry WHERE preferred_language IS NOT NULL) AS owners_with_language,
  (SELECT count(*) FROM public.gpsl_owner_registry WHERE discord_user_id IS NOT NULL) AS owners_with_discord_id,
  (SELECT count(*) FROM public.gpsl_discord_translate_dm_queue WHERE status = 'pending') AS dms_pending,
  EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'gpsl-discord-translate-dms') AS retry_cron_scheduled;
