-- =============================================================================
-- Fix: gpsl_month is text ('august', 'may', …) not smallint — broke result submit
-- Run once in Supabase after owner_inbox_notifications.sql
-- =============================================================================

ALTER TABLE public.competition_inbox
  ALTER COLUMN gpsl_month TYPE text USING gpsl_month::text;

CREATE OR REPLACE FUNCTION public.owner_inbox_send(
  p_message_type text,
  p_title text,
  p_body text,
  p_recipient_club text DEFAULT NULL,
  p_owner_id uuid DEFAULT NULL,
  p_fixture_id bigint DEFAULT NULL,
  p_submission_id bigint DEFAULT NULL,
  p_transfer_history_id bigint DEFAULT NULL,
  p_transfer_listing_id bigint DEFAULT NULL,
  p_action_href text DEFAULT NULL,
  p_dedupe_key text DEFAULT NULL,
  p_gpsl_month text DEFAULT NULL,
  p_season_id bigint DEFAULT NULL
)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_id bigint;
  v_club text := nullif(btrim(p_recipient_club), '');
BEGIN
  IF v_club IS NULL AND p_owner_id IS NULL THEN
    RETURN NULL;
  END IF;

  IF v_club = 'FOREIGN' THEN
    RETURN NULL;
  END IF;

  IF p_dedupe_key IS NOT NULL AND EXISTS (
    SELECT 1 FROM public.competition_inbox i WHERE i.dedupe_key = p_dedupe_key
  ) THEN
    RETURN NULL;
  END IF;

  INSERT INTO public.competition_inbox (
    recipient_club_short_name, owner_id, message_type,
    fixture_id, submission_id, transfer_history_id, transfer_listing_id,
    title, body, action_href, dedupe_key, gpsl_month, season_id
  )
  VALUES (
    v_club, p_owner_id, p_message_type,
    p_fixture_id, p_submission_id, p_transfer_history_id, p_transfer_listing_id,
    p_title, p_body, p_action_href, p_dedupe_key, p_gpsl_month, p_season_id
  )
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$function$;

CREATE OR REPLACE FUNCTION public.trg_result_submission_notify_submitter()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_fixture public.competition_fixtures;
  v_home_name text;
  v_away_name text;
  v_label text;
BEGIN
  SELECT * INTO v_fixture FROM public.competition_fixtures WHERE id = NEW.fixture_id;
  SELECT "Club" INTO v_home_name FROM public."Clubs" WHERE "ShortName" = v_fixture.home_club_short_name;
  SELECT "Club" INTO v_away_name FROM public."Clubs" WHERE "ShortName" = v_fixture.away_club_short_name;

  v_label := CASE
    WHEN v_fixture.competition_type = 'cup' THEN public.competition_cup_fixture_label(v_fixture)
    ELSE format('GPSL %s', coalesce(public.competition_gpsl_month_label(v_fixture.gpsl_month), v_fixture.gpsl_month, 'month'))
  END;

  PERFORM public.owner_inbox_send(
    'result_submitted',
    format('Result submitted: %s vs %s', v_home_name, v_away_name),
    format(
      E'%s — you submitted %s %s–%s %s.\nWaiting for your opponent to confirm or reject.',
      v_label, v_home_name, NEW.home_goals, NEW.away_goals, v_away_name
    ),
    NEW.submitted_by_club,
    NULL,
    NEW.fixture_id,
    NEW.id,
    NULL, NULL,
    'matchday.html?fixture=' || NEW.fixture_id::text,
    'result_submitted:' || NEW.id::text,
    v_fixture.gpsl_month,
    v_fixture.season_id
  );

  RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.owner_inbox_build_month_preview_body(
  p_club_short_name text,
  p_season_id bigint,
  p_gpsl_month text
)
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_fixture record;
  v_opp text;
  v_opp_name text;
  v_lines text[] := ARRAY[]::text[];
  v_line text;
  v_standing record;
  v_mgr_name text;
  v_scorers text;
  v_assisters text;
  v_threats text;
  v_month_label text;
BEGIN
  v_month_label := coalesce(public.competition_gpsl_month_label(p_gpsl_month), p_gpsl_month);

  FOR v_fixture IN
    SELECT f.*
    FROM public.competition_fixtures f
    WHERE f.season_id = p_season_id
      AND f.gpsl_month = p_gpsl_month
      AND f.status = 'scheduled'
      AND p_club_short_name IN (f.home_club_short_name, f.away_club_short_name)
    ORDER BY f.week_in_month, f.id
  LOOP
    v_opp := CASE
      WHEN v_fixture.home_club_short_name = p_club_short_name THEN v_fixture.away_club_short_name
      ELSE v_fixture.home_club_short_name
    END;

    SELECT c."Club" INTO v_opp_name FROM public."Clubs" c WHERE c."ShortName" = v_opp;

    SELECT s.table_position, s.w, s.d, s.l, s.pts, s.form_last10
    INTO v_standing
    FROM public.competition_standings_public s
    WHERE s.season_id = p_season_id AND s.club_short_name = v_opp;

    SELECT m.name INTO v_mgr_name
    FROM public."Managers" m
    WHERE m.contracted_club = v_opp
    LIMIT 1;

    SELECT string_agg(x.nm || ' (' || x.g::text || ')', ', ' ORDER BY x.g DESC, x.nm)
    INTO v_scorers
    FROM (
      SELECT p."Name" AS nm, coalesce(ps.goals, 0) AS g
      FROM public."Players" p
      LEFT JOIN public.competition_player_season_stats_public ps
        ON ps.player_id = p."Konami_ID"::text AND ps.club_short_name = v_opp
      WHERE p."Contracted_Team" = v_opp AND coalesce(ps.goals, 0) > 0
      ORDER BY coalesce(ps.goals, 0) DESC, p."Name"
      LIMIT 3
    ) x;

    SELECT string_agg(x.nm || ' (' || x.a::text || ')', ', ' ORDER BY x.a DESC, x.nm)
    INTO v_assisters
    FROM (
      SELECT p."Name" AS nm, coalesce(ps.assists, 0) AS a
      FROM public."Players" p
      LEFT JOIN public.competition_player_season_stats_public ps
        ON ps.player_id = p."Konami_ID"::text AND ps.club_short_name = v_opp
      WHERE p."Contracted_Team" = v_opp AND coalesce(ps.assists, 0) > 0
      ORDER BY coalesce(ps.assists, 0) DESC, p."Name"
      LIMIT 2
    ) x;

    SELECT string_agg(x.nm, ', ' ORDER BY x.r DESC)
    INTO v_threats
    FROM (
      SELECT p."Name" AS nm,
        coalesce(nullif(btrim(p."Rating"::text), '')::int, 0) AS r
      FROM public."Players" p
      WHERE p."Contracted_Team" = v_opp
      ORDER BY coalesce(nullif(btrim(p."Rating"::text), '')::int, 0) DESC, p."Name"
      LIMIT 3
    ) x;

    v_line := format(
      E'• %s %s (%s)\n  Opponent record: %sW-%sD-%sL, %s pts, pos %s. Form: %s\n  Manager: %s\n  Top rated: %s\n  Goal threats: %s\n  Top assists: %s',
      CASE WHEN v_fixture.home_club_short_name = p_club_short_name THEN 'Home vs' ELSE 'Away at' END,
      coalesce(v_opp_name, v_opp),
      CASE WHEN v_fixture.competition_type = 'cup' THEN coalesce(v_fixture.cup_code, 'cup') ELSE 'league' END,
      coalesce(v_standing.w::text, '0'),
      coalesce(v_standing.d::text, '0'),
      coalesce(v_standing.l::text, '0'),
      coalesce(v_standing.pts::text, '0'),
      coalesce(v_standing.table_position::text, '—'),
      coalesce(nullif(v_standing.form_last10, ''), '—'),
      coalesce(v_mgr_name, 'TBC'),
      coalesce(v_threats, '—'),
      coalesce(v_scorers, '—'),
      coalesce(v_assisters, '—')
    );

    v_lines := array_append(v_lines, v_line);
  END LOOP;

  IF coalesce(array_length(v_lines, 1), 0) = 0 THEN
    RETURN 'No scheduled fixtures in ' || v_month_label || '.';
  END IF;

  RETURN array_to_string(v_lines, E'\n\n');
END;
$function$;

CREATE OR REPLACE FUNCTION public.owner_inbox_notify_monthly_fixtures(
  p_season_id bigint DEFAULT NULL,
  p_gpsl_month text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season_id bigint;
  v_month text;
  v_club record;
  v_body text;
  v_count int := 0;
  v_label text;
BEGIN
  v_season_id := p_season_id;
  IF v_season_id IS NULL THEN
    SELECT id INTO v_season_id FROM public.competition_seasons WHERE is_current = true AND status = 'active' LIMIT 1;
  END IF;

  v_month := p_gpsl_month;
  IF v_month IS NULL THEN
    v_month := public.competition_active_gpsl_month(v_season_id, now());
  END IF;

  IF v_season_id IS NULL OR v_month IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_active_month');
  END IF;

  v_label := coalesce(public.competition_gpsl_month_label(v_month), v_month);

  FOR v_club IN
    SELECT c."ShortName" AS short_name
    FROM public."Clubs" c
    WHERE c.owner_id IS NOT NULL
      AND EXISTS (
        SELECT 1 FROM public.competition_fixtures f
        WHERE f.season_id = v_season_id
          AND f.gpsl_month = v_month
          AND f.status = 'scheduled'
          AND c."ShortName" IN (f.home_club_short_name, f.away_club_short_name)
      )
  LOOP
    v_body := public.owner_inbox_build_month_preview_body(v_club.short_name, v_season_id, v_month);

    IF public.owner_inbox_send(
      'monthly_fixtures',
      format('GPSL %s — your matches', v_label),
      v_body,
      v_club.short_name,
      NULL,
      NULL, NULL, NULL, NULL,
      'fixtures.html',
      format('month_preview:%s:%s:%s', v_season_id, v_month, v_club.short_name),
      v_month,
      v_season_id
    ) IS NOT NULL THEN
      v_count := v_count + 1;
    END IF;
  END LOOP;

  RETURN jsonb_build_object('ok', true, 'season_id', v_season_id, 'gpsl_month', v_month, 'notified', v_count);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.owner_inbox_send(text, text, text, text, uuid, bigint, bigint, bigint, bigint, text, text, text, bigint) TO authenticated;

NOTIFY pgrst, 'reload schema';
