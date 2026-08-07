-- =============================================================================
-- Diagnose Create Pre-Season contract tick counts
--
-- Run whole file in SQL Editor. Returns one result set.
-- Use after a tick that looks "too small" (e.g. 91 FA / 0 contested).
-- =============================================================================

WITH ctx AS (
  SELECT *
  FROM public.contract_rollover_finance_context()
),
bid_labels AS (
  SELECT
    coalesce(nullif(btrim(b.season_label), ''), '(blank)') AS season_label,
    count(*)::int AS bid_rows,
    count(DISTINCT b.player_id)::int AS players_with_bids
  FROM public.contract_expiry_wage_bids b
  GROUP BY 1
),
remaining AS (
  SELECT
    coalesce(p.contract_seasons_remaining::text, 'NULL') AS remaining,
    count(*)::int AS players
  FROM public."Players" p
  WHERE public.player_contracted_club_key(p."Contracted_Team") IS NOT NULL
  GROUP BY 1
),
final_year AS (
  SELECT
    count(*) FILTER (
      WHERE coalesce(p.contract_seasons_remaining, 0) = 1
    )::int AS remaining_1,
    count(*) FILTER (
      WHERE coalesce(p.contract_seasons_remaining, 0) = 1
        AND EXISTS (
          SELECT 1 FROM public.contract_expiry_wage_bids b
          WHERE b.player_id = p."Konami_ID"::text
        )
    )::int AS remaining_1_with_any_bid,
    count(*) FILTER (
      WHERE coalesce(p.contract_seasons_remaining, 0) = 1
        AND EXISTS (
          SELECT 1
          FROM public.contract_expiry_wage_bids b
          CROSS JOIN ctx
          WHERE b.player_id = p."Konami_ID"::text
            AND (
              b.season_label = ctx.bid_season_label
              OR b.season_label IS NOT DISTINCT FROM ctx.bid_season_label
            )
        )
    )::int AS remaining_1_with_ctx_bid,
    count(*) FILTER (
      WHERE coalesce(p.contract_seasons_remaining, 0) = 1
        AND to_regprocedure('public.player_expiry_auction_applies(text)') IS NOT NULL
        AND public.player_expiry_auction_applies(p."Konami_ID"::text)
    )::int AS remaining_1_auction_applies,
    count(*) FILTER (
      WHERE coalesce(p.contract_seasons_remaining, 0) <= 0
    )::int AS remaining_le_0_still_at_club
  FROM public."Players" p
  WHERE public.player_contracted_club_key(p."Contracted_Team") IS NOT NULL
),
expiry_hist AS (
  SELECT count(*)::int AS transfer_history_expiry_rows
  FROM public."Transfer_History" th
  WHERE th.transfer_sale_note = 'contract_expiry'
    AND th.transfer_time > now() - interval '2 days'
),
tick_log AS (
  SELECT
    l.for_season_id,
    l.for_season_label,
    l.ticked_at,
    l.result
  FROM public.competition_contract_tick_log l
  ORDER BY l.ticked_at DESC
  LIMIT 3
)
SELECT
  jsonb_build_object(
    'finance_context', (SELECT to_jsonb(c) FROM ctx c),
    'open_bid_labels', coalesce(
      (SELECT jsonb_agg(to_jsonb(b) ORDER BY b.bid_rows DESC) FROM bid_labels b),
      '[]'::jsonb
    ),
    'open_bids_total', (SELECT count(*)::int FROM public.contract_expiry_wage_bids),
    'contracted_by_remaining', coalesce(
      (SELECT jsonb_agg(to_jsonb(r) ORDER BY r.remaining) FROM remaining r),
      '[]'::jsonb
    ),
    'final_year_breakdown', (SELECT to_jsonb(f) FROM final_year f),
    'recent_expiry_transfer_history', (SELECT to_jsonb(e) FROM expiry_hist e),
    'recent_tick_logs', coalesce(
      (SELECT jsonb_agg(to_jsonb(t) ORDER BY t.ticked_at DESC) FROM tick_log t),
      '[]'::jsonb
    ),
    'hint',
      'If open_bids_total>0 but finance_context.bid_season_label is not in open_bid_labels → label mismatch (0 contested). '
      || 'If remaining_1 is still huge → FA step did not clear them. '
      || 'If remaining_1 is tiny and recent_expiry_transfer_history is large → tick already ran (client timeout after DB commit).'
  ) AS diagnosis;
