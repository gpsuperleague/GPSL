-- =============================================================================
-- Scheduling month-end rules: league + all cups
--
-- Catch-up, arrangement fines, response tracking/fines, and deferred no-show
-- forfeits previously filtered competition_type = 'league' only. Same rules
-- now apply to every cup fixture on competition_fixtures (competition_type =
-- 'cup') — Champions League, FA Cup, etc.
--
-- Run once in Supabase SQL Editor. Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.match_schedule_uses_club_month_rules(p_competition_type text)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT lower(btrim(coalesce(p_competition_type, ''))) IN ('league', 'cup');
$$;

COMMENT ON FUNCTION public.match_schedule_uses_club_month_rules(text) IS
  'True for club competitions that use GPSL month arrange/play/catch-up and month-lock scheduling fines (league + all cups).';

GRANT EXECUTE ON FUNCTION public.match_schedule_uses_club_month_rules(text) TO authenticated;

-- Catch-up: unplayed after play month closes (league + all cups)
CREATE OR REPLACE FUNCTION public.match_schedule_fixture_is_catch_up(p_fixture_id bigint)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.competition_fixtures f
    WHERE f.id = p_fixture_id
      AND public.match_schedule_uses_club_month_rules(f.competition_type)
      AND f.status = 'scheduled'
      AND public.match_schedule_fixture_play_month_closed(p_fixture_id)
  );
$$;

-- Rewrite live function bodies that still hard-filter league only
DO $patch$
DECLARE
  r record;
  def text;
  new_def text;
  changed int := 0;
BEGIN
  FOR r IN
    SELECT p.oid, p.proname
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname IN (
        'competition_process_scheduling_response_deadlines',
        'competition_enforce_scheduling_response_fines',
        'competition_process_scheduling_response_fines',
        'competition_enforce_scheduling_arrangement_fines',
        'competition_process_scheduling_arrangement_fines',
        'competition_enforce_scheduling_checkin_fines',
        'competition_process_scheduling_checkin_fines'
      )
  LOOP
    def := pg_get_functiondef(r.oid);
    IF def IS NULL THEN
      CONTINUE;
    END IF;

    new_def := def;
    -- Already cup-aware
    IF position('match_schedule_uses_club_month_rules' in new_def) > 0
       OR position('competition_type IN (''league'', ''cup'')' in new_def) > 0 THEN
      RAISE NOTICE '% already cup-aware', r.proname;
      CONTINUE;
    END IF;

    new_def := replace(
      new_def,
      'f.competition_type = ''league''',
      'public.match_schedule_uses_club_month_rules(f.competition_type)'
    );

    IF new_def IS DISTINCT FROM def THEN
      new_def := regexp_replace(
        new_def,
        '^CREATE FUNCTION',
        'CREATE OR REPLACE FUNCTION'
      );
      EXECUTE new_def;
      changed := changed + 1;
      RAISE NOTICE 'Updated % to include cups', r.proname;
    ELSE
      RAISE NOTICE '%: no league-only filter found', r.proname;
    END IF;
  END LOOP;

  RAISE NOTICE 'Scheduling cup parity: % function(s) updated', changed;
END;
$patch$;

-- Recalc pending response deadlines for cup ties as well as league
DO $$
DECLARE
  v_row record;
  v_new_due timestamptz;
BEGIN
  IF to_regprocedure(
    'public.match_schedule_compute_response_due_at(bigint,bigint,timestamptz,text)'
  ) IS NULL THEN
    RETURN;
  END IF;

  FOR v_row IN
    SELECT
      s.fixture_id,
      s.pending_proposal_id,
      s.response_due_at AS old_due,
      p.created_at AS proposed_at,
      p.proposed_by_club_short_name AS proposer
    FROM public.competition_fixture_schedule s
    JOIN public.competition_fixtures f ON f.id = s.fixture_id
    JOIN public.competition_fixture_schedule_proposal p ON p.id = s.pending_proposal_id
    WHERE s.status = 'negotiating'
      AND s.pending_proposal_id IS NOT NULL
      AND p.status = 'pending'
      AND f.status = 'scheduled'
      AND public.match_schedule_uses_club_month_rules(f.competition_type)
  LOOP
    v_new_due := public.match_schedule_compute_response_due_at(
      v_row.fixture_id,
      v_row.pending_proposal_id,
      v_row.proposed_at,
      v_row.proposer
    );

    IF v_new_due IS DISTINCT FROM v_row.old_due THEN
      UPDATE public.competition_fixture_schedule
      SET
        response_due_at = v_new_due,
        updated_at = now()
      WHERE fixture_id = v_row.fixture_id;
    END IF;
  END LOOP;
END;
$$;

NOTIFY pgrst, 'reload schema';
