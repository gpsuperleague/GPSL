-- =============================================================================
-- League clinch announcements (mathematical certainty)
--
-- Detects when outcomes are locked:
--   SuperLeague: champions · relegation playoff (16–17) · auto relegation (18–20)
--   Championship A/B: division champions · auto promotion (top 2) · promotion playoffs (3–6)
--
-- Announces via:
--   • Club inbox (affected club) + broadcast to all owners for major outcomes
--   • Discord #gpsl-news only (not notifications / tables)
--
-- Runs after each league result is marked played, and after month league-tables job.
-- Admin: SELECT public.admin_competition_announce_clinches(NULL);
-- Safe re-run (deduped per season/division/club/type).
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.competition_league_clinches (
  id bigserial PRIMARY KEY,
  season_id bigint NOT NULL REFERENCES public.competition_seasons(id) ON DELETE CASCADE,
  division text NOT NULL,
  club_short_name text NOT NULL,
  clinch_type text NOT NULL
    CHECK (clinch_type IN (
      'champions',
      'auto_promotion',
      'promotion_playoff',
      'auto_relegation',
      'relegation_playoff'
    )),
  table_position integer,
  pts integer,
  mp integer,
  games_left integer,
  headline text NOT NULL,
  body text,
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT competition_league_clinches_uidx
    UNIQUE (season_id, division, club_short_name, clinch_type)
);

CREATE INDEX IF NOT EXISTS competition_league_clinches_season_idx
  ON public.competition_league_clinches (season_id, created_at DESC);

ALTER TABLE public.competition_league_clinches ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS competition_league_clinches_select ON public.competition_league_clinches;
CREATE POLICY competition_league_clinches_select
  ON public.competition_league_clinches
  FOR SELECT TO authenticated
  USING (true);

GRANT SELECT ON public.competition_league_clinches TO authenticated;
GRANT ALL ON public.competition_league_clinches TO service_role;
GRANT USAGE, SELECT ON SEQUENCE public.competition_league_clinches_id_seq TO service_role;

CREATE OR REPLACE FUNCTION public.competition_division_label(p_division text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $function$
  SELECT CASE lower(btrim(coalesce(p_division, '')))
    WHEN 'superleague' THEN 'SuperLeague'
    WHEN 'championship_a' THEN 'Championship A'
    WHEN 'championship_b' THEN 'Championship B'
    ELSE coalesce(nullif(btrim(p_division), ''), 'League')
  END;
$function$;

-- Core detector + announcer
CREATE OR REPLACE FUNCTION public.competition_process_league_clinches(
  p_season_id bigint DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season_id bigint := p_season_id;
  v_div text;
  v_announced jsonb := '[]'::jsonb;
  v_new int := 0;
  t record;
  v_can_above int;
  v_must_above int;
  v_must_below int;
  v_games_left int;
  v_max_pts int;
  v_clinch_type text;
  v_headline text;
  v_body text;
  v_tone text;
  v_div_label text;
  v_id bigint;
  v_month text;
  v_month_label text;
  v_has_champions boolean;
  v_has_auto_promo boolean;
  v_has_auto_rel boolean;
  v_div_complete boolean;
  v_backfill record;
  v_backfill_n int := 0;
BEGIN
  -- Bulk admin deploy sets this so May multipass does not re-scan every result
  IF current_setting('gpsl.skip_clinch_scan', true) = 'on' THEN
    RETURN jsonb_build_object('ok', true, 'skipped', true, 'reason', 'bulk_deploy');
  END IF;

  IF v_season_id IS NULL THEN
    SELECT id INTO v_season_id
    FROM public.competition_seasons
    WHERE is_current = true
    ORDER BY id DESC
    LIMIT 1;
  END IF;

  IF v_season_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_season');
  END IF;

  BEGIN
    v_month := public.competition_active_gpsl_month(v_season_id, now());
  EXCEPTION WHEN OTHERS THEN
    v_month := NULL;
  END;

  BEGIN
    v_month_label := public.competition_gpsl_month_label(v_month);
  EXCEPTION WHEN OTHERS THEN
    v_month_label := initcap(coalesce(v_month, 'Season'));
  END;

  FOREACH v_div IN ARRAY ARRAY[
    'superleague',
    'championship_a',
    'championship_b'
  ]::text[]
  LOOP
    v_div_label := public.competition_division_label(v_div);

    IF NOT EXISTS (
      SELECT 1
      FROM public.competition_standings_public s
      WHERE s.season_id = v_season_id
        AND s.division = v_div
    ) THEN
      CONTINUE;
    END IF;

    -- Final table is authoritative once every side has played 38, OR May has locked
    -- (GPSL league programme ends at May lock even if a fixture was left unplayed).
    SELECT
      NOT EXISTS (
        SELECT 1
        FROM public.competition_standings_public o
        WHERE o.season_id = v_season_id
          AND o.division = v_div
          AND greatest(0, 38 - coalesce(o.mp, 0)) > 0
      )
      OR EXISTS (
        SELECT 1
        FROM public.competition_season_calendar c
        WHERE c.season_id = v_season_id
          AND c.gpsl_month = 'may'
          AND c.lock_at IS NOT NULL
          AND c.lock_at <= now()
      )
    INTO v_div_complete;

    FOR t IN
      SELECT
        s.club_short_name,
        coalesce(nullif(btrim(s.club_name), ''), s.club_short_name) AS club_name,
        s.table_position,
        coalesce(s.mp, 0) AS mp,
        coalesce(s.pts, 0) AS pts,
        coalesce(s.gd, 0) AS gd,
        coalesce(s.gf, 0) AS gf,
        greatest(0, 38 - coalesce(s.mp, 0)) AS games_left,
        coalesce(s.pts, 0) + 3 * greatest(0, 38 - coalesce(s.mp, 0)) AS max_pts
      FROM public.competition_standings_public s
      WHERE s.season_id = v_season_id
        AND s.division = v_div
      ORDER BY s.table_position, s.club_short_name
    LOOP
      v_games_left := t.games_left;
      v_max_pts := t.max_pts;

      -- Teams that can still finish above T (worst case for T: 0 more pts; ties uncertain → count as can)
      SELECT count(*)::int INTO v_can_above
      FROM public.competition_standings_public o
      WHERE o.season_id = v_season_id
        AND o.division = v_div
        AND o.club_short_name <> t.club_short_name
        AND (coalesce(o.pts, 0) + 3 * greatest(0, 38 - coalesce(o.mp, 0))) >= t.pts;

      -- Teams that must finish above T (even if T maxes and they get 0)
      SELECT count(*)::int INTO v_must_above
      FROM public.competition_standings_public o
      WHERE o.season_id = v_season_id
        AND o.division = v_div
        AND o.club_short_name <> t.club_short_name
        AND coalesce(o.pts, 0) > v_max_pts;

      -- Teams that must finish below T (even if they max and T gets 0)
      SELECT count(*)::int INTO v_must_below
      FROM public.competition_standings_public o
      WHERE o.season_id = v_season_id
        AND o.division = v_div
        AND o.club_short_name <> t.club_short_name
        AND (coalesce(o.pts, 0) + 3 * greatest(0, 38 - coalesce(o.mp, 0))) < t.pts;

      v_clinch_type := NULL;
      v_tone := NULL;
      v_headline := NULL;
      v_body := NULL;

      SELECT EXISTS (
        SELECT 1 FROM public.competition_league_clinches c
        WHERE c.season_id = v_season_id
          AND c.division = v_div
          AND c.club_short_name = t.club_short_name
          AND c.clinch_type = 'champions'
      ) INTO v_has_champions;

      SELECT EXISTS (
        SELECT 1 FROM public.competition_league_clinches c
        WHERE c.season_id = v_season_id
          AND c.division = v_div
          AND c.club_short_name = t.club_short_name
          AND c.clinch_type = 'auto_promotion'
      ) INTO v_has_auto_promo;

      SELECT EXISTS (
        SELECT 1 FROM public.competition_league_clinches c
        WHERE c.season_id = v_season_id
          AND c.division = v_div
          AND c.club_short_name = t.club_short_name
          AND c.clinch_type = 'auto_relegation'
      ) INTO v_has_auto_rel;

      -- 1) Division / league champions (clinched 1st, or final table #1 when division complete)
      -- Note: can_above uses >= pts, so a points-tied 2nd blocks mid-season math; final table catches that.
      IF NOT v_has_champions
         AND (
           v_can_above = 0
           OR (t.table_position = 1 AND coalesce(v_div_complete, false))
         ) THEN
        v_clinch_type := 'champions';
        v_tone := 'celebrate';
        IF v_div = 'superleague' THEN
          v_headline := format('🏆 CHAMPIONS — %s are SuperLeague champions!', t.club_name);
          IF coalesce(v_div_complete, false) OR v_games_left = 0 THEN
            v_body := format(
              '%s finish top of the SuperLeague with %s points and are champions.',
              t.club_name, t.pts::text
            );
          ELSE
            v_body := format(
              '%s have mathematically won the SuperLeague with %s points and %s game%s left. No side can catch them.',
              t.club_name, t.pts::text, v_games_left::text,
              CASE WHEN v_games_left = 1 THEN '' ELSE 's' END
            );
          END IF;
        ELSE
          v_headline := format('🏆 CHAMPIONS — %s are %s champions!', t.club_name, v_div_label);
          IF coalesce(v_div_complete, false) OR v_games_left = 0 THEN
            v_body := format(
              '%s finish top of %s with %s points — champions, with automatic promotion to the SuperLeague.',
              t.club_name, v_div_label, t.pts::text
            );
          ELSE
            v_body := format(
              '%s have mathematically won %s with %s points and %s game%s left — and sealed automatic promotion to the SuperLeague.',
              t.club_name, v_div_label, t.pts::text, v_games_left::text,
              CASE WHEN v_games_left = 1 THEN '' ELSE 's' END
            );
          END IF;
        END IF;

      -- 2) Championship automatic promotion (top 2) — skip if already division champions
      ELSIF v_div IN ('championship_a', 'championship_b')
        AND NOT v_has_champions
        AND NOT v_has_auto_promo
        AND v_can_above <= 1 THEN
        v_clinch_type := 'auto_promotion';
        v_tone := 'celebrate';
        v_headline := format('⬆️ AUTOMATIC PROMOTION — %s are going up!', t.club_name);
        v_body := format(
          '%s have mathematically secured a top-two finish in %s (%s pts, %s game%s left) and will be promoted to the SuperLeague.',
          t.club_name, v_div_label, t.pts::text, v_games_left::text,
          CASE WHEN v_games_left = 1 THEN '' ELSE 's' END
        );

      -- 3) Championship promotion playoff lock (top 6, not already top 2)
      ELSIF v_div IN ('championship_a', 'championship_b')
        AND NOT v_has_champions
        AND NOT v_has_auto_promo
        AND v_can_above <= 5
        AND NOT EXISTS (
          SELECT 1 FROM public.competition_league_clinches c
          WHERE c.season_id = v_season_id
            AND c.division = v_div
            AND c.club_short_name = t.club_short_name
            AND c.clinch_type = 'promotion_playoff'
        ) THEN
        v_clinch_type := 'promotion_playoff';
        v_tone := 'celebrate';
        v_headline := format('🎯 PLAYOFFS LOCKED — %s have sealed a promotion playoff place!', t.club_name);
        v_body := format(
          '%s have mathematically secured a top-six finish in %s (%s pts, %s game%s left) and will contest the Championship promotion playoffs.',
          t.club_name, v_div_label, t.pts::text, v_games_left::text,
          CASE WHEN v_games_left = 1 THEN '' ELSE 's' END
        );

      -- 4) SuperLeague automatic relegation (cannot leave bottom 3)
      ELSIF v_div = 'superleague'
        AND NOT v_has_auto_rel
        AND v_must_above >= 17 THEN
        v_clinch_type := 'auto_relegation';
        v_tone := 'commiserate';
        v_headline := format('⬇️ RELEGATED — %s are down from the SuperLeague', t.club_name);
        v_body := format(
          '%s have been mathematically relegated from the SuperLeague (%s pts, %s game%s left). They can no longer climb out of the bottom three.',
          t.club_name, t.pts::text, v_games_left::text,
          CASE WHEN v_games_left = 1 THEN '' ELSE 's' END
        );

      -- 5) SuperLeague relegation playoff lock (16–17 only)
      ELSIF v_div = 'superleague'
        AND NOT v_has_auto_rel
        AND v_must_above >= 15
        AND v_must_below >= 3
        AND NOT EXISTS (
          SELECT 1 FROM public.competition_league_clinches c
          WHERE c.season_id = v_season_id
            AND c.division = v_div
            AND c.club_short_name = t.club_short_name
            AND c.clinch_type = 'relegation_playoff'
        ) THEN
        v_clinch_type := 'relegation_playoff';
        v_tone := 'commiserate';
        v_headline := format('⚠️ RELEGATION PLAYOFF — %s are locked into 16th/17th', t.club_name);
        v_body := format(
          '%s can no longer finish higher than 17th or lower than 16th in the SuperLeague (%s pts, %s game%s left). They will contest the SuperLeague relegation playoff.',
          t.club_name, t.pts::text, v_games_left::text,
          CASE WHEN v_games_left = 1 THEN '' ELSE 's' END
        );
      END IF;

      IF v_clinch_type IS NULL THEN
        CONTINUE;
      END IF;

      INSERT INTO public.competition_league_clinches (
        season_id, division, club_short_name, clinch_type,
        table_position, pts, mp, games_left, headline, body, metadata
      )
      VALUES (
        v_season_id, v_div, t.club_short_name, v_clinch_type,
        t.table_position, t.pts, t.mp, v_games_left, v_headline, v_body,
        jsonb_build_object(
          'tone', v_tone,
          'division_label', v_div_label,
          'club_name', t.club_name,
          'gpsl_month', v_month,
          'month_label', v_month_label
        )
      )
      ON CONFLICT (season_id, division, club_short_name, clinch_type) DO NOTHING
      RETURNING id INTO v_id;

      IF v_id IS NULL THEN
        CONTINUE;
      END IF;

      v_new := v_new + 1;

      -- If CH champions just recorded, also record auto_promotion (same moment) for history
      IF v_clinch_type = 'champions' AND v_div IN ('championship_a', 'championship_b') THEN
        INSERT INTO public.competition_league_clinches (
          season_id, division, club_short_name, clinch_type,
          table_position, pts, mp, games_left, headline, body, metadata
        )
        VALUES (
          v_season_id, v_div, t.club_short_name, 'auto_promotion',
          t.table_position, t.pts, t.mp, v_games_left,
          format('⬆️ AUTOMATIC PROMOTION — %s are going up!', t.club_name),
          format(
            '%s sealed automatic promotion as %s champions.',
            t.club_name, v_div_label
          ),
          jsonb_build_object(
            'tone', 'celebrate',
            'division_label', v_div_label,
            'club_name', t.club_name,
            'via', 'champions',
            'silent', true
          )
        )
        ON CONFLICT DO NOTHING;
      END IF;

      -- Inbox → affected club
      BEGIN
        PERFORM public.owner_inbox_send(
          'league_clinch',
          v_headline,
          v_body || E'\n\nSee the league table for the full picture.',
          t.club_short_name,
          NULL, NULL, NULL, NULL, NULL,
          'progress.html',
          'clinch:' || v_season_id::text || ':' || v_div || ':' || t.club_short_name || ':' || v_clinch_type,
          v_month,
          v_season_id
        );
      EXCEPTION WHEN OTHERS THEN
        NULL;
      END;

      -- Broadcast major outcomes to every owned club
      IF v_clinch_type IN ('champions', 'auto_promotion', 'auto_relegation') THEN
        BEGIN
          PERFORM public.owner_inbox_notify_all_clubs(
            'league_clinch_broadcast',
            v_headline,
            v_body,
            'progress.html',
            'clinch_bc:' || v_season_id::text || ':' || v_div || ':' || t.club_short_name || ':' || v_clinch_type,
            v_season_id
          );
        EXCEPTION WHEN OTHERS THEN
          NULL;
        END;
      END IF;

      -- Discord #gpsl-news only
      BEGIN
        PERFORM public.gpsl_discord_feed_enqueue(
          'league_clinch',
          v_headline,
          v_body,
          CASE WHEN v_tone = 'celebrate' THEN 16766720 ELSE 10038562 END,
          'clinch_news:' || v_season_id::text || ':' || v_div || ':' || t.club_short_name || ':' || v_clinch_type,
          jsonb_build_object(
            'channel', 'news',
            'clinch_type', v_clinch_type,
            'division', v_div,
            'club_short_name', t.club_short_name,
            'tone', v_tone
          )
        );
      EXCEPTION WHEN OTHERS THEN
        NULL;
      END;

      v_announced := v_announced || jsonb_build_array(
        jsonb_build_object(
          'id', v_id,
          'division', v_div,
          'club', t.club_short_name,
          'type', v_clinch_type,
          'headline', v_headline
        )
      );
    END LOOP;
  END LOOP;

  -- Backfill Discord for clinches recorded earlier without a news queue row
  FOR v_backfill IN
    SELECT
      c.id,
      c.division,
      c.club_short_name,
      c.clinch_type,
      c.headline,
      c.body,
      c.metadata
    FROM public.competition_league_clinches c
    WHERE c.season_id = v_season_id
      AND coalesce((c.metadata->>'silent')::boolean, false) IS NOT TRUE
      AND NOT EXISTS (
        SELECT 1
        FROM public.gpsl_discord_feed_queue q
        WHERE q.dedupe_key =
          'clinch_news:' || c.season_id::text || ':' || c.division || ':'
          || c.club_short_name || ':' || c.clinch_type
      )
    ORDER BY c.id
  LOOP
    BEGIN
      PERFORM public.gpsl_discord_feed_enqueue(
        'league_clinch',
        v_backfill.headline,
        v_backfill.body,
        CASE
          WHEN coalesce(v_backfill.metadata->>'tone', '') = 'celebrate' THEN 16766720
          ELSE 10038562
        END,
        'clinch_news:' || v_season_id::text || ':' || v_backfill.division || ':'
          || v_backfill.club_short_name || ':' || v_backfill.clinch_type,
        jsonb_build_object(
          'channel', 'news',
          'clinch_type', v_backfill.clinch_type,
          'division', v_backfill.division,
          'club_short_name', v_backfill.club_short_name,
          'tone', coalesce(v_backfill.metadata->>'tone', 'celebrate'),
          'backfill', true
        )
      );
      v_backfill_n := v_backfill_n + 1;
      v_announced := v_announced || jsonb_build_array(
        jsonb_build_object(
          'id', v_backfill.id,
          'division', v_backfill.division,
          'club', v_backfill.club_short_name,
          'type', v_backfill.clinch_type,
          'headline', v_backfill.headline,
          'backfill', true
        )
      );
    EXCEPTION WHEN OTHERS THEN
      NULL;
    END;
  END LOOP;

  BEGIN
    PERFORM public.gpsl_discord_feed_request_flush();
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;

  RETURN jsonb_build_object(
    'ok', true,
    'season_id', v_season_id,
    'new_clinches', v_new,
    'discord_backfill', v_backfill_n,
    'announced', v_announced
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_process_league_clinches(bigint)
  TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.admin_competition_announce_clinches(
  p_season_id bigint DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;
  RETURN public.competition_process_league_clinches(p_season_id);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.admin_competition_announce_clinches(bigint)
  TO authenticated;

-- After league result confirmed → re-scan clinches
CREATE OR REPLACE FUNCTION public.gpsl_discord_feed_on_fixture_played()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_home text;
  v_away text;
  v_month text;
  v_comp text;
  v_detail text;
  v_headline text;
  v_body text;
  v_pen text;
  v_cup_round text;
  v_cup_match text;
BEGIN
  IF NEW.status IS DISTINCT FROM 'played' THEN
    RETURN NEW;
  END IF;
  IF TG_OP = 'UPDATE' AND OLD.status IS NOT DISTINCT FROM 'played' THEN
    RETURN NEW;
  END IF;
  IF NEW.home_goals IS NULL OR NEW.away_goals IS NULL THEN
    RETURN NEW;
  END IF;

  SELECT c."Club" INTO v_home FROM public."Clubs" c WHERE c."ShortName" = NEW.home_club_short_name;
  SELECT c."Club" INTO v_away FROM public."Clubs" c WHERE c."ShortName" = NEW.away_club_short_name;
  v_home := coalesce(nullif(btrim(v_home), ''), NEW.home_club_short_name, 'Home');
  v_away := coalesce(nullif(btrim(v_away), ''), NEW.away_club_short_name, 'Away');

  BEGIN
    v_month := public.competition_gpsl_month_label(NEW.gpsl_month);
  EXCEPTION WHEN OTHERS THEN
    v_month := NULL;
  END;
  v_month := coalesce(
    nullif(btrim(v_month), ''),
    nullif(initcap(btrim(coalesce(NEW.gpsl_month, ''))), ''),
    'Unknown month'
  );

  IF NEW.competition_type = 'cup' OR nullif(btrim(coalesce(NEW.cup_code, '')), '') IS NOT NULL THEN
    BEGIN
      v_comp := public.competition_cup_fixture_label(NEW);
    EXCEPTION WHEN OTHERS THEN
      v_comp := NULL;
    END;

    IF nullif(btrim(coalesce(v_comp, '')), '') IS NULL THEN
      v_cup_round := CASE WHEN NEW.cup_round IS NOT NULL THEN ' R' || NEW.cup_round::text ELSE '' END;
      v_cup_match := CASE WHEN NEW.cup_match IS NOT NULL THEN ' M' || NEW.cup_match::text ELSE '' END;
      v_comp := coalesce(
        nullif(btrim(
          CASE lower(coalesce(NEW.cup_code, ''))
            WHEN 'super8' THEN 'Super8'
            WHEN 'plate' THEN 'Plate'
            WHEN 'shield' THEN 'Shield'
            WHEN 'bowl' THEN 'Bowl'
            WHEN 'league_cup' THEN 'League Cup'
            ELSE initcap(replace(coalesce(NEW.cup_code, 'Cup'), '_', ' '))
          END
          || v_cup_round || v_cup_match
        ), ''),
        'Cup'
      );
    END IF;
  ELSE
    v_comp := CASE lower(coalesce(NEW.division, ''))
      WHEN 'superleague' THEN 'SuperLeague'
      WHEN 'championship_a' THEN 'Championship A'
      WHEN 'championship_b' THEN 'Championship B'
      ELSE coalesce(nullif(btrim(NEW.division), ''), 'League')
    END;
    IF NEW.matchday IS NOT NULL THEN
      v_detail := 'Matchday ' || NEW.matchday::text;
    END IF;
  END IF;

  v_comp := coalesce(nullif(btrim(v_comp), ''), 'Competition');

  v_headline := format(
    '🚨 FULL TIME — %s · %s — %s %s–%s %s',
    v_month,
    v_comp,
    v_home,
    NEW.home_goals,
    NEW.away_goals,
    v_away
  );

  v_body := v_month || ' · ' || v_comp || E'\nScore: '
    || NEW.home_goals::text || '–' || NEW.away_goals::text;

  IF v_detail IS NOT NULL THEN
    v_body := v_body || E'\n' || v_detail;
  END IF;

  IF NEW.cup_pen_winner_club_short_name IS NOT NULL THEN
    SELECT c."Club" INTO v_pen
    FROM public."Clubs" c
    WHERE c."ShortName" = NEW.cup_pen_winner_club_short_name;
    v_body := v_body || E'\nPens: '
      || coalesce(nullif(btrim(v_pen), ''), NEW.cup_pen_winner_club_short_name);
  END IF;

  PERFORM public.gpsl_discord_feed_enqueue(
    'result',
    v_headline,
    v_body,
    14747136, -- 0xe10600
    'fixture:' || NEW.id::text,
    jsonb_build_object(
      'fixture_id', NEW.id,
      'competition_type', NEW.competition_type,
      'division', NEW.division,
      'cup_code', NEW.cup_code,
      'gpsl_month', NEW.gpsl_month,
      'channel', 'results'
    )
  );

  -- Clinch scan after league results only
  IF coalesce(NEW.competition_type, 'league') = 'league'
     AND nullif(btrim(coalesce(NEW.cup_code, '')), '') IS NULL THEN
    BEGIN
      PERFORM public.competition_process_league_clinches(NEW.season_id);
    EXCEPTION WHEN OTHERS THEN
      NULL;
    END;
  END IF;

  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_gpsl_discord_feed_fixture_played ON public.competition_fixtures;
CREATE TRIGGER trg_gpsl_discord_feed_fixture_played
  AFTER INSERT OR UPDATE OF status, home_goals, away_goals
  ON public.competition_fixtures
  FOR EACH ROW
  EXECUTE FUNCTION public.gpsl_discord_feed_on_fixture_played();

-- Also run after month league-tables processing
CREATE OR REPLACE FUNCTION public.competition_process_month_league_tables(
  p_season_id bigint DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season_id bigint := p_season_id;
  v_cal record;
  v_job_key text;
  v_month_label text;
  v_qid bigint;
  v_snap jsonb;
  v_processed jsonb := '[]'::jsonb;
  v_clinches jsonb;
BEGIN
  IF v_season_id IS NULL THEN
    SELECT id INTO v_season_id
    FROM public.competition_seasons
    WHERE is_current = true
    ORDER BY id DESC
    LIMIT 1;
  END IF;

  IF v_season_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_season');
  END IF;

  FOR v_cal IN
    SELECT c.gpsl_month
    FROM public.competition_season_calendar c
    WHERE c.season_id = v_season_id
      AND c.gpsl_month IS NOT NULL
      AND c.lock_at IS NOT NULL
      AND c.lock_at <= now()
    ORDER BY public.competition_gpsl_month_sort(c.gpsl_month)
  LOOP
    v_job_key := 'league_tables:' || v_cal.gpsl_month;

    IF EXISTS (
      SELECT 1
      FROM public.competition_season_calendar_jobs j
      WHERE j.season_id = v_season_id
        AND j.job_key = v_job_key
        AND coalesce((j.result->>'ok')::boolean, false) IS TRUE
    ) THEN
      CONTINUE;
    END IF;

    BEGIN
      v_month_label := public.competition_gpsl_month_label(v_cal.gpsl_month);
    EXCEPTION WHEN OTHERS THEN
      v_month_label := initcap(v_cal.gpsl_month);
    END;

    v_snap := public.competition_league_tables_snapshot(v_season_id);

    v_qid := public.gpsl_discord_feed_enqueue(
      'tables',
      format('📊 LEAGUE TABLES — %s', coalesce(v_month_label, initcap(v_cal.gpsl_month))),
      format(
        'End of %s standings for SuperLeague, Championship A and Championship B.',
        coalesce(v_month_label, initcap(v_cal.gpsl_month))
      ),
      5793266,
      'league_tables:' || v_season_id::text || ':' || v_cal.gpsl_month,
      jsonb_build_object(
        'channel', 'tables',
        'render', true,
        'season_id', v_season_id,
        'gpsl_month', v_cal.gpsl_month,
        'month_label', v_month_label,
        'standings', coalesce(v_snap->'standings', '[]'::jsonb)
      )
    );

    INSERT INTO public.competition_season_calendar_jobs (
      season_id, job_key, gpsl_month, result
    )
    VALUES (
      v_season_id,
      v_job_key,
      v_cal.gpsl_month,
      jsonb_build_object(
        'ok', v_qid IS NOT NULL,
        'queue_id', v_qid,
        'enqueued_at', now()
      )
    )
    ON CONFLICT (season_id, job_key) DO UPDATE
      SET result = excluded.result,
          gpsl_month = excluded.gpsl_month,
          ran_at = now();

    v_processed := v_processed || jsonb_build_array(
      jsonb_build_object(
        'gpsl_month', v_cal.gpsl_month,
        'queue_id', v_qid
      )
    );
  END LOOP;

  -- Clinches after tables (covers End Month Early / month tick)
  BEGIN
    v_clinches := public.competition_process_league_clinches(v_season_id);
  EXCEPTION WHEN OTHERS THEN
    v_clinches := jsonb_build_object('ok', false, 'error', SQLERRM);
  END;

  BEGIN
    PERFORM public.gpsl_discord_feed_request_flush();
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;

  RETURN jsonb_build_object(
    'ok', true,
    'season_id', v_season_id,
    'processed', v_processed,
    'clinches', v_clinches
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_process_month_league_tables(bigint)
  TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';
