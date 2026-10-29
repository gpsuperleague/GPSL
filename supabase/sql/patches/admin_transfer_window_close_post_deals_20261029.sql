-- =============================================================================
-- Season 1 transfer-window close post: deal shortlists (single result set)
-- =============================================================================

WITH season AS (
  SELECT id AS season_id, label AS season_label
  FROM public.competition_seasons
  WHERE is_current = true
  ORDER BY id DESC
  LIMIT 1
),
active AS (
  SELECT
    s.season_id,
    s.season_label,
    lower(coalesce(public.competition_active_gpsl_month(s.season_id, now()), '')) AS gpsl_month
  FROM season s
),
cal AS (
  SELECT c.unlock_at, c.lock_at, a.*
  FROM active a
  LEFT JOIN public.competition_season_calendar c
    ON c.season_id = a.season_id
   AND lower(btrim(c.gpsl_month)) = a.gpsl_month
),
-- Prefer current GPSL month; if thin, also pull last 21 days as backup pool
deals AS (
  SELECT
    h.id,
    p."Name" AS player_name,
    p."Position" AS position,
    CASE WHEN btrim(coalesce(p."Rating"::text, '')) ~ '^[0-9]+(\.[0-9]+)?$'
         THEN btrim(p."Rating"::text)::numeric ELSE NULL END AS rating,
    CASE WHEN btrim(coalesce(p."Age"::text, '')) ~ '^[0-9]+$'
         THEN btrim(p."Age"::text)::int ELSE NULL END AS age,
    CASE WHEN btrim(coalesce(p."Height"::text, '')) ~ '^[0-9]+(\.[0-9]+)?$'
         THEN btrim(p."Height"::text)::numeric ELSE NULL END AS height_cm,
    coalesce(h.fee, 0)::numeric AS fee,
    coalesce(sc."Club", nullif(btrim(h.seller_club_id), ''), 'Free agent / Draft') AS seller_name,
    coalesce(bc."Club", h.buyer_club_id, '?') AS buyer_name,
    h.transfer_time,
    lower(coalesce(l.listing_type, '')) AS listing_type,
    CASE
      WHEN cal.unlock_at IS NOT NULL AND h.transfer_time >= cal.unlock_at
           AND h.transfer_time < cal.lock_at THEN 'month'
      WHEN h.transfer_time >= now() - interval '21 days' THEN 'recent'
      ELSE 'other'
    END AS pool
  FROM public."Transfer_History" h
  CROSS JOIN cal
  LEFT JOIN public."Player_Transfer_Listings" l ON l.id = h.listing_id
  LEFT JOIN public."Players" p ON p."Konami_ID"::text = h.player_id::text
  LEFT JOIN public."Clubs" sc ON sc."ShortName" = h.seller_club_id
  LEFT JOIN public."Clubs" bc ON bc."ShortName" = h.buyer_club_id
  WHERE nullif(btrim(coalesce(h.buyer_club_id, '')), '') IS NOT NULL
    AND h.buyer_club_id <> 'FOREIGN'
    AND coalesce(h.transfer_sale_note, '') NOT IN (
      'voluntary_contract_release', 'squad_overflow', 'new_owner_release',
      'special_auction_keep_prep', 'admin_reversed'
    )
    AND coalesce(h.transfer_sale_note, '') NOT ILIKE '%admin_reversed%'
    AND (
      (cal.unlock_at IS NOT NULL AND cal.lock_at IS NOT NULL
        AND h.transfer_time >= cal.unlock_at AND h.transfer_time < cal.lock_at)
      OR h.transfer_time >= now() - interval '21 days'
    )
),
picked AS (
  SELECT * FROM deals WHERE pool = 'month'
  UNION ALL
  SELECT d.* FROM deals d
  WHERE d.pool = 'recent'
    AND NOT EXISTS (SELECT 1 FROM deals m WHERE m.pool = 'month' LIMIT 1)
),
meta AS (
  SELECT
    0 AS sort_key,
    'META'::text AS section,
    (SELECT season_label FROM cal) AS player_name,
    NULL::numeric AS rating,
    NULL::int AS age,
    NULL::text AS position,
    NULL::numeric AS height_cm,
    NULL::numeric AS fee,
    (SELECT gpsl_month FROM cal) AS seller_name,
    to_char(timezone('Europe/London', (SELECT lock_at FROM cal)), 'Dy DD Mon HH24:MI') AS buyer_name,
    NULL::text AS listing_type,
    (SELECT count(*)::text FROM picked) AS pool
),
big_fee AS (
  SELECT 1, 'BIG_FEE', player_name, rating, age, position, height_cm, fee,
         seller_name, buyer_name, listing_type, pool
  FROM (
    SELECT *, row_number() OVER (ORDER BY fee DESC, rating DESC NULLS LAST) AS rn
    FROM picked WHERE fee > 0
  ) x WHERE rn <= 10
),
top_rated AS (
  SELECT 2, 'TOP_RATED', player_name, rating, age, position, height_cm, fee,
         seller_name, buyer_name, listing_type, pool
  FROM (
    SELECT *, row_number() OVER (ORDER BY rating DESC NULLS LAST, fee DESC) AS rn
    FROM picked WHERE rating IS NOT NULL
  ) x WHERE rn <= 10
),
u21 AS (
  SELECT 3, 'U21', player_name, rating, age, position, height_cm, fee,
         seller_name, buyer_name, listing_type, pool
  FROM (
    SELECT *, row_number() OVER (ORDER BY rating DESC NULLS LAST, fee DESC) AS rn
    FROM picked WHERE age IS NOT NULL AND age < 21 AND rating IS NOT NULL
  ) x WHERE rn <= 10
),
tall AS (
  SELECT 4, 'TALL_OUTFIELD', player_name, rating, age, position, height_cm, fee,
         seller_name, buyer_name, listing_type, pool
  FROM (
    SELECT *, row_number() OVER (ORDER BY height_cm DESC, rating DESC NULLS LAST) AS rn
    FROM picked
    WHERE height_cm IS NOT NULL
      AND height_cm >= 195
      AND upper(btrim(coalesce(position, ''))) <> 'GK'
  ) x WHERE rn <= 10
)
SELECT sort_key, section, player_name, rating, age, position, height_cm, fee,
       seller_name, buyer_name, listing_type, pool
FROM (
  SELECT * FROM meta
  UNION ALL SELECT * FROM big_fee
  UNION ALL SELECT * FROM top_rated
  UNION ALL SELECT * FROM u21
  UNION ALL SELECT * FROM tall
) z
ORDER BY sort_key, fee DESC NULLS LAST, rating DESC NULLS LAST;
