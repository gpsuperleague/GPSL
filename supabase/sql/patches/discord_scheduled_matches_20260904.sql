-- =============================================================================
-- Discord: agreed kick-offs → scheduled channels
--
-- When owners accept a match time:
--   • Club league / cup  → #gpsl-scheduled
--   • International      → #gpsl-intl-scheduled
--
-- Setup:
-- 1) Discord → create #gpsl-scheduled and #gpsl-intl-scheduled → Webhooks → copy URLs
-- 2) Supabase → Edge Functions → Secrets:
--      DISCORD_SCHEDULED_WEBHOOK_URL      = #gpsl-scheduled
--      DISCORD_INTL_SCHEDULED_WEBHOOK_URL = #gpsl-intl-scheduled
-- 3) Run this SQL
-- 4) Redeploy: supabase functions deploy discord-sky-feed
--
-- Safe re-run.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Enqueue helpers (metadata.channel drives edge routing)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.gpsl_discord_feed_enqueue_scheduled(
  p_event_type text,
  p_headline text,
  p_body text DEFAULT NULL,
  p_color integer DEFAULT 3447003, -- 0x3498db
  p_dedupe_key text DEFAULT NULL,
  p_metadata jsonb DEFAULT '{}'::jsonb
)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  RETURN public.gpsl_discord_feed_enqueue(
    coalesce(nullif(btrim(p_event_type), ''), 'scheduled'),
    p_headline,
    p_body,
    p_color,
    p_dedupe_key,
    coalesce(p_metadata, '{}'::jsonb) || jsonb_build_object('channel', 'scheduled')
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.gpsl_discord_feed_enqueue_scheduled(text, text, text, integer, text, jsonb)
  TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.gpsl_discord_feed_enqueue_intl_scheduled(
  p_event_type text,
  p_headline text,
  p_body text DEFAULT NULL,
  p_color integer DEFAULT 10181046, -- 0x9b59b6
  p_dedupe_key text DEFAULT NULL,
  p_metadata jsonb DEFAULT '{}'::jsonb
)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  RETURN public.gpsl_discord_feed_enqueue(
    coalesce(nullif(btrim(p_event_type), ''), 'intl_scheduled'),
    p_headline,
    p_body,
    p_color,
    p_dedupe_key,
    coalesce(p_metadata, '{}'::jsonb) || jsonb_build_object('channel', 'intl_scheduled')
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.gpsl_discord_feed_enqueue_intl_scheduled(text, text, text, integer, text, jsonb)
  TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Club league / cup: post when schedule becomes agreed (or kick-off changes)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.gpsl_discord_post_club_fixture_scheduled(p_fixture_id bigint)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_f public.competition_fixtures;
  v_ko timestamptz;
  v_home text;
  v_away text;
  v_month text;
  v_comp text;
  v_detail text;
  v_kind text;
  v_ko_label text;
  v_headline text;
  v_body text;
  v_dedupe text;
BEGIN
  IF p_fixture_id IS NULL THEN
    RETURN NULL;
  END IF;

  SELECT * INTO v_f
  FROM public.competition_fixtures
  WHERE id = p_fixture_id;

  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  IF coalesce(v_f.status, '') = 'played' OR coalesce(v_f.is_forfeit, false) THEN
    RETURN NULL;
  END IF;

  SELECT s.agreed_kickoff_at
  INTO v_ko
  FROM public.competition_fixture_schedule s
  WHERE s.fixture_id = p_fixture_id
    AND s.status = 'agreed'
    AND s.agreed_kickoff_at IS NOT NULL;

  IF v_ko IS NULL THEN
    RETURN NULL;
  END IF;

  SELECT c."Club" INTO v_home FROM public."Clubs" c WHERE c."ShortName" = v_f.home_club_short_name;
  SELECT c."Club" INTO v_away FROM public."Clubs" c WHERE c."ShortName" = v_f.away_club_short_name;
  v_home := coalesce(nullif(btrim(v_home), ''), v_f.home_club_short_name, 'Home');
  v_away := coalesce(nullif(btrim(v_away), ''), v_f.away_club_short_name, 'Away');

  BEGIN
    v_month := public.competition_gpsl_month_label(v_f.gpsl_month);
  EXCEPTION WHEN OTHERS THEN
    v_month := NULL;
  END;
  v_month := coalesce(
    nullif(btrim(v_month), ''),
    nullif(initcap(btrim(coalesce(v_f.gpsl_month, ''))), ''),
    'Unknown month'
  );

  IF v_f.competition_type = 'cup' OR nullif(btrim(coalesce(v_f.cup_code, '')), '') IS NOT NULL THEN
    v_kind := 'CUP';
    BEGIN
      v_comp := public.competition_cup_fixture_label(v_f);
    EXCEPTION WHEN OTHERS THEN
      v_comp := NULL;
    END;
    IF nullif(btrim(coalesce(v_comp, '')), '') IS NULL THEN
      v_comp := coalesce(
        nullif(btrim(
          CASE lower(coalesce(v_f.cup_code, ''))
            WHEN 'super8' THEN 'Super8'
            WHEN 'plate' THEN 'Plate'
            WHEN 'shield' THEN 'Shield'
            WHEN 'bowl' THEN 'Bowl'
            WHEN 'league_cup' THEN 'League Cup'
            ELSE initcap(replace(coalesce(v_f.cup_code, 'Cup'), '_', ' '))
          END
          || CASE WHEN v_f.cup_round IS NOT NULL THEN ' R' || v_f.cup_round::text ELSE '' END
          || CASE WHEN v_f.cup_match IS NOT NULL THEN ' M' || v_f.cup_match::text ELSE '' END
        ), ''),
        'Cup'
      );
    END IF;
  ELSE
    v_kind := 'LEAGUE';
    v_comp := CASE lower(coalesce(v_f.division, ''))
      WHEN 'superleague' THEN 'SuperLeague'
      WHEN 'championship_a' THEN 'Championship A'
      WHEN 'championship_b' THEN 'Championship B'
      ELSE coalesce(nullif(btrim(v_f.division), ''), 'League')
    END;
    IF v_f.matchday IS NOT NULL THEN
      v_detail := 'Matchday ' || v_f.matchday::text;
    END IF;
  END IF;

  v_comp := coalesce(nullif(btrim(v_comp), ''), 'Competition');

  BEGIN
    v_ko_label := public.match_schedule_format_kickoff_uk(v_ko);
  EXCEPTION WHEN OTHERS THEN
    v_ko_label := to_char(v_ko AT TIME ZONE 'Europe/London', 'Dy DD Mon HH24:MI') || ' UK';
  END;

  v_headline := format('📅 SCHEDULED · %s — %s vs %s', v_kind, v_home, v_away);
  v_body := format(
    E'%s · %s%s\nKick-off: %s\nOwners agreed — open Match Day when ready.',
    v_month,
    v_comp,
    CASE WHEN v_detail IS NOT NULL THEN E'\n' || v_detail ELSE '' END,
    v_ko_label
  );

  v_dedupe := format(
    'scheduled:club:%s:%s',
    p_fixture_id::text,
    to_char(v_ko AT TIME ZONE 'UTC', 'YYYYMMDDHH24MI')
  );

  RETURN public.gpsl_discord_feed_enqueue_scheduled(
    'scheduled',
    v_headline,
    v_body,
    CASE WHEN v_kind = 'CUP' THEN 15844367 ELSE 3447003 END, -- gold cup / blue league
    v_dedupe,
    jsonb_build_object(
      'fixture_id', p_fixture_id,
      'competition_type', coalesce(v_f.competition_type, 'league'),
      'kind', lower(v_kind),
      'kickoff_at', v_ko
    )
  );
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING 'gpsl_discord_post_club_fixture_scheduled(%) failed: %', p_fixture_id, SQLERRM;
  RETURN NULL;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.gpsl_discord_post_club_fixture_scheduled(bigint)
  TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.gpsl_discord_on_club_schedule_agreed()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF NEW.status IS DISTINCT FROM 'agreed' OR NEW.agreed_kickoff_at IS NULL THEN
    RETURN NEW;
  END IF;

  IF TG_OP = 'UPDATE'
     AND OLD.status IS NOT DISTINCT FROM 'agreed'
     AND OLD.agreed_kickoff_at IS NOT DISTINCT FROM NEW.agreed_kickoff_at
  THEN
    RETURN NEW;
  END IF;

  PERFORM public.gpsl_discord_post_club_fixture_scheduled(NEW.fixture_id);
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_gpsl_discord_club_schedule_agreed
  ON public.competition_fixture_schedule;

CREATE TRIGGER trg_gpsl_discord_club_schedule_agreed
  AFTER INSERT OR UPDATE OF status, agreed_kickoff_at
  ON public.competition_fixture_schedule
  FOR EACH ROW
  EXECUTE FUNCTION public.gpsl_discord_on_club_schedule_agreed();

-- ---------------------------------------------------------------------------
-- International: post when schedule becomes agreed (or kick-off changes)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.gpsl_discord_post_intl_fixture_scheduled(p_fixture_id bigint)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_f public.international_fixtures;
  v_ko timestamptz;
  v_phase text;
  v_matchup text;
  v_month text;
  v_ko_label text;
  v_headline text;
  v_body text;
  v_dedupe text;
BEGIN
  IF p_fixture_id IS NULL THEN
    RETURN NULL;
  END IF;

  IF to_regclass('public.international_fixtures') IS NULL
     OR to_regclass('public.international_fixture_schedule') IS NULL THEN
    RETURN NULL;
  END IF;

  SELECT * INTO v_f
  FROM public.international_fixtures
  WHERE id = p_fixture_id;

  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  IF coalesce(v_f.played, false) OR coalesce(v_f.status, '') = 'played' THEN
    RETURN NULL;
  END IF;

  SELECT s.agreed_kickoff_at
  INTO v_ko
  FROM public.international_fixture_schedule s
  WHERE s.fixture_id = p_fixture_id
    AND s.status = 'agreed'
    AND s.agreed_kickoff_at IS NOT NULL;

  IF v_ko IS NULL THEN
    RETURN NULL;
  END IF;

  BEGIN
    v_phase := public.international_fixture_phase_label(v_f.phase);
  EXCEPTION WHEN OTHERS THEN
    v_phase := coalesce(nullif(btrim(v_f.phase), ''), 'International');
  END;

  BEGIN
    v_matchup := public.international_fixture_matchup_label(p_fixture_id);
  EXCEPTION WHEN OTHERS THEN
    v_matchup := format(
      '%s vs %s',
      coalesce(v_f.home_nation, 'Home'),
      coalesce(v_f.away_nation, 'Away')
    );
  END;

  v_month := coalesce(
    nullif(initcap(btrim(coalesce(v_f.gpsl_month, ''))), ''),
    'International'
  );

  BEGIN
    v_ko_label := public.match_schedule_format_kickoff_uk(v_ko);
  EXCEPTION WHEN OTHERS THEN
    v_ko_label := to_char(v_ko AT TIME ZONE 'Europe/London', 'Dy DD Mon HH24:MI') || ' UK';
  END;

  v_headline := format('🌍 INTL SCHEDULED — %s', v_matchup);
  v_body := format(
    E'%s · %s\nKick-off: %s\nManagers agreed — open International Matchday when ready.',
    v_month,
    coalesce(nullif(btrim(v_phase), ''), 'International'),
    v_ko_label
  );

  v_dedupe := format(
    'scheduled:intl:%s:%s',
    p_fixture_id::text,
    to_char(v_ko AT TIME ZONE 'UTC', 'YYYYMMDDHH24MI')
  );

  RETURN public.gpsl_discord_feed_enqueue_intl_scheduled(
    'intl_scheduled',
    v_headline,
    v_body,
    10181046,
    v_dedupe,
    jsonb_build_object(
      'fixture_id', p_fixture_id,
      'phase', v_f.phase,
      'kickoff_at', v_ko
    )
  );
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING 'gpsl_discord_post_intl_fixture_scheduled(%) failed: %', p_fixture_id, SQLERRM;
  RETURN NULL;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.gpsl_discord_post_intl_fixture_scheduled(bigint)
  TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.gpsl_discord_on_intl_schedule_agreed()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF NEW.status IS DISTINCT FROM 'agreed' OR NEW.agreed_kickoff_at IS NULL THEN
    RETURN NEW;
  END IF;

  IF TG_OP = 'UPDATE'
     AND OLD.status IS NOT DISTINCT FROM 'agreed'
     AND OLD.agreed_kickoff_at IS NOT DISTINCT FROM NEW.agreed_kickoff_at
  THEN
    RETURN NEW;
  END IF;

  PERFORM public.gpsl_discord_post_intl_fixture_scheduled(NEW.fixture_id);
  RETURN NEW;
END;
$function$;

DO $$
BEGIN
  IF to_regclass('public.international_fixture_schedule') IS NULL THEN
    RAISE NOTICE 'international_fixture_schedule missing — intl scheduled Discord trigger skipped';
    RETURN;
  END IF;

  DROP TRIGGER IF EXISTS trg_gpsl_discord_intl_schedule_agreed
    ON public.international_fixture_schedule;

  CREATE TRIGGER trg_gpsl_discord_intl_schedule_agreed
    AFTER INSERT OR UPDATE OF status, agreed_kickoff_at
    ON public.international_fixture_schedule
    FOR EACH ROW
    EXECUTE FUNCTION public.gpsl_discord_on_intl_schedule_agreed();
END $$;
