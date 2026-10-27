-- =============================================================================
-- Diagnose: Ajax (AJX) / Piojo — medical staff + specialist consults
-- Run in Supabase SQL Editor (read-only except optional sync at end).
-- =============================================================================

-- 1) Club + owner
SELECT
  c."ShortName",
  c."Club",
  c.owner,
  c.owner_id,
  r.owner_tag,
  r.is_supporter,
  public.owner_is_supporter_active(c.owner_id) AS supporter_active
FROM public."Clubs" c
LEFT JOIN public.gpsl_owner_registry r ON r.owner_id = c.owner_id
WHERE upper(c."ShortName") = 'AJX';

-- 2) Medical centre + staff
SELECT *
FROM public.club_medical_centre
WHERE club_short_name = 'AJX';

SELECT
  s.id,
  s.role,
  s.slot_index,
  s.display_name,
  s.hired_at,
  s.contract_seasons_left,
  s.is_active
FROM public.club_medical_staff s
WHERE s.club_short_name = 'AJX'
ORDER BY s.role, s.slot_index;

-- 3) Prize inventory medical tokens (shop / challenges)
SELECT
  i.id,
  i.prize_type,
  i.param_int,
  i.status,
  i.source,
  i.created_at,
  i.metadata->>'label' AS label,
  i.metadata->>'consult_id' AS metadata_consult_id,
  (
    SELECT c.id
    FROM public.club_medical_consults c
    WHERE c.inventory_id = i.id
    LIMIT 1
  ) AS linked_consult_id
FROM public.club_prize_inventory i
WHERE upper(i.club_short_name) = 'AJX'
  AND i.prize_type = 'medical_token'
ORDER BY i.created_at DESC;

-- 4) Named consults (what Medical Room / Squad list)
SELECT
  c.id,
  c.matches_removed,
  c.status,
  c.source,
  c.inventory_id,
  c.label,
  c.created_at
FROM public.club_medical_consults c
WHERE upper(c.club_short_name) = 'AJX'
ORDER BY c.status, c.matches_removed DESC, c.id;

-- 5) What the UI RPC returns
SELECT public.medical_list_available_consults('AJX') AS available_consults;
SELECT public.medical_room_prize_tokens('AJX') AS prize_tokens_rpc;

-- 6) Active injuries (dropdown only appears when assessed + unused)
SELECT
  i.id,
  i.player_id,
  i.status,
  i.matches_remaining,
  i.doctor_assessed,
  EXISTS (
    SELECT 1 FROM public.club_medical_token_use u WHERE u.injury_id = i.id
  ) AS consult_already_used
FROM public.competition_player_injuries i
WHERE upper(i.club_short_name) = 'AJX'
  AND i.status = 'active'
ORDER BY i.id;

-- 7) Recent Owners Shop medical purchases (ledger)
SELECT
  l.id,
  l.entry_type,
  l.amount,
  l.description,
  l.created_at,
  l.metadata
FROM public.owner_finance_ledger l
WHERE l.owner_id = (SELECT owner_id FROM public."Clubs" WHERE "ShortName" = 'AJX')
  AND (
    l.entry_type = 'shop_purchase'
    OR coalesce(l.metadata->>'prize_type', '') = 'medical_token'
    OR l.description ILIKE '%consult%'
  )
ORDER BY l.created_at DESC
LIMIT 20;

-- Optional: if inventory exists but consult rows missing, run the fix patch first:
--   medical_shop_consult_link_fix_20261027.sql
-- Then re-check sections 3–5.
