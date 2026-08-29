-- =============================================================================
-- Fix: check-in no-show month-lock idempotency LIKE key
--
-- Bug: skip check used format('sched_checkin_lock:%s:%', month, fixture_id)
--      — only one %s (fixture_id unused), trailing % invalid/ambiguous.
-- Note write already used the correct two-%s form.
--
-- Also unchanged: only still-scheduled fixtures with no_show set are considered;
-- a normal played result clears no_show and is never forfeited here.
--
-- Run once in Supabase SQL Editor. Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.competition_enforce_scheduling_checkin_fines(
  p_season_id bigint,
  p_closed_gpsl_month text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_row record;
  v_lock timestamptz;
  v_results jsonb := '[]'::jsonb;
  v_count int := 0;
  v_skipped int := 0;
  v_note_prefix text;
BEGIN
  SELECT c.lock_at
  INTO v_lock
  FROM public.competition_season_calendar c
  WHERE c.season_id = p_season_id
    AND c.gpsl_month = p_closed_gpsl_month;

  IF v_lock IS NULL OR v_lock > now() THEN
    RETURN jsonb_build_object(
      'ok', false,
      'reason', 'month_not_closed',
      'closed_gpsl_month', p_closed_gpsl_month
    );
  END IF;

  FOR v_row IN
    SELECT
      f.id AS fixture_id,
      s.no_show_club_short_name AS loser,
      f.matchday,
      f.gpsl_month
    FROM public.competition_fixtures f
    JOIN public.competition_fixture_schedule s ON s.fixture_id = f.id
    WHERE f.season_id = p_season_id
      AND (
        CASE
          WHEN to_regprocedure('public.match_schedule_uses_club_month_rules(text)') IS NOT NULL
          THEN public.match_schedule_uses_club_month_rules(f.competition_type)
          ELSE f.competition_type IN ('league', 'cup')
        END
      )
      AND f.status = 'scheduled'
      AND f.gpsl_month = p_closed_gpsl_month
      AND s.no_show_club_short_name IS NOT NULL
      AND EXISTS (
        SELECT 1
        FROM public."Clubs" c
        WHERE c."ShortName" = s.no_show_club_short_name
          AND c.owner_id IS NOT NULL
      )
  LOOP
    -- Must match the note prefix written below: sched_checkin_lock:{month}:{fixture_id}|…
    v_note_prefix := format(
      'sched_checkin_lock:%s:%s',
      p_closed_gpsl_month,
      v_row.fixture_id
    );

    IF EXISTS (
      SELECT 1
      FROM public.competition_fine_applied fa
      WHERE fa.fixture_id = v_row.fixture_id
        AND fa.tariff_code = 'match_agreed_no_show'
        AND fa.note LIKE v_note_prefix || '%'
    ) THEN
      v_skipped := v_skipped + 1;
      CONTINUE;
    END IF;

    PERFORM public.fixture_apply_forfeit(
      v_row.fixture_id,
      v_row.loser,
      'match_agreed_no_show',
      format(
        'sched_checkin_lock:%s:%s|No check-in at agreed kick-off · %s MD%s · assessed at month lock',
        p_closed_gpsl_month,
        v_row.fixture_id,
        public.competition_gpsl_month_label(v_row.gpsl_month),
        v_row.matchday
      )
    );

    v_count := v_count + 1;
    v_results := v_results || jsonb_build_array(
      jsonb_build_object(
        'fixture_id', v_row.fixture_id,
        'loser', v_row.loser
      )
    );
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true,
    'closed_gpsl_month', p_closed_gpsl_month,
    'forfeits_applied', v_count,
    'skipped', v_skipped,
    'forfeited', v_results
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_enforce_scheduling_checkin_fines(bigint, text)
  TO authenticated;

NOTIFY pgrst, 'reload schema';
