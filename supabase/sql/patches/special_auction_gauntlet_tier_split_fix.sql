-- =============================================================================
-- Blind Gauntlet Phase 1 tiers — top and bottom both ~25%
--
-- Bug: top used ceil(n*25%), bottom used floor(n*25%).
-- With 7 bids that became 2 top / 4 middle / 1 bottom.
-- Expected: 2 top / 3 middle / 2 bottom.
--
-- Safe re-run. Also repairs tiers on auctions still in reveal/phase2
-- (adjusts fee ledger deltas if a club moves between middle and bottom).
-- =============================================================================

CREATE OR REPLACE FUNCTION public.special_auction_gauntlet_tier_counts(p_n int)
RETURNS TABLE (top_n int, middle_n int, bottom_n int)
LANGUAGE plpgsql
IMMUTABLE
AS $function$
DECLARE
  v_n int := greatest(coalesce(p_n, 0), 0);
  v_top int;
  v_bottom int;
BEGIN
  IF v_n <= 0 THEN
    top_n := 0; middle_n := 0; bottom_n := 0;
    RETURN NEXT;
    RETURN;
  END IF;

  -- Symmetric ~25% bands (round up), remainder is middle
  v_top := greatest(1, ceil(v_n * 0.25)::int);
  v_bottom := greatest(0, ceil(v_n * 0.25)::int);

  IF v_top + v_bottom > v_n THEN
    v_bottom := greatest(0, v_n - v_top);
  END IF;

  -- Keep at least one middle seat when there are 3+ bids
  IF v_n >= 3 AND v_top + v_bottom >= v_n THEN
    v_bottom := greatest(0, v_n - v_top - 1);
  END IF;

  top_n := v_top;
  bottom_n := v_bottom;
  middle_n := v_n - v_top - v_bottom;
  RETURN NEXT;
END;
$function$;

CREATE OR REPLACE FUNCTION public.special_auction_gauntlet_assign_tiers(p_auction_id bigint)
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_n int;
  v_top int;
  v_bottom int;
  v_middle int;
  r record;
  v_rank int := 0;
  v_tier text;
  v_fee numeric;
  v_assigned int := 0;
  v_counts record;
BEGIN
  SELECT count(*)::int INTO v_n
  FROM public.special_auction_gauntlet_bids
  WHERE auction_id = p_auction_id AND phase = 1;

  IF v_n = 0 THEN
    RETURN 0;
  END IF;

  SELECT * INTO v_counts
  FROM public.special_auction_gauntlet_tier_counts(v_n);
  v_top := v_counts.top_n;
  v_middle := v_counts.middle_n;
  v_bottom := v_counts.bottom_n;

  FOR r IN
    SELECT id, club_id
    FROM public.special_auction_gauntlet_bids
    WHERE auction_id = p_auction_id AND phase = 1
    ORDER BY bid_amount DESC, bid_time ASC, id ASC
  LOOP
    v_rank := v_rank + 1;
    IF v_rank <= v_top THEN
      v_tier := 'top';
      v_fee := 0;
    ELSIF v_rank <= v_top + v_middle THEN
      v_tier := 'middle';
      v_fee := 500000;
    ELSE
      v_tier := 'bottom';
      v_fee := 1000000;
    END IF;

    UPDATE public.special_auction_gauntlet_bids
    SET tier = v_tier, phase1_fee = v_fee
    WHERE id = r.id;

    IF v_fee > 0 THEN
      PERFORM public.post_special_auction_ledger_line(
        r.club_id,
        'special_auction_fee',
        -abs(v_fee),
        format('Blind Gauntlet Phase 1 fee (%s tier)', v_tier),
        p_auction_id,
        true,
        jsonb_build_object(
          'ledger_role', format('gauntlet_p1_%s_%s', v_tier, r.club_id),
          'gauntlet_tier', v_tier,
          'phase', 1
        )
      );
    END IF;

    BEGIN
      PERFORM public.owner_inbox_send(
        'special_auction_scheduled',
        format('Blind Gauntlet — you finished %s tier', initcap(v_tier)),
        CASE v_tier
          WHEN 'top' THEN
            E'You finished in the Top tier (top 25%).\nYou advance to Phase 2.\nPhase 1 fee: ₿0.\nYour Phase 2 bid must be ≥ your Phase 1 bid.'
          WHEN 'middle' THEN
            E'You finished in the Middle tier.\nYou have been eliminated from Round 2.\nPhase 1 fee charged: ₿500,000 (non-refundable).'
          ELSE
            E'You finished in the Bottom tier.\nYou have been eliminated from Round 2.\nPhase 1 fee charged: ₿1,000,000 (non-refundable).'
        END,
        r.club_id,
        NULL, NULL, NULL, NULL, NULL,
        'special_auction.html',
        format('gauntlet_tier:%s:%s', p_auction_id, r.club_id),
        NULL, NULL
      );
    EXCEPTION WHEN others THEN
      NULL;
    END;

    v_assigned := v_assigned + 1;
  END LOOP;

  RETURN v_assigned;
END;
$function$;

-- Repair live/reveal auctions that already have wrong Phase 1 tiers
CREATE OR REPLACE FUNCTION public.admin_special_auction_gauntlet_repair_phase1_tiers(
  p_auction_id bigint DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  a public.special_auctions%rowtype;
  v_n int;
  v_top int;
  v_middle int;
  v_bottom int;
  v_counts record;
  r record;
  v_rank int;
  v_tier text;
  v_fee numeric;
  v_old_fee numeric;
  v_delta numeric;
  v_changed int := 0;
  v_ids bigint[] := ARRAY[]::bigint[];
BEGIN
  IF NOT public.is_gpsl_admin()
     AND current_user NOT IN ('postgres', 'supabase_admin', 'service_role') THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  FOR a IN
    SELECT *
    FROM public.special_auctions
    WHERE auction_type = 'blind_gauntlet'
      AND status IN ('scheduled', 'active', 'revealed')
      AND (p_auction_id IS NULL OR id = p_auction_id)
      AND gauntlet_phase IN ('reveal', 'phase2', 'complete', 'failed')
    ORDER BY id DESC
  LOOP
    SELECT count(*)::int INTO v_n
    FROM public.special_auction_gauntlet_bids
    WHERE auction_id = a.id AND phase = 1;

    IF v_n = 0 THEN
      CONTINUE;
    END IF;

    SELECT * INTO v_counts
    FROM public.special_auction_gauntlet_tier_counts(v_n);
    v_top := v_counts.top_n;
    v_middle := v_counts.middle_n;
    v_bottom := v_counts.bottom_n;
    v_rank := 0;

    FOR r IN
      SELECT id, club_id, tier, phase1_fee
      FROM public.special_auction_gauntlet_bids
      WHERE auction_id = a.id AND phase = 1
      ORDER BY bid_amount DESC, bid_time ASC, id ASC
    LOOP
      v_rank := v_rank + 1;
      IF v_rank <= v_top THEN
        v_tier := 'top';
        v_fee := 0;
      ELSIF v_rank <= v_top + v_middle THEN
        v_tier := 'middle';
        v_fee := 500000;
      ELSE
        v_tier := 'bottom';
        v_fee := 1000000;
      END IF;

      v_old_fee := coalesce(r.phase1_fee, 0);
      IF r.tier IS DISTINCT FROM v_tier OR v_old_fee IS DISTINCT FROM v_fee THEN
        UPDATE public.special_auction_gauntlet_bids
        SET tier = v_tier, phase1_fee = v_fee
        WHERE id = r.id;

        v_delta := v_fee - v_old_fee;
        IF v_delta <> 0
           AND to_regprocedure(
             'public.post_special_auction_ledger_line(text,text,numeric,text,bigint,boolean,jsonb)'
           ) IS NOT NULL THEN
          PERFORM public.post_special_auction_ledger_line(
            r.club_id,
            'special_auction_fee',
            -v_delta,
            format('Blind Gauntlet Phase 1 fee adjustment (%s → %s)', coalesce(r.tier, '?'), v_tier),
            a.id,
            true,
            jsonb_build_object(
              'ledger_role', format('gauntlet_p1_adjust_%s_%s', a.id, r.club_id),
              'gauntlet_tier', v_tier,
              'phase', 1,
              'adjustment', true
            )
          );
        END IF;

        v_changed := v_changed + 1;
      END IF;
    END LOOP;

    v_ids := v_ids || a.id;
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true,
    'auctions', to_jsonb(v_ids),
    'tiers_changed', v_changed,
    'note', 'Top/bottom both use ceil(n*25%); e.g. 7 bids → 2/3/2'
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.special_auction_gauntlet_tier_counts(int) TO authenticated;
GRANT EXECUTE ON FUNCTION public.special_auction_gauntlet_assign_tiers(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_special_auction_gauntlet_repair_phase1_tiers(bigint) TO authenticated;

-- Repair current live gauntlets now
SELECT public.admin_special_auction_gauntlet_repair_phase1_tiers(NULL);

-- Quick check helper
SELECT n,
       (public.special_auction_gauntlet_tier_counts(n)).*
FROM generate_series(1, 12) AS n;

NOTIFY pgrst, 'reload schema';
