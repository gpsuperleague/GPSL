-- =============================================================================
-- Owner feedback survey
-- =============================================================================
-- · Fixed survey: 1–5 ratings per area, 0–10 "recommend GPSL", three text boxes
--   (working well / frustrations / recommendations).
-- · Automatic: once the GPSL calendar moves past August (September onwards) an
--   inbox invite goes to every club owner; open for global_settings
--   .owner_feedback_days (default 14). One reminder 48h before it closes to
--   owners who haven't responded.
-- · Owners may tick "submit anonymously": the response is then stored with no
--   owner / club and only a day-level date; a separate completion row (owner
--   only, no answers) stops repeat submissions and reminders.
-- · Admin results: admin_owner_feedback.html.
--
-- Safe re-run.
-- =============================================================================

ALTER TABLE public.global_settings
  ADD COLUMN IF NOT EXISTS owner_feedback_days int NOT NULL DEFAULT 14;

CREATE TABLE IF NOT EXISTS public.owner_feedback_surveys (
  id bigserial PRIMARY KEY,
  season_id bigint,
  survey_key text NOT NULL,
  title text NOT NULL,
  opens_at timestamptz NOT NULL DEFAULT now(),
  closes_at timestamptz NOT NULL,
  invite_sent_at timestamptz,
  reminder_sent_at timestamptz,
  invited_count int NOT NULL DEFAULT 0,
  created_by uuid,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT owner_feedback_surveys_key UNIQUE (season_id, survey_key),
  CONSTRAINT owner_feedback_surveys_window CHECK (closes_at > opens_at)
);

CREATE TABLE IF NOT EXISTS public.owner_feedback_responses (
  id bigserial PRIMARY KEY,
  survey_id bigint NOT NULL REFERENCES public.owner_feedback_surveys (id) ON DELETE CASCADE,
  owner_id uuid,
  club_short_name text,
  is_anonymous boolean NOT NULL DEFAULT false,
  ratings jsonb NOT NULL DEFAULT '{}'::jsonb,
  recommend_score int CHECK (recommend_score IS NULL OR recommend_score BETWEEN 0 AND 10),
  liked text,
  frustrations text,
  recommendation text,
  submitted_on timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT owner_feedback_responses_named CHECK (is_anonymous OR owner_id IS NOT NULL)
);

CREATE INDEX IF NOT EXISTS owner_feedback_responses_survey_idx
  ON public.owner_feedback_responses (survey_id);

CREATE TABLE IF NOT EXISTS public.owner_feedback_completions (
  survey_id bigint NOT NULL REFERENCES public.owner_feedback_surveys (id) ON DELETE CASCADE,
  owner_id uuid NOT NULL,
  club_short_name text,
  completed_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (survey_id, owner_id)
);

ALTER TABLE public.owner_feedback_surveys ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.owner_feedback_responses ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.owner_feedback_completions ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.owner_feedback_surveys FROM anon, authenticated;
REVOKE ALL ON public.owner_feedback_responses FROM anon, authenticated;
REVOKE ALL ON public.owner_feedback_completions FROM anon, authenticated;

-- ---------------------------------------------------------------------------
-- Inbox message types (keeps every existing type)
-- ---------------------------------------------------------------------------
DO $inbox_types$
DECLARE
  v_def text;
  v_list text;
BEGIN
  SELECT pg_get_constraintdef(c.oid)
  INTO v_def
  FROM pg_constraint c
  WHERE c.conrelid = 'public.competition_inbox'::regclass
    AND c.conname = 'competition_inbox_message_type_check';

  IF v_def IS NULL THEN
    RETURN;
  END IF;

  SELECT string_agg(quote_literal(t), ', ' ORDER BY t)
  INTO v_list
  FROM (
    SELECT DISTINCT message_type AS t
    FROM public.competition_inbox
    WHERE message_type IS NOT NULL
    UNION
    SELECT (regexp_matches(v_def, '''([^'']+)''', 'g'))[1]
    UNION
    SELECT unnest(ARRAY['owner_feedback_invite', 'owner_feedback_reminder'])
  ) s
  WHERE t IS NOT NULL AND btrim(t) <> '';

  ALTER TABLE public.competition_inbox
    DROP CONSTRAINT IF EXISTS competition_inbox_message_type_check;

  EXECUTE format(
    'ALTER TABLE public.competition_inbox
       ADD CONSTRAINT competition_inbox_message_type_check
       CHECK (message_type IN (%s)) NOT VALID',
    v_list
  );

  ALTER TABLE public.competition_inbox
    VALIDATE CONSTRAINT competition_inbox_message_type_check;
END;
$inbox_types$;

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.owner_feedback_rating_keys()
RETURNS text[]
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT ARRAY[
    'overall', 'auctions', 'matchday', 'scheduling', 'finances',
    'scouting', 'website', 'communication', 'rules'
  ];
$$;

CREATE OR REPLACE FUNCTION public.owner_feedback_inbox(
  p_type text,
  p_title text,
  p_body text,
  p_club text,
  p_dedupe text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  BEGIN
    PERFORM public.owner_inbox_send(
      p_type, p_title, p_body, p_club, NULL::uuid,
      NULL::bigint, NULL::bigint, NULL::bigint, NULL::bigint,
      'feedback_survey.html', p_dedupe, NULL::text, NULL::bigint, NULL::bigint
    );
  EXCEPTION WHEN undefined_function THEN
    PERFORM public.owner_inbox_send(
      p_type, p_title, p_body, p_club, NULL::uuid,
      NULL::bigint, NULL::bigint, NULL::bigint, NULL::bigint,
      'feedback_survey.html', p_dedupe, NULL::text, NULL::bigint
    );
  END;
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING 'owner feedback inbox (%/%) failed: %', p_type, p_club, SQLERRM;
END;
$function$;

CREATE OR REPLACE FUNCTION public.owner_feedback_send_invites(p_survey_id bigint)
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  s public.owner_feedback_surveys%rowtype;
  c record;
  v_n int := 0;
BEGIN
  SELECT * INTO s FROM public.owner_feedback_surveys WHERE id = p_survey_id;
  IF NOT FOUND THEN
    RETURN 0;
  END IF;

  FOR c IN
    SELECT cl."ShortName" AS club
    FROM public."Clubs" cl
    WHERE cl.owner_id IS NOT NULL
      AND nullif(btrim(cl."ShortName"), '') IS NOT NULL
  LOOP
    PERFORM public.owner_feedback_inbox(
      'owner_feedback_invite',
      'Tell us what you think — owner feedback survey',
      format(
        'We''d love your feedback on GPSL so far. The survey takes about 3 minutes: rate each area 1–5, '
        || 'tell us what''s working and what isn''t, and add any recommendations. '
        || 'You can submit anonymously if you prefer. Open until %s (UK time).',
        to_char(s.closes_at AT TIME ZONE 'Europe/London', 'Dy DD Mon HH24:MI')
      ),
      c.club,
      'owner_feedback_invite:' || s.id || ':' || c.club
    );
    v_n := v_n + 1;
  END LOOP;

  UPDATE public.owner_feedback_surveys
  SET invite_sent_at = now(), invited_count = v_n
  WHERE id = s.id;

  RETURN v_n;
END;
$function$;

-- ---------------------------------------------------------------------------
-- Cron tick (hourly): open after August, remind 48h before close
-- ---------------------------------------------------------------------------
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
       AND public.competition_gpsl_month_sort(v_month) > public.competition_gpsl_month_sort('august')
       AND NOT EXISTS (
         SELECT 1 FROM public.owner_feedback_surveys
         WHERE season_id = v_season_id AND survey_key = 'post_august'
       ) THEN
      SELECT greatest(coalesce(gs.owner_feedback_days, 14), 3) INTO v_days
      FROM public.global_settings gs WHERE gs.id = 1;

      INSERT INTO public.owner_feedback_surveys (season_id, survey_key, title, opens_at, closes_at)
      VALUES (
        v_season_id, 'post_august', 'Owner feedback survey',
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

-- ---------------------------------------------------------------------------
-- Owner RPCs
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.owner_feedback_current()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  s public.owner_feedback_surveys%rowtype;
  v_done timestamptz;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Please log in';
  END IF;

  SELECT * INTO s
  FROM public.owner_feedback_surveys
  WHERE now() >= opens_at AND now() < closes_at
  ORDER BY opens_at DESC
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('open', false, 'club_short_name', public.my_club_shortname());
  END IF;

  SELECT completed_at INTO v_done
  FROM public.owner_feedback_completions
  WHERE survey_id = s.id AND owner_id = v_uid;

  RETURN jsonb_build_object(
    'open', true,
    'survey_id', s.id,
    'title', s.title,
    'closes_at', s.closes_at,
    'completed', v_done IS NOT NULL,
    'completed_at', v_done,
    'club_short_name', public.my_club_shortname()
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.owner_feedback_submit(
  p_survey_id bigint,
  p_ratings jsonb,
  p_recommend_score int,
  p_liked text,
  p_frustrations text,
  p_recommendation text,
  p_anonymous boolean
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_club text := public.my_club_shortname();
  s public.owner_feedback_surveys%rowtype;
  v_ratings jsonb := '{}'::jsonb;
  k text;
  v_val int;
  v_anon boolean := coalesce(p_anonymous, false);
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Please log in';
  END IF;
  IF v_club IS NULL THEN
    RAISE EXCEPTION 'The survey is for club owners';
  END IF;

  SELECT * INTO s FROM public.owner_feedback_surveys WHERE id = p_survey_id;
  IF NOT FOUND OR now() < s.opens_at OR now() >= s.closes_at THEN
    RAISE EXCEPTION 'This survey is closed';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.owner_feedback_completions
    WHERE survey_id = s.id AND owner_id = v_uid
  ) THEN
    RAISE EXCEPTION 'You have already completed this survey — thank you!';
  END IF;

  FOREACH k IN ARRAY public.owner_feedback_rating_keys()
  LOOP
    IF p_ratings ? k AND nullif(p_ratings->>k, '') IS NOT NULL THEN
      v_val := (p_ratings->>k)::int;
      IF v_val < 1 OR v_val > 5 THEN
        RAISE EXCEPTION 'Ratings must be 1 to 5';
      END IF;
      v_ratings := v_ratings || jsonb_build_object(k, v_val);
    END IF;
  END LOOP;

  IF NOT (v_ratings ? 'overall') THEN
    RAISE EXCEPTION 'Please give an overall rating';
  END IF;
  IF p_recommend_score IS NOT NULL AND (p_recommend_score < 0 OR p_recommend_score > 10) THEN
    RAISE EXCEPTION 'Recommend score must be 0 to 10';
  END IF;

  INSERT INTO public.owner_feedback_completions (survey_id, owner_id, club_short_name)
  VALUES (s.id, v_uid, v_club);

  INSERT INTO public.owner_feedback_responses (
    survey_id, owner_id, club_short_name, is_anonymous, ratings, recommend_score,
    liked, frustrations, recommendation, submitted_on
  )
  VALUES (
    s.id,
    CASE WHEN v_anon THEN NULL ELSE v_uid END,
    CASE WHEN v_anon THEN NULL ELSE v_club END,
    v_anon,
    v_ratings,
    p_recommend_score,
    left(nullif(btrim(p_liked), ''), 4000),
    left(nullif(btrim(p_frustrations), ''), 4000),
    left(nullif(btrim(p_recommendation), ''), 4000),
    CASE WHEN v_anon THEN date_trunc('day', now()) ELSE now() END
  );

  RETURN jsonb_build_object('ok', true);
END;
$function$;

-- ---------------------------------------------------------------------------
-- Admin RPCs
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_owner_feedback_surveys()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admins only';
  END IF;

  RETURN coalesce((
    SELECT jsonb_agg(jsonb_build_object(
      'id', s.id,
      'title', s.title,
      'season_id', s.season_id,
      'survey_key', s.survey_key,
      'opens_at', s.opens_at,
      'closes_at', s.closes_at,
      'is_open', now() >= s.opens_at AND now() < s.closes_at,
      'invite_sent_at', s.invite_sent_at,
      'reminder_sent_at', s.reminder_sent_at,
      'invited_count', s.invited_count,
      'responses', (SELECT count(*) FROM public.owner_feedback_completions c WHERE c.survey_id = s.id)
    ) ORDER BY s.opens_at DESC)
    FROM public.owner_feedback_surveys s
  ), '[]'::jsonb);
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_owner_feedback_results(p_survey_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_stats jsonb;
  v_responses jsonb;
  v_pending jsonb;
  v_nps jsonb;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admins only';
  END IF;

  SELECT coalesce(jsonb_object_agg(k, jsonb_build_object(
    'avg', (SELECT round(avg((r.ratings->>k)::numeric), 2)
            FROM public.owner_feedback_responses r
            WHERE r.survey_id = p_survey_id AND r.ratings ? k),
    'count', (SELECT count(*) FROM public.owner_feedback_responses r
              WHERE r.survey_id = p_survey_id AND r.ratings ? k),
    'dist', (SELECT jsonb_build_array(
               count(*) FILTER (WHERE (r.ratings->>k)::int = 1),
               count(*) FILTER (WHERE (r.ratings->>k)::int = 2),
               count(*) FILTER (WHERE (r.ratings->>k)::int = 3),
               count(*) FILTER (WHERE (r.ratings->>k)::int = 4),
               count(*) FILTER (WHERE (r.ratings->>k)::int = 5))
             FROM public.owner_feedback_responses r
             WHERE r.survey_id = p_survey_id AND r.ratings ? k)
  )), '{}'::jsonb)
  INTO v_stats
  FROM unnest(public.owner_feedback_rating_keys()) k;

  SELECT jsonb_build_object(
    'count', count(*),
    'avg', round(avg(r.recommend_score), 2),
    'promoters', count(*) FILTER (WHERE r.recommend_score >= 9),
    'passives', count(*) FILTER (WHERE r.recommend_score BETWEEN 7 AND 8),
    'detractors', count(*) FILTER (WHERE r.recommend_score <= 6),
    'nps', CASE WHEN count(*) > 0 THEN round(
      100.0 * (count(*) FILTER (WHERE r.recommend_score >= 9)
             - count(*) FILTER (WHERE r.recommend_score <= 6)) / count(*)) END
  )
  INTO v_nps
  FROM public.owner_feedback_responses r
  WHERE r.survey_id = p_survey_id AND r.recommend_score IS NOT NULL;

  SELECT coalesce(jsonb_agg(jsonb_build_object(
    'id', r.id,
    'is_anonymous', r.is_anonymous,
    'club_short_name', r.club_short_name,
    'club_name', cl."Club",
    'owner_tag', reg.owner_tag,
    'ratings', r.ratings,
    'recommend_score', r.recommend_score,
    'liked', r.liked,
    'frustrations', r.frustrations,
    'recommendation', r.recommendation,
    'submitted_on', r.submitted_on
  ) ORDER BY r.submitted_on DESC, r.id DESC), '[]'::jsonb)
  INTO v_responses
  FROM public.owner_feedback_responses r
  LEFT JOIN public."Clubs" cl ON cl."ShortName" = r.club_short_name
  LEFT JOIN public.gpsl_owner_registry reg ON reg.owner_id = r.owner_id
  WHERE r.survey_id = p_survey_id;

  SELECT coalesce(jsonb_agg(jsonb_build_object(
    'club_short_name', cl."ShortName",
    'club_name', cl."Club"
  ) ORDER BY cl."Club"), '[]'::jsonb)
  INTO v_pending
  FROM public."Clubs" cl
  WHERE cl.owner_id IS NOT NULL
    AND NOT EXISTS (
      SELECT 1 FROM public.owner_feedback_completions c
      WHERE c.survey_id = p_survey_id AND c.owner_id = cl.owner_id
    );

  RETURN jsonb_build_object(
    'survey_id', p_survey_id,
    'completed', (SELECT count(*) FROM public.owner_feedback_completions c WHERE c.survey_id = p_survey_id),
    'owners', (SELECT count(*) FROM public."Clubs" cl WHERE cl.owner_id IS NOT NULL),
    'ratings', v_stats,
    'recommend', v_nps,
    'responses', v_responses,
    'not_responded', v_pending
  );
END;
$function$;

-- Open a survey now (testing / extra survey) and send invites.
CREATE OR REPLACE FUNCTION public.admin_owner_feedback_open_now(p_days int DEFAULT 14)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season_id bigint;
  v_id bigint;
  v_sent int;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admins only';
  END IF;
  IF EXISTS (
    SELECT 1 FROM public.owner_feedback_surveys WHERE now() >= opens_at AND now() < closes_at
  ) THEN
    RAISE EXCEPTION 'A survey is already open — close it first';
  END IF;

  SELECT id INTO v_season_id
  FROM public.competition_seasons
  WHERE is_current = true
  ORDER BY id DESC
  LIMIT 1;

  INSERT INTO public.owner_feedback_surveys (season_id, survey_key, title, opens_at, closes_at, created_by)
  VALUES (
    v_season_id,
    'manual_' || to_char(now(), 'YYYYMMDDHH24MISS'),
    'Owner feedback survey',
    now(),
    now() + make_interval(days => greatest(coalesce(p_days, 14), 1)),
    auth.uid()
  )
  RETURNING id INTO v_id;

  v_sent := public.owner_feedback_send_invites(v_id);
  RETURN jsonb_build_object('ok', true, 'survey_id', v_id, 'invited', v_sent);
END;
$function$;

-- Change the closing time (extend, or close now with p_closes_at = now()).
CREATE OR REPLACE FUNCTION public.admin_owner_feedback_set_close(p_survey_id bigint, p_closes_at timestamptz)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admins only';
  END IF;
  UPDATE public.owner_feedback_surveys
  SET closes_at = greatest(p_closes_at, opens_at + interval '1 minute'),
      reminder_sent_at = CASE WHEN p_closes_at > closes_at THEN NULL ELSE reminder_sent_at END
  WHERE id = p_survey_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Survey not found';
  END IF;
  RETURN jsonb_build_object('ok', true);
END;
$function$;

-- ---------------------------------------------------------------------------
-- Grants
-- ---------------------------------------------------------------------------
REVOKE ALL ON FUNCTION public.owner_feedback_tick() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.owner_feedback_send_invites(bigint) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.owner_feedback_inbox(text, text, text, text, text) FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.owner_feedback_current() TO authenticated;
GRANT EXECUTE ON FUNCTION public.owner_feedback_submit(bigint, jsonb, int, text, text, text, boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_owner_feedback_surveys() TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_owner_feedback_results(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_owner_feedback_open_now(int) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_owner_feedback_set_close(bigint, timestamptz) TO authenticated;

-- ---------------------------------------------------------------------------
-- Cron (hourly at :07)
-- ---------------------------------------------------------------------------
DO $cron$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    BEGIN
      PERFORM cron.unschedule('gpsl-owner-feedback');
    EXCEPTION WHEN OTHERS THEN
      NULL;
    END;
    PERFORM cron.schedule(
      'gpsl-owner-feedback',
      '7 * * * *',
      $job$SELECT public.owner_feedback_tick();$job$
    );
  END IF;
END;
$cron$;

NOTIFY pgrst, 'reload schema';

-- Check: what the calendar says now (the survey opens automatically once this is past August)
SELECT
  s.id AS season_id,
  public.competition_active_gpsl_month(s.id, now()) AS gpsl_month_now,
  (SELECT count(*) FROM public.owner_feedback_surveys) AS surveys,
  (SELECT count(*) FROM cron.job WHERE jobname = 'gpsl-owner-feedback') AS cron_jobs
FROM public.competition_seasons s
WHERE s.is_current = true
ORDER BY s.id DESC
LIMIT 1;
