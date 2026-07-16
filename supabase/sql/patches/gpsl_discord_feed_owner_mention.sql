-- Owner appointment Discord posts: show @owner_tag and pass tag in metadata
-- for webhook mentions (edge resolves Discord user id when bot secrets exist).
-- Run in Supabase SQL editor.

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
    v_tag := nullif(btrim(NEW.owner), '');
  END;

  v_tag := coalesce(v_tag, nullif(btrim(NEW.owner), ''), 'New owner');
  -- Always show as @tag (strip any existing leading @s first)
  v_mention := '@' || ltrim(v_tag, '@');

  PERFORM public.gpsl_discord_feed_enqueue(
    'owner',
    format('🏟️ NEW OWNER — %s', v_club),
    format('%s have appointed %s.', v_club, v_mention),
    15844367, -- 0xf1c40f
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
