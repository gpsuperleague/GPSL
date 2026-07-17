-- =============================================================================
-- Discord: push new Natter posts (with image) to #gpsl-natter
--
-- 1) Discord: create #gpsl-natter → Integrations → Webhooks → New Webhook → copy URL
-- 2) Supabase → Edge Functions → Secrets:
--      DISCORD_NATTER_WEBHOOK_URL = #gpsl-natter webhook
-- 3) Run this SQL in Supabase SQL Editor
-- 4) Redeploy: supabase functions deploy discord-sky-feed
--
-- Posts go through gpsl_discord_feed_queue → auto-flush / Push queue.
-- Image URL is built in the edge function from image_path + SUPABASE_URL.
-- Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.gpsl_discord_feed_on_natter_post()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text;
  v_month text;
  v_owner text;
  v_headline text;
  v_body text;
BEGIN
  SELECT c."Club" INTO v_club
  FROM public."Clubs" c
  WHERE c."ShortName" = NEW.club_short_name;
  v_club := coalesce(nullif(btrim(v_club), ''), NEW.club_short_name);

  BEGIN
    v_month := public.competition_gpsl_month_label(NEW.gpsl_month);
  EXCEPTION WHEN OTHERS THEN
    v_month := initcap(coalesce(NEW.gpsl_month, ''));
  END;
  IF nullif(btrim(coalesce(v_month, '')), '') IS NULL THEN
    v_month := coalesce(NEW.gpsl_month, 'Month');
  END IF;

  v_owner := nullif(btrim(coalesce(NEW.owner_tag, '')), '');
  IF v_owner IS NOT NULL AND left(v_owner, 1) <> '@' THEN
    v_owner := '@' || v_owner;
  END IF;

  v_headline := format('💬 NATTER — %s', v_club);

  v_body := v_month;
  IF v_owner IS NOT NULL THEN
    v_body := v_body || ' · ' || v_owner;
  END IF;
  v_body := v_body || E'\n\n' || left(btrim(NEW.body), 900);

  PERFORM public.gpsl_discord_feed_enqueue(
    'natter',
    v_headline,
    v_body,
    5763839, -- 0x57f287 Discord green
    'natter:' || NEW.id::text,
    jsonb_build_object(
      'post_id', NEW.id,
      'club_short_name', NEW.club_short_name,
      'gpsl_month', NEW.gpsl_month,
      'image_path', NEW.image_path,
      'channel', 'natter'
    )
  );

  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_gpsl_discord_feed_natter_post ON public.natter_posts;
CREATE TRIGGER trg_gpsl_discord_feed_natter_post
  AFTER INSERT ON public.natter_posts
  FOR EACH ROW
  EXECUTE FUNCTION public.gpsl_discord_feed_on_natter_post();

NOTIFY pgrst, 'reload schema';
