-- =============================================================================
-- Events planner: Limited Draft kind (max 3 signings, no credits)
-- Same player-draft clocks as player_draft; sets player_draft_max_signings_per_club=3.
-- Regular player_draft arm clears the limit (unlimited / credits).
-- Safe re-run.
-- =============================================================================

ALTER TABLE public.gpsl_planned_events
  DROP CONSTRAINT IF EXISTS gpsl_planned_events_kind_check;

ALTER TABLE public.gpsl_planned_events
  ADD CONSTRAINT gpsl_planned_events_kind_check
  CHECK (kind = ANY (ARRAY[
    'player_draft'::text,
    'limited_draft'::text,
    'manager_draft'::text,
    'club_auction'::text,
    'challenge'::text,
    'announcement'::text,
    'deadline'::text,
    'other'::text
  ]));

CREATE OR REPLACE FUNCTION public.gpsl_planned_event_arm(p_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_ev public.gpsl_planned_events%rowtype;
  v_gs public.global_settings%rowtype;
  v_finish timestamptz;
  v_seed jsonb := NULL;
  v_cur_on boolean;
  v_cur_start timestamptz;
  v_cur_finish timestamptz;
  v_result jsonb;
  v_label text;
  v_active int := 0;
  v_wait text;
  v_is_player boolean;
BEGIN
  SELECT * INTO v_ev FROM public.gpsl_planned_events WHERE id = p_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_found');
  END IF;

  IF v_ev.kind NOT IN ('player_draft', 'limited_draft', 'manager_draft', 'club_auction') THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_an_auction');
  END IF;

  v_is_player := v_ev.kind IN ('player_draft', 'limited_draft');

  v_label := CASE v_ev.kind
    WHEN 'player_draft' THEN 'Player draft'
    WHEN 'limited_draft' THEN 'Limited draft'
    WHEN 'manager_draft' THEN 'Manager draft'
    ELSE 'Club auction' END;

  SELECT * INTO v_gs FROM public.global_settings WHERE id = 1;

  IF v_is_player THEN
    v_cur_on := coalesce(v_gs.draft_auction_enabled, false);
    v_cur_start := v_gs.draft_auction_start_time;
    v_cur_finish := v_gs.draft_random_finish_time;
  ELSIF v_ev.kind = 'manager_draft' THEN
    v_cur_on := coalesce(v_gs.manager_draft_auction_enabled, false);
    v_cur_start := v_gs.manager_draft_auction_start_time;
    v_cur_finish := v_gs.manager_draft_random_finish_time;
  ELSE
    v_cur_on := coalesce(v_gs.club_auction_enabled, false);
    v_cur_start := v_gs.club_auction_start_time;
    v_cur_finish := v_gs.club_auction_random_finish_time;
  END IF;

  IF v_is_player THEN
    SELECT count(*)::int INTO v_active FROM public."Player_Transfer_Listings"
    WHERE listing_type = 'draft' AND status = 'Active';
  ELSIF v_ev.kind = 'manager_draft' THEN
    SELECT count(*)::int INTO v_active FROM public."Manager_Transfer_Listings"
    WHERE listing_type = 'draft' AND status = 'Active';
  ELSE
    SELECT count(*)::int INTO v_active FROM public."Club_Auction_Listings"
    WHERE status = 'Active';
  END IF;

  IF v_cur_on
     AND v_cur_start IS NOT NULL AND v_cur_finish IS NOT NULL
     AND now() < v_cur_finish
     AND v_cur_start IS DISTINCT FROM v_ev.starts_at THEN
    v_wait := format('Waiting — previous %s (starts %s UK) not finished yet', lower(v_label),
      to_char(v_cur_start AT TIME ZONE 'Europe/London', 'Dy DD Mon HH24:MI'));
  ELSIF v_cur_finish IS NOT NULL
     AND now() >= v_cur_finish
     AND v_cur_start IS DISTINCT FROM v_ev.starts_at
     AND v_active > 0 THEN
    v_wait := format('Waiting — previous %s finished, settling %s listing(s)', lower(v_label), v_active);
  END IF;

  IF v_wait IS NOT NULL THEN
    v_result := jsonb_build_object('ok', false, 'waiting', true, 'reason', v_wait);
    UPDATE public.gpsl_planned_events
    SET auto_result = v_result, updated_at = now()
    WHERE id = p_id;
    RETURN v_result;
  END IF;

  v_finish := v_ev.starts_at
    + interval '23 hours 50 minutes'
    + make_interval(secs => floor(random() * 599)::int);

  IF v_is_player THEN
    UPDATE public.global_settings
    SET draft_auction_enabled = true,
        draft_auction_start_time = v_ev.starts_at,
        draft_random_finish_time = v_finish,
        player_draft_max_signings_per_club = CASE
          WHEN v_ev.kind = 'limited_draft' THEN 3
          ELSE NULL
        END,
        updated_at = now()
    WHERE id = 1;
  ELSIF v_ev.kind = 'manager_draft' THEN
    UPDATE public.global_settings
    SET manager_draft_auction_enabled = true,
        manager_draft_auction_start_time = v_ev.starts_at,
        manager_draft_random_finish_time = v_finish,
        updated_at = now()
    WHERE id = 1;
  ELSE
    UPDATE public.global_settings
    SET club_auction_enabled = true,
        club_auction_start_time = v_ev.starts_at,
        club_auction_random_finish_time = v_finish,
        updated_at = now()
    WHERE id = 1;

    IF v_ev.seed_club_listings
       AND to_regprocedure('public.admin_club_auction_seed_listings()') IS NOT NULL THEN
      BEGIN
        v_seed := public.admin_club_auction_seed_listings();
      EXCEPTION WHEN OTHERS THEN
        v_seed := jsonb_build_object('error', SQLERRM);
      END;
    END IF;
  END IF;

  v_result := jsonb_build_object(
    'ok', true,
    'armed', v_label,
    'limited', v_ev.kind = 'limited_draft',
    'max_signings', CASE WHEN v_ev.kind = 'limited_draft' THEN 3 ELSE NULL END,
    'opens_uk', to_char(v_ev.starts_at AT TIME ZONE 'Europe/London', 'Dy DD Mon YYYY HH24:MI'),
    'seed', v_seed
  );

  UPDATE public.gpsl_planned_events
  SET auto_status = 'armed', auto_ran_at = now(), auto_result = v_result, updated_at = now()
  WHERE id = p_id;

  RETURN v_result;
END;
$function$;

REVOKE ALL ON FUNCTION public.gpsl_planned_event_arm(bigint) FROM PUBLIC, anon, authenticated;

-- Allow auto-start for limited_draft in save RPC
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

  IF v_kind NOT IN ('player_draft', 'limited_draft', 'manager_draft', 'club_auction') THEN
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

  IF v_status = 'pending' THEN
    PERFORM public.gpsl_planned_events_process();
  END IF;

  RETURN (SELECT to_jsonb(e) FROM public.gpsl_planned_events e WHERE e.id = v_id);
END;
$function$;

REVOKE ALL ON FUNCTION public.admin_planned_event_save(jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_planned_event_save(jsonb) TO authenticated;

NOTIFY pgrst, 'reload schema';
