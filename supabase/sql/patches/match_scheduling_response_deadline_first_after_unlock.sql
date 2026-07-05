-- =============================================================================
-- Fix: first home proposal AFTER play-month unlock must not use past unlock_at
-- =============================================================================
-- Bug: match_schedule_compute_response_due_at always returned play-month
-- unlock for the first proposal. If home proposed for the first time after
-- August had already opened, due_at was in the past → instant ₿2.5m fine.
--
-- Rules (unchanged intent):
--   • First proposal before play month opens → due at play-month unlock
--   • First proposal in last 24h before unlock → due 48h after proposal
--   • First proposal after play month opens → due 24h after proposal
--   • Later counters / catch-up → 24h after proposal
--
-- Run when DB is healthy. Recalculates deadlines on all pending proposals.
-- Wrongful fines already posted need admin compensation (see note at bottom).
-- =============================================================================

CREATE OR REPLACE FUNCTION public.match_schedule_compute_response_due_at(
  p_fixture_id bigint,
  p_proposal_id bigint,
  p_proposed_at timestamptz,
  p_proposer_club text
)
RETURNS timestamptz
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_fixture public.competition_fixtures;
  v_play_unlock timestamptz;
  v_is_first_proposal boolean;
BEGIN
  SELECT * INTO v_fixture
  FROM public.competition_fixtures f
  WHERE f.id = p_fixture_id;

  IF NOT FOUND THEN
    RETURN p_proposed_at + interval '24 hours';
  END IF;

  IF public.match_schedule_fixture_is_catch_up(p_fixture_id) THEN
    RETURN p_proposed_at + interval '24 hours';
  END IF;

  SELECT cal.unlock_at INTO v_play_unlock
  FROM public.competition_season_calendar cal
  WHERE cal.season_id = v_fixture.season_id
    AND cal.gpsl_month = v_fixture.gpsl_month;

  SELECT NOT EXISTS (
    SELECT 1
    FROM public.competition_fixture_schedule_proposal p
    WHERE p.fixture_id = p_fixture_id
      AND p.id <> p_proposal_id
      AND p.status <> 'withdrawn'
  )
  INTO v_is_first_proposal;

  IF NOT v_is_first_proposal THEN
    RETURN p_proposed_at + interval '24 hours';
  END IF;

  -- First proposal before play month opens
  IF v_play_unlock IS NOT NULL AND p_proposed_at < v_play_unlock THEN
    IF p_proposed_at >= v_play_unlock - interval '24 hours' THEN
      RETURN p_proposed_at + interval '48 hours';
    END IF;
    RETURN v_play_unlock;
  END IF;

  -- First proposal after play month opened (or no calendar row)
  RETURN p_proposed_at + interval '24 hours';
END;
$function$;

-- Recalculate deadlines on pending proposals (does not reverse fines already posted)
DO $$
DECLARE
  v_row record;
  v_old_due timestamptz;
  v_new_due timestamptz;
  v_prop_at timestamptz;
BEGIN
  FOR v_row IN
    SELECT
      s.fixture_id,
      s.pending_proposal_id,
      s.response_due_at AS old_due,
      p.created_at AS proposed_at
    FROM public.competition_fixture_schedule s
    JOIN public.competition_fixtures f ON f.id = s.fixture_id
    JOIN public.competition_fixture_schedule_proposal p ON p.id = s.pending_proposal_id
    WHERE s.status = 'negotiating'
      AND s.pending_proposal_id IS NOT NULL
      AND p.status = 'pending'
      AND f.status = 'scheduled'
      AND f.competition_type = 'league'
  LOOP
    v_new_due := public.match_schedule_compute_response_due_at(
      v_row.fixture_id,
      v_row.pending_proposal_id,
      v_row.proposed_at,
      (SELECT proposed_by_club_short_name
       FROM public.competition_fixture_schedule_proposal
       WHERE id = v_row.pending_proposal_id)
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

-- Admin: reverse a wrongful fine (example for fixture 2766 — adjust club/note):
-- SELECT public.competition_apply_club_fine_tariff(
--   'URW',  -- respondent club short name
--   'league_compensation',
--   2500000,
--   'Reversal: response deadline bug (first proposal after month unlock)',
--   2766,
--   (SELECT id FROM public.competition_seasons WHERE is_current = true LIMIT 1)
-- );
