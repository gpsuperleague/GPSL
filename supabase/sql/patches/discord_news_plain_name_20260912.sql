-- =============================================================================
-- Discord #gpsl-news: new member / new owner copy cleanup
--
-- • Keep Discord @mention / <@id> as message content ABOVE the embed (attention)
-- • Embed headline + body use plain name (no leading @)
-- • Do not publish Discord username / snowflake / “Discord: …” on News
-- • Staff in-app alert may still show Discord details for admins
--
-- Safe re-run. Redeploy discord-sky-feed so embed body soft-tag also drops @.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.gpsl_staff_alert_notify_member_joined(
  p_owner_id uuid,
  p_email text DEFAULT NULL, -- ignored (compat); never stored or published
  p_owner_tag text DEFAULT NULL,
  p_discord_user_id text DEFAULT NULL,
  p_discord_username text DEFAULT NULL,
  p_discord_joined_at timestamptz DEFAULT NULL
)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_id bigint;
  v_tag text := ltrim(coalesce(nullif(btrim(p_owner_tag), ''), '—'), '@');
  v_discord text := coalesce(
    nullif(btrim(p_discord_username), ''),
    nullif(btrim(p_discord_user_id), ''),
    '—'
  );
  v_joined text;
  v_staff_body text;
  v_news_body text;
  v_headline text;
BEGIN
  IF p_owner_id IS NULL THEN
    RETURN NULL;
  END IF;

  -- Intentionally unused: private email must not be copied into shared alerts.
  PERFORM p_email;

  v_joined := CASE
    WHEN p_discord_joined_at IS NOT NULL THEN
      to_char(p_discord_joined_at AT TIME ZONE 'Europe/London', 'Dy DD Mon YYYY HH24:MI')
    ELSE 'unknown'
  END;

  -- Staff alert (admin UI) — Discord details OK here
  v_headline := format('New GPSL member: %s', v_tag);
  v_staff_body := format(
    E'Owner tag: %s\nDiscord: %s\nDiscord server joined: %s (UK)\n\nThey are on the waiting list.',
    v_tag,
    v_discord,
    v_joined
  );

  v_id := public.gpsl_staff_alert_create(
    'member_joined',
    v_headline,
    v_staff_body,
    'admin_owners_waiting_list.html',
    jsonb_build_object(
      'owner_id', p_owner_id,
      'owner_tag', nullif(v_tag, '—'),
      'discord_user_id', p_discord_user_id,
      'discord_username', p_discord_username,
      'discord_joined_at', p_discord_joined_at
    ),
    'member_joined:' || p_owner_id::text
  );

  -- Discord #gpsl-news — plain name in embed; ping via metadata only
  v_news_body := format(
    E'%s has joined GPSL and is on the waiting list.',
    v_tag
  );

  BEGIN
    IF to_regprocedure(
      'public.gpsl_discord_feed_enqueue(text,text,text,integer,text,jsonb)'
    ) IS NOT NULL THEN
      PERFORM public.gpsl_discord_feed_enqueue(
        'member',
        format('🆕 NEW MEMBER — %s', v_tag),
        v_news_body,
        5763719,
        'member_joined:' || p_owner_id::text,
        jsonb_build_object(
          'owner_id', p_owner_id,
          'owner_tag', nullif(v_tag, '—'),
          'discord_user_id', nullif(btrim(coalesce(p_discord_user_id, '')), ''),
          'kind', 'member_joined',
          'channel', 'news',
          'ping', true
        )
      );
    END IF;
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'member_joined Discord enqueue failed: %', SQLERRM;
  END;

  RETURN v_id;
END;
$function$;

COMMENT ON FUNCTION public.gpsl_staff_alert_notify_member_joined(uuid, text, text, text, text, timestamptz) IS
  'Staff alert + Discord #gpsl-news when a member joins. News embed uses plain name; Discord @ stays above the embed.';

-- NEW OWNER news: plain name in embed body; tag still in metadata for ping above
CREATE OR REPLACE FUNCTION public.gpsl_discord_feed_on_owner_assign()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text;
  v_tag text;
  v_season_id bigint;
  v_discord_id text;
BEGIN
  IF NEW.owner_id IS NULL THEN
    RETURN NEW;
  END IF;
  IF TG_OP = 'UPDATE' AND OLD.owner_id IS NOT DISTINCT FROM NEW.owner_id THEN
    RETURN NEW;
  END IF;

  v_season_id := public.gpsl_discord_feed_current_season_id();
  IF public.gpsl_discord_feed_is_season1(v_season_id)
     AND public.gpsl_discord_feed_is_preseason() THEN
    RETURN NEW;
  END IF;

  v_club := coalesce(NEW."Club", public.gpsl_discord_feed_club_name(NEW."ShortName"));

  BEGIN
    SELECT
      nullif(btrim(r.owner_tag), ''),
      nullif(btrim(r.discord_user_id), '')
    INTO v_tag, v_discord_id
    FROM public.gpsl_owner_registry r
    WHERE r.owner_id = NEW.owner_id
    LIMIT 1;
  EXCEPTION WHEN undefined_table OR undefined_column THEN
    v_tag := nullif(btrim(NEW.owner), '');
    v_discord_id := NULL;
  END;

  v_tag := ltrim(coalesce(v_tag, nullif(btrim(NEW.owner), ''), 'New owner'), '@');

  PERFORM public.gpsl_discord_feed_enqueue(
    'owner',
    format('🏟️ NEW OWNER — %s', v_club),
    format('%s have appointed %s.', v_club, v_tag),
    15844367,
    'owner_appoint:' || NEW."ShortName" || ':' || NEW.owner_id::text,
    jsonb_build_object(
      'club', NEW."ShortName",
      'owner_id', NEW.owner_id,
      'owner_tag', v_tag,
      'discord_user_id', v_discord_id,
      'ping', true
    )
  );

  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_gpsl_discord_feed_owner_assign ON public."Clubs";
CREATE TRIGGER trg_gpsl_discord_feed_owner_assign
  AFTER UPDATE OF owner_id ON public."Clubs"
  FOR EACH ROW
  EXECUTE FUNCTION public.gpsl_discord_feed_on_owner_assign();

NOTIFY pgrst, 'reload schema';
