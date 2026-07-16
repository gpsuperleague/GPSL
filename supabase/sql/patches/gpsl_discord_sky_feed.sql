-- =============================================================================
-- GPSL Discord Sky News feed
--
-- Queues public league events → edge function discord-sky-feed → Discord webhook.
--
-- Setup:
--   1) Run this SQL patch in Supabase SQL Editor
--   2) Edge secrets:
--        DISCORD_WEBHOOK_URL   (channel webhook for #gpsl-news)
--        DISCORD_FEED_INVOKE_KEY (optional; cron / Database Webhook)
--   3) Deploy: supabase functions deploy discord-sky-feed
--   4) Delivery (pick one or both):
--        A) Admin → Discord News → “Push news to Discord” / “Send test”
--        B) Database Webhook on gpsl_discord_feed_queue INSERT →
--           POST https://<ref>.supabase.co/functions/v1/discord-sky-feed
--           Header: Authorization: Bearer <DISCORD_FEED_INVOKE_KEY or service_role>
--
-- Events: confirmed results, transfers, new listings, special/club auctions.
-- Safe re-run.
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.gpsl_discord_feed_queue (
  id bigserial PRIMARY KEY,
  event_type text NOT NULL,
  headline text NOT NULL,
  body text,
  color integer,
  dedupe_key text,
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  status text NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending', 'posted', 'error', 'skipped')),
  attempts integer NOT NULL DEFAULT 0,
  last_error text,
  created_at timestamptz NOT NULL DEFAULT now(),
  posted_at timestamptz
);

CREATE UNIQUE INDEX IF NOT EXISTS gpsl_discord_feed_queue_dedupe_uidx
  ON public.gpsl_discord_feed_queue (dedupe_key)
  WHERE dedupe_key IS NOT NULL;

CREATE INDEX IF NOT EXISTS gpsl_discord_feed_queue_pending_idx
  ON public.gpsl_discord_feed_queue (status, id)
  WHERE status = 'pending';

ALTER TABLE public.gpsl_discord_feed_queue ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS gpsl_discord_feed_queue_admin_select ON public.gpsl_discord_feed_queue;
CREATE POLICY gpsl_discord_feed_queue_admin_select
  ON public.gpsl_discord_feed_queue
  FOR SELECT TO authenticated
  USING (public.is_gpsl_admin());

GRANT SELECT ON public.gpsl_discord_feed_queue TO authenticated;
GRANT ALL ON public.gpsl_discord_feed_queue TO service_role;
GRANT USAGE, SELECT ON SEQUENCE public.gpsl_discord_feed_queue_id_seq TO service_role;

-- ---------------------------------------------------------------------------
-- Enqueue helper
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.gpsl_discord_feed_enqueue(
  p_event_type text,
  p_headline text,
  p_body text DEFAULT NULL,
  p_color integer DEFAULT NULL,
  p_dedupe_key text DEFAULT NULL,
  p_metadata jsonb DEFAULT '{}'::jsonb
)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_id bigint;
  v_headline text := nullif(btrim(coalesce(p_headline, '')), '');
  v_type text := lower(nullif(btrim(coalesce(p_event_type, '')), ''));
BEGIN
  IF v_headline IS NULL OR v_type IS NULL THEN
    RETURN NULL;
  END IF;

  INSERT INTO public.gpsl_discord_feed_queue (
    event_type, headline, body, color, dedupe_key, metadata
  )
  VALUES (
    v_type,
    left(v_headline, 250),
    nullif(btrim(coalesce(p_body, '')), ''),
    p_color,
    nullif(btrim(coalesce(p_dedupe_key, '')), ''),
    coalesce(p_metadata, '{}'::jsonb)
  )
  ON CONFLICT (dedupe_key) WHERE (dedupe_key IS NOT NULL) DO NOTHING
  RETURNING id INTO v_id;

  RETURN v_id;
EXCEPTION
  WHEN unique_violation THEN
    RETURN NULL;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.gpsl_discord_feed_enqueue(text, text, text, integer, text, jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.gpsl_discord_feed_enqueue(text, text, text, integer, text, jsonb) TO service_role;

-- ---------------------------------------------------------------------------
-- Result: fixture becomes played
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.gpsl_discord_feed_on_fixture_played()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_home text;
  v_away text;
  v_label text;
  v_headline text;
  v_body text;
  v_pen text;
BEGIN
  IF NEW.status IS DISTINCT FROM 'played' THEN
    RETURN NEW;
  END IF;
  IF TG_OP = 'UPDATE' AND OLD.status IS NOT DISTINCT FROM 'played' THEN
    RETURN NEW;
  END IF;
  IF NEW.home_goals IS NULL OR NEW.away_goals IS NULL THEN
    RETURN NEW;
  END IF;

  SELECT c."Club" INTO v_home FROM public."Clubs" c WHERE c."ShortName" = NEW.home_club_short_name;
  SELECT c."Club" INTO v_away FROM public."Clubs" c WHERE c."ShortName" = NEW.away_club_short_name;
  v_home := coalesce(v_home, NEW.home_club_short_name);
  v_away := coalesce(v_away, NEW.away_club_short_name);

  IF NEW.competition_type = 'cup' THEN
    BEGIN
      v_label := public.competition_cup_fixture_label(NEW);
    EXCEPTION WHEN OTHERS THEN
      v_label := coalesce(NEW.cup_code, 'Cup') || ' fixture';
    END;
  ELSE
    v_label := format('Matchday %s', NEW.matchday);
  END IF;

  v_headline := format('🚨 FULL TIME — %s %s–%s %s', v_home, NEW.home_goals, NEW.away_goals, v_away);
  v_body := v_label;

  IF NEW.cup_pen_winner_club_short_name IS NOT NULL THEN
    SELECT c."Club" INTO v_pen
    FROM public."Clubs" c
    WHERE c."ShortName" = NEW.cup_pen_winner_club_short_name;
    v_body := v_body || format(E'\nPens: %s', coalesce(v_pen, NEW.cup_pen_winner_club_short_name));
  END IF;

  PERFORM public.gpsl_discord_feed_enqueue(
    'result',
    v_headline,
    v_body,
    14747136, -- 0xe10600
    'fixture:' || NEW.id::text,
    jsonb_build_object(
      'fixture_id', NEW.id,
      'competition_type', NEW.competition_type,
      'cup_code', NEW.cup_code
    )
  );

  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_gpsl_discord_feed_fixture_played ON public.competition_fixtures;
CREATE TRIGGER trg_gpsl_discord_feed_fixture_played
  AFTER INSERT OR UPDATE OF status, home_goals, away_goals
  ON public.competition_fixtures
  FOR EACH ROW
  EXECUTE FUNCTION public.gpsl_discord_feed_on_fixture_played();

-- ---------------------------------------------------------------------------
-- Transfer completed
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.gpsl_discord_feed_on_transfer()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_name text;
  v_seller text;
  v_buyer text;
  v_fee text;
  v_headline text;
  v_body text;
BEGIN
  SELECT p."Name" INTO v_name
  FROM public."Players" p
  WHERE p."Konami_ID"::text = NEW.player_id::text
  LIMIT 1;

  v_name := coalesce(nullif(btrim(v_name), ''), 'Player ' || NEW.player_id::text);
  v_seller := coalesce(nullif(btrim(NEW.seller_club_id), ''), 'Free agent');
  v_buyer := CASE
    WHEN NEW.buyer_club_id = 'FOREIGN' THEN coalesce(nullif(btrim(NEW.foreign_buyer_name), ''), 'Foreign club')
    ELSE coalesce(nullif(btrim(NEW.buyer_club_id), ''), 'Unknown')
  END;

  BEGIN
    v_fee := public.transfer_format_money(coalesce(NEW.fee, 0));
  EXCEPTION WHEN OTHERS THEN
    v_fee := coalesce(NEW.fee, 0)::text;
  END;

  v_headline := format('🔨 DONE DEAL — %s', v_name);
  v_body := format('%s → %s\nFee: %s', v_seller, v_buyer, v_fee);

  PERFORM public.gpsl_discord_feed_enqueue(
    'transfer',
    v_headline,
    v_body,
    42641, -- 0x00a651
    'transfer:' || NEW.id::text,
    jsonb_build_object('transfer_history_id', NEW.id, 'player_id', NEW.player_id)
  );

  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_gpsl_discord_feed_transfer ON public."Transfer_History";
CREATE TRIGGER trg_gpsl_discord_feed_transfer
  AFTER INSERT ON public."Transfer_History"
  FOR EACH ROW
  EXECUTE FUNCTION public.gpsl_discord_feed_on_transfer();

-- ---------------------------------------------------------------------------
-- New transfer listing (Active, non-draft)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.gpsl_discord_feed_on_listing()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_name text;
  v_club text;
  v_price text;
  v_headline text;
  v_body text;
  v_ask numeric;
BEGIN
  IF lower(coalesce(NEW.status::text, '')) IS DISTINCT FROM 'active' THEN
    RETURN NEW;
  END IF;

  IF lower(coalesce(NEW.listing_type::text, '')) = 'draft' THEN
    RETURN NEW;
  END IF;

  SELECT p."Name" INTO v_name
  FROM public."Players" p
  WHERE p."Konami_ID"::text = NEW.player_id::text
  LIMIT 1;

  v_name := coalesce(nullif(btrim(v_name), ''), 'Player ' || NEW.player_id::text);
  v_club := coalesce(nullif(btrim(NEW.seller_club_id), ''), 'Unknown');
  v_ask := coalesce(NEW.reserve_price, NEW.market_value, 0);

  BEGIN
    v_price := public.transfer_format_money(v_ask);
  EXCEPTION WHEN OTHERS THEN
    v_price := v_ask::text;
  END;

  v_headline := format('📋 LISTED — %s', v_name);
  v_body := format('Club: %s\nAsking: %s', v_club, v_price);

  PERFORM public.gpsl_discord_feed_enqueue(
    'listing',
    v_headline,
    v_body,
    16763904, -- 0xffcc00
    'listing:' || NEW.id::text,
    jsonb_build_object('listing_id', NEW.id, 'player_id', NEW.player_id)
  );

  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_gpsl_discord_feed_listing ON public."Player_Transfer_Listings";
CREATE TRIGGER trg_gpsl_discord_feed_listing
  AFTER INSERT ON public."Player_Transfer_Listings"
  FOR EACH ROW
  EXECUTE FUNCTION public.gpsl_discord_feed_on_listing();

-- ---------------------------------------------------------------------------
-- Special auction: first transition into scheduled / active
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.gpsl_discord_feed_on_special_auction_row()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_title text;
  v_detail text;
  v_type_label text;
BEGIN
  IF NEW.status NOT IN ('scheduled', 'active') THEN
    RETURN NEW;
  END IF;

  IF TG_OP = 'UPDATE' AND OLD.status IN ('scheduled', 'active') THEN
    RETURN NEW;
  END IF;

  v_title := coalesce(nullif(btrim(NEW.title), ''), 'Special auction');
  v_type_label := CASE
    WHEN NEW.auction_type = 'snap' THEN 'Snap auction'
    ELSE 'Lowest unique bid'
  END;

  v_detail := concat_ws(
    E'\n',
    v_type_label,
    'Starts: ' || to_char(NEW.start_time AT TIME ZONE 'Europe/London', 'Dy DD Mon YYYY HH24:MI') || ' (UK)',
    CASE
      WHEN NEW.auction_type IS DISTINCT FROM 'snap' THEN
        'Ends: ' || to_char(NEW.end_time AT TIME ZONE 'Europe/London', 'Dy DD Mon YYYY HH24:MI') || ' (UK)'
      ELSE NULL
    END
  );

  PERFORM public.gpsl_discord_feed_enqueue(
    'auction',
    format('🔨 AUCTION — %s', v_title),
    v_detail,
    22456, -- 0x0057b8
    'special_auction:' || NEW.id::text,
    jsonb_build_object('auction_id', NEW.id, 'auction_type', NEW.auction_type)
  );

  RETURN NEW;
EXCEPTION WHEN OTHERS THEN
  RETURN NEW;
END;
$function$;

DO $$
BEGIN
  IF to_regclass('public.special_auctions') IS NULL THEN
    RETURN;
  END IF;

  DROP TRIGGER IF EXISTS trg_gpsl_discord_feed_special_auction ON public.special_auctions;
  CREATE TRIGGER trg_gpsl_discord_feed_special_auction
    AFTER INSERT OR UPDATE OF status
    ON public.special_auctions
    FOR EACH ROW
    EXECUTE FUNCTION public.gpsl_discord_feed_on_special_auction_row();
END $$;

-- Club auction window open
CREATE OR REPLACE FUNCTION public.gpsl_discord_feed_on_club_auction_settings()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF TG_OP = 'UPDATE'
     AND coalesce(NEW.club_auction_enabled, false) = true
     AND coalesce(OLD.club_auction_enabled, false) = false THEN
    PERFORM public.gpsl_discord_feed_enqueue(
      'auction',
      '🔨 CLUB AUCTION OPEN',
      'The club auction is now open for invited members.',
      22456,
      'club_auction_open:' || to_char(now() AT TIME ZONE 'Europe/London', 'YYYY-MM-DD'),
      '{}'::jsonb
    );
  END IF;
  RETURN NEW;
EXCEPTION WHEN undefined_column THEN
  RETURN NEW;
END;
$function$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'global_settings'
      AND column_name = 'club_auction_enabled'
  ) THEN
    RETURN;
  END IF;

  DROP TRIGGER IF EXISTS trg_gpsl_discord_feed_club_auction ON public.global_settings;
  CREATE TRIGGER trg_gpsl_discord_feed_club_auction
    AFTER UPDATE ON public.global_settings
    FOR EACH ROW
    EXECUTE FUNCTION public.gpsl_discord_feed_on_club_auction_settings();
END $$;

NOTIFY pgrst, 'reload schema';
