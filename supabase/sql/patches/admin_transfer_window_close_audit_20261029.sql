-- Audit: whole summer (Jun–Aug) vs August-only; tallest outfield; top fees
-- Safe read-only.

WITH season AS (
  SELECT id AS season_id, label AS season_label
  FROM public.competition_seasons
  WHERE is_current = true
  ORDER BY id DESC
  LIMIT 1
),
months AS (
  SELECT c.gpsl_month, c.unlock_at, c.lock_at
  FROM season s
  JOIN public.competition_season_calendar c ON c.season_id = s.season_id
  WHERE lower(btrim(c.gpsl_month)) IN ('june', 'july', 'august')
),
bounds AS (
  SELECT min(unlock_at) AS win_start, max(lock_at) AS win_end FROM months
),
aug AS (
  SELECT unlock_at, lock_at FROM months WHERE lower(btrim(gpsl_month)) = 'august' LIMIT 1
),
all_deals AS (
  SELECT
    p."Name" AS player_name,
    p."Position" AS position,
    p."Height"::text AS height_raw,
    CASE
      WHEN btrim(coalesce(p."Height"::text, '')) ~ '^[0-9]+(\.[0-9]+)?$'
        THEN btrim(p."Height"::text)::numeric
      WHEN btrim(coalesce(p."Height"::text, '')) ~ '^[0-9]+'
        THEN (regexp_match(btrim(p."Height"::text), '^[0-9]+'))[1]::numeric
      ELSE NULL
    END AS height_cm,
    CASE WHEN btrim(coalesce(p."Rating"::text, '')) ~ '^[0-9]+(\.[0-9]+)?$'
         THEN btrim(p."Rating"::text)::numeric END AS rating,
    CASE WHEN btrim(coalesce(p."Age"::text, '')) ~ '^[0-9]+$'
         THEN btrim(p."Age"::text)::int END AS age,
    coalesce(h.fee, 0)::numeric AS fee,
    coalesce(sc."Club", nullif(btrim(h.seller_club_id), ''), 'FA/Draft') AS seller_name,
    coalesce(bc."Club", h.buyer_club_id) AS buyer_name,
    h.transfer_time,
    h.transfer_sale_note,
    lower(coalesce(l.listing_type, '')) AS listing_type,
    CASE
      WHEN h.transfer_time >= (SELECT unlock_at FROM aug)
       AND h.transfer_time < (SELECT lock_at FROM aug) THEN 'august'
      ELSE 'summer_other'
    END AS pool
  FROM public."Transfer_History" h
  CROSS JOIN bounds
  LEFT JOIN public."Player_Transfer_Listings" l ON l.id = h.listing_id
  LEFT JOIN public."Players" p ON p."Konami_ID"::text = h.player_id::text
  LEFT JOIN public."Clubs" sc ON sc."ShortName" = h.seller_club_id
  LEFT JOIN public."Clubs" bc ON bc."ShortName" = h.buyer_club_id
  WHERE nullif(btrim(coalesce(h.buyer_club_id, '')), '') IS NOT NULL
    AND h.buyer_club_id <> 'FOREIGN'
    AND h.transfer_time >= (SELECT win_start FROM bounds)
    AND h.transfer_time < (SELECT win_end FROM bounds)
    AND coalesce(h.transfer_sale_note, '') NOT IN (
      'voluntary_contract_release', 'squad_overflow', 'new_owner_release',
      'special_auction_keep_prep', 'admin_reversed'
    )
    AND coalesce(h.transfer_sale_note, '') NOT ILIKE '%admin_reversed%'
),
tallest_game AS (
  SELECT
    p."Name" AS player_name,
    p."Position" AS position,
    p."Height"::text AS height_raw,
    CASE
      WHEN btrim(coalesce(p."Height"::text, '')) ~ '^[0-9]+(\.[0-9]+)?$'
        THEN btrim(p."Height"::text)::numeric
      WHEN btrim(coalesce(p."Height"::text, '')) ~ '^[0-9]+'
        THEN (regexp_match(btrim(p."Height"::text), '^[0-9]+'))[1]::numeric
      ELSE NULL
    END AS height_cm,
    CASE WHEN btrim(coalesce(p."Rating"::text, '')) ~ '^[0-9]+(\.[0-9]+)?$'
         THEN btrim(p."Rating"::text)::numeric END AS rating,
    CASE WHEN btrim(coalesce(p."Age"::text, '')) ~ '^[0-9]+$'
         THEN btrim(p."Age"::text)::int END AS age,
    p."Contracted_Team"::text AS club,
    p."Konami_ID"::text AS pid,
    row_number() OVER (
      ORDER BY
        CASE
          WHEN btrim(coalesce(p."Height"::text, '')) ~ '^[0-9]+(\.[0-9]+)?$'
            THEN btrim(p."Height"::text)::numeric
          WHEN btrim(coalesce(p."Height"::text, '')) ~ '^[0-9]+'
            THEN (regexp_match(btrim(p."Height"::text), '^[0-9]+'))[1]::numeric
          ELSE 0
        END DESC NULLS LAST
    ) AS rn
  FROM public."Players" p
  WHERE upper(btrim(coalesce(p."Position", ''))) <> 'GK'
)
SELECT sort_key, section, player_name, position, height_raw, rating, age, fee, seller_name, buyer_name, note
FROM (
  SELECT 0 AS sort_key, 'META' AS section,
         (SELECT season_label FROM season) AS player_name,
         NULL::text AS position, NULL::text AS height_raw,
         NULL::numeric AS rating, NULL::int AS age, NULL::numeric AS fee,
         to_char(timezone('Europe/London', (SELECT win_start FROM bounds)), 'Dy DD Mon HH24:MI') AS seller_name,
         to_char(timezone('Europe/London', (SELECT win_end FROM bounds)), 'Dy DD Mon HH24:MI') AS buyer_name,
         (SELECT count(*)::text FROM all_deals) AS note,
         0 AS rn
  UNION ALL
  SELECT 1, 'TOP_FEE_SUMMER', player_name, position, height_raw, rating, age, fee,
         seller_name, buyer_name,
         pool || ' | ' || coalesce(nullif(listing_type,''), '-') || ' | ' || coalesce(nullif(transfer_sale_note,''), '-'),
         rn
  FROM (
    SELECT *, row_number() OVER (ORDER BY fee DESC, rating DESC NULLS LAST) rn
    FROM all_deals WHERE fee > 0
  ) x WHERE rn <= 25
  UNION ALL
  SELECT 2, 'TOP_FEE_AUGUST', player_name, position, height_raw, rating, age, fee,
         seller_name, buyer_name, pool || ' | ' || coalesce(nullif(listing_type,''), '-'), rn
  FROM (
    SELECT *, row_number() OVER (ORDER BY fee DESC, rating DESC NULLS LAST) rn
    FROM all_deals WHERE fee > 0 AND pool = 'august'
  ) x WHERE rn <= 15
  UNION ALL
  SELECT 3, 'TALL_SUMMER', player_name, position, height_raw, rating, age, fee,
         seller_name, buyer_name, coalesce(height_cm::text,'?') || 'cm | ' || pool, rn
  FROM (
    SELECT *, row_number() OVER (ORDER BY height_cm DESC NULLS LAST, fee DESC) rn
    FROM all_deals
    WHERE height_cm IS NOT NULL AND upper(btrim(coalesce(position, ''))) <> 'GK'
  ) x WHERE rn <= 25
  UNION ALL
  SELECT 4, 'TALLEST_GAME_OUTFIELD', t.player_name, t.position, t.height_raw, t.rating, t.age,
         h.fee, t.club,
         coalesce(
           h.buyer_club_id || ' @ ' || to_char(timezone('Europe/London', h.transfer_time), 'YYYY-MM-DD HH24:MI')
           || ' | ' || coalesce(h.transfer_sale_note, '-'),
           'no qualifying transfer in window'
         ),
         coalesce(t.height_cm::text,'?') || 'cm',
         t.rn
  FROM tallest_game t
  LEFT JOIN LATERAL (
    SELECT hh.fee, hh.buyer_club_id, hh.transfer_time, hh.transfer_sale_note
    FROM public."Transfer_History" hh
    CROSS JOIN bounds b
    WHERE hh.player_id::text = t.pid
      AND hh.buyer_club_id IS NOT NULL
      AND hh.buyer_club_id <> 'FOREIGN'
      AND hh.transfer_time >= b.win_start
      AND hh.transfer_time < b.win_end
      AND coalesce(hh.transfer_sale_note, '') NOT ILIKE '%admin_reversed%'
    ORDER BY hh.transfer_time DESC
    LIMIT 1
  ) h ON true
  WHERE t.rn <= 12
) z
ORDER BY sort_key, rn;
