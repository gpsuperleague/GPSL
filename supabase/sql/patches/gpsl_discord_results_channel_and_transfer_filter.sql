-- =============================================================================
-- Discord: results → separate channel; richer result text; transfer news filter
--
-- 1) Run this SQL in Supabase SQL Editor
-- 2) Discord: create #gpsl-results (or similar) → Channel settings → Integrations
--    → Webhooks → New Webhook → Copy URL
-- 3) Supabase → Edge Functions → discord-sky-feed → Secrets:
--      DISCORD_WEBHOOK_URL          = #gpsl-news webhook (transfers / other news)
--      DISCORD_RESULTS_WEBHOOK_URL  = #gpsl-results webhook (match results only)
--      Create the results webhook FROM INSIDE #gpsl-results (wrong channel = wrong destination).
-- 4) Redeploy: supabase functions deploy discord-sky-feed
--    Without the results secret, older builds silently posted results to #gpsl-news.
--    Current edge function blocks results until DISCORD_RESULTS_WEBHOOK_URL is set.
--
-- Safe re-run.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Results: include GPSL month + competition (+ score already in headline)
-- ---------------------------------------------------------------------------

-- Body/headline fix lives in gpsl_discord_results_body_fix.sql (null-safe).
-- Kept here for first-time installs of the results channel patch.
CREATE OR REPLACE FUNCTION public.gpsl_discord_feed_on_fixture_played()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_home text;
  v_away text;
  v_month text;
  v_comp text;
  v_detail text;
  v_headline text;
  v_body text;
  v_pen text;
  v_cup_round text;
  v_cup_match text;
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
  v_home := coalesce(nullif(btrim(v_home), ''), NEW.home_club_short_name, 'Home');
  v_away := coalesce(nullif(btrim(v_away), ''), NEW.away_club_short_name, 'Away');

  BEGIN
    v_month := public.competition_gpsl_month_label(NEW.gpsl_month);
  EXCEPTION WHEN OTHERS THEN
    v_month := NULL;
  END;
  v_month := coalesce(
    nullif(btrim(v_month), ''),
    nullif(initcap(btrim(coalesce(NEW.gpsl_month, ''))), ''),
    'Unknown month'
  );

  IF NEW.competition_type = 'cup' OR nullif(btrim(coalesce(NEW.cup_code, '')), '') IS NOT NULL THEN
    BEGIN
      v_comp := public.competition_cup_fixture_label(NEW);
    EXCEPTION WHEN OTHERS THEN
      v_comp := NULL;
    END;
    IF nullif(btrim(coalesce(v_comp, '')), '') IS NULL THEN
      v_cup_round := CASE WHEN NEW.cup_round IS NOT NULL THEN ' R' || NEW.cup_round::text ELSE '' END;
      v_cup_match := CASE WHEN NEW.cup_match IS NOT NULL THEN ' M' || NEW.cup_match::text ELSE '' END;
      v_comp := coalesce(
        nullif(btrim(
          CASE lower(coalesce(NEW.cup_code, ''))
            WHEN 'super8' THEN 'Super8'
            WHEN 'plate' THEN 'Plate'
            WHEN 'shield' THEN 'Shield'
            WHEN 'bowl' THEN 'Bowl'
            WHEN 'league_cup' THEN 'League Cup'
            ELSE initcap(replace(coalesce(NEW.cup_code, 'Cup'), '_', ' '))
          END
          || v_cup_round || v_cup_match
        ), ''),
        'Cup'
      );
    END IF;
  ELSE
    v_comp := CASE lower(coalesce(NEW.division, ''))
      WHEN 'superleague' THEN 'SuperLeague'
      WHEN 'championship_a' THEN 'Championship A'
      WHEN 'championship_b' THEN 'Championship B'
      ELSE coalesce(nullif(btrim(NEW.division), ''), 'League')
    END;
    IF NEW.matchday IS NOT NULL THEN
      v_detail := 'Matchday ' || NEW.matchday::text;
    END IF;
  END IF;

  v_comp := coalesce(nullif(btrim(v_comp), ''), 'Competition');

  v_headline := format(
    '🚨 FULL TIME — %s · %s — %s %s–%s %s',
    v_month,
    v_comp,
    v_home,
    NEW.home_goals,
    NEW.away_goals,
    v_away
  );

  v_body := v_month || ' · ' || v_comp || E'\nScore: '
    || NEW.home_goals::text || '–' || NEW.away_goals::text;
  IF v_detail IS NOT NULL THEN
    v_body := v_body || E'\n' || v_detail;
  END IF;
  IF NEW.cup_pen_winner_club_short_name IS NOT NULL THEN
    SELECT c."Club" INTO v_pen
    FROM public."Clubs" c
    WHERE c."ShortName" = NEW.cup_pen_winner_club_short_name;
    v_body := v_body || E'\nPens: '
      || coalesce(nullif(btrim(v_pen), ''), NEW.cup_pen_winner_club_short_name);
  END IF;

  PERFORM public.gpsl_discord_feed_enqueue(
    'result',
    v_headline,
    v_body,
    14747136,
    'fixture:' || NEW.id::text,
    jsonb_build_object(
      'fixture_id', NEW.id,
      'competition_type', NEW.competition_type,
      'division', NEW.division,
      'cup_code', NEW.cup_code,
      'gpsl_month', NEW.gpsl_month,
      'channel', 'results'
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
-- Transfers → #gpsl-news only when rating/age thresholds met
--   Age >= 21 and Rating >= 76
--   Age <= 20 and Rating >= 70
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.gpsl_discord_feed_transfer_passes_news_filter(
  p_player_id text
)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_age int;
  v_rating numeric;
BEGIN
  SELECT
    CASE
      WHEN nullif(btrim(p."Age"::text), '') ~ '^[0-9]+$'
      THEN nullif(btrim(p."Age"::text), '')::int
      ELSE NULL
    END,
    CASE
      WHEN to_regprocedure('public.player_rating_as_numeric(text)') IS NOT NULL
      THEN public.player_rating_as_numeric(p."Rating"::text)
      WHEN nullif(btrim(p."Rating"::text), '') ~ '^[0-9]+(\.[0-9]+)?$'
      THEN nullif(btrim(p."Rating"::text), '')::numeric
      ELSE 0
    END
  INTO v_age, v_rating
  FROM public."Players" p
  WHERE p."Konami_ID"::text = btrim(coalesce(p_player_id, ''))
  LIMIT 1;

  IF v_age IS NULL OR v_rating IS NULL THEN
    RETURN false;
  END IF;

  IF v_age <= 20 THEN
    RETURN v_rating >= 70;
  END IF;

  RETURN v_rating >= 76;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.gpsl_discord_feed_transfer_passes_news_filter(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.gpsl_discord_feed_transfer_passes_news_filter(text) TO service_role;

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
  v_listing_type text;
  v_method text;
  v_note text := lower(coalesce(btrim(NEW.transfer_sale_note), ''));
  v_age int;
  v_rating numeric;
BEGIN
  SELECT
    p."Name",
    CASE
      WHEN nullif(btrim(p."Age"::text), '') ~ '^[0-9]+$'
      THEN nullif(btrim(p."Age"::text), '')::int
      ELSE NULL
    END,
    CASE
      WHEN to_regprocedure('public.player_rating_as_numeric(text)') IS NOT NULL
      THEN public.player_rating_as_numeric(p."Rating"::text)
      WHEN nullif(btrim(p."Rating"::text), '') ~ '^[0-9]+(\.[0-9]+)?$'
      THEN nullif(btrim(p."Rating"::text), '')::numeric
      ELSE 0
    END
  INTO v_name, v_age, v_rating
  FROM public."Players" p
  WHERE p."Konami_ID"::text = NEW.player_id::text
  LIMIT 1;

  v_name := coalesce(nullif(btrim(v_name), ''), 'Player ' || NEW.player_id::text);
  v_seller := public.gpsl_discord_feed_club_name(NEW.seller_club_id);

  -- Voluntary contract release (no listing) — keep on news channel
  IF v_note = 'voluntary_contract_release' THEN
    PERFORM public.gpsl_discord_feed_enqueue(
      'release',
      format('📋 CONTRACT RELEASE — %s', v_name),
      format('%s left %s.', v_name, v_seller),
      12370112, -- 0xbcbc80
      'transfer:' || NEW.id::text,
      jsonb_build_object(
        'transfer_history_id', NEW.id,
        'transfer_sale_note', NEW.transfer_sale_note,
        'channel', 'news'
      )
    );
    RETURN NEW;
  END IF;

  IF NEW.listing_id IS NULL THEN
    RETURN NEW;
  END IF;

  SELECT l.listing_type INTO v_listing_type
  FROM public."Player_Transfer_Listings" l
  WHERE l.id = NEW.listing_id;

  -- Only direct offer (transfer market). Exclude draft + transfer-list auctions.
  IF lower(coalesce(v_listing_type, '')) IS DISTINCT FROM 'direct' THEN
    RETURN NEW;
  END IF;

  -- News channel filter: U20 @70+ / 21+ @76+
  IF NOT public.gpsl_discord_feed_transfer_passes_news_filter(NEW.player_id::text) THEN
    RETURN NEW;
  END IF;

  v_buyer := CASE
    WHEN NEW.buyer_club_id = 'FOREIGN' THEN coalesce(nullif(btrim(NEW.foreign_buyer_name), ''), 'Foreign club')
    ELSE public.gpsl_discord_feed_club_name(NEW.buyer_club_id)
  END;

  BEGIN
    v_fee := public.transfer_format_money(coalesce(NEW.fee, 0));
  EXCEPTION WHEN OTHERS THEN
    v_fee := coalesce(NEW.fee, 0)::text;
  END;

  BEGIN
    v_method := public.transfer_classify_method(
      NEW.seller_club_id, NEW.buyer_club_id, NEW.listing_id,
      NEW.transfer_sale_note, NEW.foreign_buyer_name, NULL
    );
  EXCEPTION WHEN OTHERS THEN
    v_method := 'Direct offer (transfer market)';
  END;

  PERFORM public.gpsl_discord_feed_enqueue(
    'transfer',
    format('🔨 DONE DEAL — %s', v_name),
    format(
      E'%s → %s\nFee: %s\n%s\nAge %s · Rating %s',
      v_seller,
      v_buyer,
      v_fee,
      v_method,
      coalesce(v_age::text, '?'),
      coalesce(trim(to_char(v_rating, 'FM999')), '?')
    ),
    42641,
    'transfer:' || NEW.id::text,
    jsonb_build_object(
      'transfer_history_id', NEW.id,
      'listing_type', v_listing_type,
      'player_age', v_age,
      'player_rating', v_rating,
      'channel', 'news'
    )
  );

  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_gpsl_discord_feed_transfer ON public."Transfer_History";
CREATE TRIGGER trg_gpsl_discord_feed_transfer
  AFTER INSERT ON public."Transfer_History"
  FOR EACH ROW
  EXECUTE FUNCTION public.gpsl_discord_feed_on_transfer();

NOTIFY pgrst, 'reload schema';
