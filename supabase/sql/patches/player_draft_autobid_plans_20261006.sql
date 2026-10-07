-- =============================================================================
-- Player draft: away-mode auto-bid plans
-- =============================================================================
-- Owners build a plan in Scouting → Target lists from the Active Targets on a
-- board, tied to ONE dated player draft. While that draft is live a cron job
-- (every minute) works through the plan in priority order:
--   · no thread yet        → open it at the opening price (earns 2 credits)
--   · another club's thread → join at the minimum if a credit is free (1 credit),
--                             otherwise wait and retry as credits are earned
--   · already in           → keep the plan's max bid set; the existing max bid
--                             system defends up to that amount
-- Before opening / joining it checks the plan caps (total spend, max players
-- to win) and squad rules (star cap — OooO not counted — and 28-man squad).
-- No new opens / joins after the 6pm cutoff. The plan expires when the draft
-- ends; its max bids are removed and an inbox summary is sent.
--
-- Existing auction functions are NOT changed — the engine only calls
-- player_draft_place_auto_bid / player_draft_resolve_max_bids and writes
-- player_draft_max_bids rows (the same things an owner does by hand).
--
-- Admin kill switch: global_settings.draft_autobid_paused (or
-- SELECT public.admin_set_draft_autobid_paused(true);).
--
-- Safe re-run.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. Tables
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.player_draft_autobid_plans (
  id bigserial PRIMARY KEY,
  club_short_name text NOT NULL,
  owner_id uuid,
  draft_start_at timestamptz NOT NULL,
  draft_label text,
  source_board int,
  spend_cap numeric,
  max_wins int,
  enabled boolean NOT NULL DEFAULT true,
  status text NOT NULL DEFAULT 'scheduled'
    CHECK (status IN ('scheduled', 'live', 'finished', 'expired')),
  live_window_start timestamptz,
  live_window_end timestamptz,
  live_at timestamptz,
  finished_at timestamptz,
  last_run_at timestamptz,
  last_error text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT player_draft_autobid_plans_club_draft_key UNIQUE (club_short_name, draft_start_at),
  CONSTRAINT player_draft_autobid_plans_spend_cap_chk CHECK (spend_cap IS NULL OR spend_cap > 0),
  CONSTRAINT player_draft_autobid_plans_max_wins_chk CHECK (max_wins IS NULL OR max_wins BETWEEN 1 AND 28)
);

CREATE INDEX IF NOT EXISTS player_draft_autobid_plans_status_idx
  ON public.player_draft_autobid_plans (status, draft_start_at);

CREATE TABLE IF NOT EXISTS public.player_draft_autobid_targets (
  id bigserial PRIMARY KEY,
  plan_id bigint NOT NULL REFERENCES public.player_draft_autobid_plans (id) ON DELETE CASCADE,
  player_id text NOT NULL,
  priority int NOT NULL DEFAULT 0,
  max_amount numeric NOT NULL CHECK (max_amount > 0),
  included boolean NOT NULL DEFAULT true,
  allow_open boolean NOT NULL DEFAULT true,
  state text NOT NULL DEFAULT 'pending',
  state_note text,
  entered_via text CHECK (entered_via IS NULL OR entered_via IN ('opened', 'joined', 'manual')),
  max_set_amount numeric,
  last_action_at timestamptz,
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT player_draft_autobid_targets_plan_player_key UNIQUE (plan_id, player_id)
);

CREATE INDEX IF NOT EXISTS player_draft_autobid_targets_plan_idx
  ON public.player_draft_autobid_targets (plan_id, priority);

-- Only reachable through the SECURITY DEFINER functions below.
ALTER TABLE public.player_draft_autobid_plans ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.player_draft_autobid_targets ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.player_draft_autobid_plans FROM anon, authenticated;
REVOKE ALL ON public.player_draft_autobid_targets FROM anon, authenticated;

ALTER TABLE public.global_settings
  ADD COLUMN IF NOT EXISTS draft_autobid_paused boolean NOT NULL DEFAULT false;

-- ---------------------------------------------------------------------------
-- 2. Inbox message types (keeps every existing type)
-- ---------------------------------------------------------------------------
DO $inbox_types$
DECLARE
  v_def text;
  v_list text;
BEGIN
  SELECT pg_get_constraintdef(c.oid)
  INTO v_def
  FROM pg_constraint c
  WHERE c.conrelid = 'public.competition_inbox'::regclass
    AND c.conname = 'competition_inbox_message_type_check';

  IF v_def IS NULL THEN
    RETURN;
  END IF;

  SELECT string_agg(quote_literal(t), ', ' ORDER BY t)
  INTO v_list
  FROM (
    SELECT DISTINCT message_type AS t
    FROM public.competition_inbox
    WHERE message_type IS NOT NULL
    UNION
    SELECT (regexp_matches(v_def, '''([^'']+)''', 'g'))[1]
    UNION
    SELECT unnest(ARRAY['draft_autobid_live', 'draft_autobid_summary'])
  ) s
  WHERE t IS NOT NULL AND btrim(t) <> '';

  ALTER TABLE public.competition_inbox
    DROP CONSTRAINT IF EXISTS competition_inbox_message_type_check;

  EXECUTE format(
    'ALTER TABLE public.competition_inbox
       ADD CONSTRAINT competition_inbox_message_type_check
       CHECK (message_type IN (%s)) NOT VALID',
    v_list
  );

  ALTER TABLE public.competition_inbox
    VALIDATE CONSTRAINT competition_inbox_message_type_check;
END;
$inbox_types$;

-- ---------------------------------------------------------------------------
-- 3. Helpers
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.player_draft_autobid_money(p_amount numeric)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT '₿' || to_char(coalesce(p_amount, 0), 'FM999,999,999,990');
$$;

CREATE OR REPLACE FUNCTION public.player_draft_autobid_inbox(
  p_type text,
  p_title text,
  p_body text,
  p_club text,
  p_dedupe text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  BEGIN
    PERFORM public.owner_inbox_send(
      p_type, p_title, p_body, p_club, NULL::uuid,
      NULL::bigint, NULL::bigint, NULL::bigint, NULL::bigint,
      'scouting.html', p_dedupe, NULL::text, NULL::bigint, NULL::bigint
    );
  EXCEPTION WHEN undefined_function THEN
    PERFORM public.owner_inbox_send(
      p_type, p_title, p_body, p_club, NULL::uuid,
      NULL::bigint, NULL::bigint, NULL::bigint, NULL::bigint,
      'scouting.html', p_dedupe, NULL::text, NULL::bigint
    );
  END;
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING 'draft autobid inbox (%/%) failed: %', p_type, p_club, SQLERRM;
END;
$function$;

-- Current leader of a draft thread within a window.
CREATE OR REPLACE FUNCTION public.player_draft_autobid_leader(
  p_player_id text,
  p_start timestamptz,
  p_end timestamptz
)
RETURNS text
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT b.bidder_club_id
  FROM public."Player_Transfer_Bids" b
  WHERE coalesce(b.player_id, b.direct_bid_id::text) = btrim(p_player_id)
    AND b.is_direct = true
    AND b.seller_club_id IS NULL
    AND b.bid_time >= p_start
    AND b.bid_time < p_end
  ORDER BY b.bid_amount DESC, b.bid_time DESC
  LIMIT 1;
$$;

CREATE OR REPLACE FUNCTION public.player_draft_autobid_high_bid(
  p_player_id text,
  p_start timestamptz,
  p_end timestamptz
)
RETURNS numeric
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT max(b.bid_amount)
  FROM public."Player_Transfer_Bids" b
  WHERE coalesce(b.player_id, b.direct_bid_id::text) = btrim(p_player_id)
    AND b.is_direct = true
    AND b.seller_club_id IS NULL
    AND b.bid_time >= p_start
    AND b.bid_time < p_end;
$$;

-- Club-wide draft threads that may still end up in the squad: the club leads,
-- or holds a current max bid that can still beat the next minimum.
CREATE OR REPLACE FUNCTION public.player_draft_autobid_club_inplay(
  p_club text,
  p_start timestamptz,
  p_end timestamptz
)
RETURNS TABLE (out_player_id text, out_rating int, out_leading boolean)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  WITH mine AS (
    SELECT DISTINCT coalesce(b.player_id, b.direct_bid_id::text) AS pid
    FROM public."Player_Transfer_Bids" b
    WHERE b.bidder_club_id = p_club
      AND b.is_direct = true
      AND b.seller_club_id IS NULL
      AND b.bid_time >= p_start
      AND b.bid_time < p_end
  ),
  led AS (
    SELECT m.pid, public.player_draft_autobid_leader(m.pid, p_start, p_end) AS leader
    FROM mine m
  )
  SELECT l.pid, public.club_squad_player_rating(l.pid), (l.leader = p_club)
  FROM led l
  WHERE l.leader = p_club
     OR EXISTS (
       SELECT 1
       FROM public.player_draft_max_bids x
       WHERE x.club_short_name = p_club
         AND x.player_id = l.pid
         AND x.updated_at >= p_start
         AND x.max_amount >= public.player_draft_min_next_bid(l.pid)
     );
$$;

-- Removes max bid rows the plan wrote (never a max the owner set by hand).
CREATE OR REPLACE FUNCTION public.player_draft_autobid_clear_target_max(p_target_id bigint)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  t record;
BEGIN
  SELECT tg.player_id, tg.max_set_amount, pl.club_short_name
  INTO t
  FROM public.player_draft_autobid_targets tg
  JOIN public.player_draft_autobid_plans pl ON pl.id = tg.plan_id
  WHERE tg.id = p_target_id;

  IF NOT FOUND OR t.max_set_amount IS NULL THEN
    RETURN;
  END IF;

  DELETE FROM public.player_draft_max_bids m
  WHERE m.club_short_name = t.club_short_name
    AND m.player_id = t.player_id
    AND m.max_amount = t.max_set_amount;

  UPDATE public.player_draft_autobid_targets
  SET max_set_amount = NULL, updated_at = now()
  WHERE id = p_target_id;
END;
$function$;

-- ---------------------------------------------------------------------------
-- 4. Owner RPCs
-- ---------------------------------------------------------------------------

-- Drafts an owner can plan for: the current one (if not ended) plus scheduled
-- player drafts from the events planner. Entries within 12h are merged.
CREATE OR REPLACE FUNCTION public.player_draft_autobid_draft_options()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := public.my_club_shortname();
  b record;
  v_out jsonb := '[]'::jsonb;
  v_starts timestamptz[] := ARRAY[]::timestamptz[];
  e record;
  v_live boolean;
BEGIN
  SELECT * INTO b FROM public.draft_auction_window_bounds();

  IF coalesce(b.draft_enabled, false) AND b.draft_start IS NOT NULL
     AND now() < b.draft_window_end THEN
    v_live := now() >= b.draft_start;
    v_out := v_out || jsonb_build_array(jsonb_build_object(
      'start_at', b.draft_start,
      'cutoff_at', b.draft_cutoff,
      'label', CASE WHEN v_live THEN 'Live now — ' ELSE 'Next — ' END
        || to_char(b.draft_start AT TIME ZONE 'Europe/London', 'Dy DD Mon HH24:MI'),
      'live', v_live,
      'source', 'settings'
    ));
    v_starts := v_starts || b.draft_start;
  END IF;

  FOR e IN
    SELECT pe.starts_at, pe.title
    FROM public.gpsl_planned_events pe
    WHERE pe.kind = 'player_draft'
      AND pe.starts_at > now()
      AND pe.auto_status <> 'cancelled'
    ORDER BY pe.starts_at
    LIMIT 8
  LOOP
    CONTINUE WHEN EXISTS (
      SELECT 1 FROM unnest(v_starts) s
      WHERE abs(extract(epoch FROM (s - e.starts_at))) <= 43200
    );
    v_out := v_out || jsonb_build_array(jsonb_build_object(
      'start_at', e.starts_at,
      'cutoff_at', e.starts_at + interval '23 hours',
      'label', to_char(e.starts_at AT TIME ZONE 'Europe/London', 'Dy DD Mon HH24:MI')
        || coalesce(' — ' || nullif(btrim(e.title), ''), ''),
      'live', false,
      'source', 'planner'
    ));
    v_starts := v_starts || e.starts_at;
  END LOOP;

  -- Mark which options already have a plan for my club
  IF v_club IS NOT NULL THEN
    SELECT coalesce(jsonb_agg(
      o || jsonb_build_object('has_plan', EXISTS (
        SELECT 1 FROM public.player_draft_autobid_plans p
        WHERE p.club_short_name = v_club
          AND p.status IN ('scheduled', 'live')
          AND abs(extract(epoch FROM (p.draft_start_at - (o->>'start_at')::timestamptz))) <= 43200
      ))
    ), '[]'::jsonb)
    INTO v_out
    FROM jsonb_array_elements(v_out) o;
  END IF;

  RETURN v_out;
END;
$function$;

CREATE OR REPLACE FUNCTION public.player_draft_autobid_get(p_draft_start timestamptz)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := public.my_club_shortname();
  b record;
  pl public.player_draft_autobid_plans%rowtype;
  v_paused boolean;
  v_live boolean := false;
  v_ws timestamptz;
  v_we timestamptz;
  v_targets jsonb;
BEGIN
  IF v_club IS NULL THEN
    RAISE EXCEPTION 'No club linked to your account';
  END IF;

  SELECT coalesce(gs.draft_autobid_paused, false) INTO v_paused
  FROM public.global_settings gs WHERE gs.id = 1;

  SELECT * INTO b FROM public.draft_auction_window_bounds();

  SELECT * INTO pl
  FROM public.player_draft_autobid_plans p
  WHERE p.club_short_name = v_club
    AND abs(extract(epoch FROM (p.draft_start_at - p_draft_start))) <= 43200
  ORDER BY (p.status IN ('scheduled', 'live')) DESC, p.updated_at DESC
  LIMIT 1;

  IF FOUND THEN
    v_ws := coalesce(pl.live_window_start, CASE
      WHEN b.draft_start IS NOT NULL
       AND abs(extract(epoch FROM (pl.draft_start_at - b.draft_start))) <= 43200
      THEN b.draft_start END);
    v_we := coalesce(pl.live_window_end, CASE WHEN v_ws IS NOT NULL THEN b.draft_window_end END);
    v_live := v_ws IS NOT NULL AND now() >= v_ws AND now() < coalesce(v_we, v_ws);

    SELECT coalesce(jsonb_agg(jsonb_build_object(
      'player_id', t.player_id,
      'name', p."Name",
      'position', p."Position",
      'rating', public.club_squad_player_rating(t.player_id),
      'market_value', p.market_value,
      'contracted_team', p."Contracted_Team",
      'priority', t.priority,
      'max_amount', t.max_amount,
      'included', t.included,
      'allow_open', t.allow_open,
      'state', t.state,
      'state_note', t.state_note,
      'entered_via', t.entered_via,
      'leader', CASE WHEN v_ws IS NOT NULL
        THEN public.player_draft_autobid_leader(t.player_id, v_ws, coalesce(v_we, v_ws + interval '1 day')) END,
      'high_bid', CASE WHEN v_ws IS NOT NULL
        THEN public.player_draft_autobid_high_bid(t.player_id, v_ws, coalesce(v_we, v_ws + interval '1 day')) END
    ) ORDER BY t.priority, t.id), '[]'::jsonb)
    INTO v_targets
    FROM public.player_draft_autobid_targets t
    LEFT JOIN public."Players" p ON p."Konami_ID"::text = t.player_id
    WHERE t.plan_id = pl.id;
  END IF;

  RETURN jsonb_build_object(
    'club_short_name', v_club,
    'paused', v_paused,
    'is_admin', public.is_gpsl_admin(),
    'draft_live', v_live,
    'plan', CASE WHEN pl.id IS NULL THEN NULL ELSE jsonb_build_object(
      'id', pl.id,
      'draft_start_at', pl.draft_start_at,
      'draft_label', pl.draft_label,
      'source_board', pl.source_board,
      'spend_cap', pl.spend_cap,
      'max_wins', pl.max_wins,
      'enabled', pl.enabled,
      'status', pl.status,
      'live_at', pl.live_at,
      'finished_at', pl.finished_at,
      'last_run_at', pl.last_run_at,
      'last_error', pl.last_error,
      'updated_at', pl.updated_at
    ) END,
    'targets', coalesce(v_targets, '[]'::jsonb)
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.player_draft_autobid_save(
  p_draft_start timestamptz,
  p_draft_label text,
  p_source_board int,
  p_spend_cap numeric,
  p_max_wins int,
  p_enabled boolean,
  p_targets jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := public.my_club_shortname();
  pl public.player_draft_autobid_plans%rowtype;
  v_ids text[];
  r record;
  e jsonb;
  v_pid text;
  v_max numeric;
  v_n int := 0;
BEGIN
  IF v_club IS NULL THEN
    RAISE EXCEPTION 'No club linked to your account';
  END IF;
  IF p_draft_start IS NULL THEN
    RAISE EXCEPTION 'Choose a player draft';
  END IF;
  IF p_draft_start < now() - interval '1 day' THEN
    RAISE EXCEPTION 'That player draft has already finished';
  END IF;
  IF jsonb_typeof(coalesce(p_targets, '[]'::jsonb)) <> 'array' THEN
    RAISE EXCEPTION 'Targets must be a list';
  END IF;
  IF jsonb_array_length(coalesce(p_targets, '[]'::jsonb)) > 60 THEN
    RAISE EXCEPTION 'A plan can hold at most 60 targets';
  END IF;
  IF p_spend_cap IS NOT NULL AND p_spend_cap <= 0 THEN
    RAISE EXCEPTION 'Spend cap must be above zero (or left blank)';
  END IF;
  IF p_max_wins IS NOT NULL AND (p_max_wins < 1 OR p_max_wins > 28) THEN
    RAISE EXCEPTION 'Max players to win must be between 1 and 28 (or left blank)';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtext('gpsl_autobid_club:' || v_club));

  SELECT * INTO pl
  FROM public.player_draft_autobid_plans p
  WHERE p.club_short_name = v_club
    AND abs(extract(epoch FROM (p.draft_start_at - p_draft_start))) <= 43200
  ORDER BY (p.status IN ('scheduled', 'live')) DESC, p.updated_at DESC
  LIMIT 1
  FOR UPDATE;

  IF FOUND AND pl.status IN ('finished', 'expired') THEN
    RAISE EXCEPTION 'That player draft has already finished';
  END IF;

  IF NOT FOUND THEN
    INSERT INTO public.player_draft_autobid_plans (
      club_short_name, owner_id, draft_start_at, draft_label, source_board,
      spend_cap, max_wins, enabled
    )
    VALUES (
      v_club, auth.uid(), p_draft_start, nullif(btrim(p_draft_label), ''), p_source_board,
      p_spend_cap, p_max_wins, coalesce(p_enabled, true)
    )
    RETURNING * INTO pl;
  ELSE
    UPDATE public.player_draft_autobid_plans
    SET owner_id = coalesce(auth.uid(), owner_id),
        draft_label = coalesce(nullif(btrim(p_draft_label), ''), draft_label),
        source_board = p_source_board,
        spend_cap = p_spend_cap,
        max_wins = p_max_wins,
        enabled = coalesce(p_enabled, true),
        last_error = NULL,
        updated_at = now()
    WHERE id = pl.id
    RETURNING * INTO pl;
  END IF;

  SELECT coalesce(array_agg(DISTINCT btrim(x->>'player_id')), ARRAY[]::text[])
  INTO v_ids
  FROM jsonb_array_elements(coalesce(p_targets, '[]'::jsonb)) x
  WHERE nullif(btrim(x->>'player_id'), '') IS NOT NULL;

  -- Removed targets: drop the plan's own max bids first (bids already placed stay)
  FOR r IN
    SELECT t.id FROM public.player_draft_autobid_targets t
    WHERE t.plan_id = pl.id AND NOT (t.player_id = ANY (v_ids))
  LOOP
    PERFORM public.player_draft_autobid_clear_target_max(r.id);
    DELETE FROM public.player_draft_autobid_targets WHERE id = r.id;
  END LOOP;

  FOR e IN SELECT * FROM jsonb_array_elements(coalesce(p_targets, '[]'::jsonb))
  LOOP
    v_pid := nullif(btrim(e->>'player_id'), '');
    CONTINUE WHEN v_pid IS NULL;
    v_max := nullif(e->>'max_amount', '')::numeric;
    IF v_max IS NULL OR v_max <= 0 THEN
      RAISE EXCEPTION 'Every target needs a max bid above zero';
    END IF;
    v_n := v_n + 1;

    INSERT INTO public.player_draft_autobid_targets (
      plan_id, player_id, priority, max_amount, included, allow_open
    )
    VALUES (
      pl.id, v_pid,
      coalesce(nullif(e->>'priority', '')::int, v_n),
      v_max,
      coalesce((e->>'included')::boolean, true),
      coalesce((e->>'allow_open')::boolean, true)
    )
    ON CONFLICT (plan_id, player_id) DO UPDATE
    SET priority = excluded.priority,
        max_amount = excluded.max_amount,
        included = excluded.included,
        allow_open = excluded.allow_open,
        state = CASE
          WHEN player_draft_autobid_targets.state = 'ineligible'
            OR player_draft_autobid_targets.state = 'excluded'
          THEN 'pending'
          ELSE player_draft_autobid_targets.state
        END,
        state_note = CASE
          WHEN player_draft_autobid_targets.state IN ('ineligible', 'excluded') THEN NULL
          ELSE player_draft_autobid_targets.state_note
        END,
        updated_at = now();
  END LOOP;

  -- Excluded targets / plan switched off: stop the plan's max bids defending
  FOR r IN
    SELECT t.id, t.included FROM public.player_draft_autobid_targets t
    WHERE t.plan_id = pl.id
      AND (NOT t.included OR NOT pl.enabled)
  LOOP
    PERFORM public.player_draft_autobid_clear_target_max(r.id);
    IF NOT r.included THEN
      UPDATE public.player_draft_autobid_targets
      SET state = 'excluded', state_note = NULL, updated_at = now()
      WHERE id = r.id;
    END IF;
  END LOOP;

  RETURN public.player_draft_autobid_get(pl.draft_start_at);
END;
$function$;

CREATE OR REPLACE FUNCTION public.player_draft_autobid_delete(p_draft_start timestamptz)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := public.my_club_shortname();
  pl record;
  r record;
BEGIN
  IF v_club IS NULL THEN
    RAISE EXCEPTION 'No club linked to your account';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtext('gpsl_autobid_club:' || v_club));

  FOR pl IN
    SELECT p.id FROM public.player_draft_autobid_plans p
    WHERE p.club_short_name = v_club
      AND p.status IN ('scheduled', 'live')
      AND abs(extract(epoch FROM (p.draft_start_at - p_draft_start))) <= 43200
  LOOP
    FOR r IN SELECT t.id FROM public.player_draft_autobid_targets t WHERE t.plan_id = pl.id
    LOOP
      PERFORM public.player_draft_autobid_clear_target_max(r.id);
    END LOOP;
    DELETE FROM public.player_draft_autobid_plans WHERE id = pl.id;
  END LOOP;

  RETURN jsonb_build_object('ok', true);
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_set_draft_autobid_paused(p_paused boolean)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF NOT public.is_gpsl_admin()
     AND session_user NOT IN ('postgres', 'supabase_admin', 'service_role') THEN
    RAISE EXCEPTION 'Admins only';
  END IF;
  UPDATE public.global_settings
  SET draft_autobid_paused = coalesce(p_paused, false)
  WHERE id = 1;
  RETURN jsonb_build_object('ok', true, 'paused', coalesce(p_paused, false));
END;
$function$;

-- ---------------------------------------------------------------------------
-- 5. Engine
-- ---------------------------------------------------------------------------

-- One pass of one plan. Returns the number of bids / max changes made.
CREATE OR REPLACE FUNCTION public.player_draft_autobid_run_plan(p_plan_id bigint)
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  pl public.player_draft_autobid_plans%rowtype;
  b record;
  t record;
  v_club text;
  v_pid text;
  v_leader text;
  v_min numeric;
  v_cur_max numeric;
  v_eff_max numeric;
  v_set numeric;
  v_state text;
  v_note text;
  v_res jsonb;
  v_err text;
  v_credits int;
  v_n int;
  v_actions int := 0;
  v_pass int := 0;
  v_progress boolean;
  v_star_min int;
  v_star_cap int;
  v_ooo text;
  v_squad int;
  v_stars int;
  v_club_inplay int;
  v_club_inplay_stars int;
  v_plan_inplay int;
  v_plan_commit numeric;
  v_rating int;
  v_via text;
  v_window bigint[];
  v_phase int;
BEGIN
  SELECT p.club_short_name INTO v_club
  FROM public.player_draft_autobid_plans p WHERE p.id = p_plan_id;
  IF v_club IS NULL THEN
    RETURN 0;
  END IF;

  PERFORM pg_advisory_xact_lock(hashtext('gpsl_autobid_club:' || v_club));

  SELECT * INTO pl FROM public.player_draft_autobid_plans WHERE id = p_plan_id FOR UPDATE;
  IF NOT FOUND OR NOT pl.enabled OR pl.status NOT IN ('scheduled', 'live') THEN
    RETURN 0;
  END IF;

  SELECT * INTO b FROM public.draft_auction_window_bounds();
  IF NOT coalesce(b.draft_enabled, false) OR b.draft_start IS NULL
     OR now() < b.draft_start OR now() >= b.draft_window_end THEN
    RETURN 0;
  END IF;

  IF pl.status = 'scheduled' THEN
    UPDATE public.player_draft_autobid_plans
    SET status = 'live',
        live_at = now(),
        live_window_start = b.draft_start,
        live_window_end = b.draft_window_end,
        updated_at = now()
    WHERE id = pl.id;

    PERFORM public.player_draft_autobid_inbox(
      'draft_autobid_live',
      'Your auto-bid plan is live',
      format(
        'The player draft has opened and your auto-bid plan is now working through %s target(s). '
        || 'It works your top targets in priority order — opening fresh threads first, then joining other clubs'' threads with the credits earned — and bids up to your max on each. '
        || 'New opens and joins stop at the cutoff. You can change or switch off the plan in Scouting → Target lists.',
        (SELECT count(*) FROM public.player_draft_autobid_targets tc
         WHERE tc.plan_id = pl.id AND tc.included)
      ),
      v_club,
      'draft_autobid_live:' || pl.id
    );
  ELSIF pl.live_window_end IS DISTINCT FROM b.draft_window_end THEN
    UPDATE public.player_draft_autobid_plans
    SET live_window_start = b.draft_start, live_window_end = b.draft_window_end
    WHERE id = pl.id;
  END IF;

  v_star_min := public.club_squad_star_min_rating();
  v_star_cap := public.club_squad_star_cap(v_club);

  SELECT d.player_id INTO v_ooo
  FROM public.club_squad_player_designations d
  WHERE d.club_short_name = v_club AND d.designation = 'one_of_our_own'
  LIMIT 1;

  SELECT count(*)::int,
         count(*) FILTER (
           WHERE coalesce(public.club_squad_player_rating(p."Konami_ID"::text), 0) >= v_star_min
             AND (v_ooo IS NULL OR p."Konami_ID"::text <> v_ooo)
         )::int
  INTO v_squad, v_stars
  FROM public."Players" p
  WHERE p."Contracted_Team" = v_club;

  LOOP
    v_pass := v_pass + 1;
    EXIT WHEN v_pass > 4;
    v_progress := false;

    -- A) Threads the club is already in: keep the plan's max set, let it defend
    FOR t IN
      SELECT * FROM public.player_draft_autobid_targets
      WHERE plan_id = pl.id AND included
      ORDER BY priority, id
    LOOP
      v_pid := t.player_id;

      IF EXISTS (
        SELECT 1 FROM public."Players" p
        WHERE p."Konami_ID"::text = v_pid AND p."Contracted_Team" = v_club
      ) THEN
        IF t.state IS DISTINCT FROM 'owned' AND t.state IS DISTINCT FROM 'won' THEN
          UPDATE public.player_draft_autobid_targets
          SET state = CASE WHEN t.entered_via IS NULL THEN 'owned' ELSE 'won' END,
              state_note = NULL, updated_at = now()
          WHERE id = t.id;
        END IF;
        CONTINUE;
      END IF;

      CONTINUE WHEN NOT public.player_draft_club_has_bid(v_club, v_pid);

      v_set := t.max_set_amount;
      SELECT m.max_amount INTO v_cur_max
      FROM public.player_draft_max_bids m
      WHERE m.club_short_name = v_club AND m.player_id = v_pid;

      IF NOT FOUND THEN
        INSERT INTO public.player_draft_max_bids (club_short_name, player_id, max_amount, updated_at)
        VALUES (v_club, v_pid, t.max_amount, now())
        ON CONFLICT (club_short_name, player_id) DO NOTHING;
        v_set := t.max_amount;
        v_actions := v_actions + 1;
      ELSIF t.max_set_amount IS NOT NULL
        AND v_cur_max = t.max_set_amount
        AND v_cur_max <> t.max_amount THEN
        UPDATE public.player_draft_max_bids
        SET max_amount = t.max_amount, updated_at = now()
        WHERE club_short_name = v_club AND player_id = v_pid;
        v_set := t.max_amount;
        v_actions := v_actions + 1;
      END IF;

      SELECT m.max_amount INTO v_eff_max
      FROM public.player_draft_max_bids m
      WHERE m.club_short_name = v_club AND m.player_id = v_pid;
      v_eff_max := coalesce(v_eff_max, t.max_amount);

      v_leader := public.player_draft_autobid_leader(v_pid, b.draft_start, b.draft_window_end);
      v_min := public.player_draft_min_next_bid(v_pid);

      IF v_leader IS DISTINCT FROM v_club AND v_min <= v_eff_max THEN
        PERFORM set_config('gpsl.max_bid_resolving', '', true);
        v_n := public.player_draft_resolve_max_bids(v_pid);
        IF coalesce(v_n, 0) > 0 THEN
          v_actions := v_actions + v_n;
        END IF;
        v_leader := public.player_draft_autobid_leader(v_pid, b.draft_start, b.draft_window_end);
        v_min := public.player_draft_min_next_bid(v_pid);
      END IF;

      v_state := CASE
        WHEN v_leader = v_club THEN 'leading'
        WHEN v_min > v_eff_max THEN 'beaten'
        ELSE 'in_play'
      END;

      UPDATE public.player_draft_autobid_targets
      SET state = v_state,
          state_note = CASE WHEN v_state = 'beaten'
            THEN 'Bidding passed your max of ' || public.player_draft_autobid_money(v_eff_max) END,
          entered_via = coalesce(entered_via, 'manual'),
          max_set_amount = v_set,
          last_action_at = CASE WHEN t.state IS DISTINCT FROM v_state THEN now() ELSE last_action_at END,
          updated_at = now()
      WHERE id = t.id
        AND (state IS DISTINCT FROM v_state
          OR max_set_amount IS DISTINCT FROM v_set
          OR entered_via IS NULL);
    END LOOP;

    -- B) Threads not yet entered. With max players = N only the top N
    -- targets not already at the club are worked: phase 1 opens fresh threads
    -- (earning credits), phase 2 joins other clubs' threads with them.
    v_window := NULL;
    IF pl.max_wins IS NOT NULL THEN
      SELECT coalesce(array_agg(w.id), '{}'::bigint[]) INTO v_window
      FROM (
        SELECT tw.id FROM public.player_draft_autobid_targets tw
        WHERE tw.plan_id = pl.id AND tw.included
          AND tw.state IS DISTINCT FROM 'owned'
        ORDER BY tw.priority, tw.id
        LIMIT pl.max_wins
      ) w;

      UPDATE public.player_draft_autobid_targets tx
      SET state = 'skipped',
          state_note = format('Outside your top %s', pl.max_wins),
          updated_at = now()
      WHERE tx.plan_id = pl.id AND tx.included
        AND NOT (tx.id = ANY(v_window))
        AND tx.state NOT IN ('owned', 'won', 'leading', 'in_play', 'beaten')
        AND (tx.state IS DISTINCT FROM 'skipped'
          OR tx.state_note IS DISTINCT FROM format('Outside your top %s', pl.max_wins));
    END IF;

    FOR v_phase IN 1..2 LOOP
    FOR t IN
      SELECT * FROM public.player_draft_autobid_targets
      WHERE plan_id = pl.id AND included
        AND state NOT IN ('ineligible', 'owned', 'won')
        AND (v_window IS NULL OR id = ANY(v_window))
      ORDER BY priority, id
    LOOP
      v_pid := t.player_id;
      CONTINUE WHEN public.player_draft_club_has_bid(v_club, v_pid);

      v_leader := public.player_draft_autobid_leader(v_pid, b.draft_start, b.draft_window_end);
      CONTINUE WHEN v_phase = 1 AND v_leader IS NOT NULL;
      v_min := public.player_draft_min_next_bid(v_pid);
      v_state := NULL;
      v_note := NULL;

      IF v_min IS NULL THEN
        v_state := 'ineligible';
        v_note := 'No market value';
      ELSIF v_min > t.max_amount THEN
        v_state := 'priced_out';
        v_note := 'Next bid ' || public.player_draft_autobid_money(v_min)
          || ' is above your max of ' || public.player_draft_autobid_money(t.max_amount);
      ELSIF now() >= b.draft_cutoff THEN
        v_state := 'cutoff';
        v_note := 'Cutoff passed before it could be entered';
      ELSIF v_leader IS NULL AND NOT t.allow_open THEN
        v_state := 'waiting_open';
        v_note := 'Waiting for another club to open the thread';
      END IF;

      IF v_state IS NULL THEN
        -- Plan caps (spend / wins) count plan targets still in play
        SELECT count(*)::int, coalesce(sum(greatest(
                 tt.max_amount,
                 coalesce(public.player_draft_autobid_high_bid(tt.player_id, b.draft_start, b.draft_window_end), 0)
               )), 0)
        INTO v_plan_inplay, v_plan_commit
        FROM public.player_draft_autobid_targets tt
        WHERE tt.plan_id = pl.id
          AND tt.id <> t.id
          AND tt.state IN ('leading', 'in_play');

        -- Squad rules count every live thread the club could still win
        SELECT count(*)::int,
               count(*) FILTER (WHERE coalesce(ip.out_rating, 0) >= v_star_min)::int
        INTO v_club_inplay, v_club_inplay_stars
        FROM public.player_draft_autobid_club_inplay(v_club, b.draft_start, b.draft_window_end) ip
        WHERE ip.out_player_id <> v_pid;

        v_rating := coalesce(public.club_squad_player_rating(v_pid), 0);

        IF pl.spend_cap IS NOT NULL AND v_plan_commit + t.max_amount > pl.spend_cap THEN
          v_state := 'skipped';
          v_note := 'Spend cap: ' || public.player_draft_autobid_money(v_plan_commit)
            || ' already committed of ' || public.player_draft_autobid_money(pl.spend_cap);
        ELSIF v_squad + v_club_inplay + 1 > 28 THEN
          v_state := 'skipped';
          v_note := format('Squad would exceed 28 (%s signed + %s in play)', v_squad, v_club_inplay);
        ELSIF v_rating >= v_star_min AND v_stars + v_club_inplay_stars + 1 > v_star_cap THEN
          v_state := 'skipped';
          v_note := format('Star cap %s reached (%s stars + %s in play)', v_star_cap, v_stars, v_club_inplay_stars);
        END IF;
      END IF;

      IF v_state IS NULL AND v_leader IS NOT NULL THEN
        v_credits := public.club_draft_auction_credits(
          v_club, b.draft_start, b.draft_cutoff, b.draft_window_end
        );
        IF coalesce(v_credits, 0) <= 0 THEN
          v_state := 'waiting_credits';
          v_note := 'Waiting for a free credit to join';
        END IF;
      END IF;

      IF v_state IS NOT NULL THEN
        UPDATE public.player_draft_autobid_targets
        SET state = v_state, state_note = v_note, updated_at = now()
        WHERE id = t.id
          AND (state IS DISTINCT FROM v_state OR state_note IS DISTINCT FROM v_note);
        CONTINUE;
      END IF;

      -- Enter: set the max first, then bid the minimum (the bid trigger lets
      -- every club's max bid respond).
      v_via := CASE WHEN v_leader IS NULL THEN 'opened' ELSE 'joined' END;
      v_err := NULL;
      BEGIN
        INSERT INTO public.player_draft_max_bids (club_short_name, player_id, max_amount, updated_at)
        VALUES (v_club, v_pid, t.max_amount, now())
        ON CONFLICT (club_short_name, player_id) DO UPDATE
        SET max_amount = excluded.max_amount, updated_at = now();

        PERFORM set_config('gpsl.max_bid_resolving', '', true);
        v_res := public.player_draft_place_auto_bid(v_club, v_pid, v_min);

        IF coalesce(v_res->>'skipped', '') <> '' OR coalesce((v_res->>'ok')::boolean, false) IS NOT TRUE THEN
          RAISE EXCEPTION 'autobid_skip:%', coalesce(nullif(v_res->>'skipped', ''), 'failed');
        END IF;
      EXCEPTION WHEN OTHERS THEN
        v_err := SQLERRM;
      END;

      IF v_err IS NOT NULL THEN
        IF v_err LIKE 'autobid_skip:no_credits%' THEN
          v_state := 'waiting_credits';
          v_note := 'Waiting for a free credit to join';
        ELSIF v_err LIKE 'autobid_skip:cutoff%' THEN
          v_state := 'cutoff';
          v_note := 'Cutoff passed before it could be entered';
        ELSIF v_err LIKE 'autobid_skip:below_min%' THEN
          v_state := 'priced_out';
          v_note := 'Price moved above your max';
        ELSIF v_err LIKE 'autobid_skip:%' THEN
          v_state := 'waiting_open';
          v_note := 'Draft not accepting bids right now (' || replace(v_err, 'autobid_skip:', '') || ')';
        ELSE
          v_state := 'ineligible';
          v_note := left(v_err, 240);
        END IF;
        UPDATE public.player_draft_autobid_targets
        SET state = v_state, state_note = v_note, updated_at = now()
        WHERE id = t.id;
        CONTINUE;
      END IF;

      v_leader := public.player_draft_autobid_leader(v_pid, b.draft_start, b.draft_window_end);
      v_min := public.player_draft_min_next_bid(v_pid);

      UPDATE public.player_draft_autobid_targets
      SET state = CASE
            WHEN v_leader = v_club THEN 'leading'
            WHEN v_min > t.max_amount THEN 'beaten'
            ELSE 'in_play'
          END,
          state_note = CASE WHEN v_leader IS DISTINCT FROM v_club AND v_min > t.max_amount
            THEN 'Bidding passed your max of ' || public.player_draft_autobid_money(t.max_amount) END,
          entered_via = v_via,
          max_set_amount = t.max_amount,
          last_action_at = now(),
          updated_at = now()
      WHERE id = t.id;

      v_actions := v_actions + 1;
      v_progress := true;
    END LOOP;
    END LOOP;

    EXIT WHEN NOT v_progress;
  END LOOP;

  UPDATE public.player_draft_autobid_plans
  SET last_run_at = now(), last_error = NULL
  WHERE id = pl.id;

  RETURN v_actions;
END;
$function$;

-- Close plans whose draft has ended: final states, remove the plan's max bids,
-- inbox summary. Plans whose draft never ran just expire quietly.
CREATE OR REPLACE FUNCTION public.player_draft_autobid_finish_due()
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  b record;
  pl record;
  t record;
  v_end timestamptz;
  v_leader text;
  v_done int := 0;
  v_opened int;
  v_joined int;
  v_won int;
  v_lost int;
  v_skipped int;
  v_never int;
  v_won_names text;
  v_body text;
BEGIN
  SELECT * INTO b FROM public.draft_auction_window_bounds();

  FOR pl IN
    SELECT * FROM public.player_draft_autobid_plans
    WHERE status IN ('scheduled', 'live')
    ORDER BY id
  LOOP
    v_end := coalesce(
      pl.live_window_end,
      CASE WHEN b.draft_start IS NOT NULL
            AND abs(extract(epoch FROM (pl.draft_start_at - b.draft_start))) <= 43200
           THEN b.draft_window_end END,
      pl.draft_start_at + interval '24 hours'
    );
    CONTINUE WHEN now() < v_end + interval '10 minutes';

    PERFORM pg_advisory_xact_lock(hashtext('gpsl_autobid_club:' || pl.club_short_name));

    IF pl.status = 'live' AND pl.live_window_start IS NOT NULL THEN
      FOR t IN
        SELECT * FROM public.player_draft_autobid_targets
        WHERE plan_id = pl.id AND included
      LOOP
        IF EXISTS (
          SELECT 1 FROM public."Players" p
          WHERE p."Konami_ID"::text = t.player_id AND p."Contracted_Team" = pl.club_short_name
        ) AND t.state = 'owned' THEN
          CONTINUE;
        END IF;

        v_leader := public.player_draft_autobid_leader(t.player_id, pl.live_window_start, pl.live_window_end);
        IF v_leader = pl.club_short_name THEN
          UPDATE public.player_draft_autobid_targets
          SET state = 'won', state_note = NULL, updated_at = now() WHERE id = t.id;
        ELSIF t.entered_via IS NOT NULL
           OR public.player_draft_club_has_bid(pl.club_short_name, t.player_id) THEN
          UPDATE public.player_draft_autobid_targets
          SET state = 'lost',
              state_note = coalesce(t.state_note, 'Outbid'),
              updated_at = now()
          WHERE id = t.id;
        END IF;
      END LOOP;

      SELECT
        count(*) FILTER (WHERE entered_via = 'opened'),
        count(*) FILTER (WHERE entered_via = 'joined'),
        count(*) FILTER (WHERE state = 'won'),
        count(*) FILTER (WHERE state = 'lost'),
        count(*) FILTER (WHERE state IN ('skipped', 'ineligible', 'priced_out')),
        count(*) FILTER (WHERE entered_via IS NULL
                           AND state NOT IN ('won', 'owned', 'skipped', 'ineligible', 'priced_out'))
      INTO v_opened, v_joined, v_won, v_lost, v_skipped, v_never
      FROM public.player_draft_autobid_targets
      WHERE plan_id = pl.id AND included;

      SELECT string_agg(coalesce(p."Name", tw.player_id), ', ' ORDER BY tw.priority)
      INTO v_won_names
      FROM public.player_draft_autobid_targets tw
      LEFT JOIN public."Players" p ON p."Konami_ID"::text = tw.player_id
      WHERE tw.plan_id = pl.id AND tw.included AND tw.state = 'won';

      v_body := format(
        'Your auto-bid plan has finished. Opened %s · Joined %s · Leading at the close %s · Outbid %s · Skipped %s · Never entered %s.',
        v_opened, v_joined, v_won, v_lost, v_skipped, v_never
      );
      IF v_won_names IS NOT NULL THEN
        v_body := v_body || ' Leading at the close: ' || v_won_names || '.';
      END IF;
      v_body := v_body || ' Full detail per player is in Scouting → Target lists → Auto-bid plan.';

      PERFORM public.player_draft_autobid_inbox(
        'draft_autobid_summary',
        'Auto-bid plan summary',
        v_body,
        pl.club_short_name,
        'draft_autobid_summary:' || pl.id
      );
    END IF;

    FOR t IN SELECT id FROM public.player_draft_autobid_targets WHERE plan_id = pl.id
    LOOP
      PERFORM public.player_draft_autobid_clear_target_max(t.id);
    END LOOP;

    UPDATE public.player_draft_autobid_plans
    SET status = CASE WHEN pl.status = 'live' THEN 'finished' ELSE 'expired' END,
        finished_at = now(),
        updated_at = now()
    WHERE id = pl.id;

    v_done := v_done + 1;
  END LOOP;

  RETURN v_done;
END;
$function$;

CREATE OR REPLACE FUNCTION public.player_draft_autobid_tick()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  b record;
  p record;
  v_paused boolean;
  v_finished int := 0;
  v_plans int := 0;
  v_actions int := 0;
  v_n int;
BEGIN
  IF NOT pg_try_advisory_xact_lock(hashtext('gpsl_draft_autobid_tick')) THEN
    RETURN jsonb_build_object('ok', true, 'skipped', 'busy');
  END IF;

  BEGIN
    v_finished := public.player_draft_autobid_finish_due();
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'draft autobid finish failed: %', SQLERRM;
  END;

  SELECT coalesce(gs.draft_autobid_paused, false) INTO v_paused
  FROM public.global_settings gs WHERE gs.id = 1;
  IF coalesce(v_paused, false) THEN
    RETURN jsonb_build_object('ok', true, 'skipped', 'paused', 'finished', v_finished);
  END IF;

  SELECT * INTO b FROM public.draft_auction_window_bounds();
  IF NOT coalesce(b.draft_enabled, false) OR b.draft_start IS NULL
     OR now() < b.draft_start OR now() >= b.draft_window_end THEN
    RETURN jsonb_build_object('ok', true, 'skipped', 'no_live_draft', 'finished', v_finished);
  END IF;

  FOR p IN
    SELECT pl.id
    FROM public.player_draft_autobid_plans pl
    WHERE pl.status IN ('scheduled', 'live')
      AND pl.enabled
      AND abs(extract(epoch FROM (pl.draft_start_at - b.draft_start))) <= 43200
    ORDER BY pl.created_at, pl.id
  LOOP
    BEGIN
      v_n := public.player_draft_autobid_run_plan(p.id);
      v_actions := v_actions + coalesce(v_n, 0);
      v_plans := v_plans + 1;
    EXCEPTION WHEN OTHERS THEN
      UPDATE public.player_draft_autobid_plans
      SET last_error = left(SQLERRM, 500), last_run_at = now()
      WHERE id = p.id;
    END;
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true, 'plans', v_plans, 'actions', v_actions, 'finished', v_finished
  );
END;
$function$;

-- ---------------------------------------------------------------------------
-- 6. Grants
-- ---------------------------------------------------------------------------
REVOKE ALL ON FUNCTION public.player_draft_autobid_tick() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.player_draft_autobid_run_plan(bigint) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.player_draft_autobid_finish_due() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.player_draft_autobid_clear_target_max(bigint) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.player_draft_autobid_inbox(text, text, text, text, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.player_draft_autobid_club_inplay(text, timestamptz, timestamptz) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.player_draft_autobid_leader(text, timestamptz, timestamptz) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.player_draft_autobid_high_bid(text, timestamptz, timestamptz) FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.player_draft_autobid_draft_options() TO authenticated;
GRANT EXECUTE ON FUNCTION public.player_draft_autobid_get(timestamptz) TO authenticated;
GRANT EXECUTE ON FUNCTION public.player_draft_autobid_save(timestamptz, text, int, numeric, int, boolean, jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.player_draft_autobid_delete(timestamptz) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_set_draft_autobid_paused(boolean) TO authenticated;

-- ---------------------------------------------------------------------------
-- 7. Cron (every minute; exits immediately when no player draft is live)
-- ---------------------------------------------------------------------------
DO $cron$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    BEGIN
      PERFORM cron.unschedule('gpsl-draft-autobid');
    EXCEPTION WHEN OTHERS THEN
      NULL;
    END;
    PERFORM cron.schedule(
      'gpsl-draft-autobid',
      '* * * * *',
      $job$SELECT public.player_draft_autobid_tick();$job$
    );
  ELSE
    RAISE NOTICE 'pg_cron not installed — schedule public.player_draft_autobid_tick() every minute manually';
  END IF;
END;
$cron$;

NOTIFY pgrst, 'reload schema';

-- Check
SELECT
  (SELECT count(*) FROM public.player_draft_autobid_plans) AS plans,
  (SELECT draft_autobid_paused FROM public.global_settings WHERE id = 1) AS paused,
  (SELECT count(*) FROM cron.job WHERE jobname = 'gpsl-draft-autobid') AS cron_jobs;
