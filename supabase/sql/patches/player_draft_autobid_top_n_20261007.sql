-- =============================================================================
-- Player draft auto-bid: "Max players" = work only the top N targets
-- =============================================================================
-- Setting max players to N now means the plan works the first N targets on the
-- list (in priority order, skipping players the club already has) and never
-- goes below them. Each pass:
--   1) opens every fresh thread in the top N (earning credits),
--   2) goes round the top N again and joins other clubs' threads with the
--      credits earned.
-- Targets below the top N are shown as "Outside your top N". Blank = no limit
-- (whole list, as before).
--
-- Full redefinition of player_draft_autobid_run_plan (same as the copy in
-- player_draft_autobid_plans_20261006.sql). Safe to re-run.
-- =============================================================================

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
        -- Spend cap counts plan targets still in play
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

REVOKE ALL ON FUNCTION public.player_draft_autobid_run_plan(bigint) FROM PUBLIC, anon, authenticated;

-- Check: every helper the engine calls should be true
SELECT
  position('FOR v_phase IN 1..2 LOOP' IN pg_get_functiondef(
    'public.player_draft_autobid_run_plan(bigint)'::regprocedure)) > 0 AS top_n_installed,
  to_regproc('public.player_draft_autobid_leader') IS NOT NULL AS has_leader,
  to_regproc('public.player_draft_autobid_high_bid') IS NOT NULL AS has_high_bid,
  to_regproc('public.player_draft_autobid_club_inplay') IS NOT NULL AS has_club_inplay,
  to_regproc('public.player_draft_autobid_money') IS NOT NULL AS has_money,
  to_regproc('public.player_draft_autobid_inbox') IS NOT NULL AS has_inbox,
  to_regproc('public.player_draft_place_auto_bid') IS NOT NULL AS has_place_auto_bid,
  to_regproc('public.player_draft_club_has_bid') IS NOT NULL AS has_club_has_bid;
