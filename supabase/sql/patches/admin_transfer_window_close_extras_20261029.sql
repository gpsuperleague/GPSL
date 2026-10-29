-- Club-to-club deals + tall outfielders (190cm+) for August GPSL window
WITH season AS (
  SELECT id AS season_id FROM public.competition_seasons
  WHERE is_current = true ORDER BY id DESC LIMIT 1
),
cal AS (
  SELECT c.unlock_at, c.lock_at
  FROM season s
  JOIN public.competition_season_calendar c
    ON c.season_id = s.season_id
   AND lower(btrim(c.gpsl_month)) = 'august'
),
deals AS (
  SELECT
    p."Name" AS player_name,
    p."Position" AS position,
    CASE WHEN btrim(coalesce(p."Rating"::text, '')) ~ '^[0-9]+(\.[0-9]+)?$'
         THEN btrim(p."Rating"::text)::numeric END AS rating,
    CASE WHEN btrim(coalesce(p."Age"::text, '')) ~ '^[0-9]+$'
         THEN btrim(p."Age"::text)::int END AS age,
    CASE WHEN btrim(coalesce(p."Height"::text, '')) ~ '^[0-9]+(\.[0-9]+)?$'
         THEN btrim(p."Height"::text)::numeric END AS height_cm,
    coalesce(h.fee, 0)::numeric AS fee,
    coalesce(sc."Club", nullif(btrim(h.seller_club_id), ''), 'FA/Draft') AS seller_name,
    coalesce(bc."Club", h.buyer_club_id) AS buyer_name,
    h.seller_club_id,
    lower(coalesce(l.listing_type, '')) AS listing_type
  FROM public."Transfer_History" h
  CROSS JOIN cal
  LEFT JOIN public."Player_Transfer_Listings" l ON l.id = h.listing_id
  LEFT JOIN public."Players" p ON p."Konami_ID"::text = h.player_id::text
  LEFT JOIN public."Clubs" sc ON sc."ShortName" = h.seller_club_id
  LEFT JOIN public."Clubs" bc ON bc."ShortName" = h.buyer_club_id
  WHERE h.buyer_club_id IS NOT NULL
    AND h.buyer_club_id <> 'FOREIGN'
    AND h.transfer_time >= cal.unlock_at
    AND h.transfer_time < cal.lock_at
    AND coalesce(h.transfer_sale_note, '') NOT IN (
      'voluntary_contract_release', 'squad_overflow', 'new_owner_release',
      'special_auction_keep_prep', 'admin_reversed'
    )
)
SELECT 'CLUB_FEE' AS section, player_name, rating, age, position, height_cm, fee, seller_name, buyer_name
FROM deals
WHERE nullif(btrim(seller_club_id), '') IS NOT NULL
  AND seller_club_id <> 'FOREIGN'
  AND fee > 0
ORDER BY fee DESC
LIMIT 12;

WITH season AS (
  SELECT id AS season_id FROM public.competition_seasons
  WHERE is_current = true ORDER BY id DESC LIMIT 1
),
cal AS (
  SELECT c.unlock_at, c.lock_at
  FROM season s
  JOIN public.competition_season_calendar c
    ON c.season_id = s.season_id
   AND lower(btrim(c.gpsl_month)) = 'august'
),
deals AS (
  SELECT
    p."Name" AS player_name,
    p."Position" AS position,
    CASE WHEN btrim(coalesce(p."Rating"::text, '')) ~ '^[0-9]+(\.[0-9]+)?$'
         THEN btrim(p."Rating"::text)::numeric END AS rating,
    CASE WHEN btrim(coalesce(p."Age"::text, '')) ~ '^[0-9]+$'
         THEN btrim(p."Age"::text)::int END AS age,
    CASE WHEN btrim(coalesce(p."Height"::text, '')) ~ '^[0-9]+(\.[0-9]+)?$'
         THEN btrim(p."Height"::text)::numeric END AS height_cm,
    coalesce(h.fee, 0)::numeric AS fee,
    coalesce(sc."Club", nullif(btrim(h.seller_club_id), ''), 'FA/Draft') AS seller_name,
    coalesce(bc."Club", h.buyer_club_id) AS buyer_name
  FROM public."Transfer_History" h
  CROSS JOIN cal
  LEFT JOIN public."Players" p ON p."Konami_ID"::text = h.player_id::text
  LEFT JOIN public."Clubs" sc ON sc."ShortName" = h.seller_club_id
  LEFT JOIN public."Clubs" bc ON bc."ShortName" = h.buyer_club_id
  WHERE h.buyer_club_id IS NOT NULL
    AND h.buyer_club_id <> 'FOREIGN'
    AND h.transfer_time >= cal.unlock_at
    AND h.transfer_time < cal.lock_at
    AND coalesce(h.transfer_sale_note, '') NOT IN (
      'voluntary_contract_release', 'squad_overflow', 'new_owner_release',
      'special_auction_keep_prep', 'admin_reversed'
    )
)
SELECT 'TALL190' AS section, player_name, rating, age, position, height_cm, fee, seller_name, buyer_name
FROM deals
WHERE height_cm IS NOT NULL
  AND height_cm >= 190
  AND upper(btrim(coalesce(position, ''))) <> 'GK'
ORDER BY height_cm DESC, rating DESC NULLS LAST
LIMIT 12;
