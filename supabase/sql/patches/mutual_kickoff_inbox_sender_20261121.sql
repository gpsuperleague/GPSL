-- A kick-off change from the calendar was labelled "Play now" and the
-- club who asked received the same "please confirm" note as the opponent.
-- Opponent still confirms. The sender gets a waiting note, with no confirm button.

DO $inbox$
DECLARE
  v_def text;
  v_list text;
BEGIN
  SELECT pg_get_constraintdef(c.oid) INTO v_def
  FROM pg_constraint c
  WHERE c.conrelid = 'public.competition_inbox'::regclass
    AND c.conname = 'competition_inbox_message_type_check';

  IF v_def IS NOT NULL AND position('''match_mutual_override_sent''' IN v_def) = 0 THEN
    SELECT string_agg(quote_literal(t), ', ' ORDER BY t) INTO v_list
    FROM (
      SELECT DISTINCT message_type AS t
      FROM public.competition_inbox
      WHERE message_type IS NOT NULL
      UNION
      SELECT (regexp_matches(coalesce(v_def, ''), '''([^'']+)''', 'g'))[1]
      UNION SELECT 'match_mutual_override_sent'
    ) s
    WHERE t IS NOT NULL AND btrim(t) <> '';

    ALTER TABLE public.competition_inbox
      DROP CONSTRAINT IF EXISTS competition_inbox_message_type_check;
    EXECUTE format(
      'ALTER TABLE public.competition_inbox ADD CONSTRAINT competition_inbox_message_type_check CHECK (message_type IN (%s)) NOT VALID',
      v_list
    );
    ALTER TABLE public.competition_inbox
      VALIDATE CONSTRAINT competition_inbox_message_type_check;
  END IF;
END
$inbox$;

CREATE OR REPLACE FUNCTION public.match_schedule_notify_opponent(
  p_fixture public.competition_fixtures,
  p_message_type text,
  p_title text,
  p_body text,
  p_opponent_club text,
  p_dedupe_suffix text,
  p_proposal_id bigint DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_href text;
  v_title text;
  v_body text;
  v_actor text;
  v_actor_title text;
  v_actor_body text;
BEGIN
  v_href := 'fixture_schedule.html?fixture=' || p_fixture.id::text;
  v_title := public.competition_fixture_inbox_title(p_fixture.id, p_title);
  v_body := public.competition_fixture_inbox_body(p_fixture.id, p_body);

  PERFORM public.owner_inbox_send(
    p_message_type,
    v_title,
    v_body,
    p_opponent_club,
    NULL,
    p_fixture.id,
    NULL, NULL, NULL,
    v_href,
    'schedule:' || p_fixture.id::text || ':' || p_dedupe_suffix,
    p_fixture.gpsl_month,
    p_fixture.season_id,
    p_proposal_id
  );

  IF p_message_type IN (
    'match_mutual_override_requested',
    'match_mutual_override_cancelled',
    'match_rescheduled',
    'match_emergency_drop',
    'match_play_now_pressed',
    'match_already_played'
  ) THEN
    v_actor := CASE
      WHEN p_opponent_club = p_fixture.home_club_short_name THEN p_fixture.away_club_short_name
      WHEN p_opponent_club = p_fixture.away_club_short_name THEN p_fixture.home_club_short_name
      ELSE NULL
    END;

    IF v_actor IS NOT NULL AND v_actor IS DISTINCT FROM p_opponent_club THEN
      IF p_message_type = 'match_mutual_override_requested' THEN
        v_actor_title := public.competition_fixture_inbox_title(p_fixture.id, 'Kick-off change sent');
        v_actor_body := public.competition_fixture_inbox_body(
          p_fixture.id,
          'You asked '
            || coalesce(public.club_display_name(p_opponent_club), p_opponent_club)
            || ' to confirm a kick-off change. Waiting for them. Nothing changes until they confirm.'
        );
        PERFORM public.owner_inbox_send(
          'match_mutual_override_sent',
          v_actor_title,
          v_actor_body,
          v_actor,
          NULL,
          p_fixture.id,
          NULL, NULL, NULL,
          v_href,
          'schedule:' || p_fixture.id::text || ':' || p_dedupe_suffix || ':sent',
          p_fixture.gpsl_month,
          p_fixture.season_id,
          p_proposal_id
        );
      ELSE
        PERFORM public.owner_inbox_send(
          p_message_type,
          v_title,
          v_body,
          v_actor,
          NULL,
          p_fixture.id,
          NULL, NULL, NULL,
          v_href,
          'schedule:' || p_fixture.id::text || ':' || p_dedupe_suffix || ':both',
          p_fixture.gpsl_month,
          p_fixture.season_id,
          p_proposal_id
        );
      END IF;
    END IF;
  END IF;
END;
$function$;

DO $copy$
DECLARE
  v_def text;
  v_old text;
  v_new text;
BEGIN
  SELECT replace(pg_get_functiondef('public.fixture_mutual_override_request(bigint, text, timestamp with time zone)'::regprocedure), E'\r\n', E'\n')
  INTO v_def;

  v_old := 'Play now requested';
  v_new := 'Different kick-off requested';
  IF position(v_old IN v_def) > 0 THEN
    v_def := replace(v_def, v_old, v_new);
  END IF;

  v_old := ' proposed play now at ';
  v_new := ' asked for a different kick-off at ';
  IF position(v_old IN v_def) > 0 THEN
    v_def := replace(v_def, v_old, v_new);
  END IF;

  IF v_def IS NOT NULL AND position('Different kick-off requested' IN v_def) > 0 THEN
    EXECUTE v_def;
  END IF;
END
$copy$;

UPDATE public.competition_inbox i
SET
  message_type = 'match_mutual_override_sent',
  title = replace(i.title, 'Play now requested', 'Kick-off change sent'),
  body = 'You asked '
    || coalesce(public.club_display_name(
         CASE
           WHEN i.recipient_club_short_name = f.home_club_short_name THEN f.away_club_short_name
           ELSE f.home_club_short_name
         END
       ), '')
    || ' to confirm a kick-off change. Waiting for them. Nothing changes until they confirm.'
FROM public.competition_fixtures f
WHERE i.fixture_id = f.id
  AND i.message_type = 'match_mutual_override_requested'
  AND coalesce(i.dedupe_key, '') LIKE '%:both'
  AND i.body ILIKE '%play now%';

UPDATE public.competition_inbox
SET
  title = replace(title, 'Play now requested', 'Different kick-off requested'),
  body = replace(body, 'proposed play now at', 'asked for a different kick-off at')
WHERE message_type = 'match_mutual_override_requested'
  AND body ILIKE '%play now%'
  AND coalesce(dedupe_key, '') NOT LIKE '%:both';
