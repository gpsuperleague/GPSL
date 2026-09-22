-- =============================================================================
-- Discord Sky feed: cup win copy — "win the X Cup" (not "X final")
-- 2026-09-22
-- Safe re-run.
-- Example: "Arsenal win the Bowl Cup." instead of "Arsenal win the Bowl final."
-- =============================================================================

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
    WHEN 'super8' THEN 'Super 8 Cup'
    WHEN 'plate' THEN 'Plate Cup'
    WHEN 'shield' THEN 'Shield Cup'
    WHEN 'bowl' THEN 'Bowl Cup'
    WHEN 'spoon' THEN 'Bowl Cup'
    WHEN 'league_cup' THEN 'League Cup'
    ELSE coalesce(nullif(btrim(NEW.cup_code), ''), 'Cup')
  END;

  PERFORM public.gpsl_discord_feed_enqueue(
    'cup',
    format('🏆 %s WINNERS — %s', upper(v_cup), v_club),
    format('%s win the %s (%s).', v_club, v_cup, coalesce(NEW.season_label, 'this season')),
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
    WHEN 'super8' THEN 'Super 8 Cup'
    WHEN 'plate' THEN 'Plate Cup'
    WHEN 'shield' THEN 'Shield Cup'
    WHEN 'bowl' THEN 'Bowl Cup'
    WHEN 'spoon' THEN 'Bowl Cup'
    WHEN 'league_cup' THEN 'League Cup'
    ELSE coalesce(nullif(btrim(NEW.cup_code), ''), 'Cup')
  END;

  PERFORM public.gpsl_discord_feed_enqueue(
    'cup',
    format('🏆 %s WINNERS — %s', upper(v_cup), v_club),
    format('%s win the %s.', v_club, v_cup),
    16766720,
    'cup_winner:' || coalesce(NEW.season_id::text, 'x') || ':' || coalesce(NEW.cup_code, 'cup'),
    jsonb_build_object('fixture_id', NEW.id, 'cup_code', NEW.cup_code, 'winner', v_winner)
  );

  RETURN NEW;
END;
$function$;

NOTIFY pgrst, 'reload schema';
