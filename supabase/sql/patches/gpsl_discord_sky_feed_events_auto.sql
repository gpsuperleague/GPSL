-- =============================================================================
-- GPSL Discord Sky News — extra events + auto-flush (no admin button needed)
--
-- Requires: gpsl_discord_sky_feed.sql already applied.
--
-- After this patch:
--   1) Edge secret DISCORD_FEED_INVOKE_KEY = a long random string
--      (same value you save in Admin → Discord News Feed → Auto-post settings)
--   2) Deploy/redeploy: supabase functions deploy discord-sky-feed
--   3) Enable extension pg_net (Dashboard → Database → Extensions) if prompted
--   4) On Admin → Discord News Feed, save Auto-post URL + invoke key
--
-- Auto-flush: AFTER INSERT on queue → pg_net POST to discord-sky-feed
--             + pg_cron every 2 minutes for retries
-- =============================================================================

DO $$
BEGIN
  CREATE EXTENSION IF NOT EXISTS pg_net WITH SCHEMA extensions;
EXCEPTION WHEN OTHERS THEN
  BEGIN
    CREATE EXTENSION IF NOT EXISTS pg_net;
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'pg_net extension not available — enable it in Database → Extensions';
  END;
END $$;

-- ---------------------------------------------------------------------------
-- Auto-flush settings (admin-writable)
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.gpsl_discord_feed_settings (
  id smallint PRIMARY KEY DEFAULT 1 CHECK (id = 1),
  edge_function_url text,
  invoke_key text,
  auto_flush_enabled boolean NOT NULL DEFAULT true,
  updated_at timestamptz NOT NULL DEFAULT now()
);

INSERT INTO public.gpsl_discord_feed_settings (id)
VALUES (1)
ON CONFLICT (id) DO NOTHING;

ALTER TABLE public.gpsl_discord_feed_settings ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS gpsl_discord_feed_settings_admin ON public.gpsl_discord_feed_settings;
CREATE POLICY gpsl_discord_feed_settings_admin
  ON public.gpsl_discord_feed_settings
  FOR ALL TO authenticated
  USING (public.is_gpsl_admin())
  WITH CHECK (public.is_gpsl_admin());

GRANT SELECT, UPDATE ON public.gpsl_discord_feed_settings TO authenticated;
GRANT ALL ON public.gpsl_discord_feed_settings TO service_role;

CREATE OR REPLACE FUNCTION public.admin_discord_feed_set_auto(
  p_edge_function_url text,
  p_invoke_key text,
  p_enabled boolean DEFAULT true
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  UPDATE public.gpsl_discord_feed_settings
  SET edge_function_url = nullif(btrim(coalesce(p_edge_function_url, '')), ''),
      invoke_key = nullif(btrim(coalesce(p_invoke_key, '')), ''),
      auto_flush_enabled = coalesce(p_enabled, true),
      updated_at = now()
  WHERE id = 1;

  RETURN jsonb_build_object(
    'ok', true,
    'auto_flush_enabled', coalesce(p_enabled, true),
    'has_url', nullif(btrim(coalesce(p_edge_function_url, '')), '') IS NOT NULL,
    'has_key', nullif(btrim(coalesce(p_invoke_key, '')), '') IS NOT NULL
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.admin_discord_feed_set_auto(text, text, boolean) TO authenticated;

CREATE OR REPLACE FUNCTION public.gpsl_discord_feed_request_flush()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions, net
AS $function$
DECLARE
  v_url text;
  v_key text;
  v_enabled boolean;
  v_pending int;
BEGIN
  SELECT s.edge_function_url, s.invoke_key, s.auto_flush_enabled
  INTO v_url, v_key, v_enabled
  FROM public.gpsl_discord_feed_settings s
  WHERE s.id = 1;

  IF NOT coalesce(v_enabled, false) THEN
    RETURN;
  END IF;
  IF v_url IS NULL OR v_key IS NULL THEN
    RETURN;
  END IF;

  SELECT count(*)::int INTO v_pending
  FROM public.gpsl_discord_feed_queue
  WHERE status = 'pending';

  IF coalesce(v_pending, 0) < 1 THEN
    RETURN;
  END IF;

  PERFORM net.http_post(
    url := v_url,
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || v_key
    ),
    body := '{}'::jsonb,
    timeout_milliseconds := 8000
  );
EXCEPTION
  WHEN undefined_function THEN
    RAISE WARNING 'gpsl_discord_feed_request_flush: pg_net net.http_post missing — enable pg_net';
  WHEN OTHERS THEN
    RAISE WARNING 'gpsl_discord_feed_request_flush failed: %', SQLERRM;
END;
$function$;

REVOKE ALL ON FUNCTION public.gpsl_discord_feed_request_flush() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.gpsl_discord_feed_request_flush() TO postgres;
GRANT EXECUTE ON FUNCTION public.gpsl_discord_feed_request_flush() TO service_role;

CREATE OR REPLACE FUNCTION public.gpsl_discord_feed_queue_after_insert()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF NEW.status = 'pending' THEN
    PERFORM public.gpsl_discord_feed_request_flush();
  END IF;
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_gpsl_discord_feed_queue_flush ON public.gpsl_discord_feed_queue;
CREATE TRIGGER trg_gpsl_discord_feed_queue_flush
  AFTER INSERT ON public.gpsl_discord_feed_queue
  FOR EACH ROW
  EXECUTE FUNCTION public.gpsl_discord_feed_queue_after_insert();

-- Cron retry (pending stuck / rate limits)
DO $do$
DECLARE
  v_job record;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    RAISE WARNING 'pg_cron not enabled — queue still auto-flushes on INSERT via pg_net';
    RETURN;
  END IF;

  FOR v_job IN
    SELECT jobid FROM cron.job WHERE jobname = 'gpsl-discord-feed-flush'
  LOOP
    PERFORM cron.unschedule(v_job.jobid);
  END LOOP;

  PERFORM cron.schedule(
    'gpsl-discord-feed-flush',
    '*/2 * * * *',
    $$SELECT public.gpsl_discord_feed_request_flush();$$
  );
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING 'Could not schedule discord feed cron: %', SQLERRM;
END;
$do$;

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.gpsl_discord_feed_club_name(p_short text)
RETURNS text
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT coalesce(
    (SELECT c."Club" FROM public."Clubs" c WHERE c."ShortName" = p_short LIMIT 1),
    nullif(btrim(p_short), ''),
    'Unknown club'
  );
$$;

CREATE OR REPLACE FUNCTION public.gpsl_discord_feed_current_season_id()
RETURNS bigint
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT id
  FROM public.competition_seasons
  WHERE is_current = true
  ORDER BY id DESC
  LIMIT 1;
$$;

CREATE OR REPLACE FUNCTION public.gpsl_discord_feed_is_season1(p_season_id bigint DEFAULT NULL)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_id bigint := coalesce(p_season_id, public.gpsl_discord_feed_current_season_id());
  v_ord integer;
BEGIN
  IF v_id IS NULL THEN
    RETURN false;
  END IF;
  BEGIN
    v_ord := public.competition_season_ordinal(v_id);
  EXCEPTION WHEN OTHERS THEN
    SELECT count(*)::integer INTO v_ord
    FROM public.competition_seasons s
    WHERE s.id <= v_id;
  END;
  RETURN coalesce(v_ord, 0) = 1;
END;
$function$;

CREATE OR REPLACE FUNCTION public.gpsl_discord_feed_is_preseason()
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_status text;
  v_phase text;
BEGIN
  SELECT lower(coalesce(s.status, ''))
  INTO v_status
  FROM public.competition_seasons s
  WHERE s.is_current = true
  ORDER BY s.id DESC
  LIMIT 1;

  IF v_status IN ('setup', 'preseason') THEN
    RETURN true;
  END IF;

  BEGIN
    SELECT lower(coalesce(g.league_phase, ''))
    INTO v_phase
    FROM public.global_settings g
    ORDER BY g.id
    LIMIT 1;
  EXCEPTION WHEN undefined_column THEN
    v_phase := NULL;
  END;

  IF v_phase IN ('summer_break', 'preseason', 'pre_season') THEN
    RETURN true;
  END IF;

  RETURN false;
END;
$function$;

-- ---------------------------------------------------------------------------
-- 1) Transfers — transfer market direct deals only (not list/draft auctions)
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
  v_listing_type text;
  v_method text;
  v_note text := lower(coalesce(btrim(NEW.transfer_sale_note), ''));
BEGIN
  SELECT p."Name" INTO v_name
  FROM public."Players" p
  WHERE p."Konami_ID"::text = NEW.player_id::text
  LIMIT 1;

  v_name := coalesce(nullif(btrim(v_name), ''), 'Player ' || NEW.player_id::text);
  v_seller := public.gpsl_discord_feed_club_name(NEW.seller_club_id);

  -- Voluntary contract release (no listing)
  IF v_note = 'voluntary_contract_release' THEN
    PERFORM public.gpsl_discord_feed_enqueue(
      'release',
      format('📋 CONTRACT RELEASE — %s', v_name),
      format('%s left %s.', v_name, v_seller),
      12370112, -- 0xbcbc80
      'transfer:' || NEW.id::text,
      jsonb_build_object(
        'transfer_history_id', NEW.id,
        'transfer_sale_note', NEW.transfer_sale_note
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
    format('%s → %s\nFee: %s\n%s', v_seller, v_buyer, v_fee, v_method),
    42641,
    'transfer:' || NEW.id::text,
    jsonb_build_object('transfer_history_id', NEW.id, 'listing_type', v_listing_type)
  );

  RETURN NEW;
END;
$function$;

-- ---------------------------------------------------------------------------
-- 2) Manager appointments (not season 1) / sackings / resignations
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.gpsl_discord_feed_on_manager_stint()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_name text;
  v_club text;
  v_season_id bigint;
BEGIN
  SELECT m.name INTO v_name FROM public."Managers" m WHERE m.id = NEW.manager_id;
  v_name := coalesce(nullif(btrim(v_name), ''), 'Manager #' || NEW.manager_id::text);
  v_club := public.gpsl_discord_feed_club_name(NEW.club_short_name);
  v_season_id := coalesce(NEW.season_id, public.gpsl_discord_feed_current_season_id());

  -- Appointment: new open stint
  IF TG_OP = 'INSERT' AND NEW.ended_at IS NULL THEN
    IF public.gpsl_discord_feed_is_season1(v_season_id) THEN
      RETURN NEW;
    END IF;

    PERFORM public.gpsl_discord_feed_enqueue(
      'manager',
      format('👔 MANAGER APPOINTED — %s', v_name),
      format('%s take charge at %s.', v_name, v_club),
      3447003, -- 0x3498db
      'mgr_appoint:' || NEW.id::text,
      jsonb_build_object('stint_id', NEW.id, 'manager_id', NEW.manager_id, 'club', NEW.club_short_name)
    );
    RETURN NEW;
  END IF;

  -- Departure
  IF TG_OP = 'UPDATE'
     AND NEW.ended_at IS NOT NULL
     AND OLD.ended_at IS NULL
     AND NEW.end_kind IS NOT NULL THEN

    IF NEW.end_kind = 'sack' THEN
      PERFORM public.gpsl_discord_feed_enqueue(
        'manager',
        format('🔥 MANAGER SACKED — %s', v_name),
        format('%s have sacked %s.', v_club, v_name),
        15158332, -- 0xe74c3c
        'mgr_sack:' || NEW.id::text,
        jsonb_build_object('stint_id', NEW.id, 'manager_id', NEW.manager_id, 'end_kind', NEW.end_kind)
      );
    ELSIF NEW.end_kind IN ('release', 'expire') THEN
      PERFORM public.gpsl_discord_feed_enqueue(
        'manager',
        format('🚪 MANAGER RESIGNS — %s', v_name),
        format('%s have left %s.', v_name, v_club),
        10181046, -- 0x9b59b6
        'mgr_resign:' || NEW.id::text,
        jsonb_build_object('stint_id', NEW.id, 'manager_id', NEW.manager_id, 'end_kind', NEW.end_kind)
      );
    ELSIF NEW.end_kind = 'transfer' THEN
      -- Failed-target / forced exit leaving them free agent (not a market move to another club)
      IF NOT EXISTS (
        SELECT 1 FROM public."Managers" m
        WHERE m.id = NEW.manager_id AND m.contracted_club IS NOT NULL
      ) AND NOT EXISTS (
        SELECT 1 FROM public.manager_club_stints s
        WHERE s.manager_id = NEW.manager_id AND s.ended_at IS NULL AND s.id IS DISTINCT FROM NEW.id
      ) THEN
        PERFORM public.gpsl_discord_feed_enqueue(
          'manager',
          format('🚪 MANAGER DEPARTS — %s', v_name),
          format('%s have left %s after failing to meet expectations.', v_name, v_club),
          10181046,
          'mgr_resign:' || NEW.id::text,
          jsonb_build_object('stint_id', NEW.id, 'manager_id', NEW.manager_id, 'end_kind', NEW.end_kind)
        );
      END IF;
    END IF;
  END IF;

  RETURN NEW;
END;
$function$;

DO $$
BEGIN
  IF to_regclass('public.manager_club_stints') IS NULL THEN
    RETURN;
  END IF;
  DROP TRIGGER IF EXISTS trg_gpsl_discord_feed_manager_stint ON public.manager_club_stints;
  CREATE TRIGGER trg_gpsl_discord_feed_manager_stint
    AFTER INSERT OR UPDATE OF ended_at, end_kind
    ON public.manager_club_stints
    FOR EACH ROW
    EXECUTE FUNCTION public.gpsl_discord_feed_on_manager_stint();
END $$;

-- ---------------------------------------------------------------------------
-- 3) Owner appointments (skip season 1 pre-season)
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

  PERFORM public.gpsl_discord_feed_enqueue(
    'owner',
    format('🏟️ NEW OWNER — %s', v_club),
    format('%s have appointed %s.', v_club, v_tag),
    15844367, -- 0xf1c40f
    'owner_appoint:' || NEW."ShortName" || ':' || NEW.owner_id::text,
    jsonb_build_object('club', NEW."ShortName", 'owner_id', NEW.owner_id)
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
-- 4) Title wins / relegations (season archive)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.gpsl_discord_feed_on_club_archive()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text;
  v_div text;
BEGIN
  v_club := public.gpsl_discord_feed_club_name(NEW.club_short_name);
  v_div := CASE lower(coalesce(NEW.division, ''))
    WHEN 'superleague' THEN 'Super League'
    WHEN 'championship_a' THEN 'Championship A'
    WHEN 'championship_b' THEN 'Championship B'
    ELSE coalesce(NEW.division, 'League')
  END;

  IF NEW.final_position = 1 THEN
    PERFORM public.gpsl_discord_feed_enqueue(
      'title',
      format('🏆 CHAMPIONS — %s', v_club),
      format('%s are %s champions (%s).', v_club, v_div, coalesce(NEW.season_label, 'this season')),
      16766720, -- 0xffd700
      'league_champ:' || coalesce(NEW.season_id::text, NEW.season_label) || ':' || NEW.division,
      jsonb_build_object(
        'club', NEW.club_short_name,
        'division', NEW.division,
        'season_id', NEW.season_id,
        'position', NEW.final_position
      )
    );
  END IF;

  IF lower(coalesce(NEW.division, '')) = 'superleague'
     AND coalesce(NEW.final_position, 0) >= 18 THEN
    PERFORM public.gpsl_discord_feed_enqueue(
      'relegation',
      format('📉 RELEGATED — %s', v_club),
      format('%s finish %s%s in the Super League and are relegated (%s).',
        v_club,
        NEW.final_position,
        CASE NEW.final_position
          WHEN 1 THEN 'st' WHEN 2 THEN 'nd' WHEN 3 THEN 'rd'
          ELSE 'th'
        END,
        coalesce(NEW.season_label, 'this season')
      ),
      10053324, -- 0x995533
      'releg:' || coalesce(NEW.season_id::text, NEW.season_label) || ':' || NEW.club_short_name,
      jsonb_build_object(
        'club', NEW.club_short_name,
        'position', NEW.final_position,
        'season_id', NEW.season_id
      )
    );
  END IF;

  RETURN NEW;
END;
$function$;

DO $$
BEGIN
  IF to_regclass('public.competition_club_season_archive') IS NULL THEN
    RETURN;
  END IF;
  DROP TRIGGER IF EXISTS trg_gpsl_discord_feed_club_archive ON public.competition_club_season_archive;
  CREATE TRIGGER trg_gpsl_discord_feed_club_archive
    AFTER INSERT OR UPDATE OF final_position, division
    ON public.competition_club_season_archive
    FOR EACH ROW
    EXECUTE FUNCTION public.gpsl_discord_feed_on_club_archive();
END $$;

-- ---------------------------------------------------------------------------
-- 5) Cup wins (archive table + live cup final)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.gpsl_discord_feed_on_cup_winner()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text;
  v_cup text;
BEGIN
  IF NEW.winner_club_short_name IS NULL THEN
    RETURN NEW;
  END IF;
  IF TG_OP = 'UPDATE'
     AND OLD.winner_club_short_name IS NOT DISTINCT FROM NEW.winner_club_short_name THEN
    RETURN NEW;
  END IF;

  v_club := public.gpsl_discord_feed_club_name(NEW.winner_club_short_name);
  v_cup := CASE lower(NEW.cup_code)
    WHEN 'super8' THEN 'Super 8'
    WHEN 'plate' THEN 'Plate'
    WHEN 'shield' THEN 'Shield'
    WHEN 'bowl' THEN 'Bowl'
    WHEN 'league_cup' THEN 'League Cup'
    ELSE upper(NEW.cup_code)
  END;

  PERFORM public.gpsl_discord_feed_enqueue(
    'cup',
    format('🏆 %s WINNERS — %s', upper(v_cup), v_club),
    format('%s lift the %s (%s).', v_club, v_cup, coalesce(NEW.season_label, 'this season')),
    16766720,
    'cup_winner:' || coalesce(NEW.season_id::text, 'x') || ':' || NEW.cup_code,
    jsonb_build_object(
      'cup_code', NEW.cup_code,
      'winner', NEW.winner_club_short_name,
      'season_id', NEW.season_id
    )
  );

  RETURN NEW;
END;
$function$;

DO $$
BEGIN
  IF to_regclass('public.competition_cup_season_winner') IS NULL THEN
    RETURN;
  END IF;
  DROP TRIGGER IF EXISTS trg_gpsl_discord_feed_cup_winner ON public.competition_cup_season_winner;
  CREATE TRIGGER trg_gpsl_discord_feed_cup_winner
    AFTER INSERT OR UPDATE OF winner_club_short_name
    ON public.competition_cup_season_winner
    FOR EACH ROW
    EXECUTE FUNCTION public.gpsl_discord_feed_on_cup_winner();
END $$;

-- Live cup final (when final is confirmed played)
CREATE OR REPLACE FUNCTION public.gpsl_discord_feed_on_cup_final_played()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_winner text;
  v_club text;
  v_cup text;
  v_is_final boolean := false;
BEGIN
  IF NEW.status IS DISTINCT FROM 'played' THEN
    RETURN NEW;
  END IF;
  IF TG_OP = 'UPDATE' AND OLD.status IS NOT DISTINCT FROM 'played' THEN
    RETURN NEW;
  END IF;
  IF NEW.competition_type IS DISTINCT FROM 'cup' THEN
    RETURN NEW;
  END IF;

  BEGIN
    v_is_final := public.competition_fixture_is_cup_final(NEW);
  EXCEPTION WHEN OTHERS THEN
    v_is_final := false;
  END;
  IF NOT v_is_final THEN
    RETURN NEW;
  END IF;

  IF NEW.cup_pen_winner_club_short_name IS NOT NULL THEN
    v_winner := NEW.cup_pen_winner_club_short_name;
  ELSIF NEW.home_goals > NEW.away_goals THEN
    v_winner := NEW.home_club_short_name;
  ELSIF NEW.away_goals > NEW.home_goals THEN
    v_winner := NEW.away_club_short_name;
  ELSE
    RETURN NEW;
  END IF;

  v_club := public.gpsl_discord_feed_club_name(v_winner);
  v_cup := CASE lower(coalesce(NEW.cup_code, ''))
    WHEN 'super8' THEN 'Super 8'
    WHEN 'plate' THEN 'Plate'
    WHEN 'shield' THEN 'Shield'
    WHEN 'bowl' THEN 'Bowl'
    WHEN 'league_cup' THEN 'League Cup'
    ELSE coalesce(upper(NEW.cup_code), 'Cup')
  END;

  PERFORM public.gpsl_discord_feed_enqueue(
    'cup',
    format('🏆 %s WINNERS — %s', upper(v_cup), v_club),
    format('%s win the %s final.', v_club, v_cup),
    16766720,
    'cup_winner:' || coalesce(NEW.season_id::text, 'x') || ':' || coalesce(NEW.cup_code, 'cup'),
    jsonb_build_object('fixture_id', NEW.id, 'cup_code', NEW.cup_code, 'winner', v_winner)
  );

  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_gpsl_discord_feed_cup_final ON public.competition_fixtures;
CREATE TRIGGER trg_gpsl_discord_feed_cup_final
  AFTER INSERT OR UPDATE OF status, home_goals, away_goals, cup_pen_winner_club_short_name
  ON public.competition_fixtures
  FOR EACH ROW
  EXECUTE FUNCTION public.gpsl_discord_feed_on_cup_final_played();

-- ---------------------------------------------------------------------------
-- 6) Playoff results / winners (CH 16v17 Shield/Bowl slots)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.gpsl_discord_feed_on_playoff_qualifier()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text;
  v_div text;
  v_headline text;
  v_body text;
BEGIN
  v_club := public.gpsl_discord_feed_club_name(NEW.club_short_name);
  v_div := CASE lower(coalesce(NEW.division, ''))
    WHEN 'championship_a' THEN 'Championship A'
    WHEN 'championship_b' THEN 'Championship B'
    ELSE coalesce(NEW.division, 'Championship')
  END;

  IF NEW.qualifier_role = 'shield_playoff_winner' THEN
    v_headline := format('⚔️ PLAYOFF WINNERS — %s', v_club);
    v_body := format('%s win the %s Shield/Bowl playoff and qualify for the Shield.', v_club, v_div);
  ELSIF NEW.qualifier_role = 'bowl_playoff_loser' THEN
    v_headline := format('⚔️ PLAYOFF RESULT — %s', v_club);
    v_body := format('%s lose the %s Shield/Bowl playoff and drop into the Bowl.', v_club, v_div);
  ELSE
    v_headline := format('⚔️ PLAYOFF — %s', v_club);
    v_body := format('%s — %s (%s).', v_club, NEW.qualifier_role, v_div);
  END IF;

  PERFORM public.gpsl_discord_feed_enqueue(
    'playoff',
    v_headline,
    v_body,
    10181046,
    'playoff:' || NEW.season_id::text || ':' || NEW.division || ':' || NEW.qualifier_role,
    jsonb_build_object(
      'club', NEW.club_short_name,
      'division', NEW.division,
      'role', NEW.qualifier_role,
      'season_id', NEW.season_id
    )
  );

  RETURN NEW;
END;
$function$;

DO $$
BEGIN
  IF to_regclass('public.competition_cup_manual_qualifiers') IS NULL THEN
    RETURN;
  END IF;
  DROP TRIGGER IF EXISTS trg_gpsl_discord_feed_playoff ON public.competition_cup_manual_qualifiers;
  CREATE TRIGGER trg_gpsl_discord_feed_playoff
    AFTER INSERT OR UPDATE OF club_short_name, qualifier_role
    ON public.competition_cup_manual_qualifiers
    FOR EACH ROW
    EXECUTE FUNCTION public.gpsl_discord_feed_on_playoff_qualifier();
END $$;

-- Soften listing noise: keep Active non-draft, but that was already in base patch.

NOTIFY pgrst, 'reload schema';
