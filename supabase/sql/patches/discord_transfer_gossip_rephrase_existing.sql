-- =============================================================================
-- Rephrase existing Discord transfer rumours through the 5 rotating lines
-- (does not touch idle gossip). Safe re-run.
-- =============================================================================

WITH ranked AS (
  SELECT
    r.id,
    coalesce(nullif(btrim(r.club_name), ''), nullif(btrim(r.club_short_name), ''), 'A GPSL club') AS club,
    coalesce(nullif(btrim(r.player_name), ''), 'a target') AS player,
    row_number() OVER (ORDER BY r.created_at ASC, r.id ASC) AS rn
  FROM public.gpsl_transfer_rumours r
  WHERE r.source = 'discord'
)
UPDATE public.gpsl_transfer_rumours t
SET headline = CASE ((ranked.rn - 1) % 5) + 1
  WHEN 1 THEN format('RUMOUR: %s are tracking %s', ranked.club, ranked.player)
  WHEN 2 THEN format('RUMOUR: %s are considering an approach for %s', ranked.club, ranked.player)
  WHEN 3 THEN format(
    'RUMOUR: %s have been scouting %s, offer imminent according to sources',
    ranked.club, ranked.player
  )
  WHEN 4 THEN format('RUMOUR: %s in private discussions with %s', ranked.player, ranked.club)
  ELSE format(
    'RUMOUR: %s sporting director at odds with manager on transfer targets as %s causes divide',
    ranked.club, ranked.player
  )
END
FROM ranked
WHERE t.id = ranked.id;

-- Quick check
SELECT id, club_short_name, player_name, headline, created_at
FROM public.gpsl_transfer_rumours
WHERE source = 'discord'
ORDER BY created_at ASC, id ASC;
