-- =============================================================================
-- READ-ONLY audit: Marseille (MAR) takeover — what was posted on arrival
-- Changes nothing. Paste the result back so duplicates can be reversed.
--
-- Sections (one result table):
--   1 club       current owner, balance, ledger total this season
--   2 owners     owner-change trail (registry + Discord owner posts)
--   3 ledger     every MAR ledger row this season; dup_count > 1 = same type,
--                amount and description posted more than once
--   4 inbox      welcome / arrival inbox messages for MAR or its owner
-- =============================================================================

WITH season AS (
  SELECT public.competition_finances_current_season_id() AS id
),
club AS (
  SELECT c."ShortName" AS short, c."Club" AS name, c.owner_id, c.owner
  FROM public."Clubs" c
  WHERE c."ShortName" = 'MAR'
),
ledger AS (
  SELECT
    l.id, l.created_at, l.entry_type, l.amount, l.description,
    l.metadata->>'source' AS source,
    l.metadata->>'owner_id' AS meta_owner,
    count(*) OVER (PARTITION BY l.entry_type, l.amount, l.description) AS dup_count
  FROM public.competition_finance_ledger l, season s
  WHERE l.club_short_name = 'MAR'
    AND l.season_id = s.id
)
SELECT * FROM (
  -- 1) club
  SELECT 1 AS section, now() AS at, 'club' AS item,
         (SELECT balance FROM public."Club_Finances" WHERE club_name = 'MAR') AS amount,
         format('owner %s (%s) · ledger total this season %s · ledger rows %s · prior finance season? %s',
           coalesce(public.owner_registry_resolve_tag(c.owner_id), c.owner, '—'),
           c.owner_id,
           (SELECT coalesce(sum(amount), 0) FROM ledger),
           (SELECT count(*) FROM ledger),
           public.club_had_prior_finance_season('MAR', (SELECT id FROM season))
         ) AS detail
  FROM club c

  UNION ALL
  -- 2) owner trail
  SELECT 2, r.status_changed_at, 'registry',
         NULL,
         format('%s · status %s · last club %s', coalesce(r.owner_tag, r.owner_id::text), r.status, r.last_club_short_name)
  FROM public.gpsl_owner_registry r
  WHERE r.last_club_short_name = 'MAR'
     OR r.owner_id = (SELECT owner_id FROM club)

  UNION ALL
  SELECT 2, q.created_at, 'discord ' || q.event_type,
         NULL,
         format('%s · %s · key %s', q.headline, q.status, q.dedupe_key)
  FROM public.gpsl_discord_feed_queue q
  WHERE q.metadata->>'club' = 'MAR'
    AND q.event_type IN ('owner', 'owner_depart', 'owner_departure')

  UNION ALL
  -- 3) ledger (this season)
  SELECT 3, l.created_at,
         l.entry_type || CASE WHEN l.dup_count > 1 THEN '  ⚠ x' || l.dup_count ELSE '' END,
         l.amount,
         format('#%s %s · source %s · owner %s', l.id, l.description, coalesce(l.source, '—'), coalesce(l.meta_owner, '—'))
  FROM ledger l

  UNION ALL
  -- 4) inbox
  SELECT 4, i.created_at, 'inbox ' || i.message_type,
         NULL,
         format('%s · to club %s / owner %s · key %s', i.title, coalesce(i.recipient_club_short_name, '—'),
                coalesce(i.owner_id::text, '—'), coalesce(i.dedupe_key, '—'))
  FROM public.competition_inbox i
  WHERE (i.recipient_club_short_name = 'MAR' OR i.owner_id = (SELECT owner_id FROM club))
    AND i.created_at > now() - interval '7 days'
    AND (i.message_type ILIKE '%welcome%' OR i.message_type ILIKE '%owner%'
         OR i.message_type ILIKE '%assign%' OR i.title ILIKE '%welcome%')
) x
ORDER BY section, at NULLS FIRST;
