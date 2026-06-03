-- =============================================================================
-- Retrospective test: squad overflow (Urawa Reds = URD)
--
-- STEP 0 (required for preview / fix / assign+overflow):
--   Run the ENTIRE file: squad_overflow_enforcement.sql
--   Then re-run section 2–3 below.
--
-- Section 1 works without that file (plain counts on Players / Clubs).
-- =============================================================================

-- ── 1) Current URD state (no overflow functions needed) ────────────────────
SELECT public.check_club_squad_composition('URD') AS composition;

SELECT
  c."ShortName",
  c."Club",
  (
    SELECT count(*)::int
    FROM public."Players" p
    WHERE p."Contracted_Team" = 'URD'
  ) AS squad_count
FROM public."Clubs" c
WHERE c."ShortName" = 'URD';

-- Foreign interest (skip if columns missing — run foreign_interest_teams.sql first)
SELECT
  c."ShortName",
  c.foreign_interest_remaining,
  c.foreign_tracking_teams
FROM public."Clubs" c
WHERE c."ShortName" = 'URD';

-- Squad list (highest rated first)
SELECT
  p."Konami_ID",
  p."Name",
  p."Rating",
  p."Season_Signed",
  p.market_value
FROM public."Players" p
WHERE p."Contracted_Team" = 'URD'
ORDER BY coalesce(p."Rating", 0) DESC NULLS LAST, p."Name";

-- Inline “who would be released” (not signed this GPSL season) — no RPC required
WITH cur AS (
  SELECT coalesce(
    (
      SELECT btrim(s.label)
      FROM public.competition_seasons s
      WHERE s.is_current = true
      ORDER BY s.id DESC
      LIMIT 1
    ),
    ''
  ) AS season_label
)
SELECT
  p."Konami_ID",
  p."Name",
  p."Rating",
  p."Season_Signed",
  'eligible_for_overflow_release' AS note
FROM public."Players" p
CROSS JOIN cur
WHERE p."Contracted_Team" = 'URD'
  AND NOT (
    btrim(coalesce(p."Season_Signed", '')) <> ''
    AND btrim(p."Season_Signed") = cur.season_label
  )
ORDER BY coalesce(p."Rating", 0) DESC NULLS LAST, p."Name"
LIMIT 1;

-- ── 2) After squad_overflow_enforcement.sql is deployed (admin) ───────────
-- SELECT public.preview_squad_overflow_release('URD', NULL) AS preview_now;

-- Fix 29 → 28 without signing anyone new (UNCOMMENT after reviewing preview):
-- SELECT public.admin_enforce_squad_overflow('URD') AS fix_29_to_28;

-- Re-check:
-- SELECT count(*)::int AS squad_count_after
-- FROM public."Players" p WHERE p."Contracted_Team" = 'URD';

-- ── 3) Simulate “won a listing” (after squad_overflow_enforcement.sql) ─────
/*
SELECT "Konami_ID", "Name", "Rating", market_value
FROM public."Players"
WHERE "Contracted_Team" IS NULL OR btrim("Contracted_Team"::text) = ''
ORDER BY coalesce("Rating", 0) DESC NULLS LAST
LIMIT 10;
*/

-- SELECT public.player_assign_to_club('KONAMI_ID_HERE', 'URD', NULL) AS assign_result;

-- ── 4) Recent URD sales (foreign_buyer_name needs foreign_interest_teams.sql) ─
SELECT
  h.transfer_time,
  h.player_id,
  p."Name",
  p."Rating",
  h.seller_club_id,
  h.buyer_club_id,
  h.fee
FROM public."Transfer_History" h
LEFT JOIN public."Players" p ON p."Konami_ID" = h.player_id
WHERE h.seller_club_id = 'URD'
ORDER BY h.transfer_time DESC NULLS LAST
LIMIT 10;

-- =============================================================================
-- LIVE APP TEST CHECKLIST
-- =============================================================================
-- [ ] squad_overflow_enforcement.sql — full file, success
-- [ ] all_listings.js?v=10 on GitHub Pages
-- Path A: Run inline preview above → admin_enforce_squad_overflow('URD')
-- Path B: 28 players → bid with warning → win listing → 28 again + release
-- =============================================================================
