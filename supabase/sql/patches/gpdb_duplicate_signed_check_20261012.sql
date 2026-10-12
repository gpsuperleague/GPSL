-- =============================================================================
-- READ-ONLY: duplicate player cards (2026-10-12)
-- =============================================================================
-- The dedup audit (gpdb_player_duplicate_audit) matches FULL name + nation, so
-- "P. E. Aubameyang" and "Pierre Aubameyang" never matched.
-- This looser check pairs cards with the same SURNAME + nation + position and
-- age within 1 year, and shows who signed each card first.
-- Pairs on gpdb_player_dedup_ignore are left out.
-- Result: one row per pair; most urgent first (both cards contracted).
-- =============================================================================

WITH p AS (
  SELECT
    pl."Konami_ID"::text AS id,
    pl."Name" AS name,
    pl."Nation" AS nation,
    pl."Position" AS pos,
    pl."Rating" AS rating,
    nullif(regexp_replace(coalesce(pl."Age"::text, ''), '[^0-9]', '', 'g'), '')::int AS age,
    nullif(btrim(coalesce(pl."Contracted_Team"::text, '')), '') AS club,
    public.normalize_nation_key(regexp_replace(btrim(pl."Name"), '^.*[ .]', '')) AS surname_key,
    public.normalize_nation_key(pl."Nation") AS nation_key,
    public.gpdb_player_duplicate_key(pl."Name", pl."Nation") AS full_key
  FROM public."Players" pl
  WHERE NOT EXISTS (
    SELECT 1 FROM public.gpdb_player_dedup_ignore i WHERE i.konami_id = pl."Konami_ID"::text
  )
),
first_sign AS (
  SELECT DISTINCT ON (h.player_id::text)
    h.player_id::text AS id,
    h.buyer_club_id AS buyer,
    h.fee,
    h.transfer_time
  FROM public."Transfer_History" h
  WHERE h.buyer_club_id IS NOT NULL AND h.buyer_club_id <> 'FOREIGN'
  ORDER BY h.player_id::text, h.transfer_time ASC
),
pairs AS (
  SELECT a.*, b.id AS b_id, b.name AS b_name, b.rating AS b_rating, b.age AS b_age, b.club AS b_club,
         (a.full_key = b.full_key) AS same_full_name
  FROM p a
  JOIN p b
    ON b.surname_key = a.surname_key
   AND b.nation_key = a.nation_key
   AND b.id > a.id
   AND coalesce(b.pos, '') = coalesce(a.pos, '')
   AND (a.age IS NULL OR b.age IS NULL OR abs(a.age - b.age) <= 1)
  WHERE coalesce(a.surname_key, '') <> '' AND coalesce(a.nation_key, '') <> ''
    AND length(a.surname_key) >= 3
)
SELECT
  CASE
    WHEN x.club IS NOT NULL AND x.b_club IS NOT NULL THEN '1 BOTH CONTRACTED'
    WHEN x.club IS NOT NULL OR x.b_club IS NOT NULL THEN '2 one contracted'
    ELSE '3 both free agents'
  END AS status,
  x.name AS card_a,
  x.id AS id_a,
  x.club AS club_a,
  fa.buyer AS a_first_signed_by,
  to_char(fa.transfer_time AT TIME ZONE 'Europe/London', 'Dy DD Mon HH24:MI') AS a_signed_uk,
  fa.fee AS a_fee,
  x.b_name AS card_b,
  x.b_id AS id_b,
  x.b_club AS club_b,
  fb.buyer AS b_first_signed_by,
  to_char(fb.transfer_time AT TIME ZONE 'Europe/London', 'Dy DD Mon HH24:MI') AS b_signed_uk,
  fb.fee AS b_fee,
  CASE
    WHEN fa.transfer_time IS NULL OR fb.transfer_time IS NULL THEN NULL
    WHEN fa.transfer_time <= fb.transfer_time THEN coalesce(fa.buyer, '?') || ' (card A)'
    ELSE coalesce(fb.buyer, '?') || ' (card B)'
  END AS signed_first,
  x.nation,
  x.pos,
  x.age AS age_a, x.b_age AS age_b,
  x.rating AS rating_a, x.b_rating AS rating_b,
  x.same_full_name AS dedup_audit_would_catch
FROM pairs x
LEFT JOIN first_sign fa ON fa.id = x.id
LEFT JOIN first_sign fb ON fb.id = x.b_id
ORDER BY 1, x.name;
