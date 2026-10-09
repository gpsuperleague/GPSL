-- =============================================================================
-- Diagnose: why a club's draft max bids (bid modal) are not auto-bidding
-- READ-ONLY: the dry-run bid is rolled back inside an exception block.
-- Set the club below (defaults to the club owned by the GPSL admin account).
-- =============================================================================

CREATE TEMP TABLE IF NOT EXISTS _gpsl_max_bid_diag (
  player text,
  my_max numeric,
  leader text,
  high_bid numeric,
  min_next numeric,
  i_have_bid boolean,
  credits int,
  plan_target text,
  verdict text,
  dry_run text
) ON COMMIT PRESERVE ROWS;
TRUNCATE _gpsl_max_bid_diag;

DO $diag$
DECLARE
  v_club text := (
    SELECT c."ShortName" FROM public."Clubs" c
    JOIN auth.users u ON u.id = c.owner_id
    WHERE lower(u.email) = 'rotavator66@outlook.com'
    LIMIT 1
  );
  b record;
  m record;
  v_leader text;
  v_high numeric;
  v_min numeric;
  v_has boolean;
  v_credits int;
  v_plan text;
  v_verdict text;
  v_dry text;
  v_res jsonb;
BEGIN
  SELECT * INTO b FROM public.draft_auction_window_bounds();

  FOR m IN
    SELECT mb.player_id, mb.max_amount, p."Name" AS name
    FROM public.player_draft_max_bids mb
    LEFT JOIN public."Players" p ON p."Konami_ID"::text = mb.player_id
    WHERE mb.club_short_name = v_club
    ORDER BY mb.updated_at DESC
  LOOP
    SELECT x.bidder_club_id, x.bid_amount INTO v_leader, v_high
    FROM public."Player_Transfer_Bids" x
    WHERE coalesce(x.player_id, x.direct_bid_id::text) = m.player_id
      AND x.is_direct AND x.seller_club_id IS NULL
      AND x.bid_time >= b.draft_start AND x.bid_time < b.draft_window_end
    ORDER BY x.bid_amount DESC, x.bid_time DESC
    LIMIT 1;

    v_min := public.player_draft_min_next_bid(m.player_id);
    v_has := public.player_draft_club_has_bid(v_club, m.player_id);
    v_credits := public.club_draft_auction_credits(v_club, b.draft_start, b.draft_cutoff, b.draft_window_end);

    SELECT format('plan max %s, state %s%s', t.max_amount, t.state,
                  coalesce(' (' || t.state_note || ')', ''))
    INTO v_plan
    FROM public.player_draft_autobid_targets t
    JOIN public.player_draft_autobid_plans pl ON pl.id = t.plan_id
    WHERE pl.club_short_name = v_club AND t.player_id = m.player_id
      AND pl.status IN ('scheduled', 'live')
    ORDER BY pl.id DESC
    LIMIT 1;

    v_dry := NULL;
    v_verdict := CASE
      WHEN NOT coalesce(b.draft_enabled, false) OR now() < b.draft_start OR now() >= b.draft_window_end
        THEN 'Draft window closed'
      WHEN v_leader = v_club THEN 'You are leading — nothing to do'
      WHEN v_min IS NULL THEN 'No minimum bid (no market value?)'
      WHEN v_min > m.max_amount THEN 'Bidding has passed your max'
      WHEN v_leader IS NOT NULL AND NOT v_has AND coalesce(v_credits, 0) <= 0
        THEN 'Needs a free credit to join (max bid waits)'
      WHEN v_leader IS NULL AND now() >= b.draft_cutoff THEN 'Cutoff passed — cannot open new thread'
      ELSE 'SHOULD HAVE BID'
    END;

    IF v_verdict = 'SHOULD HAVE BID' THEN
      BEGIN
        PERFORM set_config('gpsl.max_bid_resolving', '', true);
        v_res := public.player_draft_place_auto_bid(v_club, m.player_id, v_min);
        RAISE EXCEPTION 'DRYRUN %', v_res::text;
      EXCEPTION WHEN OTHERS THEN
        v_dry := SQLERRM;
      END;
    END IF;

    INSERT INTO _gpsl_max_bid_diag VALUES (
      coalesce(m.name, m.player_id), m.max_amount, v_leader, v_high, v_min,
      v_has, v_credits, v_plan, v_verdict, v_dry
    );
  END LOOP;

  IF v_club IS NULL THEN
    INSERT INTO _gpsl_max_bid_diag (verdict) VALUES ('No club found for that owner email');
  END IF;
END
$diag$;

SELECT * FROM _gpsl_max_bid_diag;
