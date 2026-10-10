-- =============================================================================
-- Main sponsor choice — status check (read-only)
-- Shows: was the 9 Oct "until June locks" patch run, when June locks/locked,
-- and every club's sponsor state this season.
-- =============================================================================

WITH s AS (
  SELECT public.club_commercial_current_season() AS season_id
),
june AS (
  SELECT m.lock_at
  FROM public.competition_season_calendar m, s
  WHERE m.season_id = s.season_id AND m.gpsl_month = 'june'
),
info AS (
  SELECT
    0 AS g,
    'SETTINGS' AS club,
    'patch run? ' || CASE WHEN to_regprocedure('public.club_commercial_offer_deadline(bigint)') IS NOT NULL
                          THEN 'YES' ELSE 'NO' END
      || ' · June lock (UK) ' || coalesce(to_char((SELECT lock_at FROM june) AT TIME ZONE 'Europe/London', 'DD Mon HH24:MI'), 'none')
      || CASE WHEN (SELECT lock_at FROM june) <= now() THEN ' — ALREADY LOCKED' ELSE ' — still open' END
      AS state,
    NULL::text AS detail
),
clubs AS (
  SELECT
    1 AS g,
    c."ShortName" AS club,
    CASE
      WHEN sp.id IS NOT NULL AND sp.auto_selected THEN 'AUTO-SIGNED (owner never chose)'
      WHEN sp.id IS NOT NULL THEN 'chosen by owner'
      WHEN o.open_offers > 0 AND o.next_expiry > now() THEN 'choosing — offers open'
      WHEN o.open_offers > 0 THEN 'offers EXPIRED, not yet auto-signed'
      ELSE 'no offers'
    END AS state,
    coalesce(sp.deal_kind || ' deal', '')
      || CASE WHEN o.next_expiry IS NOT NULL
              THEN ' · offers expire ' || to_char(o.next_expiry AT TIME ZONE 'Europe/London', 'DD Mon HH24:MI')
              ELSE '' END AS detail
  FROM public."Clubs" c
  CROSS JOIN s
  LEFT JOIN LATERAL (
    SELECT cs.id, cs.auto_selected, cs.deal_kind
    FROM public.club_commercial_sponsorships cs
    WHERE cs.club_short_name = c."ShortName" AND cs.start_season_id = s.season_id
    ORDER BY cs.id DESC LIMIT 1
  ) sp ON true
  LEFT JOIN LATERAL (
    SELECT count(*) FILTER (WHERE so.status = 'offered') AS open_offers,
           max(so.expires_at) FILTER (WHERE so.status = 'offered') AS next_expiry
    FROM public.club_commercial_sponsor_offers so
    WHERE so.club_short_name = c."ShortName" AND so.season_id = s.season_id
  ) o ON true
  WHERE c.owner_id IS NOT NULL
)
SELECT club, state, detail FROM (
  SELECT g, club, state, detail FROM info
  UNION ALL
  SELECT g, club, state, detail FROM clubs
) x
ORDER BY g, state, club;
