-- =============================================================================
-- Expiry wage-bid audit — contested players WITH bids
--
-- Use this around season rollover to see what should happen, then what did.
--
-- BEFORE Create Pre-Season / Tick:
--   1) Run STEP A (creates/refreshes snapshot table)
--   2) Run STEP B (export / review expected outcomes) — download as CSV if you like
--
-- AFTER Create Pre-Season + Tick:
--   3) Run STEP C (compare snapshot → live squad / wages / ledger / transfers)
--      (uncomment the STEP C query block at the bottom)
--
-- Safe re-run. Run in Supabase SQL Editor.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- STEP A — Snapshot contested players that have at least one wage bid
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.admin_expiry_bid_audit_snapshot (
  snapshot_id bigserial PRIMARY KEY,
  snapped_at timestamptz NOT NULL DEFAULT now(),
  bid_season_label text NOT NULL,
  player_id text NOT NULL,
  player_name text,
  position text,
  age text,
  nation text,
  rating numeric,
  market_value numeric,
  holding_club text,
  holding_tier text,
  current_wage numeric,
  contract_seasons_remaining int,
  bid_count int NOT NULL DEFAULT 0,
  expected_winner_club text,
  expected_winning_wage numeric,
  expected_holder_wins boolean,
  expected_mv_to_holder numeric,
  expected_champ_sl_signing_fee numeric,
  all_bids jsonb NOT NULL DEFAULT '[]'::jsonb,
  notes text
);

CREATE INDEX IF NOT EXISTS admin_expiry_bid_audit_snapshot_at_idx
  ON public.admin_expiry_bid_audit_snapshot (snapped_at DESC);

CREATE INDEX IF NOT EXISTS admin_expiry_bid_audit_snapshot_player_idx
  ON public.admin_expiry_bid_audit_snapshot (player_id, snapped_at DESC);

COMMENT ON TABLE public.admin_expiry_bid_audit_snapshot IS
  'Pre-rollover snapshot of contested expiry players who have wage bids — for post-tick audit.';

-- Fresh snapshot batch (keeps older batches for history)
DO $$
DECLARE
  v_bid_label text;
  v_fee_pct numeric := 15;
  v_batch timestamptz := now();
  v_count int := 0;
BEGIN
  -- Prefer previous season relative to newest preseason; else current label; else latest bid label
  BEGIN
    SELECT c.bid_season_label INTO v_bid_label
    FROM public.contract_rollover_finance_context() c;
  EXCEPTION
    WHEN OTHERS THEN
      v_bid_label := NULL;
  END;

  IF v_bid_label IS NULL THEN
    v_bid_label := public.current_gpsl_season_label();
  END IF;

  IF v_bid_label IS NULL THEN
    SELECT b.season_label INTO v_bid_label
    FROM public.contract_expiry_wage_bids b
    GROUP BY b.season_label
    ORDER BY max(b.created_at) DESC
    LIMIT 1;
  END IF;

  IF v_bid_label IS NULL OR btrim(v_bid_label) = '' THEN
    RAISE EXCEPTION 'No season_label found for expiry bids — nothing to snapshot';
  END IF;

  BEGIN
    v_fee_pct := public.contract_expiry_champ_sl_signing_fee_pct();
  EXCEPTION
    WHEN OTHERS THEN
      v_fee_pct := 15;
  END;

  INSERT INTO public.admin_expiry_bid_audit_snapshot (
    snapped_at,
    bid_season_label,
    player_id,
    player_name,
    position,
    age,
    nation,
    rating,
    market_value,
    holding_club,
    holding_tier,
    current_wage,
    contract_seasons_remaining,
    bid_count,
    expected_winner_club,
    expected_winning_wage,
    expected_holder_wins,
    expected_mv_to_holder,
    expected_champ_sl_signing_fee,
    all_bids,
    notes
  )
  SELECT
    v_batch,
    v_bid_label,
    p."Konami_ID"::text,
    p."Name",
    p."Position",
    p."Age"::text,
    p."Nation",
    p."Rating",
    greatest(coalesce(p.market_value::numeric, 0), 0),
    public.player_contracted_club_key(p."Contracted_Team"),
    public.competition_club_division_tier(
      public.player_contracted_club_key(p."Contracted_Team")
    ),
    p.contract_wage,
    p.contract_seasons_remaining,
    agg.bid_count,
    agg.expected_winner_club,
    agg.expected_winning_wage,
    (agg.expected_winner_club = public.player_contracted_club_key(p."Contracted_Team")),
    CASE
      WHEN agg.expected_winner_club IS DISTINCT FROM public.player_contracted_club_key(p."Contracted_Team")
        THEN greatest(coalesce(p.market_value::numeric, 0), 0)
      ELSE 0
    END,
    CASE
      WHEN agg.expected_winner_club IS DISTINCT FROM public.player_contracted_club_key(p."Contracted_Team")
       AND public.competition_club_division_tier(
             public.player_contracted_club_key(p."Contracted_Team")
           ) = 'superleague'
       AND public.competition_club_division_tier(agg.expected_winner_club) = 'championship'
        THEN round(greatest(coalesce(p.market_value::numeric, 0), 0) * v_fee_pct / 100.0)
      ELSE 0
    END,
    agg.all_bids,
    CASE
      WHEN NOT public.player_expiry_auction_applies(p."Konami_ID"::text)
        THEN 'WARNING: bids exist but player_expiry_auction_applies=false'
      WHEN coalesce(p.contract_seasons_remaining, 0) <> 1
        THEN 'WARNING: not remaining=1'
      ELSE 'contested + has bid(s)'
    END
  FROM public."Players" p
  JOIN LATERAL (
    SELECT
      count(*)::int AS bid_count,
      (
        SELECT b2.bidder_club_short_name
        FROM public.contract_expiry_wage_bids b2
        WHERE b2.player_id = p."Konami_ID"::text
          AND b2.season_label = v_bid_label
        ORDER BY
          b2.wage_offer DESC,
          CASE
            WHEN b2.bidder_club_short_name
              = public.player_contracted_club_key(p."Contracted_Team")
              THEN 0 ELSE 1
          END,
          b2.created_at ASC
        LIMIT 1
      ) AS expected_winner_club,
      (
        SELECT b2.wage_offer
        FROM public.contract_expiry_wage_bids b2
        WHERE b2.player_id = p."Konami_ID"::text
          AND b2.season_label = v_bid_label
        ORDER BY
          b2.wage_offer DESC,
          CASE
            WHEN b2.bidder_club_short_name
              = public.player_contracted_club_key(p."Contracted_Team")
              THEN 0 ELSE 1
          END,
          b2.created_at ASC
        LIMIT 1
      ) AS expected_winning_wage,
      coalesce(
        (
          SELECT jsonb_agg(
            jsonb_build_object(
              'bidder', b3.bidder_club_short_name,
              'wage_offer', b3.wage_offer,
              'created_at', b3.created_at
            )
            ORDER BY b3.wage_offer DESC, b3.created_at ASC
          )
          FROM public.contract_expiry_wage_bids b3
          WHERE b3.player_id = p."Konami_ID"::text
            AND b3.season_label = v_bid_label
        ),
        '[]'::jsonb
      ) AS all_bids
    FROM public.contract_expiry_wage_bids b
    WHERE b.player_id = p."Konami_ID"::text
      AND b.season_label = v_bid_label
  ) agg ON agg.bid_count > 0
  WHERE public.player_expiry_auction_applies(p."Konami_ID"::text)
     OR EXISTS (
       SELECT 1
       FROM public.contract_expiry_wage_bids bx
       WHERE bx.player_id = p."Konami_ID"::text
         AND bx.season_label = v_bid_label
     );

  GET DIAGNOSTICS v_count = ROW_COUNT;

  RAISE NOTICE 'Snapshot % — % contested player(s) with bids for season_label=%',
    v_batch, v_count, v_bid_label;
END $$;

-- ---------------------------------------------------------------------------
-- STEP B — Export / review expected outcomes (latest snapshot batch)
-- In Supabase: run this alone if needed, then Download as CSV
-- ---------------------------------------------------------------------------
SELECT
  s.snapped_at,
  s.bid_season_label,
  s.player_id,
  s.player_name,
  s.position,
  s.age,
  s.holding_club,
  s.holding_tier,
  s.current_wage AS wage_before,
  s.market_value,
  s.bid_count,
  s.expected_winner_club,
  s.expected_winning_wage,
  s.expected_holder_wins AS stays_at_holder,
  s.expected_mv_to_holder AS expected_mv_fee,
  s.expected_champ_sl_signing_fee,
  s.all_bids,
  s.notes
FROM public.admin_expiry_bid_audit_snapshot s
WHERE s.snapped_at = (
  SELECT max(s2.snapped_at) FROM public.admin_expiry_bid_audit_snapshot s2
)
ORDER BY
  s.expected_holder_wins ASC,
  s.expected_mv_to_holder DESC,
  s.player_name;

-- ---------------------------------------------------------------------------
-- STEP C — AFTER tick: compare snapshot → actual outcomes
-- Uncomment and run AFTER Create Pre-Season / Tick
-- ---------------------------------------------------------------------------

-- SELECT
--   s.player_id,
--   s.player_name,
--   s.holding_club AS club_before,
--   s.expected_winner_club,
--   s.expected_winning_wage,
--   public.player_contracted_club_key(p."Contracted_Team") AS club_after,
--   p.contract_wage AS wage_after,
--   p.contract_seasons_remaining AS seasons_after,
--   p."Season_Signed" AS season_signed_after,
--   CASE
--     WHEN p."Konami_ID" IS NULL THEN 'FAIL: player row missing'
--     WHEN public.player_contracted_club_key(p."Contracted_Team") IS NULL
--       THEN 'UNEXPECTED FA (had winning bid expected)'
--     WHEN public.player_contracted_club_key(p."Contracted_Team")
--          IS NOT DISTINCT FROM s.expected_winner_club
--      AND round(coalesce(p.contract_wage, 0), 0)
--          = round(coalesce(s.expected_winning_wage, 0), 0)
--      AND coalesce(p.contract_seasons_remaining, 0) = 3
--       THEN 'OK'
--     WHEN public.player_contracted_club_key(p."Contracted_Team")
--          IS NOT DISTINCT FROM s.expected_winner_club
--      AND coalesce(p.contract_seasons_remaining, 0) = 3
--       THEN 'CHECK wage'
--     ELSE 'CHECK club/wage/seasons'
--   END AS contract_status,
--   s.expected_mv_to_holder,
--   coalesce(led.purchase_amt, 0) AS ledger_purchase_on_new_season,
--   coalesce(led.sale_amt, 0) AS ledger_sale_on_new_season,
--   coalesce(led.signing_fee_amt, 0) AS ledger_champ_signing_fee,
--   CASE
--     WHEN s.expected_mv_to_holder <= 0 THEN 'n/a (holder won / no MV)'
--     WHEN coalesce(led.sale_amt, 0) >= s.expected_mv_to_holder * 0.999
--      AND coalesce(led.purchase_amt, 0) <= -s.expected_mv_to_holder * 0.999
--       THEN 'OK MV posted'
--     ELSE 'CHECK MV ledger'
--   END AS mv_status,
--   CASE
--     WHEN s.expected_champ_sl_signing_fee <= 0 THEN 'n/a'
--     WHEN coalesce(led.signing_fee_amt, 0) <= -s.expected_champ_sl_signing_fee * 0.999
--       THEN 'OK signing fee'
--     ELSE 'CHECK signing fee'
--   END AS signing_fee_status,
--   th.transfer_time AS transfer_history_at,
--   th.buyer_club_id AS th_buyer,
--   th.fee AS th_fee
-- FROM public.admin_expiry_bid_audit_snapshot s
-- LEFT JOIN public."Players" p
--   ON p."Konami_ID"::text = s.player_id
-- LEFT JOIN LATERAL (
--   SELECT
--     sum(CASE WHEN l.entry_type = 'transfer_purchase' THEN l.amount ELSE 0 END) AS purchase_amt,
--     sum(CASE WHEN l.entry_type = 'transfer_sale' THEN l.amount ELSE 0 END) AS sale_amt,
--     sum(CASE WHEN l.entry_type = 'contract_expiry_champ_signing_fee' THEN l.amount ELSE 0 END)
--       AS signing_fee_amt
--   FROM public.competition_finance_ledger l
--   WHERE l.metadata->>'player_id' = s.player_id
--     AND coalesce(l.metadata->>'source', '') = 'contract_expiry'
--     AND l.season_id = (
--       SELECT cs.id
--       FROM public.competition_seasons cs
--       WHERE cs.status IN ('preseason', 'setup', 'active')
--       ORDER BY cs.id DESC
--       LIMIT 1
--     )
-- ) led ON true
-- LEFT JOIN LATERAL (
--   SELECT h.transfer_time, h.buyer_club_id, h.fee
--   FROM public."Transfer_History" h
--   WHERE h.player_id = s.player_id
--     AND h.transfer_time >= s.snapped_at
--   ORDER BY h.transfer_time DESC
--   LIMIT 1
-- ) th ON true
-- WHERE s.snapped_at = (
--   SELECT max(s2.snapped_at) FROM public.admin_expiry_bid_audit_snapshot s2
-- )
-- ORDER BY
--   CASE
--     WHEN public.player_contracted_club_key(p."Contracted_Team")
--          IS NOT DISTINCT FROM s.expected_winner_club
--      AND round(coalesce(p.contract_wage, 0), 0)
--          = round(coalesce(s.expected_winning_wage, 0), 0)
--       THEN 1
--     ELSE 0
--   END,
--   s.player_name;

-- Optional: list snapshot batches
-- SELECT snapped_at, bid_season_label, count(*) AS players
-- FROM public.admin_expiry_bid_audit_snapshot
-- GROUP BY 1, 2
-- ORDER BY 1 DESC;
