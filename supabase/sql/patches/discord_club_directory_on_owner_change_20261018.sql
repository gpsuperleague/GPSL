-- =============================================================================
-- Refresh Discord Club Directory when an owner is assigned or leaves a club.
--
-- Edits the existing GPSL Club Directory post in place (same as daily cron).
-- Runs even in Season 1 preseason (when news posts are suppressed).
-- Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.gpsl_discord_club_directory_sync_on_owner_change()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF to_regprocedure('public.gpsl_discord_club_directory_request_sync(boolean)') IS NULL THEN
    RETURN;
  END IF;
  BEGIN
    PERFORM public.gpsl_discord_club_directory_request_sync(false);
  EXCEPTION
    WHEN OTHERS THEN
      RAISE WARNING 'club directory sync after owner change failed: %', SQLERRM;
  END;
END;
$function$;

REVOKE ALL ON FUNCTION public.gpsl_discord_club_directory_sync_on_owner_change() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.gpsl_discord_club_directory_sync_on_owner_change()
  TO postgres, service_role;

-- ---------------------------------------------------------------------------
-- Owner assign
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.gpsl_discord_feed_on_owner_assign()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text;
  v_tag text;
  v_mention text;
  v_season_id bigint;
BEGIN
  IF NEW.owner_id IS NULL THEN
    RETURN NEW;
  END IF;
  IF TG_OP = 'UPDATE' AND OLD.owner_id IS NOT DISTINCT FROM NEW.owner_id THEN
    RETURN NEW;
  END IF;

  -- Keep #club-directory current even when news is skipped
  PERFORM public.gpsl_discord_club_directory_sync_on_owner_change();

  v_season_id := public.gpsl_discord_feed_current_season_id();
  IF public.gpsl_discord_feed_is_season1(v_season_id)
     AND public.gpsl_discord_feed_is_preseason() THEN
    RETURN NEW;
  END IF;

  v_club := coalesce(NEW."Club", public.gpsl_discord_feed_club_name(NEW."ShortName"));

  BEGIN
    SELECT nullif(btrim(r.owner_tag), '') INTO v_tag
    FROM public.gpsl_owner_registry r
    WHERE r.owner_id = NEW.owner_id
    LIMIT 1;
  EXCEPTION WHEN undefined_table OR undefined_column THEN
    v_tag := null;
  END;

  v_tag := coalesce(
    v_tag,
    nullif(btrim(NEW.owner), ''),
    nullif(btrim(OLD.owner), '')
  );

  IF v_tag IS NULL
     OR lower(v_tag) IN ('new owner', 'owner', 'unknown')
     OR upper(v_tag) = upper(NEW."ShortName") THEN
    v_tag := '(set Discord tag)';
  END IF;

  v_mention := '@' || ltrim(v_tag, '@');

  PERFORM public.gpsl_discord_feed_enqueue(
    'owner',
    format('🏟️ NEW OWNER — %s', v_club),
    format('%s have appointed %s.', v_club, v_mention),
    15844367,
    'owner_appoint:' || NEW."ShortName" || ':' || NEW.owner_id::text,
    jsonb_build_object(
      'club', NEW."ShortName",
      'owner_id', NEW.owner_id,
      'owner_tag', v_tag,
      'mention', v_mention
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

-- ---------------------------------------------------------------------------
-- Owner depart
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.gpsl_discord_feed_on_owner_depart()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text;
  v_tag text;
  v_discord_id text;
  v_season_id bigint;
  v_division text;
BEGIN
  IF OLD.owner_id IS NULL OR OLD.owner_id IS NOT DISTINCT FROM NEW.owner_id THEN
    RETURN NEW;
  END IF;

  -- Keep #club-directory current even when news is skipped
  PERFORM public.gpsl_discord_club_directory_sync_on_owner_change();

  v_season_id := public.gpsl_discord_feed_current_season_id();
  IF public.gpsl_discord_feed_is_season1(v_season_id)
     AND public.gpsl_discord_feed_is_preseason() THEN
    RETURN NEW;
  END IF;

  v_club := coalesce(NEW."Club", public.gpsl_discord_feed_club_name(NEW."ShortName"));

  BEGIN
    SELECT nullif(btrim(r.owner_tag), ''), nullif(btrim(r.discord_user_id), '')
    INTO v_tag, v_discord_id
    FROM public.gpsl_owner_registry r
    WHERE r.owner_id = OLD.owner_id
    LIMIT 1;
  EXCEPTION WHEN undefined_table OR undefined_column THEN
    v_tag := NULL;
    v_discord_id := NULL;
  END;
  v_tag := ltrim(coalesce(v_tag, nullif(btrim(OLD.owner), ''), 'The owner'), '@');

  PERFORM public.gpsl_discord_feed_enqueue(
    'owner',
    format('👋 OWNER DEPARTS — %s', v_club),
    CASE WHEN NEW.owner_id IS NULL
      THEN format('%s has left %s. The club is now looking for a new owner.', v_tag, v_club)
      ELSE format('%s has left %s.', v_tag, v_club)
    END,
    10038562,
    'owner_depart:' || NEW."ShortName" || ':' || OLD.owner_id::text || ':'
      || floor(extract(epoch FROM now()))::bigint::text,
    jsonb_build_object(
      'kind', 'owner_depart',
      'club', NEW."ShortName",
      'owner_id', OLD.owner_id,
      'owner_tag', v_tag,
      'discord_user_id', v_discord_id,
      'channel', 'news'
    )
  );

  IF NEW.owner_id IS NULL AND v_season_id IS NOT NULL THEN
    SELECT ccs.division INTO v_division
    FROM public.competition_club_seasons ccs
    WHERE ccs.season_id = v_season_id
      AND ccs.club_short_name = NEW."ShortName"
      AND lower(ccs.division) IN ('superleague', 'championship_a', 'championship_b')
    LIMIT 1;

    IF v_division IS NOT NULL THEN
      PERFORM public.gpsl_discord_feed_enqueue_job_center(
        'job_center',
        format('🏚️ NOW AVAILABLE — %s', v_club),
        format('%s (%s) no longer has an owner. Interested? Ask an admin in Discord.',
               v_club, public.gpsl_discord_division_label(v_division)),
        10038562,
        'job_center_vacant:' || NEW."ShortName" || ':' || floor(extract(epoch FROM now()))::bigint::text,
        jsonb_build_object('kind', 'club_vacant', 'club', NEW."ShortName", 'division', v_division)
      );
    END IF;
  END IF;

  RETURN NEW;
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING 'owner departure Discord post failed for %: %', NEW."ShortName", SQLERRM;
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_gpsl_discord_feed_owner_depart ON public."Clubs";
CREATE TRIGGER trg_gpsl_discord_feed_owner_depart
  AFTER UPDATE OF owner_id ON public."Clubs"
  FOR EACH ROW
  EXECUTE FUNCTION public.gpsl_discord_feed_on_owner_depart();

-- ---------------------------------------------------------------------------
-- Owner Discord tag change (registry) — roster column uses the tag
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.gpsl_discord_feed_on_owner_tag_change()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF TG_OP = 'UPDATE'
     AND OLD.owner_tag IS NOT DISTINCT FROM NEW.owner_tag THEN
    RETURN NEW;
  END IF;

  -- Only refresh if this owner currently holds a club
  IF EXISTS (
    SELECT 1
    FROM public."Clubs" c
    WHERE c.owner_id = NEW.owner_id
  ) THEN
    PERFORM public.gpsl_discord_club_directory_sync_on_owner_change();
  END IF;

  RETURN NEW;
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING 'club directory sync after owner tag change failed: %', SQLERRM;
  RETURN NEW;
END;
$function$;

DO $trg$
BEGIN
  IF to_regclass('public.gpsl_owner_registry') IS NULL THEN
    RAISE NOTICE 'gpsl_owner_registry missing — tag-change trigger skipped';
    RETURN;
  END IF;

  DROP TRIGGER IF EXISTS trg_gpsl_discord_club_directory_owner_tag
    ON public.gpsl_owner_registry;

  CREATE TRIGGER trg_gpsl_discord_club_directory_owner_tag
    AFTER UPDATE OF owner_tag ON public.gpsl_owner_registry
    FOR EACH ROW
    EXECUTE FUNCTION public.gpsl_discord_feed_on_owner_tag_change();
END
$trg$;

NOTIFY pgrst, 'reload schema';
