-- =============================================================================
-- Club auction — capacity-based stadium cost + enriched public listing view
-- Opening / reserve bid = stadium capacity × ₿1,000
-- Run after patches/club_auction.sql
-- =============================================================================

DROP FUNCTION IF EXISTS public.club_auction_opening_bid_for_capacity(integer);

CREATE OR REPLACE FUNCTION public.club_auction_opening_bid_for_capacity(p_capacity bigint)
RETURNS numeric
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT greatest(coalesce(p_capacity, 0), 0)::numeric * 1000;
$$;

COMMENT ON FUNCTION public.club_auction_opening_bid_for_capacity(bigint) IS
  'Club auction opening bid = stadium capacity × ₿1,000.';

-- Keep rank helper for legacy scripts; seed uses capacity now.
CREATE OR REPLACE FUNCTION public.club_auction_opening_bid_for_rank(p_rank smallint)
RETURNS numeric
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT public.club_auction_opening_bid_for_capacity(
    CASE
      WHEN p_rank IS NULL THEN 0
      ELSE greatest(1000, (61 - greatest(least(p_rank, 60), 1)) * 1000)
    END
  );
$$;

CREATE OR REPLACE FUNCTION public.admin_club_auction_seed_listings()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club record;
  v_opening numeric;
  v_inserted int := 0;
  v_skipped int := 0;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  FOR v_club IN
    SELECT
      c."ShortName" AS club_short_name,
      coalesce(c."Capacity", 0)::int AS capacity,
      p.prestige_rank
    FROM public."Clubs" c
    LEFT JOIN public.competition_club_prestige_public p
      ON p.club_short_name = c."ShortName"
    WHERE c."ShortName" <> 'FOREIGN'
      AND c.owner_id IS NULL
    ORDER BY p.prestige_rank NULLS LAST, c."ShortName"
  LOOP
    IF EXISTS (
      SELECT 1
      FROM public."Club_Auction_Listings" l
      WHERE l.club_short_name = v_club.club_short_name
        AND l.status = 'Active'
    ) THEN
      v_skipped := v_skipped + 1;
      CONTINUE;
    END IF;

    v_opening := public.club_auction_opening_bid_for_capacity(v_club.capacity);

    INSERT INTO public."Club_Auction_Listings" (
      club_short_name,
      status,
      opening_bid,
      reserve_price,
      prestige_rank,
      expected_position,
      created_at,
      updated_at
    )
    VALUES (
      v_club.club_short_name,
      'Active',
      v_opening,
      v_opening,
      v_club.prestige_rank,
      public.competition_club_baseline_expected_position(
        v_club.prestige_rank,
        (SELECT count(*)::smallint FROM public."Clubs" c2 WHERE c2."ShortName" <> 'FOREIGN')
      ),
      now(),
      now()
    );

    v_inserted := v_inserted + 1;
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true,
    'inserted', v_inserted,
    'skipped_existing_active', v_skipped
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_club_auction_refresh_opening_bids()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_updated int := 0;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  UPDATE public."Club_Auction_Listings" l
  SET opening_bid = public.club_auction_opening_bid_for_capacity(coalesce(c."Capacity", 0)::bigint),
      reserve_price = public.club_auction_opening_bid_for_capacity(coalesce(c."Capacity", 0)::bigint),
      updated_at = now()
  FROM public."Clubs" c
  WHERE c."ShortName" = l.club_short_name
    AND l.status = 'Active';

  GET DIAGNOSTICS v_updated = ROW_COUNT;

  RETURN jsonb_build_object('ok', true, 'updated', v_updated);
END;
$function$;

DROP VIEW IF EXISTS public.club_auction_listings_public;

CREATE VIEW public.club_auction_listings_public
WITH (security_invoker = false)
AS
SELECT
  l.id,
  l.club_short_name,
  c."Club" AS club_name,
  c."Stadium" AS stadium,
  coalesce(c."Capacity", 0)::int AS capacity,
  public.club_auction_opening_bid_for_capacity(coalesce(c."Capacity", 0)::bigint) AS stadium_cost,
  round(coalesce(c."Capacity", 0)::numeric * 20) AS full_gate_matchday,
  round(coalesce(c."Capacity", 0)::numeric * 1500 * 0.125) AS season_maintenance_cost,
  c."Nation" AS nation,
  l.status,
  l.opening_bid,
  l.reserve_price,
  l.prestige_rank,
  coalesce(
    l.expected_position,
    public.competition_club_baseline_expected_position(
      l.prestige_rank,
      (SELECT count(*)::smallint FROM public."Clubs" c2 WHERE c2."ShortName" <> 'FOREIGN')
    )
  ) AS season1_expected_position,
  l.current_highest_bid,
  l.current_highest_bidder,
  r.owner_tag AS current_leader_tag,
  l.transfer_completed,
  l.created_at,
  l.updated_at,
  public.club_auction_min_next_bid(l.id) AS min_next_bid
FROM public."Club_Auction_Listings" l
JOIN public."Clubs" c ON c."ShortName" = l.club_short_name
LEFT JOIN public.gpsl_owner_registry r ON r.owner_id = l.current_highest_bidder
WHERE l.status = 'Active'
  AND c.owner_id IS NULL
ORDER BY l.prestige_rank NULLS LAST, l.club_short_name;

GRANT SELECT ON public.club_auction_listings_public TO authenticated;
GRANT SELECT ON public.club_auction_listings_public TO anon;

GRANT EXECUTE ON FUNCTION public.club_auction_opening_bid_for_capacity(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_club_auction_refresh_opening_bids() TO authenticated;

-- Align active listings with capacity × ₿1,000 (safe to re-run)
UPDATE public."Club_Auction_Listings" l
SET opening_bid = public.club_auction_opening_bid_for_capacity(coalesce(c."Capacity", 0)::bigint),
    reserve_price = public.club_auction_opening_bid_for_capacity(coalesce(c."Capacity", 0)::bigint),
    expected_position = public.competition_club_baseline_expected_position(
      l.prestige_rank,
      (SELECT count(*)::smallint FROM public."Clubs" c2 WHERE c2."ShortName" <> 'FOREIGN')
    ),
    updated_at = now()
FROM public."Clubs" c
WHERE c."ShortName" = l.club_short_name
  AND l.status = 'Active';

NOTIFY pgrst, 'reload schema';
