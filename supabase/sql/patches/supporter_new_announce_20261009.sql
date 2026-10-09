-- =============================================================================
-- New Ko-fi Supporter → announce in every owner's inbox + Discord #gpsl-news
--
-- Fires when gpsl_owner_registry.is_supporter goes false → true (admin ticks
-- the Supporter box). Unticking never announces anything.
--   • Inbox: every owned club gets "New GPSL Supporter" (links to profile)
--   • Inbox: the supporter gets a personal thank-you listing their perks
--   • Discord: #gpsl-news post
-- One announcement per owner per calendar month (London), so untick/re-tick
-- by mistake doesn't spam.
-- Failures are swallowed — ticking the box can never fail because of this.
--
-- Run after ko_fi_supporters_20260922.sql, owner_inbox_notifications.sql and
-- gpsl_discord_sky_feed.sql. Safe re-run.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. Inbox message types (keeps every existing type)
-- ---------------------------------------------------------------------------
DO $inbox_types$
DECLARE
  v_def text;
  v_list text;
BEGIN
  SELECT pg_get_constraintdef(c.oid)
  INTO v_def
  FROM pg_constraint c
  WHERE c.conrelid = 'public.competition_inbox'::regclass
    AND c.conname = 'competition_inbox_message_type_check';

  SELECT string_agg(quote_literal(t), ', ' ORDER BY t)
  INTO v_list
  FROM (
    SELECT DISTINCT message_type AS t
    FROM public.competition_inbox
    WHERE message_type IS NOT NULL
    UNION
    SELECT (regexp_matches(coalesce(v_def, ''), '''([^'']+)''', 'g'))[1]
    UNION
    SELECT 'supporter_new'
    UNION
    SELECT 'supporter_thanks'
  ) s
  WHERE t IS NOT NULL AND btrim(t) <> '';

  ALTER TABLE public.competition_inbox
    DROP CONSTRAINT IF EXISTS competition_inbox_message_type_check;

  EXECUTE format(
    'ALTER TABLE public.competition_inbox
       ADD CONSTRAINT competition_inbox_message_type_check
       CHECK (message_type IN (%s)) NOT VALID',
    v_list
  );

  ALTER TABLE public.competition_inbox
    VALIDATE CONSTRAINT competition_inbox_message_type_check;
END;
$inbox_types$;

-- ---------------------------------------------------------------------------
-- 2. Announce
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.supporter_announce_new(p_owner_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_ym text := public.supporter_london_ym();
  v_key text;
  v_tag text;
  v_who text;
  v_club text;
  v_club_name text;
  v_count int;
  v_inbox int := 0;
  v_discord bigint;
BEGIN
  IF p_owner_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_owner');
  END IF;

  v_key := format('supporter_new:%s:%s', p_owner_id, v_ym);

  v_tag := nullif(btrim(coalesce(public.owner_registry_resolve_tag(p_owner_id), '')), '');
  v_who := CASE WHEN v_tag IS NULL THEN 'A GPSL owner' ELSE '@' || ltrim(v_tag, '@') END;

  SELECT c."ShortName", c."Club"
  INTO v_club, v_club_name
  FROM public."Clubs" c
  WHERE c.owner_id = p_owner_id
  LIMIT 1;

  SELECT count(*)::int INTO v_count
  FROM public.gpsl_owner_registry r
  WHERE r.is_supporter;

  BEGIN
    v_inbox := coalesce(public.owner_inbox_notify_all_clubs(
      'supporter_new',
      format('💛 New GPSL Supporter — %s', v_who),
      format(
        E'%s%s has become a GPSL Supporter on Ko-fi.\n\nSupporters help pay for the servers that keep GPSL running — that''s %s supporter%s now. Thank you!\n\nWant to join them? Look for "Support on Ko-fi" on your dashboard.',
        v_who,
        CASE WHEN v_club_name IS NOT NULL THEN format(' (%s)', v_club_name) ELSE '' END,
        v_count,
        CASE WHEN v_count = 1 THEN '' ELSE 's' END
      ),
      'owner_profile.html?owner=' || p_owner_id::text,
      v_key,
      NULL
    ), 0);
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'supporter_new inbox broadcast failed: %', SQLERRM;
  END;

  BEGIN
    PERFORM public.owner_inbox_send(
      p_message_type => 'supporter_thanks',
      p_title => '💛 Thank you for supporting GPSL!',
      p_body => E'You''re now a GPSL Supporter — thank you. Your perks are switched on:\n\n• Profile badge (upload it on your owner profile)\n• Club colour scheme for your dashboard and club pages\n• ₿1,000 into your Building Society on the 1st of every month\n• Entry into the monthly Supporters'' lottery\n• One free club swap per season (GPSL June window)\n\nThe whole league has been told — enjoy the 💛.',
      p_recipient_club => v_club,
      p_owner_id => p_owner_id,
      p_action_href => 'owner_profile.html?owner=' || p_owner_id::text,
      p_dedupe_key => format('supporter_thanks:%s:%s', p_owner_id, v_ym)
    );
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'supporter_thanks inbox failed: %', SQLERRM;
  END;

  BEGIN
    v_discord := public.gpsl_discord_feed_enqueue(
      'supporter_new',
      format('💛 NEW SUPPORTER — %s', v_who),
      format(
        E'**%s**%s has become a GPSL Supporter on Ko-fi! That''s **%s** supporter%s helping keep the league running — thank you.\n\nSupport GPSL: https://ko-fi.com/gpsluk',
        v_who,
        CASE WHEN v_club_name IS NOT NULL THEN format(' (%s)', v_club_name) ELSE '' END,
        v_count,
        CASE WHEN v_count = 1 THEN '' ELSE 's' END
      ),
      16766720,
      v_key,
      jsonb_build_object(
        'channel', 'news',
        'kind', 'supporter_new',
        'owner_id', p_owner_id,
        'owner_tag', v_tag,
        'club', v_club
      )
    );
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'supporter_new Discord enqueue failed: %', SQLERRM;
  END;

  RETURN jsonb_build_object(
    'ok', true,
    'owner_tag', v_tag,
    'club', v_club,
    'inboxes_sent', v_inbox,
    'discord_queued', v_discord IS NOT NULL
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.supporter_announce_new(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.supporter_announce_new(uuid) TO service_role;

-- ---------------------------------------------------------------------------
-- 3. Trigger: is_supporter false → true
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.trg_gpsl_owner_registry_supporter_announce()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF coalesce(NEW.is_supporter, false)
     AND (TG_OP = 'INSERT' OR NOT coalesce(OLD.is_supporter, false)) THEN
    BEGIN
      PERFORM public.supporter_announce_new(NEW.owner_id);
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'supporter announce failed: %', SQLERRM;
    END;
  END IF;
  RETURN NULL;
END;
$function$;

DROP TRIGGER IF EXISTS gpsl_owner_registry_supporter_announce ON public.gpsl_owner_registry;
CREATE TRIGGER gpsl_owner_registry_supporter_announce
  AFTER INSERT OR UPDATE OF is_supporter ON public.gpsl_owner_registry
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_gpsl_owner_registry_supporter_announce();

NOTIFY pgrst, 'reload schema';

-- ---------------------------------------------------------------------------
-- Check
-- ---------------------------------------------------------------------------
SELECT
  EXISTS (
    SELECT 1 FROM pg_trigger
    WHERE tgname = 'gpsl_owner_registry_supporter_announce' AND NOT tgisinternal
  ) AS trigger_installed,
  pg_get_constraintdef(c.oid) LIKE '%supporter_new%' AS inbox_type_allowed,
  (SELECT count(*) FROM public.gpsl_owner_registry WHERE is_supporter) AS current_supporters
FROM pg_constraint c
WHERE c.conrelid = 'public.competition_inbox'::regclass
  AND c.conname = 'competition_inbox_message_type_check';
