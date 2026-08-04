-- =============================================================================
-- Admin checklist after End season → Summer Break
--
-- Ending a season clears is_current, so the checklist had nothing new to bind
-- to and could keep showing the finished season's ticks (or a stale current).
--
-- This patch:
--   1) Hardens competition_end_season (end whatever is_current; mark complete)
--   2) Auto-ticks "End current season {summer break}" on that season's checklist
--   3) Returns next setup/preseason id (if any) for the UI to bind a fresh list
--
-- Run in Supabase SQL Editor. Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.competition_end_season()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season public.competition_seasons;
  v_next bigint;
  v_end_key text :=
    'end_of_season||End current season {summer break}|admin_season.html|wf-close-season';
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  -- Prefer the flagged current season (even if status drifted)
  SELECT * INTO v_season
  FROM public.competition_seasons
  WHERE is_current = true
  ORDER BY id DESC
  LIMIT 1;

  IF NOT FOUND THEN
    SELECT * INTO v_season
    FROM public.competition_seasons
    WHERE status = 'active'
    ORDER BY id DESC
    LIMIT 1;
  END IF;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'No active current season to end';
  END IF;

  UPDATE public.competition_seasons
  SET
    status = 'complete',
    is_current = false,
    ended_at = coalesce(ended_at, now())
  WHERE id = v_season.id;

  -- No season should remain current after summer break
  UPDATE public.competition_seasons
  SET is_current = false
  WHERE is_current = true
    AND id <> v_season.id;

  UPDATE public.global_settings
  SET league_phase = 'summer_break', updated_at = now()
  WHERE id = 1;

  -- Record that this close-out step was done on the finished season
  IF to_regprocedure('public.admin_workflow_checklist_set(bigint,text,boolean,text)') IS NOT NULL THEN
    PERFORM public.admin_workflow_checklist_set(
      v_season.id,
      v_end_key,
      true,
      'Auto-ticked by competition_end_season'
    );
  END IF;

  SELECT s.id INTO v_next
  FROM public.competition_seasons s
  WHERE s.status IN ('preseason', 'setup')
    AND s.id > v_season.id
  ORDER BY
    CASE s.status WHEN 'preseason' THEN 0 WHEN 'setup' THEN 1 ELSE 2 END,
    s.id DESC
  LIMIT 1;

  RETURN jsonb_build_object(
    'season_id', v_season.id,
    'label', v_season.label,
    'league_phase', 'summer_break',
    'next_season_id', v_next,
    'checklist_note',
      CASE
        WHEN v_next IS NOT NULL THEN
          'Finished-season ticks kept for history. Checklist should follow the next preseason/setup season (blank).'
        ELSE
          'Finished-season ticks kept for history. Create Pre-Season for a blank checklist.'
      END
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_end_season() TO authenticated;
