-- Injury pins: cups jump in front of league matches in the same GPSL month.
-- A treatment already calls competition_injury_assign_fixtures. A cup draw did not,
-- so the squad kept the league match that was next when the injury was saved.
--
-- Order: GPSL month, then cup before league, then matchday, then id.
-- A new cup fixture re-pins both clubs' unserved absences.
-- Safe re-run. Re-pins every active injury that still has matches left.

CREATE OR REPLACE FUNCTION public.competition_injury_assign_fixtures(
  p_injury_id bigint
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_inj public.competition_player_injuries%rowtype;
  v_season_id bigint;
  v_fx record;
  v_need_out int;
  v_need_rec int;
BEGIN
  SELECT * INTO v_inj FROM public.competition_player_injuries WHERE id = p_injury_id;
  IF NOT FOUND THEN RETURN; END IF;

  v_need_out := greatest(coalesce(v_inj.matches_out_remaining, 0), 0);
  v_need_rec := greatest(coalesce(v_inj.recovery_remaining, 0), 0);

  DELETE FROM public.competition_player_injury_fixtures
  WHERE injury_id = p_injury_id AND served = false;

  SELECT s.id INTO v_season_id
  FROM public.competition_seasons s
  WHERE s.is_current = true
  ORDER BY s.id DESC
  LIMIT 1;

  IF v_season_id IS NULL THEN
    v_season_id := coalesce(v_inj.season_id, v_inj.incurred_season_id);
  END IF;

  FOR v_fx IN
    SELECT f.id
    FROM public.competition_fixtures f
    WHERE f.season_id = v_season_id
      AND f.status = 'scheduled'
      AND (f.home_club_short_name = v_inj.club_short_name
           OR f.away_club_short_name = v_inj.club_short_name)
      AND (v_inj.source_fixture_id IS NULL OR f.id IS DISTINCT FROM v_inj.source_fixture_id)
      AND NOT public.competition_injury_is_preseason_month(f.gpsl_month)
    ORDER BY
      coalesce(public.competition_gpsl_month_sort(f.gpsl_month), 99),
      CASE WHEN f.competition_type = 'cup' THEN 0 ELSE 1 END,
      coalesce(f.matchday, 9999),
      f.id
  LOOP
    EXIT WHEN v_need_out <= 0 AND v_need_rec <= 0;

    IF v_need_out > 0 THEN
      INSERT INTO public.competition_player_injury_fixtures (
        injury_id, fixture_id, phase, served
      ) VALUES (p_injury_id, v_fx.id, 'out', false)
      ON CONFLICT (injury_id, fixture_id) DO UPDATE
        SET phase = 'out', served = false;
      v_need_out := v_need_out - 1;
    ELSIF v_need_rec > 0 THEN
      INSERT INTO public.competition_player_injury_fixtures (
        injury_id, fixture_id, phase, served
      ) VALUES (p_injury_id, v_fx.id, 'recovery', false)
      ON CONFLICT (injury_id, fixture_id) DO UPDATE
        SET phase = 'recovery', served = false;
      v_need_rec := v_need_rec - 1;
    END IF;
  END LOOP;
END;
$function$;

CREATE OR REPLACE FUNCTION public.trg_cup_fixture_resync_injuries()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF NEW.competition_type IS DISTINCT FROM 'cup' THEN
    RETURN NEW;
  END IF;

  IF to_regprocedure('public.competition_resync_pending_injuries(bigint, text)') IS NULL THEN
    RETURN NEW;
  END IF;

  PERFORM public.competition_resync_pending_injuries(NEW.season_id, NEW.home_club_short_name);
  PERFORM public.competition_resync_pending_injuries(NEW.season_id, NEW.away_club_short_name);
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS cup_fixture_resync_injuries ON public.competition_fixtures;
CREATE TRIGGER cup_fixture_resync_injuries
  AFTER INSERT ON public.competition_fixtures
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_cup_fixture_resync_injuries();

DO $$
DECLARE
  r record;
  v_n int := 0;
BEGIN
  FOR r IN
    SELECT i.id
    FROM public.competition_player_injuries i
    WHERE i.status = 'active'
      AND (
        coalesce(i.matches_out_remaining, 0) > 0
        OR coalesce(i.recovery_remaining, 0) > 0
      )
  LOOP
    PERFORM public.competition_injury_assign_fixtures(r.id);
    v_n := v_n + 1;
  END LOOP;
  RAISE NOTICE 'injury_cup_before_league: re-pinned % active injuries', v_n;
END $$;

NOTIFY pgrst, 'reload schema';
