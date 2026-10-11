-- =============================================================================
-- One-off: #gpsl-job-center "available" post for every club without an owner
-- in Super League and Championship A this season.
--
-- Skips:
--   • clubs already posted as "NOW AVAILABLE" in the last 48h (owner just left,
--     via discord_job_center_now_and_owner_departure_20261011.sql)
--   • any clubs listed in v_skip below — add the ShortNames of owners who just
--     left if their posts went out another way
-- One post per club. Safe re-run (dedupe per club per season).
-- =============================================================================

DO $$
DECLARE
  v_skip text[] := ARRAY[]::text[];   -- e.g. ARRAY['ACM','MAR']
  v_season_id bigint;
  r record;
BEGIN
  SELECT id INTO v_season_id
  FROM public.competition_seasons
  WHERE is_current = true
  ORDER BY id DESC
  LIMIT 1;

  IF v_season_id IS NULL THEN
    RAISE EXCEPTION 'No current season';
  END IF;

  FOR r IN
    SELECT c."ShortName" AS short_name,
           coalesce(nullif(btrim(c."Club"), ''), c."ShortName") AS club_name,
           ccs.division
    FROM public.competition_club_seasons ccs
    JOIN public."Clubs" c ON c."ShortName" = ccs.club_short_name
    WHERE ccs.season_id = v_season_id
      AND lower(ccs.division) IN ('superleague', 'championship_a')
      AND c.owner_id IS NULL
      AND c."ShortName" IS DISTINCT FROM 'FOREIGN'
      AND NOT (upper(c."ShortName") = ANY (SELECT upper(x) FROM unnest(v_skip) x))
      AND NOT EXISTS (
        SELECT 1 FROM public.gpsl_discord_feed_queue q
        WHERE q.metadata->>'kind' = 'club_vacant'
          AND q.metadata->>'club' = c."ShortName"
          AND q.created_at > now() - interval '48 hours'
      )
    ORDER BY CASE lower(ccs.division) WHEN 'superleague' THEN 1 ELSE 2 END, c."Club"
  LOOP
    PERFORM public.gpsl_discord_feed_enqueue_job_center(
      'job_center',
      format('🏚️ AVAILABLE — %s', r.club_name),
      format('%s (%s) is looking for an owner. Interested? Ask an admin in Discord.',
             r.club_name, public.gpsl_discord_division_label(r.division)),
      10038562,
      'job_center_vacant_seed:' || v_season_id::text || ':' || r.short_name,
      jsonb_build_object('kind', 'club_vacant_seed', 'club', r.short_name, 'division', r.division)
    );
  END LOOP;

  BEGIN
    PERFORM public.gpsl_discord_feed_request_flush();
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;
END $$;

-- Report: Job Center posts queued by this patch
SELECT q.id, q.headline, q.body, q.created_at AT TIME ZONE 'Europe/London' AS queued_uk
FROM public.gpsl_discord_feed_queue q
WHERE q.metadata->>'kind' = 'club_vacant_seed'
ORDER BY q.id;
