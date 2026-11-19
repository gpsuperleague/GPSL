-- A match on its own final play day cannot take a kick-off that day.
-- The latest kick-off is the UK day before the window lock, so one club
-- can enter the result before the cutoff. Other matches are unchanged.
-- CLI (postgres) can still repair a kick-off. Safe re-run.

CREATE OR REPLACE FUNCTION public.match_schedule_final_play_lock_at(p_fixture_id bigint)
RETURNS timestamptz
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_f public.competition_fixtures;
  v_play_sort int;
  v_grace int;
  v_lock timestamptz;
BEGIN
  SELECT * INTO v_f FROM public.competition_fixtures WHERE id = p_fixture_id;
  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  v_play_sort := public.competition_gpsl_month_sort(v_f.gpsl_month);
  v_grace := public.match_schedule_play_grace_months(v_f.competition_type, v_f.gpsl_month);
  IF v_play_sort IS NULL OR v_grace IS NULL THEN
    RETURN NULL;
  END IF;

  SELECT cal.lock_at INTO v_lock
  FROM public.competition_season_calendar cal
  WHERE cal.season_id = v_f.season_id
    AND public.competition_gpsl_month_sort(cal.gpsl_month) <= v_play_sort + v_grace
  ORDER BY public.competition_gpsl_month_sort(cal.gpsl_month) DESC
  LIMIT 1;

  RETURN v_lock;
END;
$function$;

CREATE OR REPLACE FUNCTION public.match_schedule_kickoff_is_final_play_day(
  p_fixture_id bigint,
  p_kickoff_at timestamptz
)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_lock timestamptz;
BEGIN
  IF p_kickoff_at IS NULL THEN
    RETURN false;
  END IF;

  v_lock := public.match_schedule_final_play_lock_at(p_fixture_id);
  IF v_lock IS NULL THEN
    RETURN false;
  END IF;

  RETURN (timezone('Europe/London', p_kickoff_at))::date
      = (timezone('Europe/London', v_lock))::date;
END;
$function$;

CREATE OR REPLACE FUNCTION public.match_schedule_assert_not_final_play_day(
  p_fixture_id bigint,
  p_kickoff_at timestamptz
)
RETURNS void
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF session_user IN ('postgres', 'supabase_admin') THEN
    RETURN;
  END IF;

  IF public.match_schedule_kickoff_is_final_play_day(p_fixture_id, p_kickoff_at) THEN
    RAISE EXCEPTION
      'This kick-off is on the cutoff day. The latest kick-off is the day before, so at least one club can enter the result before the window closes.';
  END IF;
END;
$function$;

CREATE OR REPLACE FUNCTION public.trg_reject_final_play_day_kickoff()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_fixture_id bigint;
  v_kickoff timestamptz;
BEGIN
  IF session_user IN ('postgres', 'supabase_admin') THEN
    RETURN NEW;
  END IF;

  IF TG_TABLE_NAME = 'competition_fixture_schedule' THEN
    IF TG_OP = 'UPDATE'
       AND NEW.agreed_kickoff_at IS NOT DISTINCT FROM OLD.agreed_kickoff_at THEN
      RETURN NEW;
    END IF;
    v_fixture_id := NEW.fixture_id;
    v_kickoff := NEW.agreed_kickoff_at;
  ELSIF TG_TABLE_NAME = 'competition_fixture_schedule_proposal' THEN
    IF TG_OP = 'UPDATE'
       AND NEW.kickoff_at IS NOT DISTINCT FROM OLD.kickoff_at THEN
      RETURN NEW;
    END IF;
    v_fixture_id := NEW.fixture_id;
    v_kickoff := NEW.kickoff_at;
  ELSIF TG_TABLE_NAME = 'competition_fixture_mutual_override' THEN
    IF TG_OP = 'UPDATE'
       AND NEW.proposed_kickoff_at IS NOT DISTINCT FROM OLD.proposed_kickoff_at THEN
      RETURN NEW;
    END IF;
    v_fixture_id := NEW.fixture_id;
    v_kickoff := NEW.proposed_kickoff_at;
  ELSIF TG_TABLE_NAME = 'competition_fixture_play_now_session' THEN
    IF TG_OP <> 'INSERT' THEN
      RETURN NEW;
    END IF;
    v_fixture_id := NEW.fixture_id;
    v_kickoff := coalesce(NEW.window_started_at, now());
  ELSE
    RETURN NEW;
  END IF;

  PERFORM public.match_schedule_assert_not_final_play_day(v_fixture_id, v_kickoff);
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_schedule_reject_final_play_day ON public.competition_fixture_schedule;
CREATE TRIGGER trg_schedule_reject_final_play_day
  BEFORE INSERT OR UPDATE OF agreed_kickoff_at
  ON public.competition_fixture_schedule
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_reject_final_play_day_kickoff();

DROP TRIGGER IF EXISTS trg_proposal_reject_final_play_day ON public.competition_fixture_schedule_proposal;
CREATE TRIGGER trg_proposal_reject_final_play_day
  BEFORE INSERT OR UPDATE OF kickoff_at
  ON public.competition_fixture_schedule_proposal
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_reject_final_play_day_kickoff();

DROP TRIGGER IF EXISTS trg_mutual_reject_final_play_day ON public.competition_fixture_mutual_override;
CREATE TRIGGER trg_mutual_reject_final_play_day
  BEFORE INSERT OR UPDATE OF proposed_kickoff_at
  ON public.competition_fixture_mutual_override
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_reject_final_play_day_kickoff();

DROP TRIGGER IF EXISTS trg_play_now_reject_final_play_day ON public.competition_fixture_play_now_session;
CREATE TRIGGER trg_play_now_reject_final_play_day
  BEFORE INSERT
  ON public.competition_fixture_play_now_session
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_reject_final_play_day_kickoff();

GRANT EXECUTE ON FUNCTION public.match_schedule_final_play_lock_at(bigint) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.match_schedule_kickoff_is_final_play_day(bigint, timestamptz) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.match_schedule_assert_not_final_play_day(bigint, timestamptz) TO authenticated, service_role;
