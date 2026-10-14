-- =============================================================================
-- Special auctions: allow several scheduled auctions at once.
--
-- 1) special_auction_activate only knocks back to draft the auctions whose
--    time window overlaps the one being activated (it used to demote every
--    other scheduled/active auction).
-- 2) Snap player identity is also hidden while the snap is a draft, so the
--    owner pages never show a mystery prize (admin pages read the table).
--
-- Body otherwise identical to special_auction_inbox_notify.sql. Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.special_auction_snap_identity_hidden(p_auction public.special_auctions)
RETURNS boolean
LANGUAGE sql
STABLE
AS $$
  SELECT
    p_auction.auction_type = 'snap'
    AND (
      p_auction.status = 'draft'
      OR (
        p_auction.status IN ('scheduled', 'active')
        AND (
          now() < p_auction.start_time
          OR now() < coalesce(p_auction.snap_random_end_at, p_auction.end_time)
        )
      )
    );
$$;

CREATE OR REPLACE FUNCTION public.special_auction_activate(p_auction_id bigint)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_row public.special_auctions%rowtype;
  v_random_end timestamptz;
  v_end timestamptz;
BEGIN
  IF NOT public.is_gpsl_admin() THEN RAISE EXCEPTION 'Admin only'; END IF;

  SELECT * INTO v_row FROM public.special_auctions WHERE id = p_auction_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Auction not found'; END IF;

  v_end := CASE
    WHEN v_row.auction_type = 'snap' THEN v_row.start_time + interval '60 minutes'
    ELSE coalesce(v_row.end_time, v_row.start_time + interval '60 minutes')
  END;

  -- Only clashing auctions (overlapping time windows) go back to draft
  UPDATE public.special_auctions o
  SET status = 'draft', updated_at = now()
  WHERE o.status IN ('scheduled', 'active')
    AND o.id IS DISTINCT FROM p_auction_id
    AND o.start_time < v_end
    AND coalesce(o.end_time, o.start_time + interval '60 minutes') > v_row.start_time;

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

GRANT EXECUTE ON FUNCTION public.special_auction_snap_identity_hidden(public.special_auctions) TO authenticated;
GRANT EXECUTE ON FUNCTION public.special_auction_activate(bigint) TO authenticated;

NOTIFY pgrst, 'reload schema';

-- Report: snap 12 should show prize = null (hidden)
SELECT
  a.id, a.title, a.status, a.start_time,
  public.special_auction_snap_identity_hidden(a) AS identity_hidden,
  public.special_auction_owner_json(a)->>'prize_player_id' AS owner_sees_prize
FROM public.special_auctions a
WHERE a.status IN ('draft', 'scheduled', 'active')
ORDER BY a.start_time;
