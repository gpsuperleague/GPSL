-- =============================================================================
-- Owner feedback survey: open in GPSL December (not post-August)
-- =============================================================================
-- Prerequisite: owner_feedback_survey_20261006.sql (creates tables + RPCs).
-- That base patch now also opens in December; this patch is for DBs that
-- already had the post-August tick installed.
--
-- Safe re-run.
-- =============================================================================

DO $$
BEGIN
  IF to_regclass('public.owner_feedback_surveys') IS NULL THEN
    RAISE EXCEPTION
      'owner_feedback_surveys missing — run supabase/sql/patches/owner_feedback_survey_20261006.sql first, then re-run this patch';
  END IF;
END $$;

-- Close early post-August surveys that are still open.
UPDATE public.owner_feedback_surveys
SET closes_at = now()
WHERE survey_key = 'post_august'
  AND now() >= opens_at
  AND now() < closes_at
  AND closes_at > opens_at + interval '1 minute';

CREATE OR REPLACE FUNCTION public.owner_feedback_tick()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season_id bigint;
  v_month text;
  v_days int;
  v_id bigint;
  v_opened boolean := false;
  v_reminded int := 0;
  s record;
  c record;
BEGIN
  SELECT id INTO v_season_id
  FROM public.competition_seasons
  WHERE is_current = true AND status = 'active'
  ORDER BY id DESC
  LIMIT 1;

  IF v_season_id IS NOT NULL THEN
    BEGIN
      v_month := public.competition_active_gpsl_month(v_season_id, now());
    EXCEPTION WHEN OTHERS THEN
      v_month := NULL;
    END;

    IF v_month IS NOT NULL
       AND public.competition_gpsl_month_sort(v_month)
           >= public.competition_gpsl_month_sort('december')
       AND NOT EXISTS (
         SELECT 1 FROM public.owner_feedback_surveys
         WHERE season_id = v_season_id AND survey_key = 'december'
       ) THEN
      SELECT greatest(coalesce(gs.owner_feedback_days, 14), 3) INTO v_days
      FROM public.global_settings gs WHERE gs.id = 1;

      INSERT INTO public.owner_feedback_surveys (season_id, survey_key, title, opens_at, closes_at)
      VALUES (
        v_season_id, 'december', 'Owner feedback survey',
        now(), now() + make_interval(days => coalesce(v_days, 14))
      )
      ON CONFLICT (season_id, survey_key) DO NOTHING
      RETURNING id INTO v_id;

      IF v_id IS NOT NULL THEN
        PERFORM public.owner_feedback_send_invites(v_id);
        v_opened := true;
      END IF;
    END IF;
  END IF;

  FOR s IN
    SELECT * FROM public.owner_feedback_surveys
    WHERE reminder_sent_at IS NULL
      AND invite_sent_at IS NOT NULL
      AND now() < closes_at
      AND now() >= closes_at - interval '48 hours'
      AND closes_at - opens_at > interval '72 hours'
  LOOP
    FOR c IN
      SELECT cl."ShortName" AS club
      FROM public."Clubs" cl
      WHERE cl.owner_id IS NOT NULL
        AND nullif(btrim(cl."ShortName"), '') IS NOT NULL
        AND NOT EXISTS (
          SELECT 1 FROM public.owner_feedback_completions fc
          WHERE fc.survey_id = s.id AND fc.owner_id = cl.owner_id
        )
    LOOP
      PERFORM public.owner_feedback_inbox(
        'owner_feedback_reminder',
        'Reminder: owner feedback survey closes soon',
        format(
          'The owner feedback survey closes %s (UK time). It only takes a few minutes and you can stay anonymous — your ideas shape what we build next.',
          to_char(s.closes_at AT TIME ZONE 'Europe/London', 'Dy DD Mon HH24:MI')
        ),
        c.club,
        'owner_feedback_reminder:' || s.id || ':' || c.club
      );
      v_reminded := v_reminded + 1;
    END LOOP;

    UPDATE public.owner_feedback_surveys SET reminder_sent_at = now() WHERE id = s.id;
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true, 'season_id', v_season_id, 'gpsl_month', v_month,
    'opened', v_opened, 'reminders', v_reminded
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.owner_feedback_tick() FROM PUBLIC, anon, authenticated;

SELECT
  s.id AS season_id,
  public.competition_active_gpsl_month(s.id, now()) AS gpsl_month_now,
  (SELECT count(*) FROM public.owner_feedback_surveys ofs
    WHERE ofs.season_id = s.id AND ofs.survey_key = 'december') AS december_surveys,
  (SELECT count(*) FROM public.owner_feedback_surveys ofs
    WHERE ofs.season_id = s.id AND ofs.survey_key = 'post_august'
      AND now() >= ofs.opens_at AND now() < ofs.closes_at) AS post_august_still_open
FROM public.competition_seasons s
WHERE s.is_current = true
ORDER BY s.id DESC
LIMIT 1;
