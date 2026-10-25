-- =============================================================================
-- Legacy card release → market value (not purchase refund) — 2026-10-25
-- =============================================================================
-- After a PESDB sync, cards missing from pesdb.net are marked legacy while they
-- stay at a club. Owners may release them for Players.market_value at any time:
--   • No voluntary / New Owner release quota used
--   • Central Bank credits market value (ledger type legacy_card_refund)
--   • Player becomes a free agent; pesdb_unavailable stays true → unsignable
--     until a future sync restores the card
-- Replaces the earlier “refund what you paid” payout with market value.
-- Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.legacy_cards_rows(p_club text DEFAULT NULL)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT coalesce(jsonb_agg(jsonb_build_object(
      'club', x.club,
      'player_id', x.player_id,
      'name', x.name,
      'position', x.position,
      'rating', x.rating,
      'market_value', x.market_value,
      'contract_seasons_remaining', x.seasons,
      'contract_wage', x.wage,
      'legacy_since', x.legacy_since,
      'bought_at', pu.bought_at,
      'how', pu.how,
      'bought_while_legacy', (x.legacy_since IS NOT NULL AND pu.bought_at IS NOT NULL
                              AND pu.bought_at >= x.legacy_since),
      'fee_paid', pu.fee_paid,
      'agent_fee', pu.agent_fee,
      'income_tax', pu.income_tax,
      -- Payout is market value (0 if already refunded / released accounting row exists for this purchase)
      'refund', CASE
        WHEN pu.already_refunded THEN 0
        ELSE greatest(coalesce(nullif(btrim(x.market_value::text), '')::numeric, 0), 0)
      END,
      'payout_kind', 'market_value',
      'already_refunded', pu.already_refunded
    ) ORDER BY x.club, x.name), '[]'::jsonb)
  FROM (
    SELECT public.player_contracted_club_key(p."Contracted_Team") AS club,
           p."Konami_ID"::text AS player_id, p."Name" AS name, p."Position" AS position,
           p."Rating" AS rating, p.market_value, p.contract_seasons_remaining AS seasons,
           p.contract_wage AS wage, p.pesdb_unavailable_since AS legacy_since
    FROM public."Players" p
    WHERE coalesce(p.pesdb_unavailable, false)
      AND public.player_contracted_club_key(p."Contracted_Team") IS NOT NULL
      AND (p_club IS NULL OR public.player_contracted_club_key(p."Contracted_Team") = p_club)
  ) x
  LEFT JOIN LATERAL public.legacy_card_purchase(x.club, x.player_id) pu ON true;
$$;

REVOKE EXECUTE ON FUNCTION public.legacy_cards_rows(text) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.legacy_card_refund_internal(
  p_player_id text,
  p_club text,
  p_by_admin boolean
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_pid text := btrim(p_player_id);
  v_player public."Players"%rowtype;
  pu record;
  v_refund numeric := 0;
  v_mv numeric := 0;
  v_ledger bigint;
  v_season bigint;
BEGIN
  SELECT * INTO v_player FROM public."Players" WHERE "Konami_ID"::text = v_pid FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Player not found';
  END IF;
  IF public.player_contracted_club_key(v_player."Contracted_Team") IS DISTINCT FROM p_club THEN
    RAISE EXCEPTION 'Player is not at this club';
  END IF;
  IF NOT coalesce(v_player.pesdb_unavailable, false) THEN
    RAISE EXCEPTION '% is not a legacy card — legacy release only applies to legacy cards', v_player."Name";
  END IF;

  PERFORM pg_advisory_xact_lock(hashtext('legacy_refund:' || v_pid));

  -- Block a second Central Bank credit for the same purchase row (if any).
  SELECT * INTO pu FROM public.legacy_card_purchase(p_club, v_pid);
  IF pu.already_refunded THEN
    RAISE EXCEPTION '% was already released / refunded for this club purchase', v_player."Name";
  END IF;

  v_mv := greatest(coalesce(nullif(btrim(v_player.market_value::text), '')::numeric, 0), 0);
  v_refund := v_mv;

  UPDATE public."Player_Transfer_Listings" l
  SET status = 'Closed', transfer_completed = false, winning_bid = NULL, winning_club = NULL
  WHERE btrim(l.player_id::text) = v_pid
    AND l.seller_club_id = p_club
    AND l.status IN ('Active', 'Review', 'Seller Review');

  UPDATE public."Player_Transfer_Bids" b
  SET status = 'rejected'
  WHERE b.is_direct = true
    AND b.listing_id IS NULL
    AND lower(coalesce(b.status::text, '')) = 'active'
    AND (btrim(coalesce(b.player_id::text, '')) = v_pid OR btrim(coalesce(b.direct_bid_id::text, '')) = v_pid);

  -- Leaves pesdb_unavailable = true → free agent stays unsignable while legacy
  PERFORM public.player_release_from_club(v_pid);

  v_season := public.current_gpsl_season_id();

  IF v_refund > 0 THEN
    v_ledger := public.post_club_ledger(
      p_club,
      'legacy_card_refund',
      v_refund,
      format('Legacy card release: %s (market value)', v_player."Name"),
      jsonb_build_object(
        'player_id', v_pid,
        'player_name', v_player."Name",
        'transfer_history_id', pu.transfer_history_id,
        'fee_paid', pu.fee_paid,
        'agent_fee', pu.agent_fee,
        'income_tax', pu.income_tax,
        'market_value', v_mv,
        'payout_kind', 'market_value',
        'legacy_card_refund', true,
        'by_admin', p_by_admin
      ),
      v_season,
      NULL,
      true,
      true
    );
  END IF;

  INSERT INTO public.player_legacy_card_refunds (
    player_id, player_name, club_short_name, transfer_history_id, amount, ledger_id, refunded_by, by_admin
  ) VALUES (
    v_pid, v_player."Name", p_club,
    pu.transfer_history_id,
    v_refund, v_ledger, auth.uid(), p_by_admin
  );

  RETURN jsonb_build_object(
    'ok', true,
    'player_id', v_pid,
    'player_name', v_player."Name",
    'club', p_club,
    'refund', v_refund,
    'market_value', v_mv,
    'payout_kind', 'market_value',
    'fee_paid', pu.fee_paid,
    'agent_fee', pu.agent_fee,
    'income_tax', pu.income_tax,
    'ledger_id', v_ledger
  );
END;
$function$;

REVOKE EXECUTE ON FUNCTION public.legacy_card_refund_internal(text, text, boolean) FROM PUBLIC, anon, authenticated;

COMMENT ON FUNCTION public.player_legacy_card_refund(text) IS
  'Release a legacy card for market value. No release quota. Player becomes an unsignable legacy free agent.';
