-- =============================================================================
-- Events planner — allow editing an auto-start event after its start time
--
-- Bug: editing any auto-start event (title, detail, visibility…) reset its
-- auto_status to 'pending'; once the start had passed the save failed with
-- "Auto-start needs a start time in the future".
--
-- Now: if an existing event keeps the same kind + start time, its current
-- auto_status (armed / failed / cancelled / pending) is kept and it is not
-- re-armed. A new or re-timed auto-start event still needs a future start.
-- Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.admin_planned_event_save(p_event jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_id bigint := nullif(p_event->>'id', '')::bigint;
  v_kind text := coalesce(nullif(p_event->>'kind', ''), 'other');
  v_starts timestamptz := nullif(p_event->>'starts_at', '')::timestamptz;
  v_ends timestamptz := nullif(p_event->>'ends_at', '')::timestamptz;
  v_auto boolean := coalesce((p_event->>'auto_start')::boolean, false);
  v_status text;
  v_old public.gpsl_planned_events%rowtype;
  v_unchanged boolean := false;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF v_starts IS NULL THEN
    RAISE EXCEPTION 'Start date/time required';
  END IF;

  IF v_kind NOT IN ('player_draft', 'manager_draft', 'club_auction') THEN
    v_auto := false;
  END IF;

  IF v_id IS NOT NULL THEN
    SELECT * INTO v_old FROM public.gpsl_planned_events WHERE id = v_id;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'Event % not found', v_id;
    END IF;
    v_unchanged := v_old.auto_start
      AND v_old.starts_at = v_starts
      AND v_old.kind = v_kind
      AND v_old.auto_status <> 'none';
  END IF;

  v_status := CASE
    WHEN NOT v_auto THEN 'none'
    WHEN v_unchanged THEN v_old.auto_status
    ELSE 'pending'
  END;

  IF v_auto AND v_status = 'pending' AND v_starts <= now() AND NOT v_unchanged THEN
    RAISE EXCEPTION
      'Auto-start needs a start time in the future (% UK has passed). Untick Auto-start to keep it as a calendar note, or set a later start.',
      to_char(v_starts AT TIME ZONE 'Europe/London', 'DD Mon YYYY HH24:MI');
  END IF;

  IF v_id IS NULL THEN
    INSERT INTO public.gpsl_planned_events (
      title, detail, kind, starts_at, ends_at, link_href, visible,
      auto_start, arm_hours_before, seed_club_listings, auto_status, created_by
    ) VALUES (
      btrim(p_event->>'title'),
      nullif(btrim(coalesce(p_event->>'detail', '')), ''),
      v_kind,
      v_starts,
      v_ends,
      nullif(btrim(coalesce(p_event->>'link_href', '')), ''),
      coalesce((p_event->>'visible')::boolean, true),
      v_auto,
      coalesce(nullif(p_event->>'arm_hours_before', '')::int, 24),
      coalesce((p_event->>'seed_club_listings')::boolean, true),
      v_status,
      auth.uid()
    )
    RETURNING id INTO v_id;
  ELSE
    UPDATE public.gpsl_planned_events
    SET title = btrim(p_event->>'title'),
        detail = nullif(btrim(coalesce(p_event->>'detail', '')), ''),
        kind = v_kind,
        starts_at = v_starts,
        ends_at = v_ends,
        link_href = nullif(btrim(coalesce(p_event->>'link_href', '')), ''),
        visible = coalesce((p_event->>'visible')::boolean, true),
        auto_start = v_auto,
        arm_hours_before = coalesce(nullif(p_event->>'arm_hours_before', '')::int, 24),
        seed_club_listings = coalesce((p_event->>'seed_club_listings')::boolean, true),
        auto_status = v_status,
        auto_result = CASE
          WHEN v_status = 'pending' AND NOT v_unchanged THEN '{}'::jsonb
          ELSE auto_result
        END,
        updated_at = now()
    WHERE id = v_id;
  END IF;

  -- Arm straight away if already inside the arm window
  IF v_status = 'pending' THEN
    PERFORM public.gpsl_planned_events_process();
  END IF;

  RETURN (SELECT to_jsonb(e) FROM public.gpsl_planned_events e WHERE e.id = v_id);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.admin_planned_event_save(jsonb) TO authenticated;

NOTIFY pgrst, 'reload schema';

SELECT id, title, kind, starts_at, auto_start, auto_status
FROM public.gpsl_planned_events
ORDER BY starts_at DESC
LIMIT 10;
