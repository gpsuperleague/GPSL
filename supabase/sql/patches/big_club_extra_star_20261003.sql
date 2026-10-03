-- =============================================================================
-- Big clubs: +1 star player (2026-10-03)
--
-- Star cap (excl. One of Our Own) = Superleague 3 / Championship 2,
-- plus global_settings.big_club_extra_stars (default 1) when the club's tier is
-- 'big' (prestige rank ≤ stadium_big_club_max_rank, default top 10, or a tier
-- override). So a big club: SL 4 / Champ 3.
--
-- Tier is recalculated each season with prestige. A club that was big last season
-- and isn't now ("demoted") and is over its new cap may, until GPSL August
-- unlocks, sell in the open market OR release over-cap stars for 125% of market
-- value. Inbox notice sent once. From August the normal enforcement applies
-- (lowest stars released @ MV + ₿2.5m fine each).
--
-- Safe to re-run.
-- =============================================================================

ALTER TABLE public.global_settings
  ADD COLUMN IF NOT EXISTS big_club_extra_stars smallint NOT NULL DEFAULT 1;

-- ---------------------------------------------------------------------------
-- 1. Star cap
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.club_squad_star_cap(p_club_short_name text)
RETURNS smallint
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_base smallint;
  v_extra smallint := 0;
  v_tier text;
BEGIN
  v_base := CASE
    WHEN public.competition_club_division_tier(p_club_short_name) = 'superleague' THEN 3
    ELSE 2
  END;

  BEGIN
    v_tier := public.competition_club_tier(p_club_short_name);
  EXCEPTION WHEN OTHERS THEN
    v_tier := NULL;
  END;

  IF v_tier = 'big' THEN
    v_extra := coalesce(
      (SELECT big_club_extra_stars FROM public.global_settings WHERE id = 1),
      1
    );
  END IF;

  RETURN (v_base + greatest(v_extra, 0))::smallint;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.club_squad_star_cap(text) TO authenticated;

-- ---------------------------------------------------------------------------
-- 2. Demotion helpers
-- ---------------------------------------------------------------------------
-- Big at the locked prestige of the most recent completed season.
CREATE OR REPLACE FUNCTION public.club_was_big_last_season(p_club_short_name text)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  WITH prev AS (
    SELECT max(snap.season_id) AS season_id
    FROM public.competition_club_prestige_snapshot snap
    JOIN public.competition_seasons cs ON cs.id = snap.season_id
    WHERE cs.status = 'complete'
  )
  SELECT coalesce((
    SELECT snap.prestige_rank <= coalesce(
      (SELECT stadium_big_club_max_rank FROM public.global_settings WHERE id = 1), 10
    )
    FROM prev
    JOIN public.competition_club_prestige_snapshot snap
      ON snap.season_id = prev.season_id
     AND snap.club_short_name = p_club_short_name
  ), false);
$$;

-- Season being prepared / played (latest not finished).
CREATE OR REPLACE FUNCTION public.club_star_demotion_season()
RETURNS bigint
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT max(cs.id)
  FROM public.competition_seasons cs
  WHERE cs.status IN ('setup', 'preseason', 'active');
$$;

-- Release window: until GPSL August unlocks (no calendar → while setup / preseason).
CREATE OR REPLACE FUNCTION public.club_star_demotion_deadline()
RETURNS timestamptz
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT m.unlock_at
  FROM public.competition_season_calendar m
  WHERE m.season_id = public.club_star_demotion_season()
    AND m.gpsl_month = 'august'
  LIMIT 1;
$$;

CREATE OR REPLACE FUNCTION public.club_star_demotion_window_open()
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season bigint := public.club_star_demotion_season();
  v_deadline timestamptz := public.club_star_demotion_deadline();
BEGIN
  IF v_season IS NULL THEN
    RETURN false;
  END IF;
  IF v_deadline IS NOT NULL THEN
    RETURN now() < v_deadline;
  END IF;
  RETURN EXISTS (
    SELECT 1 FROM public.competition_seasons
    WHERE id = v_season AND status IN ('setup', 'preseason')
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.club_star_demotion_state(p_club_short_name text)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := btrim(p_club_short_name);
  v_was_big boolean;
  v_is_big boolean;
  v_cap int;
  v_count int;
  v_min smallint := 79;
  v_ooo text;
  v_stars jsonb;
BEGIN
  v_was_big := public.club_was_big_last_season(v_club);
  BEGIN
    v_is_big := public.competition_club_tier(v_club) = 'big';
  EXCEPTION WHEN OTHERS THEN
    v_is_big := false;
  END;

  IF NOT v_was_big OR v_is_big THEN
    RETURN jsonb_build_object('ok', true, 'demoted', false);
  END IF;

  v_cap := public.club_squad_star_cap(v_club);
  v_count := public.club_star_count_for_cap(v_club);
  IF to_regprocedure('public.club_squad_star_min_rating()') IS NOT NULL THEN
    v_min := public.club_squad_star_min_rating();
  END IF;
  v_ooo := public.club_ooo_player_id(v_club);

  SELECT coalesce(jsonb_agg(jsonb_build_object(
      'player_id', p."Konami_ID"::text,
      'name', p."Name",
      'position', p."Position",
      'rating', p."Rating",
      'market_value', p.market_value,
      'release_fee', round(greatest(coalesce(p.market_value::numeric, 0), 0) * 1.25)
    ) ORDER BY nullif(regexp_replace(coalesce(btrim(p."Rating"::text), ''), '[^0-9]', '', 'g'), '')::int,
               p.market_value), '[]'::jsonb)
  INTO v_stars
  FROM public."Players" p
  WHERE p."Contracted_Team" = v_club
    AND nullif(regexp_replace(coalesce(btrim(p."Rating"::text), ''), '[^0-9]', '', 'g'), '')::int >= v_min
    AND (v_ooo IS NULL OR p."Konami_ID"::text <> v_ooo);

  RETURN jsonb_build_object(
    'ok', true,
    'demoted', true,
    'window_open', public.club_star_demotion_window_open(),
    'deadline', public.club_star_demotion_deadline(),
    'star_cap', v_cap,
    'star_count', v_count,
    'over', greatest(v_count - v_cap, 0),
    'stars', v_stars
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.club_was_big_last_season(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.club_star_demotion_window_open() TO authenticated;
GRANT EXECUTE ON FUNCTION public.club_star_demotion_state(text) TO authenticated;

-- ---------------------------------------------------------------------------
-- 3. Owner release @ 125% MV (demoted + over cap + window open)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.player_star_demotion_release(p_player_id text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_pid text := btrim(p_player_id);
  v_club text;
  v_state jsonb;
  v_res jsonb;
BEGIN
  SELECT c."ShortName" INTO v_club
  FROM public."Clubs" c
  WHERE c.owner_id = auth.uid()
  LIMIT 1;
  IF v_club IS NULL THEN
    RAISE EXCEPTION 'You do not own a club';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtext('star_demotion_release:' || v_club));

  v_state := public.club_star_demotion_state(v_club);
  IF NOT coalesce((v_state->>'demoted')::boolean, false) THEN
    RAISE EXCEPTION 'Only clubs that lost big-club status can use this release';
  END IF;
  IF NOT coalesce((v_state->>'window_open')::boolean, false) THEN
    RAISE EXCEPTION 'The 125%% release window has closed (it ends when GPSL August starts)';
  END IF;
  IF coalesce((v_state->>'over')::int, 0) <= 0 THEN
    RAISE EXCEPTION 'You are already within your star cap';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM jsonb_array_elements(v_state->'stars') s
    WHERE s->>'player_id' = v_pid
  ) THEN
    RAISE EXCEPTION 'That player is not one of your counted star players';
  END IF;

  v_res := public.club_august_release_player(
    v_club, v_pid, 1.25,
    'big_club_demotion_release',
    'Released at 125% MV (lost big-club status)'
  );

  RETURN v_res || jsonb_build_object('club', v_club);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.player_star_demotion_release(text) TO authenticated;

-- ---------------------------------------------------------------------------
-- 4. Inbox notice (once per club per season) — cron hourly
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
    SELECT 'star_cap_demotion'
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

CREATE OR REPLACE FUNCTION public.club_star_demotion_notify()
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season bigint := public.club_star_demotion_season();
  r record;
  v_state jsonb;
  v_n int := 0;
  v_title text := '⭐ Lost big-club status — star cap reduced';
  v_body text;
  v_deadline timestamptz;
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;
  IF v_season IS NULL OR NOT public.club_star_demotion_window_open() THEN
    RETURN 0;
  END IF;
  v_deadline := public.club_star_demotion_deadline();

  FOR r IN
    SELECT c."ShortName" AS club, c.owner_id
    FROM public."Clubs" c
    WHERE c.owner_id IS NOT NULL
      AND c."ShortName" <> 'FOREIGN'
      AND public.club_was_big_last_season(c."ShortName")
  LOOP
    v_state := public.club_star_demotion_state(r.club);
    CONTINUE WHEN NOT coalesce((v_state->>'demoted')::boolean, false)
               OR coalesce((v_state->>'over')::int, 0) <= 0;

    v_body := format(
      'Your club is no longer a big club this season, so your star cap drops to %s (you have %s). '
      'Until GPSL August starts%s you can sell star players on the open market, or release them from your Squad page for 125%% of market value. '
      'Any club still over the cap when August starts has its lowest-rated stars released at market value plus a ₿2.5m fine each.',
      v_state->>'star_cap', v_state->>'star_count',
      CASE WHEN v_deadline IS NOT NULL
        THEN ' (' || to_char(v_deadline AT TIME ZONE 'Europe/London', 'Dy DD Mon HH24:MI') || ' UK)'
        ELSE '' END
    );

    BEGIN
      BEGIN
        PERFORM public.owner_inbox_send(
          'star_cap_demotion'::text, v_title, v_body, r.club, r.owner_id,
          NULL::bigint, NULL::bigint, NULL::bigint, NULL::bigint,
          'squad.html'::text, format('star_cap_demotion:%s:%s', v_season, r.club),
          NULL::text, v_season, NULL::bigint
        );
      EXCEPTION WHEN undefined_function THEN
        PERFORM public.owner_inbox_send(
          'star_cap_demotion'::text, v_title, v_body, r.club, r.owner_id,
          NULL::bigint, NULL::bigint, NULL::bigint, NULL::bigint,
          'squad.html'::text, format('star_cap_demotion:%s:%s', v_season, r.club),
          NULL::text, v_season
        );
      END;
      v_n := v_n + 1;
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'star demotion inbox skipped for %: %', r.club, SQLERRM;
    END;
  END LOOP;

  RETURN v_n;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.club_star_demotion_notify() TO authenticated;

DO $cron$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'gpsl-star-demotion-notify') THEN
      PERFORM cron.unschedule('gpsl-star-demotion-notify');
    END IF;
    PERFORM cron.schedule(
      'gpsl-star-demotion-notify',
      '25 * * * *',
      $job$SELECT public.club_star_demotion_notify();$job$
    );
  ELSE
    RAISE WARNING 'pg_cron not installed — run SELECT public.club_star_demotion_notify(); once the new season''s prestige is set.';
  END IF;
END $cron$;

NOTIFY pgrst, 'reload schema';

-- Check: big clubs and their caps now
-- SELECT c."ShortName", public.competition_club_tier(c."ShortName") AS tier,
--        public.club_squad_star_cap(c."ShortName") AS star_cap,
--        public.club_star_count_for_cap(c."ShortName") AS stars
-- FROM public."Clubs" c
-- WHERE public.competition_club_tier(c."ShortName") = 'big'
-- ORDER BY 1;
