-- =============================================================================
-- Expiry wage-bid rollover audit (one script — run before AND after tick)
--
-- Run the WHOLE file in Supabase SQL Editor.
-- You should always see a results table (players, or one DIAGNOSTIC row).
--
-- BEFORE tick: report_mode = BEFORE_TICK (expected winners / fees)
-- AFTER tick:  report_mode = AFTER_TICK  (OK / CHECK vs snapshot)
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.admin_expiry_bid_audit_snapshot (
  snapshot_id bigserial PRIMARY KEY,
  snapped_at timestamptz NOT NULL DEFAULT now(),
  bid_season_label text NOT NULL,
  player_id text NOT NULL,
  player_name text,
  position text,
  age text,
  nation text,
  rating text,
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

DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'admin_expiry_bid_audit_snapshot'
      AND column_name = 'rating'
      AND data_type = 'numeric'
  ) THEN
    ALTER TABLE public.admin_expiry_bid_audit_snapshot
      ALTER COLUMN rating TYPE text USING rating::text;
  END IF;
END $$;

DO $$
DECLARE
  v_bid_label text;
  v_fee_pct numeric := 15;
  v_batch timestamptz := now();
  v_open_bids int := 0;
  v_count int := 0;
  v_labels text;
BEGIN
  SELECT count(*)::int INTO v_open_bids
  FROM public.contract_expiry_wage_bids;

  IF v_open_bids = 0 THEN
    RAISE NOTICE 'No open expiry wage bids — AFTER mode if a prior snapshot exists.';
    RETURN;
  END IF;

  -- Season label that actually has the most bids (avoids wrong-label empty snapshot)
  SELECT b.season_label INTO v_bid_label
  FROM public.contract_expiry_wage_bids b
  GROUP BY b.season_label
  ORDER BY count(*) DESC, max(b.created_at) DESC
  LIMIT 1;

  SELECT string_agg(x.lbl || ' (' || x.n::text || ')', ', ' ORDER BY x.n DESC)
  INTO v_labels
  FROM (
    SELECT season_label AS lbl, count(*)::int AS n
    FROM public.contract_expiry_wage_bids
    GROUP BY season_label
  ) x;

  RAISE NOTICE 'Open bids=%; using season_label=%; all: %',
    v_open_bids, v_bid_label, coalesce(v_labels, '(none)');

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
    d.player_id,
    p."Name",
    p."Position",
    p."Age"::text,
    p."Nation",
    p."Rating"::text,
    greatest(coalesce(p.market_value::numeric, 0), 0),
    d.holding_club,
    CASE
      WHEN d.holding_club IS NULL THEN NULL
      ELSE public.competition_club_division_tier(d.holding_club)
    END,
    p.contract_wage,
    p.contract_seasons_remaining::int,
    d.bid_count,
    d.expected_winner_club,
    d.expected_winning_wage,
    (d.expected_winner_club IS NOT DISTINCT FROM d.holding_club),
    CASE
      WHEN d.expected_winner_club IS DISTINCT FROM d.holding_club
        THEN greatest(coalesce(p.market_value::numeric, 0), 0)
      ELSE 0
    END,
    CASE
      WHEN d.expected_winner_club IS DISTINCT FROM d.holding_club
       AND d.holding_club IS NOT NULL
       AND public.competition_club_division_tier(d.holding_club) = 'superleague'
       AND public.competition_club_division_tier(d.expected_winner_club) = 'championship'
        THEN round(greatest(coalesce(p.market_value::numeric, 0), 0) * v_fee_pct / 100.0)
      ELSE 0
    END,
    d.all_bids,
    CASE
      WHEN p."Konami_ID" IS NULL THEN 'WARNING: player_id not in Players'
      WHEN to_regprocedure('public.player_expiry_auction_applies(text)') IS NOT NULL
       AND NOT public.player_expiry_auction_applies(d.player_id)
        THEN 'WARNING: bids exist but auction_applies=false'
      WHEN coalesce(p.contract_seasons_remaining, 0) <> 1
        THEN 'WARNING: not remaining=1'
      ELSE 'contested + has bid(s)'
    END
  FROM (
    SELECT
      b.player_id,
      count(*)::int AS bid_count,
      public.player_contracted_club_key(
        (SELECT p2."Contracted_Team" FROM public."Players" p2
         WHERE p2."Konami_ID"::text = b.player_id)
      ) AS holding_club,
      (
        SELECT b2.bidder_club_short_name
        FROM public.contract_expiry_wage_bids b2
        WHERE b2.player_id = b.player_id
          AND b2.season_label = v_bid_label
        ORDER BY
          b2.wage_offer DESC,
          CASE
            WHEN b2.bidder_club_short_name = public.player_contracted_club_key(
              (SELECT p3."Contracted_Team" FROM public."Players" p3
               WHERE p3."Konami_ID"::text = b.player_id)
            ) THEN 0 ELSE 1
          END,
          b2.created_at ASC
        LIMIT 1
      ) AS expected_winner_club,
      (
        SELECT b2.wage_offer
        FROM public.contract_expiry_wage_bids b2
        WHERE b2.player_id = b.player_id
          AND b2.season_label = v_bid_label
        ORDER BY
          b2.wage_offer DESC,
          CASE
            WHEN b2.bidder_club_short_name = public.player_contracted_club_key(
              (SELECT p3."Contracted_Team" FROM public."Players" p3
               WHERE p3."Konami_ID"::text = b.player_id)
            ) THEN 0 ELSE 1
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
          WHERE b3.player_id = b.player_id
            AND b3.season_label = v_bid_label
        ),
        '[]'::jsonb
      ) AS all_bids
    FROM public.contract_expiry_wage_bids b
    WHERE b.season_label = v_bid_label
    GROUP BY b.player_id
  ) d
  LEFT JOIN public."Players" p
    ON p."Konami_ID"::text = d.player_id;

  GET DIAGNOSTICS v_count = ROW_COUNT;
  RAISE NOTICE 'Snapshot saved: % player(s) at %', v_count, v_batch;
END $$;

-- Always return rows: player report, or a single diagnostic row
WITH latest AS (
  SELECT max(snapped_at) AS snapped_at
  FROM public.admin_expiry_bid_audit_snapshot
),
open_bids AS (
  SELECT count(*)::int AS n FROM public.contract_expiry_wage_bids
),
bid_labels AS (
  SELECT coalesce(
    string_agg(season_label || ' (' || n::text || ')', ', ' ORDER BY n DESC),
    '(none)'
  ) AS labels
  FROM (
    SELECT season_label, count(*)::int AS n
    FROM public.contract_expiry_wage_bids
    GROUP BY season_label
  ) x
),
report AS (
  SELECT
    CASE WHEN (SELECT n FROM open_bids) > 0 THEN 'BEFORE_TICK' ELSE 'AFTER_TICK' END
      AS report_mode,
    s.snapped_at,
    s.bid_season_label,
    s.player_id,
    s.player_name,
    s.holding_club AS club_before,
    s.expected_winner_club,
    s.expected_winning_wage,
    s.current_wage AS wage_before,
    s.market_value,
    s.bid_count,
    s.expected_holder_wins AS stays_at_holder,
    s.expected_mv_to_holder,
    s.expected_champ_sl_signing_fee,
    CASE WHEN (SELECT n FROM open_bids) > 0 THEN NULL
         ELSE public.player_contracted_club_key(p."Contracted_Team")
    END AS club_after,
    CASE WHEN (SELECT n FROM open_bids) > 0 THEN NULL ELSE p.contract_wage END
      AS wage_after,
    CASE WHEN (SELECT n FROM open_bids) > 0 THEN NULL ELSE p.contract_seasons_remaining END
      AS seasons_after,
    CASE WHEN (SELECT n FROM open_bids) > 0 THEN NULL ELSE p."Season_Signed" END
      AS season_signed_after,
    CASE
      WHEN (SELECT n FROM open_bids) > 0 THEN s.notes
      WHEN p."Konami_ID" IS NULL THEN 'FAIL: player row missing'
      WHEN public.player_contracted_club_key(p."Contracted_Team") IS NULL
        THEN 'UNEXPECTED FA (had winning bid expected)'
      WHEN public.player_contracted_club_key(p."Contracted_Team")
           IS NOT DISTINCT FROM s.expected_winner_club
       AND round(coalesce(p.contract_wage, 0), 0)
           = round(coalesce(s.expected_winning_wage, 0), 0)
       AND coalesce(p.contract_seasons_remaining, 0) = 3
        THEN 'OK'
      WHEN public.player_contracted_club_key(p."Contracted_Team")
           IS NOT DISTINCT FROM s.expected_winner_club
       AND coalesce(p.contract_seasons_remaining, 0) = 3
        THEN 'CHECK wage'
      ELSE 'CHECK club/wage/seasons'
    END AS contract_status,
    CASE WHEN (SELECT n FROM open_bids) > 0 THEN NULL ELSE coalesce(led.purchase_amt, 0) END
      AS ledger_purchase,
    CASE WHEN (SELECT n FROM open_bids) > 0 THEN NULL ELSE coalesce(led.sale_amt, 0) END
      AS ledger_sale,
    CASE WHEN (SELECT n FROM open_bids) > 0 THEN NULL ELSE coalesce(led.signing_fee_amt, 0) END
      AS ledger_champ_signing_fee,
    CASE
      WHEN (SELECT n FROM open_bids) > 0 THEN NULL
      WHEN s.expected_mv_to_holder <= 0 THEN 'n/a (holder won / no MV)'
      WHEN coalesce(led.sale_amt, 0) >= s.expected_mv_to_holder * 0.999
       AND coalesce(led.purchase_amt, 0) <= -s.expected_mv_to_holder * 0.999
        THEN 'OK MV posted'
      ELSE 'CHECK MV ledger'
    END AS mv_status,
    CASE
      WHEN (SELECT n FROM open_bids) > 0 THEN NULL
      WHEN s.expected_champ_sl_signing_fee <= 0 THEN 'n/a'
      WHEN coalesce(led.signing_fee_amt, 0) <= -s.expected_champ_sl_signing_fee * 0.999
        THEN 'OK signing fee'
      ELSE 'CHECK signing fee'
    END AS signing_fee_status,
    s.all_bids::text AS all_bids
  FROM public.admin_expiry_bid_audit_snapshot s
  CROSS JOIN latest
  LEFT JOIN public."Players" p
    ON p."Konami_ID"::text = s.player_id
  LEFT JOIN LATERAL (
    SELECT
      sum(CASE WHEN l.entry_type = 'transfer_purchase' THEN l.amount ELSE 0 END) AS purchase_amt,
      sum(CASE WHEN l.entry_type = 'transfer_sale' THEN l.amount ELSE 0 END) AS sale_amt,
      sum(CASE WHEN l.entry_type = 'contract_expiry_champ_signing_fee' THEN l.amount ELSE 0 END)
        AS signing_fee_amt
    FROM public.competition_finance_ledger l
    WHERE l.metadata->>'player_id' = s.player_id
      AND coalesce(l.metadata->>'source', '') = 'contract_expiry'
      AND l.season_id = (
        SELECT cs.id
        FROM public.competition_seasons cs
        WHERE cs.status IN ('preseason', 'setup', 'active')
        ORDER BY cs.id DESC
        LIMIT 1
      )
  ) led ON true
  WHERE latest.snapped_at IS NOT NULL
    AND s.snapped_at = latest.snapped_at
)
SELECT * FROM report
UNION ALL
SELECT
  'DIAGNOSTIC' AS report_mode,
  NULL, NULL,
  NULL,
  'No snapshot rows — check open bids / season labels' AS player_name,
  NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
  NULL, NULL, NULL, NULL,
  'open_bids=' || (SELECT n::text FROM open_bids)
    || '; labels=' || (SELECT labels FROM bid_labels)
    || '; snapshot_rows=' || (
      SELECT count(*)::text FROM public.admin_expiry_bid_audit_snapshot
    ) AS contract_status,
  NULL, NULL, NULL, NULL, NULL, NULL
WHERE NOT EXISTS (SELECT 1 FROM report)
ORDER BY 1, 5;
