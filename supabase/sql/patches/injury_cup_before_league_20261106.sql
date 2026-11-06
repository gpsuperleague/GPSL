-- Injury pins: cups jump in front of league matches in the same GPSL month.
-- Played matches after the injury match count as served before any re-pin,
-- so a later cup draw cannot move an already-played absence onto a future game.
-- A treatment already calls this function. A new cup fixture calls it for both clubs.
--
-- Order: GPSL month, then cup before league, then matchday, then id.
-- Safe re-run.

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
  v_src public.competition_fixtures%rowtype;
  v_season_id bigint;
  v_fx record;
  v_need_out int;
  v_need_rec int;
  v_has_src boolean := false;
BEGIN
  SELECT * INTO v_inj FROM public.competition_player_injuries WHERE id = p_injury_id;
  IF NOT FOUND THEN RETURN; END IF;

  -- A pin left on a match that has already been played is served, not moved.
  FOR v_fx IN
    SELECT iff.id, iff.phase
    FROM public.competition_player_injury_fixtures iff
    JOIN public.competition_fixtures f ON f.id = iff.fixture_id
    WHERE iff.injury_id = p_injury_id
      AND iff.served = false
      AND lower(coalesce(f.status, '')) IN ('played', 'completed', 'forfeit')
      AND coalesce(f.is_void, false) = false
  LOOP
    UPDATE public.competition_player_injury_fixtures
    SET served = true
    WHERE id = v_fx.id;

    IF v_fx.phase = 'recovery' THEN
      UPDATE public.competition_player_injuries
      SET recovery_remaining = greatest(coalesce(recovery_remaining, 1) - 1, 0)
      WHERE id = p_injury_id;
    ELSE
      UPDATE public.competition_player_injuries
      SET matches_out_remaining = greatest(coalesce(matches_out_remaining, 1) - 1, 0)
      WHERE id = p_injury_id;
    END IF;
  END LOOP;

  SELECT * INTO v_inj FROM public.competition_player_injuries WHERE id = p_injury_id;

  IF v_inj.source_fixture_id IS NOT NULL THEN
    SELECT * INTO v_src FROM public.competition_fixtures WHERE id = v_inj.source_fixture_id;
    v_has_src := FOUND;
  END IF;

  SELECT s.id INTO v_season_id
  FROM public.competition_seasons s
  WHERE s.is_current = true
  ORDER BY s.id DESC
  LIMIT 1;

  IF v_season_id IS NULL THEN
    v_season_id := coalesce(v_inj.season_id, v_inj.incurred_season_id);
  END IF;

  -- Matches already played after the injury match, and never linked, still count.
  IF v_has_src AND v_season_id IS NOT NULL THEN
    FOR v_fx IN
      SELECT f.id
      FROM public.competition_fixtures f
      WHERE f.season_id = v_season_id
        AND f.id IS DISTINCT FROM v_src.id
        AND lower(coalesce(f.status, '')) IN ('played', 'completed', 'forfeit')
        AND coalesce(f.is_void, false) = false
        AND (f.home_club_short_name = v_inj.club_short_name
             OR f.away_club_short_name = v_inj.club_short_name)
        AND NOT public.competition_injury_is_preseason_month(f.gpsl_month)
        AND (
          coalesce(public.competition_gpsl_month_sort(f.gpsl_month), 99),
          CASE WHEN f.competition_type = 'cup' THEN 0 ELSE 1 END,
          coalesce(f.matchday, 9999),
          f.id
        ) > (
          coalesce(public.competition_gpsl_month_sort(v_src.gpsl_month), 99),
          CASE WHEN v_src.competition_type = 'cup' THEN 0 ELSE 1 END,
          coalesce(v_src.matchday, 9999),
          v_src.id
        )
        AND NOT EXISTS (
          SELECT 1
          FROM public.competition_player_injury_fixtures iff
          WHERE iff.injury_id = p_injury_id
            AND iff.fixture_id = f.id
            AND iff.served = true
        )
      ORDER BY
        coalesce(public.competition_gpsl_month_sort(f.gpsl_month), 99),
        CASE WHEN f.competition_type = 'cup' THEN 0 ELSE 1 END,
        coalesce(f.matchday, 9999),
        f.id
    LOOP
      SELECT * INTO v_inj FROM public.competition_player_injuries WHERE id = p_injury_id;
      EXIT WHEN coalesce(v_inj.matches_out_remaining, 0) <= 0
        AND coalesce(v_inj.recovery_remaining, 0) <= 0;

      IF coalesce(v_inj.matches_out_remaining, 0) > 0 THEN
        INSERT INTO public.competition_player_injury_fixtures (
          injury_id, fixture_id, phase, served
        ) VALUES (p_injury_id, v_fx.id, 'out', true)
        ON CONFLICT (injury_id, fixture_id) DO UPDATE
          SET phase = 'out', served = true;
        UPDATE public.competition_player_injuries
        SET matches_out_remaining = greatest(coalesce(matches_out_remaining, 1) - 1, 0)
        WHERE id = p_injury_id;
      ELSE
        INSERT INTO public.competition_player_injury_fixtures (
          injury_id, fixture_id, phase, served
        ) VALUES (p_injury_id, v_fx.id, 'recovery', true)
        ON CONFLICT (injury_id, fixture_id) DO UPDATE
          SET phase = 'recovery', served = true;
        UPDATE public.competition_player_injuries
        SET recovery_remaining = greatest(coalesce(recovery_remaining, 1) - 1, 0)
        WHERE id = p_injury_id;
      END IF;
    END LOOP;
  END IF;

  SELECT * INTO v_inj FROM public.competition_player_injuries WHERE id = p_injury_id;

  UPDATE public.competition_player_injuries
  SET status = 'recovered',
      recovered_at = coalesce(recovered_at, now())
  WHERE id = p_injury_id
    AND status = 'active'
    AND coalesce(matches_out_remaining, 0) <= 0
    AND coalesce(recovery_remaining, 0) <= 0;

  SELECT * INTO v_inj FROM public.competition_player_injuries WHERE id = p_injury_id;
  IF v_inj.status IS DISTINCT FROM 'active' THEN
    DELETE FROM public.competition_player_injury_fixtures
    WHERE injury_id = p_injury_id AND served = false;
    RETURN;
  END IF;

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

-- Summerville after the re-pin: the match he was injured in, and what is left.
SELECT
  i.id,
  i.label,
  i.status,
  i.matches_out AS out_at_start,
  i.matches_out_remaining AS out_left,
  src.gpsl_month AS injured_month,
  src.matchday AS injured_matchday,
  src.competition_type AS injured_in,
  src.home_club_short_name || ' vs ' || src.away_club_short_name AS injured_match,
  src.status AS source_status,
  (
    SELECT count(*)
    FROM public.competition_player_injury_fixtures f
    WHERE f.injury_id = i.id AND f.served AND f.phase = 'out'
  ) AS matches_served,
  (
    SELECT string_agg(
      f.gpsl_month || ' ' || f.competition_type || ' MD' || coalesce(f.matchday::text, '?')
        || ' ' || f.home_club_short_name || ' vs ' || f.away_club_short_name
        || CASE WHEN iff.served THEN ' (served)' ELSE ' (still out)' END,
      ' | ' ORDER BY
        coalesce(public.competition_gpsl_month_sort(f.gpsl_month), 99),
        CASE WHEN f.competition_type = 'cup' THEN 0 ELSE 1 END,
        coalesce(f.matchday, 9999),
        f.id
    )
    FROM public.competition_player_injury_fixtures iff
    JOIN public.competition_fixtures f ON f.id = iff.fixture_id
    WHERE iff.injury_id = i.id
  ) AS pins
FROM public.competition_player_injuries i
LEFT JOIN public.competition_fixtures src ON src.id = i.source_fixture_id
WHERE i.player_id = '132152'
ORDER BY i.created_at DESC;
