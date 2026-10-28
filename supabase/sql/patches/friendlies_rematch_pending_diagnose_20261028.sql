-- =============================================================================
-- Friendlies: diagnose stuck pending + rematch matching pairs (2026-10-28)
--
-- Symptom: your Discord post gets ⏳; opponent posts the same scoreline but gets
-- no tick / no hourglass → their message was never ingested (usually Discord →
-- club mapping failed) or sits as a second pending that never paired.
--
-- This patch:
--   1) DIAGNOSE helpers for JUB / PSG / SLB style cases
--   2) admin_gpsl_friendlies_rematch_pending() — confirm any two pending reports
--      that already share the same canonical scoreline (different clubs)
--
-- Safe re-run. After mapping fixes, also use Admin → Discord Friendlies →
-- Poll now (force rescan) so opponent messages in the last ~50 are re-read.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Rematch: pair pending reports that already agree on canon
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_gpsl_friendlies_rematch_pending(
  p_dry_run boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_a public.gpsl_friendly_reports%ROWTYPE;
  v_b public.gpsl_friendly_reports%ROWTYPE;
  v_friendly_id bigint;
  v_scoreline text;
  v_pay_l jsonb;
  v_pay_r jsonb;
  v_matched int := 0;
  v_details jsonb := '[]'::jsonb;
  v_pending_hours int := public.gpsl_friendlies_pending_hours();
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  FOR v_a IN
    SELECT r.*
    FROM public.gpsl_friendly_reports r
    WHERE r.status = 'pending'
      AND r.posted_at >= now() - make_interval(hours => v_pending_hours)
    ORDER BY r.posted_at ASC
  LOOP
    -- Still pending? (may have been matched earlier in this loop)
    IF NOT EXISTS (
      SELECT 1 FROM public.gpsl_friendly_reports x
      WHERE x.id = v_a.id AND x.status = 'pending'
    ) THEN
      CONTINUE;
    END IF;

    SELECT r.* INTO v_b
    FROM public.gpsl_friendly_reports r
    WHERE r.status = 'pending'
      AND r.id <> v_a.id
      AND r.season_id = v_a.season_id
      AND r.gpsl_month = v_a.gpsl_month
      AND r.canon_club_a = v_a.canon_club_a
      AND r.canon_club_b = v_a.canon_club_b
      AND r.canon_score_a = v_a.canon_score_a
      AND r.canon_score_b = v_a.canon_score_b
      AND upper(r.reporter_club_short_name) <> upper(v_a.reporter_club_short_name)
      AND (
        upper(r.reporter_club_short_name) = upper(v_a.canon_club_a)
        OR upper(r.reporter_club_short_name) = upper(v_a.canon_club_b)
      )
      AND (
        upper(v_a.reporter_club_short_name) = upper(v_a.canon_club_a)
        OR upper(v_a.reporter_club_short_name) = upper(v_a.canon_club_b)
      )
      AND r.posted_at >= now() - make_interval(hours => v_pending_hours)
    ORDER BY r.posted_at ASC
    LIMIT 1;

    IF v_b.id IS NULL THEN
      CONTINUE;
    END IF;

    v_scoreline := format(
      '%s %s - %s %s',
      v_a.club_left, v_a.score_left, v_a.score_right, v_a.club_right
    );

    IF NOT p_dry_run THEN
      INSERT INTO public.gpsl_friendlies (
        season_id, gpsl_month,
        club_left, score_left, club_right, score_right,
        report_1_id, report_2_id
      )
      VALUES (
        v_a.season_id, v_a.gpsl_month,
        v_a.club_left, v_a.score_left, v_a.club_right, v_a.score_right,
        v_a.id, v_b.id
      )
      RETURNING id INTO v_friendly_id;

      v_pay_l := public.gpsl_friendlies_pay_club(
        v_a.season_id, v_a.gpsl_month, v_a.club_left, v_friendly_id, v_scoreline
      );
      v_pay_r := public.gpsl_friendlies_pay_club(
        v_a.season_id, v_a.gpsl_month, v_a.club_right, v_friendly_id, v_scoreline
      );

      UPDATE public.gpsl_friendlies
      SET paid_left = coalesce((v_pay_l ->> 'paid')::numeric, 0),
          paid_right = coalesce((v_pay_r ->> 'paid')::numeric, 0),
          left_skipped_reason = v_pay_l ->> 'skipped',
          right_skipped_reason = v_pay_r ->> 'skipped'
      WHERE id = v_friendly_id;

      UPDATE public.gpsl_friendly_reports
      SET status = 'matched',
          matched_friendly_id = v_friendly_id,
          note = coalesce(note, 'Rematched by admin_gpsl_friendlies_rematch_pending')
      WHERE id IN (v_a.id, v_b.id);
    END IF;

    v_matched := v_matched + 1;
    v_details := v_details || jsonb_build_array(jsonb_build_object(
      'friendly_id', v_friendly_id,
      'month', v_a.gpsl_month,
      'scoreline', v_scoreline,
      'report_a', v_a.id,
      'report_b', v_b.id,
      'club_a', v_a.reporter_club_short_name,
      'club_b', v_b.reporter_club_short_name,
      'msg_a', v_a.discord_message_id,
      'msg_b', v_b.discord_message_id
    ));
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true,
    'dry_run', p_dry_run,
    'matched_pairs', v_matched,
    'details', v_details
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.admin_gpsl_friendlies_rematch_pending(boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_gpsl_friendlies_rematch_pending(boolean)
  TO service_role, authenticated;

-- ---------------------------------------------------------------------------
-- DIAGNOSE — JUB / PSG / SLB pending + owner Discord links
-- ---------------------------------------------------------------------------

-- 1) Pending reports involving JUB, PSG, or SLB
SELECT
  r.id,
  r.status,
  r.gpsl_month,
  r.reporter_club_short_name AS reporter,
  format('%s %s-%s %s', r.club_left, r.score_left, r.score_right, r.club_right) AS posted,
  format('%s %s-%s %s', r.canon_club_a, r.canon_score_a, r.canon_score_b, r.canon_club_b) AS canon,
  r.discord_user_id,
  r.discord_message_id,
  r.posted_at,
  r.note
FROM public.gpsl_friendly_reports r
WHERE r.status IN ('pending', 'ignored', 'expired')
  AND r.posted_at > now() - interval '7 days'
  AND (
    upper(r.reporter_club_short_name) IN ('JUB', 'PSG', 'SLB')
    OR upper(r.club_left) IN ('JUB', 'PSG', 'SLB')
    OR upper(r.club_right) IN ('JUB', 'PSG', 'SLB')
    OR upper(r.canon_club_a) IN ('JUB', 'PSG', 'SLB')
    OR upper(r.canon_club_b) IN ('JUB', 'PSG', 'SLB')
  )
ORDER BY r.posted_at DESC;

-- 2) Owner Discord linkage for those clubs (ingest needs discord_user_id or matching tag/nick)
SELECT
  c."ShortName" AS club,
  c.owner AS clubs_owner_tag,
  r.owner_tag AS registry_tag,
  r.discord_user_id,
  CASE
    WHEN nullif(btrim(coalesce(r.discord_user_id, '')), '') IS NOT NULL THEN 'linked'
    ELSE 'NO discord_user_id — nick/tag match only'
  END AS link_status
FROM public."Clubs" c
LEFT JOIN public.gpsl_owner_registry r ON r.owner_id = c.owner_id
WHERE upper(c."ShortName") IN ('JUB', 'PSG', 'SLB')
ORDER BY c."ShortName";

-- 3) Preview rematch (no writes)
SELECT public.admin_gpsl_friendlies_rematch_pending(true) AS rematch_dry_run;

-- 4) Apply rematch if dry_run shows pairs
-- SELECT public.admin_gpsl_friendlies_rematch_pending(false) AS rematch_applied;
