-- =============================================================================
-- Fix: GPSL results Discord posts missing month + competition
--
-- Cause: format('%s', NULL) returns NULL in Postgres, so if cup label / month
-- helpers returned null the entire body became null (headline-only embeds).
-- Safe re-run.
-- =============================================================================

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

    -- competition_cup_fixture_label uses format() with nullable round/match → can be NULL
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

  -- Put month + competition in headline so they always show even if body is dropped
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
    14747136, -- 0xe10600
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

NOTIFY pgrst, 'reload schema';
