-- =============================================================================
-- Admin: auto-bid plan TEST RUN (nothing is saved)
-- =============================================================================
-- admin_player_draft_autobid_simulate(...) pretends a player draft went live
-- an hour ago, builds the plan from the Scouting panel, and runs the REAL
-- engine (player_draft_autobid_run_plan → player_draft_place_auto_bid /
-- resolver / credits / triggers / inbox):
--   1. optional rival clubs open some of the targets first (tests "join")
--      and one rival holds a max above yours (tests "beaten")
--   2. engine pass 1
--   3. a rival outbids you where you lead (tests your max bid defending)
--   4. engine pass 2
--   5. the draft "ends" → finish + inbox summary
-- It records every step, then ROLLS EVERYTHING BACK (settings, listings, bids,
-- max bids, credits, plan rows, inbox, Discord queue). Nobody else sees it.
-- Refuses to run while a real player draft is live.
--
-- Safe re-run. Requires player_draft_autobid_plans_20261006.sql.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.admin_player_draft_autobid_simulate(
  p_targets jsonb,
  p_spend_cap numeric DEFAULT NULL,
  p_max_wins int DEFAULT NULL,
  p_rivals boolean DEFAULT true,
  p_club text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := coalesce(nullif(btrim(p_club), ''), public.my_club_shortname());
  b record;
  v_plan_id bigint;
  v_start timestamptz := now() - interval '1 hour';
  v_end timestamptz := now() + interval '22 hours 50 minutes';
  v_rivals text[];
  v_rival text;
  v_report jsonb := '{}'::jsonb;
  v_log jsonb := '[]'::jsonb;
  v_res jsonb;
  v_pid text;
  v_name text;
  v_min numeric;
  v_max numeric;
  v_leader text;
  v_n int;
  e jsonb;
  i int := 0;
  t record;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admins only';
  END IF;
  IF v_club IS NULL THEN
    RAISE EXCEPTION 'No club to test as — pass p_club';
  END IF;
  IF jsonb_typeof(coalesce(p_targets, '[]'::jsonb)) <> 'array'
     OR jsonb_array_length(coalesce(p_targets, '[]'::jsonb)) = 0 THEN
    RAISE EXCEPTION 'Add at least one target to test';
  END IF;

  SELECT * INTO b FROM public.draft_auction_window_bounds();
  IF coalesce(b.draft_enabled, false) AND b.draft_start IS NOT NULL
     AND now() >= b.draft_start AND now() < b.draft_window_end THEN
    RAISE EXCEPTION 'A real player draft is live — run the test when no draft is running';
  END IF;

  BEGIN
    -- Pretend the draft opened an hour ago
    UPDATE public.global_settings
    SET draft_auction_enabled = true,
        draft_auction_start_time = v_start,
        draft_random_finish_time = v_end,
        draft_autobid_paused = false
    WHERE id = 1;

    INSERT INTO public.player_draft_autobid_plans (
      club_short_name, owner_id, draft_start_at, draft_label, spend_cap, max_wins, enabled
    )
    VALUES (v_club, auth.uid(), v_start, 'TEST RUN', p_spend_cap, p_max_wins, true)
    ON CONFLICT (club_short_name, draft_start_at) DO UPDATE
    SET spend_cap = excluded.spend_cap, max_wins = excluded.max_wins, enabled = true, status = 'scheduled'
    RETURNING id INTO v_plan_id;

    FOR e IN SELECT * FROM jsonb_array_elements(p_targets)
    LOOP
      v_pid := nullif(btrim(e->>'player_id'), '');
      CONTINUE WHEN v_pid IS NULL OR nullif(e->>'max_amount', '') IS NULL;
      i := i + 1;
      INSERT INTO public.player_draft_autobid_targets (plan_id, player_id, priority, max_amount, included, allow_open)
      VALUES (
        v_plan_id, v_pid, i, (e->>'max_amount')::numeric,
        coalesce((e->>'included')::boolean, true),
        coalesce((e->>'allow_open')::boolean, true)
      )
      ON CONFLICT (plan_id, player_id) DO NOTHING;
    END LOOP;

    v_report := v_report || jsonb_build_object(
      'club', v_club,
      'credits_at_start', public.club_draft_auction_credits(v_club, v_start, v_start + interval '23 hours', v_end)
    );

    -- 1. Rivals act first
    IF coalesce(p_rivals, true) THEN
      SELECT array_agg(x.s) INTO v_rivals
      FROM (
        SELECT cl."ShortName" AS s
        FROM public."Clubs" cl
        WHERE cl.owner_id IS NOT NULL AND cl."ShortName" <> v_club
        ORDER BY random()
        LIMIT 3
      ) x;

      IF coalesce(array_length(v_rivals, 1), 0) > 0 THEN
        i := 0;
        FOR t IN
          SELECT tg.player_id, tg.max_amount, tg.priority, p."Name" AS name
          FROM public.player_draft_autobid_targets tg
          LEFT JOIN public."Players" p ON p."Konami_ID"::text = tg.player_id
          WHERE tg.plan_id = v_plan_id AND tg.included
          ORDER BY tg.priority
        LOOP
          i := i + 1;
          -- Targets #2 and #3: a rival opens the thread before your plan runs
          CONTINUE WHEN i NOT IN (2, 3);
          v_rival := v_rivals[1 + (i % array_length(v_rivals, 1))];
          BEGIN
            PERFORM set_config('gpsl.max_bid_resolving', '', true);
            v_res := public.player_draft_place_auto_bid(v_rival, t.player_id, public.player_draft_min_next_bid(t.player_id));
            v_log := v_log || jsonb_build_array(jsonb_build_object(
              'step', 'before pass 1', 'club', v_rival, 'player', coalesce(t.name, t.player_id),
              'action', 'opened the thread', 'result', v_res));
          EXCEPTION WHEN OTHERS THEN
            v_log := v_log || jsonb_build_array(jsonb_build_object(
              'step', 'before pass 1', 'club', v_rival, 'player', coalesce(t.name, t.player_id),
              'action', 'tried to open', 'result', SQLERRM));
            CONTINUE;
          END;
          -- Target #3: that rival also holds a max above yours → you get beaten
          IF i = 3 THEN
            INSERT INTO public.player_draft_max_bids (club_short_name, player_id, max_amount, updated_at)
            VALUES (v_rival, t.player_id, t.max_amount + 1000000, now())
            ON CONFLICT (club_short_name, player_id) DO UPDATE
            SET max_amount = excluded.max_amount, updated_at = now();
            v_log := v_log || jsonb_build_array(jsonb_build_object(
              'step', 'before pass 1', 'club', v_rival, 'player', coalesce(t.name, t.player_id),
              'action', 'set a max bid of ' || public.player_draft_autobid_money(t.max_amount + 1000000)
                || ' (above yours)'));
          END IF;
        END LOOP;
      END IF;
    END IF;

    -- 2. Engine pass 1
    PERFORM set_config('gpsl.max_bid_resolving', '', true);
    v_n := public.player_draft_autobid_run_plan(v_plan_id);
    v_report := v_report || jsonb_build_object(
      'pass1_actions', v_n,
      'pass1', (
        SELECT coalesce(jsonb_agg(jsonb_build_object(
          'player', coalesce(p."Name", tg.player_id),
          'max', tg.max_amount,
          'state', tg.state,
          'note', tg.state_note,
          'entered_via', tg.entered_via,
          'leader', public.player_draft_autobid_leader(tg.player_id, v_start, v_end),
          'high_bid', public.player_draft_autobid_high_bid(tg.player_id, v_start, v_end)
        ) ORDER BY tg.priority), '[]'::jsonb)
        FROM public.player_draft_autobid_targets tg
        LEFT JOIN public."Players" p ON p."Konami_ID"::text = tg.player_id
        WHERE tg.plan_id = v_plan_id
      ),
      'credits_after_pass1', public.club_draft_auction_credits(v_club, v_start, v_start + interval '23 hours', v_end)
    );

    -- 3. A rival outbids you on the first thread you lead
    IF coalesce(array_length(v_rivals, 1), 0) > 0 THEN
      SELECT tg.player_id, p."Name" INTO v_pid, v_name
      FROM public.player_draft_autobid_targets tg
      LEFT JOIN public."Players" p ON p."Konami_ID"::text = tg.player_id
      WHERE tg.plan_id = v_plan_id AND tg.state = 'leading'
      ORDER BY tg.priority
      LIMIT 1;

      IF v_pid IS NOT NULL THEN
        v_rival := v_rivals[1];
        IF v_rival = public.player_draft_autobid_leader(v_pid, v_start, v_end) AND array_length(v_rivals, 1) > 1 THEN
          v_rival := v_rivals[2];
        END IF;
        v_min := public.player_draft_min_next_bid(v_pid);
        BEGIN
          PERFORM set_config('gpsl.max_bid_resolving', '', true);
          v_res := public.player_draft_place_auto_bid(v_rival, v_pid, v_min);
          v_leader := public.player_draft_autobid_leader(v_pid, v_start, v_end);
          v_log := v_log || jsonb_build_array(jsonb_build_object(
            'step', 'between passes', 'club', v_rival, 'player', coalesce(v_name, v_pid),
            'action', 'outbid you at ' || public.player_draft_autobid_money(v_min),
            'result', CASE WHEN v_leader = v_club
              THEN 'your max bid answered instantly — you lead at '
                || public.player_draft_autobid_money(public.player_draft_autobid_high_bid(v_pid, v_start, v_end))
              ELSE 'leader now ' || coalesce(v_leader, '—') END));
        EXCEPTION WHEN OTHERS THEN
          v_log := v_log || jsonb_build_array(jsonb_build_object(
            'step', 'between passes', 'club', v_rival, 'player', coalesce(v_name, v_pid),
            'action', 'tried to outbid', 'result', SQLERRM));
        END;
      END IF;
    END IF;

    -- 4. Engine pass 2
    PERFORM set_config('gpsl.max_bid_resolving', '', true);
    v_n := public.player_draft_autobid_run_plan(v_plan_id);
    v_report := v_report || jsonb_build_object(
      'pass2_actions', v_n,
      'pass2', (
        SELECT coalesce(jsonb_agg(jsonb_build_object(
          'player', coalesce(p."Name", tg.player_id),
          'max', tg.max_amount,
          'state', tg.state,
          'note', tg.state_note,
          'entered_via', tg.entered_via,
          'leader', public.player_draft_autobid_leader(tg.player_id, v_start, v_end),
          'high_bid', public.player_draft_autobid_high_bid(tg.player_id, v_start, v_end)
        ) ORDER BY tg.priority), '[]'::jsonb)
        FROM public.player_draft_autobid_targets tg
        LEFT JOIN public."Players" p ON p."Konami_ID"::text = tg.player_id
        WHERE tg.plan_id = v_plan_id
      ),
      'your_bids', (
        SELECT coalesce(jsonb_agg(jsonb_build_object(
          'player', coalesce(p."Name", coalesce(bd.player_id, bd.direct_bid_id::text)),
          'amount', bd.bid_amount,
          'opened', bd.is_first_draft_bid,
          'join', bd.is_draft_join,
          'credit_used', bd.draft_join_consumed
        ) ORDER BY bd.bid_amount), '[]'::jsonb)
        FROM public."Player_Transfer_Bids" bd
        LEFT JOIN public."Players" p ON p."Konami_ID"::text = coalesce(bd.player_id, bd.direct_bid_id::text)
        WHERE bd.bidder_club_id = v_club
          AND bd.is_direct = true
          AND bd.seller_club_id IS NULL
          AND bd.bid_time >= v_start
      ),
      'credits_after_pass2', public.club_draft_auction_credits(v_club, v_start, v_start + interval '23 hours', v_end)
    );

    -- 5. Draft "ends": shift this test's bids into a closed window, then finish
    UPDATE public."Player_Transfer_Bids"
    SET bid_time = bid_time - interval '2 hours'
    WHERE bid_time >= now();

    UPDATE public.player_draft_autobid_plans
    SET live_window_start = now() - interval '4 hours',
        live_window_end = now() - interval '15 minutes'
    WHERE id = v_plan_id;

    PERFORM public.player_draft_autobid_finish_due();

    v_report := v_report || jsonb_build_object(
      'final', (
        SELECT coalesce(jsonb_agg(jsonb_build_object(
          'player', coalesce(p."Name", tg.player_id),
          'state', tg.state,
          'note', tg.state_note,
          'entered_via', tg.entered_via
        ) ORDER BY tg.priority), '[]'::jsonb)
        FROM public.player_draft_autobid_targets tg
        LEFT JOIN public."Players" p ON p."Konami_ID"::text = tg.player_id
        WHERE tg.plan_id = v_plan_id
      ),
      'max_bids_left_after_finish', (
        SELECT count(*) FROM public.player_draft_max_bids m
        JOIN public.player_draft_autobid_targets tg
          ON tg.plan_id = v_plan_id AND tg.player_id = m.player_id
        WHERE m.club_short_name = v_club
      ),
      'inbox', (
        SELECT coalesce(jsonb_agg(jsonb_build_object('title', ci.title, 'body', ci.body) ORDER BY ci.id), '[]'::jsonb)
        FROM public.competition_inbox ci
        WHERE ci.recipient_club_short_name = v_club
          AND ci.message_type IN ('draft_autobid_live', 'draft_autobid_summary')
          AND ci.created_at >= now()
      ),
      'rival_actions', v_log
    );

    RAISE EXCEPTION 'gpsl_autobid_sim_rollback';
  EXCEPTION
    WHEN raise_exception THEN
      IF SQLERRM <> 'gpsl_autobid_sim_rollback' THEN
        RETURN jsonb_build_object('ok', false, 'error', SQLERRM, 'partial', v_report || jsonb_build_object('rival_actions', v_log));
      END IF;
    WHEN OTHERS THEN
      RETURN jsonb_build_object('ok', false, 'error', SQLERRM, 'partial', v_report || jsonb_build_object('rival_actions', v_log));
  END;

  RETURN jsonb_build_object('ok', true, 'rolled_back', true) || v_report;
END;
$function$;

REVOKE ALL ON FUNCTION public.admin_player_draft_autobid_simulate(jsonb, numeric, int, boolean, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_player_draft_autobid_simulate(jsonb, numeric, int, boolean, text) TO authenticated;

NOTIFY pgrst, 'reload schema';
