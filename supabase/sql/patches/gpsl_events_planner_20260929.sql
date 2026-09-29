-- =============================================================================
-- Admin events planner → Season Calendar
--
--   gpsl_planned_events: admin-planned events shown on season_calendar.html
--     kinds: player_draft | manager_draft | club_auction | challenge |
--            announcement | deadline | other
--
--   Auto-start (player_draft / manager_draft / club_auction):
--     arm_hours_before the start, the cron switches that auction ON and sets
--     its clock: start = starts_at, secret finish = start + 23h50m + 0–9m58s
--     (same Day-1 / Day-2 rule as Admin → Transfers). Existing triggers then
--     post the usual inbox + Discord "scheduled" notices; bidding opens by
--     itself at starts_at. Club auctions can also seed listings.
--
--   Challenge windows / payouts are NOT stored here — the calendar reads them
--   straight from Challenge Admin (competition_challenge_config).
--
-- Safe re-run.
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.gpsl_planned_events (
  id bigserial PRIMARY KEY,
  title text NOT NULL CHECK (nullif(btrim(title), '') IS NOT NULL),
  detail text,
  kind text NOT NULL DEFAULT 'other' CHECK (kind IN (
    'player_draft', 'manager_draft', 'club_auction',
    'challenge', 'announcement', 'deadline', 'other'
  )),
  starts_at timestamptz NOT NULL,
  ends_at timestamptz,
  link_href text,
  visible boolean NOT NULL DEFAULT true,
  auto_start boolean NOT NULL DEFAULT false,
  arm_hours_before int NOT NULL DEFAULT 24 CHECK (arm_hours_before BETWEEN 0 AND 336),
  seed_club_listings boolean NOT NULL DEFAULT true,
  auto_status text NOT NULL DEFAULT 'none' CHECK (auto_status IN (
    'none', 'pending', 'armed', 'failed', 'cancelled'
  )),
  auto_ran_at timestamptz,
  auto_result jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_by uuid,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT gpsl_planned_events_window CHECK (ends_at IS NULL OR ends_at >= starts_at)
);

CREATE INDEX IF NOT EXISTS gpsl_planned_events_starts_idx
  ON public.gpsl_planned_events (starts_at);

CREATE INDEX IF NOT EXISTS gpsl_planned_events_pending_idx
  ON public.gpsl_planned_events (starts_at)
  WHERE auto_status = 'pending';

ALTER TABLE public.gpsl_planned_events ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS gpsl_planned_events_select ON public.gpsl_planned_events;
CREATE POLICY gpsl_planned_events_select ON public.gpsl_planned_events
  FOR SELECT TO authenticated
  USING (visible OR public.is_gpsl_admin());

GRANT SELECT ON public.gpsl_planned_events TO authenticated;

-- ---------------------------------------------------------------------------
-- Arm one auction event (internal)
-- ---------------------------------------------------------------------------
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
  v_cur_start timestamptz;
  v_cur_finish timestamptz;
  v_cur_on boolean;
  v_seed jsonb;
  v_result jsonb;
  v_label text;
  v_active int := 0;
  v_wait text;
BEGIN
  SELECT * INTO v_ev FROM public.gpsl_planned_events WHERE id = p_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_found');
  END IF;

  IF v_ev.kind NOT IN ('player_draft', 'manager_draft', 'club_auction') THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_an_auction');
  END IF;

  v_label := CASE v_ev.kind
    WHEN 'player_draft' THEN 'Player draft'
    WHEN 'manager_draft' THEN 'Manager draft'
    ELSE 'Club auction' END;

  SELECT * INTO v_gs FROM public.global_settings WHERE id = 1;

  IF v_ev.kind = 'player_draft' THEN
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

  IF v_ev.kind = 'player_draft' THEN
    SELECT count(*)::int INTO v_active FROM public."Player_Transfer_Listings"
    WHERE listing_type = 'draft' AND status = 'Active';
  ELSIF v_ev.kind = 'manager_draft' THEN
    SELECT count(*)::int INTO v_active FROM public."Manager_Transfer_Listings"
    WHERE listing_type = 'draft' AND status = 'Active';
  ELSE
    SELECT count(*)::int INTO v_active FROM public."Club_Auction_Listings"
    WHERE status = 'Active';
  END IF;

  -- Back-to-back days (Day 1 → Day 2): stay pending until the previous
  -- auction of this type is over AND settled. Re-arming earlier would move
  -- the finish clock and roll unsettled Day 1 listings into Day 2.
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

  IF v_ev.kind = 'player_draft' THEN
    UPDATE public.global_settings
    SET draft_auction_enabled = true,
        draft_auction_start_time = v_ev.starts_at,
        draft_random_finish_time = v_finish,
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

  -- Never store the secret finish on this owner-readable row
  v_result := jsonb_build_object(
    'ok', true,
    'armed', v_label,
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

-- ---------------------------------------------------------------------------
-- Cron: arm due auctions
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.gpsl_planned_events_process()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  r record;
  v_armed int := 0;
  v_missed int := 0;
  v_res jsonb;
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  FOR r IN
    SELECT id, starts_at, arm_hours_before
    FROM public.gpsl_planned_events
    WHERE auto_status = 'pending'
      AND auto_start
      AND starts_at - make_interval(hours => arm_hours_before) <= now()
    ORDER BY starts_at
  LOOP
    IF r.starts_at < now() - interval '12 hours' THEN
      UPDATE public.gpsl_planned_events
      SET auto_status = 'failed', auto_ran_at = now(),
          auto_result = jsonb_build_object('ok', false, 'reason', 'Start time passed before it could be armed'),
          updated_at = now()
      WHERE id = r.id;
      v_missed := v_missed + 1;
      CONTINUE;
    END IF;

    BEGIN
      v_res := public.gpsl_planned_event_arm(r.id);
      IF coalesce((v_res->>'ok')::boolean, false) THEN
        v_armed := v_armed + 1;
      END IF;
    EXCEPTION WHEN OTHERS THEN
      UPDATE public.gpsl_planned_events
      SET auto_status = 'failed', auto_ran_at = now(),
          auto_result = jsonb_build_object('ok', false, 'reason', SQLERRM),
          updated_at = now()
      WHERE id = r.id;
    END;
  END LOOP;

  RETURN jsonb_build_object('ok', true, 'armed', v_armed, 'missed', v_missed);
END;
$function$;

REVOKE ALL ON FUNCTION public.gpsl_planned_events_process() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.gpsl_planned_events_process() TO authenticated;

-- ---------------------------------------------------------------------------
-- Admin RPCs
-- ---------------------------------------------------------------------------
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
  END IF;

  v_status := CASE
    WHEN NOT v_auto THEN 'none'
    WHEN v_id IS NOT NULL
         AND v_old.auto_status = 'armed'
         AND v_old.starts_at = v_starts
         AND v_old.kind = v_kind THEN 'armed'
    ELSE 'pending'
  END;

  IF v_auto AND v_status = 'pending' AND v_starts <= now() THEN
    RAISE EXCEPTION 'Auto-start needs a start time in the future';
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
        auto_result = CASE WHEN v_status = 'pending' THEN '{}'::jsonb ELSE auto_result END,
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

CREATE OR REPLACE FUNCTION public.admin_planned_event_delete(p_id bigint)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;
  DELETE FROM public.gpsl_planned_events WHERE id = p_id;
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_planned_event_arm_now(p_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;
  RETURN public.gpsl_planned_event_arm(p_id);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.admin_planned_event_save(jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_planned_event_delete(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_planned_event_arm_now(bigint) TO authenticated;

DO $cron$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'gpsl-planned-events') THEN
      PERFORM cron.unschedule('gpsl-planned-events');
    END IF;
    PERFORM cron.schedule(
      'gpsl-planned-events',
      '*/5 * * * *',
      $job$SELECT public.gpsl_planned_events_process();$job$
    );
  END IF;
END;
$cron$;

NOTIFY pgrst, 'reload schema';
