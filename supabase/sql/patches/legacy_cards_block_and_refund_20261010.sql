-- =============================================================================
-- Legacy cards: close every way in + owner refund + report (2026-10-10)
-- =============================================================================
-- Legacy card = Players.pesdb_unavailable (card no longer on pesdb.net).
-- Clubs ended up owning legacy cards bought in the draft. The checks lived in
-- functions that several older patches redefine (re-running one reopens the
-- hole), and nothing stopped a draft that was already open when the card went
-- legacy from settling.
--
-- This patch adds guards that live in their own triggers:
--   1) Bids: any bid (draft, auto-bid, max bid, scouting, offer) on a legacy
--      card is refused at insert.
--   2) Signing: a legacy card can't go from free agent to a club. The error
--      reads as an exclusion, so draft settlement closes that auction unsold
--      instead of failing.
--   3) Card goes legacy on a sync → its open draft auctions close (unsold)
--      and every max bid on it is removed.
--   4) Open draft auctions on legacy cards now → closed.
--
-- Refund (owner, any time, regardless of contract):
--   player_legacy_card_refund(player_id) → player released to free agency and
--   the club gets back what it paid for its latest purchase of the card:
--   fee actually paid + agent fee + income tax on that purchase. Paid by the
--   Central Bank (ledger type legacy_card_refund). One refund per purchase.
--   Admin can do the same for any club: admin_legacy_card_refund(player_id).
--
-- Report:
--   club_legacy_cards(club)         → Squad page panel (own club / staff)
--   admin_legacy_cards_report()      → every legacy card at a club
--
-- Safe re-run.
-- =============================================================================

SELECT public.gpsl_ledger_ensure_entry_types(ARRAY['legacy_card_refund']);

CREATE TABLE IF NOT EXISTS public.player_legacy_card_refunds (
  id bigserial PRIMARY KEY,
  player_id text NOT NULL,
  player_name text,
  club_short_name text NOT NULL,
  transfer_history_id bigint,
  amount numeric(14, 2) NOT NULL DEFAULT 0,
  ledger_id bigint,
  refunded_by uuid,
  by_admin boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS player_legacy_card_refunds_history_uq
  ON public.player_legacy_card_refunds (transfer_history_id)
  WHERE transfer_history_id IS NOT NULL;

ALTER TABLE public.player_legacy_card_refunds ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS player_legacy_card_refunds_read ON public.player_legacy_card_refunds;
CREATE POLICY player_legacy_card_refunds_read ON public.player_legacy_card_refunds
  FOR SELECT TO authenticated USING (true);

-- ---------------------------------------------------------------------------
-- 1) Bids on legacy cards — refused at insert
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.trg_player_transfer_bids_block_legacy()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_pid text := nullif(btrim(coalesce(NEW.player_id::text, NEW.direct_bid_id::text, '')), '');
BEGIN
  IF v_pid IS NULL AND NEW.listing_id IS NOT NULL THEN
    SELECT nullif(btrim(l.player_id::text), '') INTO v_pid
    FROM public."Player_Transfer_Listings" l
    WHERE l.id = NEW.listing_id;
  END IF;

  IF v_pid IS NOT NULL AND EXISTS (
    SELECT 1 FROM public."Players" p
    WHERE p."Konami_ID"::text = v_pid AND coalesce(p.pesdb_unavailable, false)
  ) THEN
    RAISE EXCEPTION
      'This player card is no longer on pesdb.net (legacy card). It cannot be bid on until it returns on a PESDB sync.';
  END IF;

  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS player_transfer_bids_00_block_legacy ON public."Player_Transfer_Bids";
CREATE TRIGGER player_transfer_bids_00_block_legacy
  BEFORE INSERT ON public."Player_Transfer_Bids"
  FOR EACH ROW EXECUTE FUNCTION public.trg_player_transfer_bids_block_legacy();

-- ---------------------------------------------------------------------------
-- 2) Signing a legacy free agent — refused (settlement soft-skips: the
--    message matches transferengine_is_exclusion_error)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.trg_players_block_legacy_signing()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF coalesce(NEW.pesdb_unavailable, false)
     AND nullif(btrim(coalesce(OLD."Contracted_Team"::text, '')), '') IS NULL
     AND nullif(btrim(coalesce(NEW."Contracted_Team"::text, '')), '') IS NOT NULL
     AND coalesce(current_setting('gpsl.allow_legacy_signing', true), '') <> 'on' THEN
    RAISE EXCEPTION
      'Legacy card: % is excluded from GPSL signings until the card returns on pesdb.net (PESDB sync).',
      coalesce(NEW."Name", NEW."Konami_ID"::text);
  END IF;
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS players_block_legacy_signing ON public."Players";
CREATE TRIGGER players_block_legacy_signing
  BEFORE UPDATE OF "Contracted_Team" ON public."Players"
  FOR EACH ROW EXECUTE FUNCTION public.trg_players_block_legacy_signing();

-- ---------------------------------------------------------------------------
-- 3) Card goes legacy → close its draft auctions and drop max bids
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.legacy_card_close_draft_market(p_player_id text)
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_pid text := btrim(p_player_id);
  v_n int;
BEGIN
  UPDATE public."Player_Transfer_Listings" l
  SET status = 'Closed', transfer_completed = false
  WHERE l.listing_type = 'draft'
    AND l.status IN ('Active', 'Review')
    AND btrim(l.player_id::text) = v_pid;
  GET DIAGNOSTICS v_n = ROW_COUNT;

  DELETE FROM public.player_draft_max_bids m WHERE btrim(m.player_id) = v_pid;

  RETURN v_n;
END;
$function$;

CREATE OR REPLACE FUNCTION public.trg_players_legacy_close_market()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF coalesce(NEW.pesdb_unavailable, false) AND NOT coalesce(OLD.pesdb_unavailable, false) THEN
    PERFORM public.legacy_card_close_draft_market(NEW."Konami_ID"::text);
  END IF;
  RETURN NULL;
END;
$function$;

DROP TRIGGER IF EXISTS players_legacy_close_market ON public."Players";
CREATE TRIGGER players_legacy_close_market
  AFTER UPDATE OF pesdb_unavailable ON public."Players"
  FOR EACH ROW EXECUTE FUNCTION public.trg_players_legacy_close_market();

REVOKE EXECUTE ON FUNCTION public.legacy_card_close_draft_market(text) FROM PUBLIC, anon, authenticated;

-- 4) Close what is open right now
DROP TABLE IF EXISTS _legacy_closed;
CREATE TEMP TABLE _legacy_closed AS
SELECT p."Konami_ID"::text AS player_id, p."Name" AS player_name,
       public.legacy_card_close_draft_market(p."Konami_ID"::text) AS auctions_closed
FROM public."Players" p
WHERE coalesce(p.pesdb_unavailable, false)
  AND (
    EXISTS (
      SELECT 1 FROM public."Player_Transfer_Listings" l
      WHERE l.listing_type = 'draft' AND l.status IN ('Active', 'Review')
        AND btrim(l.player_id::text) = p."Konami_ID"::text
    )
    OR EXISTS (
      SELECT 1 FROM public.player_draft_max_bids m WHERE btrim(m.player_id) = p."Konami_ID"::text
    )
  );

-- ---------------------------------------------------------------------------
-- What a club paid for its latest purchase of a player
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.legacy_card_purchase(p_club text, p_player_id text)
RETURNS TABLE (
  transfer_history_id bigint,
  bought_at timestamptz,
  how text,
  fee_paid numeric,
  agent_fee numeric,
  income_tax numeric,
  total_paid numeric,
  already_refunded boolean
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  h record;
  v_fee numeric := 0;
  v_agent numeric := 0;
  v_tax numeric := 0;
  v_rows int := 0;
BEGIN
  SELECT th.id, th.transfer_time, th.fee, th.agent_fee, th.seller_club_id, th.listing_id
  INTO h
  FROM public."Transfer_History" th
  WHERE th.buyer_club_id = p_club
    AND btrim(th.player_id::text) = btrim(p_player_id)
  ORDER BY th.transfer_time DESC, th.id DESC
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN QUERY SELECT NULL::bigint, NULL::timestamptz, 'no purchase found'::text,
      0::numeric, 0::numeric, 0::numeric, 0::numeric, false;
    RETURN;
  END IF;

  SELECT
    coalesce(sum(-l.amount) FILTER (WHERE l.entry_type = 'transfer_purchase'), 0),
    coalesce(sum(-l.amount) FILTER (WHERE l.entry_type = 'transfer_agent_fee'), 0),
    coalesce(sum(-l.amount) FILTER (WHERE l.entry_type = 'gov_income_tax'), 0),
    count(*)::int
  INTO v_fee, v_agent, v_tax, v_rows
  FROM public.competition_finance_ledger l
  WHERE l.club_short_name = p_club
    AND l.metadata->>'transfer_history_id' = h.id::text
    AND l.entry_type IN ('transfer_purchase', 'transfer_agent_fee', 'gov_income_tax')
    AND l.amount < 0;

  IF v_rows = 0 THEN
    v_fee := abs(coalesce(h.fee, 0));
    v_agent := abs(coalesce(h.agent_fee, 0));
  END IF;

  RETURN QUERY SELECT
    h.id,
    h.transfer_time,
    CASE
      WHEN nullif(btrim(coalesce(h.seller_club_id::text, '')), '') IS NULL THEN 'draft / free agent'
      ELSE 'transfer from ' || h.seller_club_id::text
    END,
    round(v_fee, 2), round(v_agent, 2), round(v_tax, 2),
    round(v_fee + v_agent + v_tax, 2),
    EXISTS (SELECT 1 FROM public.player_legacy_card_refunds r WHERE r.transfer_history_id = h.id);
END;
$function$;

REVOKE EXECUTE ON FUNCTION public.legacy_card_purchase(text, text) FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Report rows (one per legacy card at a club)
-- ---------------------------------------------------------------------------
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
      'refund', CASE WHEN pu.already_refunded THEN 0 ELSE pu.total_paid END,
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

CREATE OR REPLACE FUNCTION public.club_legacy_cards(p_club_short_name text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := public.my_club_shortname();
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;
  IF p_club_short_name IS NOT NULL AND public.is_gpsl_admin() THEN
    v_club := p_club_short_name;
  END IF;
  IF v_club IS NULL OR btrim(v_club) = '' THEN
    RETURN jsonb_build_object('club', NULL, 'cards', '[]'::jsonb);
  END IF;
  RETURN jsonb_build_object(
    'club', v_club,
    'is_owner', v_club = public.my_club_shortname(),
    'cards', public.legacy_cards_rows(v_club)
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.club_legacy_cards(text) TO authenticated;

CREATE OR REPLACE FUNCTION public.admin_legacy_cards_report()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;
  RETURN jsonb_build_object(
    'cards', public.legacy_cards_rows(NULL),
    'refunds', coalesce((
      SELECT jsonb_agg(to_jsonb(r) ORDER BY r.created_at DESC)
      FROM public.player_legacy_card_refunds r
    ), '[]'::jsonb)
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.admin_legacy_cards_report() TO authenticated;

-- ---------------------------------------------------------------------------
-- Refund: release the card + pay back the purchase
-- ---------------------------------------------------------------------------
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
    RAISE EXCEPTION '% is not a legacy card — the legacy refund only applies to legacy cards', v_player."Name";
  END IF;

  PERFORM pg_advisory_xact_lock(hashtext('legacy_refund:' || v_pid));

  SELECT * INTO pu FROM public.legacy_card_purchase(p_club, v_pid);
  IF pu.transfer_history_id IS NOT NULL AND NOT pu.already_refunded THEN
    v_refund := greatest(coalesce(pu.total_paid, 0), 0);
  END IF;

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

  PERFORM public.player_release_from_club(v_pid);

  v_season := public.current_gpsl_season_id();

  IF v_refund > 0 THEN
    v_ledger := public.post_club_ledger(
      p_club,
      'legacy_card_refund',
      v_refund,
      format('Legacy card refund: %s (purchase returned)', v_player."Name"),
      jsonb_build_object(
        'player_id', v_pid,
        'player_name', v_player."Name",
        'transfer_history_id', pu.transfer_history_id,
        'fee_paid', pu.fee_paid,
        'agent_fee', pu.agent_fee,
        'income_tax', pu.income_tax,
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
    CASE WHEN v_refund > 0 THEN pu.transfer_history_id END,
    v_refund, v_ledger, auth.uid(), p_by_admin
  );

  RETURN jsonb_build_object(
    'ok', true,
    'player_id', v_pid,
    'player_name', v_player."Name",
    'club', p_club,
    'refund', v_refund,
    'fee_paid', pu.fee_paid,
    'agent_fee', pu.agent_fee,
    'income_tax', pu.income_tax,
    'ledger_id', v_ledger
  );
END;
$function$;

REVOKE EXECUTE ON FUNCTION public.legacy_card_refund_internal(text, text, boolean) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.player_legacy_card_refund(p_player_id text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;
  v_club := public.my_club_shortname();
  IF v_club IS NULL OR btrim(v_club) = '' THEN
    RAISE EXCEPTION 'No club linked to this account';
  END IF;
  RETURN public.legacy_card_refund_internal(p_player_id, v_club, false);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.player_legacy_card_refund(text) TO authenticated;

CREATE OR REPLACE FUNCTION public.admin_legacy_card_refund(p_player_id text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text;
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;
  SELECT public.player_contracted_club_key(p."Contracted_Team") INTO v_club
  FROM public."Players" p WHERE p."Konami_ID"::text = btrim(p_player_id);
  IF v_club IS NULL THEN
    RAISE EXCEPTION 'Player is not at a club';
  END IF;
  RETURN public.legacy_card_refund_internal(p_player_id, v_club, true);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.admin_legacy_card_refund(text) TO authenticated;

NOTIFY pgrst, 'reload schema';

-- ---------------------------------------------------------------------------
-- Report: every legacy card at a club (+ any draft auctions just closed)
-- bought_while_legacy = true → the club bought it AFTER it went legacy
-- ---------------------------------------------------------------------------
SELECT
  r->>'club' AS club,
  r->>'name' AS player,
  r->>'position' AS pos,
  (r->>'bought_while_legacy')::boolean AS bought_while_legacy,
  (r->>'legacy_since')::timestamptz AT TIME ZONE 'Europe/London' AS legacy_since_uk,
  (r->>'bought_at')::timestamptz AT TIME ZONE 'Europe/London' AS bought_at_uk,
  r->>'how' AS how,
  (r->>'fee_paid')::numeric AS fee_paid,
  (r->>'agent_fee')::numeric AS agent_fee,
  (r->>'income_tax')::numeric AS income_tax,
  (r->>'refund')::numeric AS refund_if_returned,
  (SELECT count(*) FROM _legacy_closed) AS open_auctions_closed_now
FROM (SELECT 1) one
LEFT JOIN LATERAL jsonb_array_elements(public.legacy_cards_rows(NULL)) r ON true
ORDER BY (r->>'bought_while_legacy')::boolean DESC NULLS LAST, r->>'club', r->>'name';
