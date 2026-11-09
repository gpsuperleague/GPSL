-- =============================================================================
-- Confirm result: stop the statement timeout
--
-- Platense vs Porto, Super League MD11: competition_confirm_result returns 500.
-- The result write was still followed, in the same request, by challenge scans,
-- a full division prize pass, and the injury/fitness roll (which walks the
-- rest of the season). That overruns the request limit and rolls the result back.
--
-- Confirm now saves the score, stats, gates, TV, cup advance, and inbox, then
-- returns. A one-minute job does challenges, prizes, and the injury/fitness roll.
--
-- The played-fixture trigger also skips the league-clinch scan while confirm
-- is running (that scan is a known timeout).
--
-- Run once in the Supabase SQL editor. Safe re-run.
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.competition_confirm_followup (
  fixture_id bigint PRIMARY KEY,
  queued_at timestamptz NOT NULL DEFAULT now(),
  done_at timestamptz,
  attempts int NOT NULL DEFAULT 0,
  last_error text
);

CREATE INDEX IF NOT EXISTS competition_confirm_followup_pending_idx
  ON public.competition_confirm_followup (queued_at)
  WHERE done_at IS NULL;

ALTER TABLE public.competition_confirm_followup ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON public.competition_confirm_followup FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.competition_confirm_followup_one(p_fixture_id bigint)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
SET statement_timeout TO '120s'
AS $function$
DECLARE
  v_f public.competition_fixtures;
BEGIN
  PERFORM set_config('statement_timeout', '120s', true);
  PERFORM set_config('gpsl.skip_clinch_scan', 'on', true);
  PERFORM set_config('gpsl.skip_bookies_reprice', 'on', true);
  PERFORM set_config('gpsl.defer_injury_fitness', 'off', true);

  SELECT * INTO v_f FROM public.competition_fixtures WHERE id = p_fixture_id;
  IF NOT FOUND OR v_f.status IS DISTINCT FROM 'played' THEN
    UPDATE public.competition_confirm_followup
    SET done_at = now(), last_error = 'fixture not played'
    WHERE fixture_id = p_fixture_id;
    RETURN;
  END IF;

  IF to_regprocedure('public.competition_try_award_challenges(bigint,text,boolean)') IS NOT NULL THEN
    PERFORM public.competition_try_award_challenges(v_f.season_id, v_f.home_club_short_name, false);
    PERFORM public.competition_try_award_challenges(v_f.season_id, v_f.away_club_short_name, false);
  ELSIF to_regprocedure('public.competition_try_award_challenges(bigint,text)') IS NOT NULL THEN
    PERFORM public.competition_try_award_challenges(v_f.season_id, v_f.home_club_short_name);
    PERFORM public.competition_try_award_challenges(v_f.season_id, v_f.away_club_short_name);
  END IF;

  IF coalesce(v_f.competition_type, 'league') = 'league'
     AND to_regprocedure('public.competition_try_pay_league_division_prizes(bigint,text)') IS NOT NULL THEN
    PERFORM public.competition_try_pay_league_division_prizes(v_f.season_id, v_f.division);
  END IF;

  IF to_regprocedure('public.competition_serve_injuries_for_fixture(bigint)') IS NOT NULL THEN
    PERFORM public.competition_serve_injuries_for_fixture(v_f.id);
  END IF;

  UPDATE public.competition_confirm_followup
  SET done_at = now(), last_error = NULL
  WHERE fixture_id = p_fixture_id;
EXCEPTION WHEN OTHERS THEN
  UPDATE public.competition_confirm_followup
  SET attempts = attempts + 1,
      last_error = SQLERRM
  WHERE fixture_id = p_fixture_id;
END;
$function$;

REVOKE ALL ON FUNCTION public.competition_confirm_followup_one(bigint) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.competition_confirm_followup_one(bigint) TO service_role;

CREATE OR REPLACE FUNCTION public.competition_confirm_followup_tick()
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
SET statement_timeout TO '150s'
AS $function$
DECLARE
  v_id bigint;
  v_n int := 0;
BEGIN
  PERFORM set_config('statement_timeout', '150s', true);

  FOR v_id IN
    SELECT q.fixture_id
    FROM public.competition_confirm_followup q
    WHERE q.done_at IS NULL
      AND q.attempts < 5
    ORDER BY q.queued_at
    LIMIT 2
  LOOP
    PERFORM public.competition_confirm_followup_one(v_id);
    v_n := v_n + 1;
  END LOOP;

  RETURN v_n;
END;
$function$;

REVOKE ALL ON FUNCTION public.competition_confirm_followup_tick() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.competition_confirm_followup_tick() TO service_role;

-- Take the slow work out of the live confirm function.
DO $trim$
DECLARE
  v_oid oid;
  v_def text;
  v_new text;
  v_tail text;
  v_queue text := E'  INSERT INTO public.competition_confirm_followup (fixture_id)\n'
    || E'  VALUES (v_fixture.id)\n'
    || E'  ON CONFLICT (fixture_id) DO UPDATE\n'
    || E'  SET queued_at = now(), done_at = NULL, attempts = 0, last_error = NULL;\n';
BEGIN
  v_oid := to_regprocedure('public.competition_confirm_result(bigint, jsonb)');
  IF v_oid IS NULL THEN
    RAISE EXCEPTION 'competition_confirm_result(bigint, jsonb) missing';
  END IF;

  v_def := pg_get_functiondef(v_oid);
  IF position('competition_confirm_followup' IN v_def) > 0 THEN
    RAISE NOTICE 'confirm already queues follow-up';
    RETURN;
  END IF;

  -- Drop the challenge block. Keep cup advancement. Drop the league-prize branch.
  -- Default regex: '.' matches newlines.
  v_new := regexp_replace(
    v_def,
    E'  IF to_regprocedure\\(''public\\.competition_try_award_challenges\\(bigint,text,boolean\\)''\\) IS NOT NULL THEN.*?  END IF;\\s*'
      || E'  IF v_fixture\\.competition_type = ''cup'' THEN\\s*'
      || E'    PERFORM public\\.competition_cup_on_fixture_played\\(v_sub\\.fixture_id\\);\\s*'
      || E'  ELSIF v_fixture\\.competition_type = ''league''.*?  END IF;',
    E'  IF v_fixture.competition_type = ''cup'' THEN\n'
      || E'    PERFORM public.competition_cup_on_fixture_played(v_sub.fixture_id);\n'
      || E'  END IF;\n'
  );

  v_tail := regexp_replace(
    v_new,
    E'  -- Soft tail: fitness \\+ injury roll \\(cannot undo confirm\\).*?END IF;\\s*END;',
    v_queue || E'END;'
  );

  IF v_tail = v_new THEN
    v_tail := regexp_replace(
      v_new,
      E'  PERFORM set_config\\(''gpsl\\.defer_injury_fitness'', ''off'', true\\);.*?competition_serve_injuries_for_fixture\\(v_fixture\\.id\\);\\s*EXCEPTION WHEN OTHERS THEN.*?END IF;\\s*END;',
      v_queue || E'END;'
    );
  END IF;

  IF v_tail IS NOT DISTINCT FROM v_def OR position('competition_confirm_followup' IN v_tail) = 0 THEN
    RAISE EXCEPTION
      'Could not trim competition_confirm_result — the live body does not match the expected challenge/injury tail';
  END IF;

  EXECUTE v_tail;
  EXECUTE 'ALTER FUNCTION public.competition_confirm_result(bigint, jsonb) SET statement_timeout TO ''30s''';
  RAISE NOTICE 'confirm queues challenges, prizes, and injury/fitness';
END;
$trim$;

-- Clinch scan on the played trigger must stay off during confirm.
DO $clinch$
DECLARE
  v_oid oid;
  v_def text;
  v_new text;
BEGIN
  v_oid := to_regprocedure('public.gpsl_discord_feed_on_fixture_played()');
  IF v_oid IS NULL THEN
    RETURN;
  END IF;

  v_def := pg_get_functiondef(v_oid);
  IF position('skip_clinch_scan' IN v_def) > 0 THEN
    RETURN;
  END IF;

  v_new := replace(
    v_def,
    E'  IF NEW.home_goals IS NULL OR NEW.away_goals IS NULL THEN\n    RETURN NEW;\n  END IF;\n',
    E'  IF NEW.home_goals IS NULL OR NEW.away_goals IS NULL THEN\n    RETURN NEW;\n  END IF;\n'
      || E'  IF current_setting(''gpsl.skip_clinch_scan'', true) = ''on'' THEN\n    RETURN NEW;\n  END IF;\n'
  );

  IF v_new = v_def THEN
    RAISE WARNING 'discord played trigger: clinch skip was not added';
  ELSE
    EXECUTE v_new;
  END IF;
END;
$clinch$;

DO $cron$
BEGIN
  BEGIN
    PERFORM cron.unschedule('gpsl-confirm-followup');
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;

  PERFORM cron.schedule(
    'gpsl-confirm-followup',
    '* * * * *',
    $q$SELECT public.competition_confirm_followup_tick();$q$
  );
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING 'Could not schedule confirm follow-up: %', SQLERRM;
END;
$cron$;

NOTIFY pgrst, 'reload schema';
