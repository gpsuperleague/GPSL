-- =============================================================================
-- Special auction → owner inbox when scheduled / published (activate)
-- Also: admin resend for an already-published auction.
-- Safe re-run.
-- =============================================================================

ALTER TABLE public.competition_inbox
  DROP CONSTRAINT IF EXISTS competition_inbox_message_type_check;

ALTER TABLE public.competition_inbox
  ADD CONSTRAINT competition_inbox_message_type_check
  CHECK (
    message_type IN (
      'welcome_gpsl',
      'result_submitted',
      'result_to_confirm',
      'result_rejected',
      'result_confirmed',
      'transfer_signed',
      'transfer_sold',
      'transfer_upcoming',
      'draft_scheduled',
      'fine_applied',
      'points_deduction',
      'nation_pick_turn',
      'nation_selection_open',
      'season_expectations',
      'season_overview',
      'player_awards',
      'monthly_fixtures',
      'match_time_proposed',
      'match_time_countered',
      'match_time_proposal_sent',
      'match_time_counter_sent',
      'match_time_accepted',
      'match_rescheduled',
      'match_emergency_drop',
      'match_forfeit_applied',
      'match_checkin_open',
      'match_mutual_override_requested',
      'match_mutual_override_applied',
      'special_auction_scheduled'
    )
  ) NOT VALID;

ALTER TABLE public.competition_inbox
  VALIDATE CONSTRAINT competition_inbox_message_type_check;

-- Drop older single-arg overloads if present
DROP FUNCTION IF EXISTS public.special_auction_notify_scheduled(bigint);
DROP FUNCTION IF EXISTS public.admin_special_auction_notify_scheduled(bigint);

CREATE OR REPLACE FUNCTION public.special_auction_notify_scheduled(
  p_auction_id bigint,
  p_force boolean DEFAULT false
)
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  a public.special_auctions%rowtype;
  v_start text;
  v_title text;
  v_body text;
  v_type_label text;
  v_count int := 0;
  v_dedupe text;
BEGIN
  IF to_regprocedure('public.owner_inbox_notify_all_clubs(text,text,text,text,text,bigint)') IS NULL THEN
    RAISE EXCEPTION 'owner_inbox_notify_all_clubs missing — run owner_inbox_notifications.sql';
  END IF;

  SELECT * INTO a FROM public.special_auctions WHERE id = p_auction_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Auction not found';
  END IF;

  IF a.status NOT IN ('scheduled', 'active') THEN
    RAISE EXCEPTION 'Auction must be scheduled or active to notify (status=%)', a.status;
  END IF;

  v_start := to_char(a.start_time AT TIME ZONE 'Europe/London', 'Dy DD Mon YYYY HH24:MI');
  v_type_label := CASE a.auction_type
    WHEN 'lowest_unique' THEN 'Lowest unique bid auction'
    WHEN 'snap' THEN 'Snap auction'
    WHEN 'blind_gauntlet' THEN 'Blind Gauntlet'
    ELSE 'Special auction'
  END;

  v_title := format('%s scheduled', v_type_label);

  IF a.auction_type = 'snap' THEN
    v_body := format(
      E'%s — %s\n\nOpens %s (UK).\nRuns about one hour; bidding ends at a secret random time in the final 10 minutes.\nClues unlock during the auction; the player identity is revealed when it ends.\n\nOpen Special Auction to take part.',
      v_type_label,
      coalesce(nullif(btrim(a.title), ''), 'Special auction'),
      v_start
    );
  ELSIF a.auction_type = 'blind_gauntlet' THEN
    v_body := format(
      E'%s — %s\n\nOpens %s (UK).\nTwo blind phases (Phase 1 → reveal → Phase 2). Check Special Auction / Blind Gauntlet for rules and fees.\n\nOpen Blind Gauntlet to take part.',
      v_type_label,
      coalesce(nullif(btrim(a.title), ''), 'Special auction'),
      v_start
    );
  ELSIF a.auction_type = 'lowest_unique' THEN
    v_body := format(
      E'%s — %s\n\nBidding window: %s (UK) until %s (UK).\nOne secret bid per club (nearest ₿1m). Lowest unique bid wins.\n\nOpen Special Auction to take part.',
      v_type_label,
      coalesce(nullif(btrim(a.title), ''), 'Special auction'),
      v_start,
      to_char(a.end_time AT TIME ZONE 'Europe/London', 'Dy DD Mon YYYY HH24:MI')
    );
  ELSE
    v_body := format(
      E'%s — %s\n\nOpens %s (UK)%s.\n\nOpen Special Auction to take part.',
      v_type_label,
      coalesce(nullif(btrim(a.title), ''), 'Special auction'),
      v_start,
      CASE
        WHEN a.end_time IS NOT NULL THEN
          ' until ' || to_char(a.end_time AT TIME ZONE 'Europe/London', 'Dy DD Mon YYYY HH24:MI') || ' (UK)'
        ELSE ''
      END
    );
  END IF;

  v_dedupe := 'special_auction_scheduled:' || a.id::text;
  IF p_force THEN
    v_dedupe := v_dedupe || ':resent:' || floor(extract(epoch FROM now()))::text;
  END IF;

  v_count := public.owner_inbox_notify_all_clubs(
    'special_auction_scheduled',
    v_title,
    v_body,
    CASE
      WHEN a.auction_type = 'blind_gauntlet' THEN 'special_auction_gauntlet.html'
      ELSE 'special_auction.html'
    END,
    v_dedupe,
    NULL
  );

  RETURN v_count;
END;
$function$;

-- Admin-only wrapper (for resend from SQL / admin UI)
CREATE OR REPLACE FUNCTION public.admin_special_auction_notify_scheduled(
  p_auction_id bigint,
  p_force boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_n int;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;
  v_n := public.special_auction_notify_scheduled(p_auction_id, coalesce(p_force, false));
  RETURN jsonb_build_object('ok', true, 'notified', v_n, 'auction_id', p_auction_id);
END;
$function$;

-- Hook into activate (same body as snap_v2 activate + notify)
CREATE OR REPLACE FUNCTION public.special_auction_activate(p_auction_id bigint)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_row public.special_auctions%rowtype;
  v_random_end timestamptz;
BEGIN
  IF NOT public.is_gpsl_admin() THEN RAISE EXCEPTION 'Admin only'; END IF;

  SELECT * INTO v_row FROM public.special_auctions WHERE id = p_auction_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Auction not found'; END IF;

  UPDATE public.special_auctions
  SET status = 'draft', updated_at = now()
  WHERE status IN ('scheduled', 'active')
    AND id IS DISTINCT FROM p_auction_id;

  IF v_row.auction_type = 'snap' THEN
    v_random_end :=
      v_row.start_time
      + interval '50 minutes'
      + (random() * interval '10 minutes');

    UPDATE public.special_auctions
    SET end_time = v_row.start_time + interval '60 minutes',
        snap_random_end_at = v_random_end,
        snap_bid_fee = coalesce(nullif(snap_bid_fee, 0), 300000),
        status = CASE WHEN now() < start_time THEN 'scheduled' ELSE 'active' END,
        updated_at = now()
    WHERE id = p_auction_id;
  ELSE
    UPDATE public.special_auctions
    SET status = CASE WHEN now() < start_time THEN 'scheduled' ELSE 'active' END,
        updated_at = now()
    WHERE id = p_auction_id;
  END IF;

  BEGIN
    PERFORM public.special_auction_notify_scheduled(p_auction_id);
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'special_auction_notify_scheduled failed: %', SQLERRM;
  END;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.special_auction_notify_scheduled(bigint, boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_special_auction_notify_scheduled(bigint, boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.special_auction_activate(bigint) TO authenticated;

NOTIFY pgrst, 'reload schema';

-- Notify owners for the current published auction (run once after this patch):
-- SELECT public.admin_special_auction_notify_scheduled(id, true)
-- FROM public.special_auctions
-- WHERE status IN ('scheduled', 'active')
-- ORDER BY id DESC
-- LIMIT 1;
