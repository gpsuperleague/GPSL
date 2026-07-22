-- =============================================================================
-- Discord #whos-who — division roster (owner tag · club), silent daily edit
--
-- SETUP
-- -----
-- 1) Discord: channel #whos-who (or "whos who")
--    → Integrations → Webhooks → New Webhook → Copy URL
-- 2) Supabase → Edge Functions → Secrets:
--      DISCORD_WHOS_WHO_WEBHOOK_URL = that webhook URL
-- 3) Run THIS patch in SQL Editor
-- 4) Redeploy: supabase functions deploy discord-sky-feed
-- 5) Admin → Discord News → "Publish Who's Who now"
--    (or: SELECT public.admin_discord_publish_whos_who(true);)
--
-- Daily cron (06:00 UTC) edits the SAME message (no new posts, no pings).
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.gpsl_discord_whos_who_state (
  id int PRIMARY KEY DEFAULT 1 CHECK (id = 1),
  webhook_message_id text,
  last_content_hash text,
  last_synced_at timestamptz,
  last_error text,
  last_action text,
  season_id bigint
);

INSERT INTO public.gpsl_discord_whos_who_state (id)
VALUES (1)
ON CONFLICT (id) DO NOTHING;

ALTER TABLE public.gpsl_discord_whos_who_state ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS gpsl_discord_whos_who_state_service ON public.gpsl_discord_whos_who_state;
CREATE POLICY gpsl_discord_whos_who_state_service
  ON public.gpsl_discord_whos_who_state
  FOR ALL TO service_role
  USING (true) WITH CHECK (true);

CREATE OR REPLACE FUNCTION public.competition_whos_who_roster(
  p_season_id bigint DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season_id bigint := p_season_id;
  v_season_label text;
  v_divisions jsonb := '[]'::jsonb;
  v_slug text;
  v_label text;
  v_clubs jsonb;
  v_div record;
BEGIN
  IF v_season_id IS NULL THEN
    SELECT id, coalesce(nullif(btrim(label), ''), 'Season ' || id::text)
    INTO v_season_id, v_season_label
    FROM public.competition_seasons
    WHERE is_current = true
    ORDER BY id DESC
    LIMIT 1;
  ELSE
    SELECT coalesce(nullif(btrim(label), ''), 'Season ' || id::text)
    INTO v_season_label
    FROM public.competition_seasons
    WHERE id = v_season_id;
  END IF;

  IF v_season_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_season');
  END IF;

  FOR v_div IN
    SELECT * FROM (VALUES
      (0, 'superleague', 'SuperLeague'),
      (1, 'championship_a', 'Championship A'),
      (2, 'championship_b', 'Championship B')
    ) AS t(ord, slug, label)
    ORDER BY ord
  LOOP
    v_slug := v_div.slug;
    v_label := v_div.label;

    SELECT coalesce(jsonb_agg(row_obj ORDER BY sort_tag, sort_club), '[]'::jsonb)
    INTO v_clubs
    FROM (
      SELECT
        jsonb_build_object(
          'owner_tag', CASE
            WHEN upper(btrim(coalesce(
              nullif(btrim(public.owner_registry_resolve_tag(c.owner_id)), ''),
              nullif(btrim(c.owner), ''),
              ''
            ))) = upper(btrim(c."ShortName"))
              THEN '—'
            WHEN nullif(btrim(public.owner_registry_resolve_tag(c.owner_id)), '') IS NOT NULL
              THEN nullif(btrim(public.owner_registry_resolve_tag(c.owner_id)), '')
            WHEN nullif(btrim(c.owner), '') IS NOT NULL
             AND upper(btrim(c.owner)) IS DISTINCT FROM upper(btrim(c."ShortName"))
              THEN nullif(btrim(c.owner), '')
            ELSE '—'
          END,
          'club_name', coalesce(nullif(btrim(c."Club"), ''), c."ShortName"),
          'short_name', c."ShortName",
          'vacant', (
            upper(btrim(coalesce(
              nullif(btrim(public.owner_registry_resolve_tag(c.owner_id)), ''),
              nullif(btrim(c.owner), ''),
              c."ShortName"
            ))) = upper(btrim(c."ShortName"))
            OR c.owner_id IS NULL
          )
        ) AS row_obj,
        lower(coalesce(
          nullif(btrim(public.owner_registry_resolve_tag(c.owner_id)), ''),
          nullif(btrim(c.owner), ''),
          '—'
        )) AS sort_tag,
        lower(coalesce(c."Club", c."ShortName", '')) AS sort_club
      FROM public.competition_club_seasons ccs
      JOIN public."Clubs" c ON c."ShortName" = ccs.club_short_name
      WHERE ccs.season_id = v_season_id
        AND ccs.division = v_slug
    ) x;

    v_divisions := v_divisions || jsonb_build_array(
      jsonb_build_object(
        'slug', v_slug,
        'label', v_label,
        'clubs', coalesce(v_clubs, '[]'::jsonb)
      )
    );
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true,
    'season_id', v_season_id,
    'season_label', coalesce(v_season_label, 'Season'),
    'divisions', v_divisions
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_whos_who_roster(bigint)
  TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.gpsl_discord_whos_who_request_sync(
  p_force boolean DEFAULT false
)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions, net
AS $function$
DECLARE
  v_url text;
  v_key text;
  v_req_id bigint;
BEGIN
  SELECT s.edge_function_url, s.invoke_key
  INTO v_url, v_key
  FROM public.gpsl_discord_feed_settings s
  WHERE s.id = 1;

  IF v_url IS NULL OR v_key IS NULL THEN
    UPDATE public.gpsl_discord_whos_who_state
    SET last_error = 'missing edge_function_url or invoke_key in gpsl_discord_feed_settings',
        last_synced_at = now(),
        last_action = 'error'
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
      'action', 'whos_who',
      'force', coalesce(p_force, false),
      'source', 'gpsl_discord_whos_who_request_sync'
    ),
    timeout_milliseconds := 30000
  );

  UPDATE public.gpsl_discord_whos_who_state
  SET last_synced_at = now(),
      last_error = NULL,
      last_action = 'requested'
  WHERE id = 1;

  RETURN v_req_id;
EXCEPTION
  WHEN undefined_function THEN
    UPDATE public.gpsl_discord_whos_who_state
    SET last_error = 'pg_net net.http_post missing — enable pg_net',
        last_synced_at = now(),
        last_action = 'error'
    WHERE id = 1;
    RETURN NULL;
  WHEN OTHERS THEN
    UPDATE public.gpsl_discord_whos_who_state
    SET last_error = left(SQLERRM, 500),
        last_synced_at = now(),
        last_action = 'error'
    WHERE id = 1;
    RETURN NULL;
END;
$function$;

REVOKE ALL ON FUNCTION public.gpsl_discord_whos_who_request_sync(boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.gpsl_discord_whos_who_request_sync(boolean)
  TO postgres, service_role;

CREATE OR REPLACE FUNCTION public.admin_discord_publish_whos_who(
  p_force boolean DEFAULT true
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

  IF coalesce(p_force, true) THEN
    UPDATE public.gpsl_discord_whos_who_state
    SET last_content_hash = NULL
    WHERE id = 1;
  END IF;

  v_req := public.gpsl_discord_whos_who_request_sync(coalesce(p_force, true));

  RETURN jsonb_build_object(
    'ok', true,
    'request_id', v_req,
    'hint', 'Edge function will create or silently edit the #whos-who message within ~30s.'
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.admin_discord_publish_whos_who(boolean)
  TO authenticated;

-- Daily silent sync at 06:00 UTC
DO $cron$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'gpsl-discord-whos-who-daily') THEN
      PERFORM cron.unschedule('gpsl-discord-whos-who-daily');
    END IF;
    PERFORM cron.schedule(
      'gpsl-discord-whos-who-daily',
      '0 6 * * *',
      $job$SELECT public.gpsl_discord_whos_who_request_sync(false);$job$
    );
  END IF;
EXCEPTION
  WHEN OTHERS THEN
    RAISE NOTICE 'whos-who cron schedule skipped: %', SQLERRM;
END;
$cron$;
