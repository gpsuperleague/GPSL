-- =============================================================================
-- One-shot: friendly welcome inbox for clubs that already completed handpick
-- approval (latest approved submission per club, current owner only).
-- Safe re-run (dedupe_key).
-- =============================================================================

DO $retro$
DECLARE
  r record;
  v_mgr_name text;
  v_body text;
  v_inbox_id bigint;
  v_sent int := 0;
  v_skipped int := 0;
  v_player_n int;
BEGIN
  FOR r IN
    WITH latest AS (
      SELECT DISTINCT ON (s.club_short_name)
        s.id AS submission_id,
        s.club_short_name,
        s.owner_id AS submission_owner_id,
        s.player_ids,
        s.manager_id,
        s.reviewed_at
      FROM public.club_handpick_submissions s
      WHERE s.status = 'approved'
      ORDER BY s.club_short_name, s.reviewed_at DESC NULLS LAST, s.id DESC
    )
    SELECT
      l.submission_id,
      l.club_short_name,
      c."Club" AS club_name,
      c.owner_id,
      l.player_ids,
      l.manager_id,
      l.reviewed_at
    FROM latest l
    JOIN public."Clubs" c ON c."ShortName" = l.club_short_name
    WHERE c.owner_id IS NOT NULL
    ORDER BY l.club_short_name
  LOOP
    -- Already sent (approve path or prior retro)
    IF EXISTS (
      SELECT 1
      FROM public.competition_inbox i
      WHERE i.dedupe_key IN (
        format('handpick_approved:%s', r.submission_id),
        format('handpick_welcome_retro:%s', r.submission_id),
        format('handpick_welcome_retro_club:%s', r.club_short_name)
      )
    ) THEN
      v_skipped := v_skipped + 1;
      CONTINUE;
    END IF;

    v_mgr_name := NULL;
    IF r.manager_id IS NOT NULL THEN
      SELECT m.name INTO v_mgr_name
      FROM public."Managers" m
      WHERE m.id = r.manager_id;
    END IF;

    v_player_n := coalesce(array_length(r.player_ids, 1), 0);

    v_body := format(
      E'Welcome to GPSL — and well done on completing your mid-season handpick for %s (%s).\n\n'
      || E'Your wishlist was approved (%s players%s).\n\n'
      || E'Next steps:\n'
      || E'• Open Squad to check registration, pick One of our Own / Fan Favourite, and tidy wages\n'
      || E'• Arrange fixtures from Fixtures / Schedule\n'
      || E'• Browse the handbook (Learning GPSL) if you are new to matchdays\n\n'
      || E'If anything looks wrong with the squad or cash, message an admin.\n'
      || E'Enjoy the rest of the season — good luck!',
      coalesce(nullif(btrim(r.club_name), ''), r.club_short_name),
      r.club_short_name,
      v_player_n::text,
      CASE
        WHEN nullif(btrim(coalesce(v_mgr_name, '')), '') IS NOT NULL
          THEN format(', manager %s', v_mgr_name)
        WHEN r.manager_id IS NOT NULL
          THEN format(', manager #%s', r.manager_id::text)
        ELSE ''
      END
    );

    BEGIN
      v_inbox_id := public.owner_inbox_send(
        'handpick_welcome',
        format('Welcome — handpick complete (%s)', r.club_short_name),
        v_body,
        r.club_short_name,
        r.owner_id,
        NULL::bigint,
        NULL::bigint,
        NULL::bigint,
        NULL::bigint,
        'squad.html',
        format('handpick_welcome_retro_club:%s', r.club_short_name),
        NULL::text,
        NULL::bigint
      );
      IF v_inbox_id IS NOT NULL THEN
        v_sent := v_sent + 1;
        RAISE NOTICE 'Sent welcome to % (%) inbox_id=%', r.club_short_name, r.owner_id, v_inbox_id;
      ELSE
        v_skipped := v_skipped + 1;
        RAISE NOTICE 'Skipped % (dedupe or no insert)', r.club_short_name;
      END IF;
    EXCEPTION WHEN OTHERS THEN
      v_skipped := v_skipped + 1;
      RAISE NOTICE 'Failed %: %', r.club_short_name, SQLERRM;
    END;
  END LOOP;

  RAISE NOTICE 'Handpick retro welcome done: sent=% skipped=%', v_sent, v_skipped;
END;
$retro$;

-- Verify what landed
SELECT
  i.id,
  i.recipient_club_short_name,
  i.message_type,
  i.title,
  i.dedupe_key,
  i.created_at
FROM public.competition_inbox i
WHERE i.message_type IN ('handpick_welcome', 'handpick_approved')
   OR i.dedupe_key LIKE 'handpick_welcome%'
   OR i.dedupe_key LIKE 'handpick_approved:%'
ORDER BY i.created_at DESC
LIMIT 20;
