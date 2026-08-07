-- Quick verify after diagnose: who was released, any contested winners, squad left.
-- Run in SQL Editor (multiple result sets).

-- 1) Contracted squad still on books
SELECT
  count(*) FILTER (
    WHERE nullif(btrim(p."Contracted_Team"), '') IS NOT NULL
  )::int AS contracted_team_set,
  count(*) FILTER (
    WHERE public.player_contracted_club_key(p."Contracted_Team") IS NOT NULL
  )::int AS contracted_key_ok,
  count(*) FILTER (
    WHERE public.player_contracted_club_key(p."Contracted_Team") IS NOT NULL
      AND coalesce(p.contract_seasons_remaining, 0) >= 2
  )::int AS remaining_ge_2,
  count(*) FILTER (
    WHERE public.player_contracted_club_key(p."Contracted_Team") IS NOT NULL
      AND coalesce(p.contract_seasons_remaining, 0) = 1
  )::int AS remaining_1
FROM public."Players" p;

-- 2) Expiry transfers last 3 days (FA buyer vs club-to-club)
SELECT
  CASE
    WHEN th.buyer_club_id = 'FOREIGN' OR th.foreign_buyer_name IS NOT NULL THEN 'FA_FOREIGN'
    ELSE 'CLUB_TO_CLUB'
  END AS kind,
  count(*)::int AS rows,
  coalesce(sum(th.fee), 0)::numeric AS total_fee
FROM public."Transfer_History" th
WHERE th.transfer_sale_note = 'contract_expiry'
  AND th.transfer_time > now() - interval '3 days'
GROUP BY 1
ORDER BY 1;

-- 3) Any expiry moves involving Jubilo / Man City (adjust short names if needed)
SELECT
  th.transfer_time,
  th.player_id,
  p."Name" AS player_name,
  th.seller_club_id,
  th.buyer_club_id,
  th.fee,
  th.foreign_buyer_name
FROM public."Transfer_History" th
LEFT JOIN public."Players" p ON p."Konami_ID"::text = th.player_id
WHERE th.transfer_sale_note = 'contract_expiry'
  AND th.transfer_time > now() - interval '3 days'
  AND (
    th.seller_club_id ILIKE ANY (ARRAY['%JUB%', '%MCI%', '%CITY%', 'JUB', 'MCI'])
    OR th.buyer_club_id ILIKE ANY (ARRAY['%JUB%', '%MCI%', '%CITY%', 'JUB', 'MCI'])
  )
ORDER BY th.transfer_time DESC
LIMIT 100;

-- 4) Tick log summary for season 4
SELECT for_season_label, ticked_at, result
FROM public.competition_contract_tick_log
WHERE for_season_id = 21
ORDER BY ticked_at DESC;
