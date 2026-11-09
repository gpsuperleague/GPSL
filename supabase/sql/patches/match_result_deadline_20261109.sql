-- =============================================================================
-- Match result deadline (2026-11-09)
--
-- Same window as match video:
--   month the fixture was actually played in, then that month's lock
--   + 72 hours (match_video_missing_fine_grace_hours)
--   + 24 hours to recover (match video suspend hours)
--
-- If the result is still not confirmed at +72h:
--   ₿500k for each club that has not entered their side, plus an inbox reminder.
--   A club that already submitted is not charged.
-- If it is still not confirmed at +96h:
--   another ₿500k for each club that still has not entered, then the result is closed.
--   Score already submitted is kept. If nobody submitted, the score is 0–0.
--   Starters on the matchday lineup are rated 3, with no goals, assists,
--   cards, or player of the match. The normal stat rules are not applied.
--   Neither club can edit it afterwards.
--
-- Forfeits are left alone. A confirmed result is left alone.
-- The first fine is not refunded if they confirm during the 24 hours.
--
-- Safe re-run. The last statement runs the check once.
-- =============================================================================

INSERT INTO public.competition_fine_tariff AS t (
  code, label, category, direction, amount, amount_mode, sort_order, is_active, updated_at
)
VALUES
  (
    'match_result_late',
    'Result not confirmed after 72 hours',
    'matchday',
    'fine',
    500000,
    'fixed',
    76,
    true,
    now()
  ),
  (
    'match_result_closed',
    'Result closed after the 24 hour recovery',
    'matchday',
    'fine',
    500000,
    'fixed',
    77,
    true,
    now()
  )
ON CONFLICT (code) DO UPDATE
SET amount = EXCLUDED.amount,
    label = EXCLUDED.label,
    is_active = true,
    updated_at = now();

ALTER TABLE public.competition_fixtures
  ADD COLUMN IF NOT EXISTS result_auto_closed boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN public.competition_fixtures.result_auto_closed IS
  'Result was closed by the deadline. Score and stats cannot be edited.';

CREATE TABLE IF NOT EXISTS public.fixture_result_deadline (
  fixture_id bigint PRIMARY KEY
    REFERENCES public.competition_fixtures (id) ON DELETE CASCADE,
  reminded_at timestamptz,
  closed_at timestamptz,
  score_source text,
  created_at timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.fixture_result_deadline IS
  'One row per fixture once the result deadline has fined or closed it.';

DO $inbox$
DECLARE
  v_def text;
  v_list text;
BEGIN
  SELECT pg_get_constraintdef(c.oid) INTO v_def
  FROM pg_constraint c
  WHERE c.conrelid = 'public.competition_inbox'::regclass
    AND c.conname = 'competition_inbox_message_type_check';

  IF v_def IS NULL OR position('''match_result_deadline''' IN v_def) > 0 THEN
    RETURN;
  END IF;

  SELECT string_agg(quote_literal(t), ', ' ORDER BY t) INTO v_list
  FROM (
    SELECT DISTINCT message_type AS t
    FROM public.competition_inbox
    WHERE message_type IS NOT NULL
    UNION
    SELECT (regexp_matches(coalesce(v_def, ''), '''([^'']+)''', 'g'))[1]
    UNION SELECT 'match_result_deadline'
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
END
$inbox$;

CREATE OR REPLACE FUNCTION public.match_result_is_confirmed(p_fixture_id bigint)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.competition_result_submissions s
    WHERE s.fixture_id = p_fixture_id
      AND s.status = 'confirmed'
  )
  OR EXISTS (
    SELECT 1
    FROM public.competition_fixtures f
    WHERE f.id = p_fixture_id
      AND f.status = 'played'
      AND f.home_goals IS NOT NULL
      AND f.away_goals IS NOT NULL
      AND NOT EXISTS (
        SELECT 1
        FROM public.competition_result_submissions s
        WHERE s.fixture_id = f.id
          AND s.status = 'pending'
      )
  );
$$;

REVOKE ALL ON FUNCTION public.match_result_is_confirmed(bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.match_result_is_confirmed(bigint) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.match_result_deadline_tick()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_grace int := 72;
  v_recover int := 24;
  v_fine numeric := 500000;
  v_r record;
  v_sub public.competition_result_submissions;
  v_play timestamptz;
  v_lock timestamptz;
  v_remind_at timestamptz;
  v_close_at timestamptz;
  v_row public.fixture_result_deadline;
  v_club text;
  v_entered text;
  v_side text;
  v_home_total smallint;
  v_away_total smallint;
  v_source text;
  v_label text;
  v_reminded int := 0;
  v_closed int := 0;
  v_skipped int := 0;
  v_player record;
BEGIN
  IF NOT (
    coalesce(auth.role(), '') = 'service_role'
    OR coalesce(public.is_gpsl_admin(), false)
    OR session_user IN ('postgres', 'supabase_admin')
  ) THEN
    RAISE EXCEPTION 'Not allowed';
  END IF;

  BEGIN
    v_grace := coalesce(public.match_video_missing_fine_grace_hours(), 72);
  EXCEPTION WHEN OTHERS THEN
    v_grace := 72;
  END;
  IF v_grace < 1 THEN
    v_grace := 72;
  END IF;

  BEGIN
    SELECT coalesce(s.missing_pts_suspend_hours, 24)
    INTO v_recover
    FROM public.gpsl_discord_match_videos_settings s
    WHERE s.id = 1;
  EXCEPTION WHEN OTHERS THEN
    v_recover := 24;
  END;
  IF v_recover IS NULL OR v_recover < 1 THEN
    v_recover := 24;
  END IF;

  FOR v_r IN
    SELECT f.*
    FROM public.competition_fixtures f
    JOIN public.competition_seasons sz
      ON sz.id = f.season_id
     AND sz.is_current
     AND sz.status = 'active'
    WHERE f.status IN ('scheduled', 'played')
      AND coalesce(f.is_forfeit, false) = false
      AND coalesce(f.is_void, false) = false
      AND coalesce(f.result_auto_closed, false) = false
      AND coalesce(f.competition_type, 'league') IN ('league', 'cup')
      AND NOT public.match_result_is_confirmed(f.id)
  LOOP
    BEGIN
      v_play := public.match_video_play_at(v_r.id);
      v_lock := public.match_video_due_lock_at(v_r.id);
      IF v_play IS NULL OR v_lock IS NULL OR v_play > now() OR v_lock > now() THEN
        CONTINUE;
      END IF;

      v_remind_at := v_lock + make_interval(hours => v_grace);
      v_close_at := v_remind_at + make_interval(hours => v_recover);
      IF now() < v_remind_at THEN
        CONTINUE;
      END IF;

      INSERT INTO public.fixture_result_deadline (fixture_id)
      VALUES (v_r.id)
      ON CONFLICT (fixture_id) DO NOTHING;

      SELECT * INTO v_row
      FROM public.fixture_result_deadline
      WHERE fixture_id = v_r.id
      FOR UPDATE;

      v_label := coalesce(
        public.competition_gpsl_month_label(public.match_video_due_gpsl_month(v_r.id)),
        public.match_video_due_gpsl_month(v_r.id),
        '?'
      );

      v_sub := NULL;
      SELECT * INTO v_sub
      FROM public.competition_result_submissions s
      WHERE s.fixture_id = v_r.id
        AND s.status = 'pending'
      ORDER BY s.id DESC
      LIMIT 1;

      v_entered := CASE
        WHEN v_sub.id IS NOT NULL THEN v_sub.submitted_by_club
        ELSE NULL
      END;

      IF v_row.reminded_at IS NULL THEN
        FOREACH v_side IN ARRAY ARRAY['home', 'away']
        LOOP
          v_club := CASE
            WHEN v_side = 'home' THEN v_r.home_club_short_name
            ELSE v_r.away_club_short_name
          END;
          IF v_club IS NULL THEN
            CONTINUE;
          END IF;
          IF NOT EXISTS (
            SELECT 1 FROM public."Clubs" c
            WHERE c."ShortName" = v_club
              AND c.owner_id IS NOT NULL
          ) THEN
            CONTINUE;
          END IF;

          IF v_entered IS NOT NULL
             AND upper(btrim(v_club)) = upper(btrim(v_entered)) THEN
            BEGIN
              PERFORM public.owner_inbox_send(
                'match_result_deadline',
                'Result deadline — your side is in',
                format(
                  E'You already entered this result. Your opponent has not confirmed it.\n'
                  || E'The ₿500,000 charge is theirs, not yours. They have %s hours left.\n'
                  || E'If they still have not confirmed, the result is closed on the score you submitted and only they are charged again.',
                  v_recover
                ),
                v_club,
                NULL,
                v_r.id,
                NULL, NULL, NULL,
                'matchday.html?fixture=' || v_r.id::text,
                'result_deadline_remind_clear:' || v_r.id::text || ':' || v_club,
                v_r.gpsl_month,
                v_r.season_id,
                NULL
              );
            EXCEPTION WHEN OTHERS THEN
              RAISE WARNING 'result deadline clear inbox %: %', v_r.id, SQLERRM;
            END;
            CONTINUE;
          END IF;

          PERFORM public.competition_apply_club_fine_tariff(
            v_club,
            'match_result_late',
            v_fine,
            format(
              'Your result was not entered within %sh of the %s lock (MD%s)',
              v_grace,
              v_label,
              coalesce(v_r.matchday::text, '?')
            ),
            v_r.id,
            v_r.season_id
          );

          BEGIN
            PERFORM public.owner_inbox_send(
              'match_result_deadline',
              'Result deadline — 24 hours to finish',
              format(
                E'The month this match was played in (%s) locked, and %s hours have passed without your result.\n'
                || E'₿500,000 has been charged to your club.\n'
                || E'Enter and confirm within %s hours. After that, another ₿500,000 is charged and the result is closed: a score already submitted is kept, otherwise it is 0–0. Starters are rated 3 with no goals or assists, and it cannot be edited.',
                v_label,
                v_grace,
                v_recover
              ),
              v_club,
              NULL,
              v_r.id,
              NULL, NULL, NULL,
              'matchday.html?fixture=' || v_r.id::text,
              'result_deadline_remind:' || v_r.id::text || ':' || v_club,
              v_r.gpsl_month,
              v_r.season_id,
              NULL
            );
          EXCEPTION WHEN OTHERS THEN
            RAISE WARNING 'result deadline reminder inbox %: %', v_r.id, SQLERRM;
          END;
        END LOOP;

        UPDATE public.fixture_result_deadline
        SET reminded_at = now()
        WHERE fixture_id = v_r.id;
        v_reminded := v_reminded + 1;
      END IF;

      IF now() < v_close_at OR v_row.closed_at IS NOT NULL THEN
        CONTINUE;
      END IF;

      IF public.match_result_is_confirmed(v_r.id) THEN
        CONTINUE;
      END IF;

      IF v_sub.id IS NOT NULL THEN
        v_source := 'pending';
        IF v_r.competition_type = 'cup'
           AND to_regprocedure('public.competition_cup_open_play_totals(smallint,smallint,smallint,smallint)') IS NOT NULL THEN
          SELECT t.home_total, t.away_total
          INTO v_home_total, v_away_total
          FROM public.competition_cup_open_play_totals(
            v_sub.home_goals, v_sub.away_goals, v_sub.et_home_goals, v_sub.et_away_goals
          ) t;
        ELSE
          v_home_total := v_sub.home_goals;
          v_away_total := v_sub.away_goals;
        END IF;

        UPDATE public.competition_result_submissions
        SET status = 'confirmed',
            responded_by_club = CASE
              WHEN v_sub.submitted_by_club = v_r.home_club_short_name THEN v_r.away_club_short_name
              ELSE v_r.home_club_short_name
            END,
            responded_at = now()
        WHERE id = v_sub.id;
      ELSE
        v_source := 'nil_nil';
        v_home_total := 0;
        v_away_total := 0;
        INSERT INTO public.competition_result_submissions (
          fixture_id,
          submitted_by_club,
          home_goals,
          away_goals,
          status,
          responded_by_club,
          submitted_at,
          responded_at,
          player_stats
        )
        VALUES (
          v_r.id,
          v_r.home_club_short_name,
          0,
          0,
          'confirmed',
          v_r.away_club_short_name,
          now(),
          now(),
          '[]'::jsonb
        );
      END IF;

      UPDATE public.competition_fixtures
      SET status = 'played',
          home_goals = v_home_total,
          away_goals = v_away_total,
          cup_pen_winner_club_short_name = CASE
            WHEN v_source = 'pending' THEN v_sub.pen_winner_club_short_name
            ELSE NULL
          END,
          result_auto_closed = true,
          home_stats_edit_used_at = coalesce(home_stats_edit_used_at, now()),
          away_stats_edit_used_at = coalesce(away_stats_edit_used_at, now())
      WHERE id = v_r.id;

      DELETE FROM public.competition_match_player_stats
      WHERE fixture_id = v_r.id;

      IF to_regprocedure('public.club_matchday_squad_for_fixture(text,bigint)') IS NOT NULL THEN
        FOR v_player IN
          SELECT q.club_short_name, q.player_id
          FROM (
            SELECT v_r.home_club_short_name AS club_short_name, sp.player_id
            FROM public.club_matchday_squad_for_fixture(v_r.home_club_short_name, v_r.id) sp
            WHERE sp.slot_kind = 'pitch'
            UNION ALL
            SELECT v_r.away_club_short_name, sp.player_id
            FROM public.club_matchday_squad_for_fixture(v_r.away_club_short_name, v_r.id) sp
            WHERE sp.slot_kind = 'pitch'
          ) q
          WHERE q.player_id IS NOT NULL
            AND btrim(q.player_id) <> ''
        LOOP
          INSERT INTO public.competition_match_player_stats (
            fixture_id, season_id, club_short_name, player_id,
            appeared, started, subbed_on, goals, own_goals, assists, rating,
            is_player_of_match, yellow_card, red_card
          )
          VALUES (
            v_r.id, v_r.season_id, v_player.club_short_name, v_player.player_id,
            true, true, false, 0, 0, 0, 3.0,
            false, false, false
          )
          ON CONFLICT (fixture_id, player_id) DO NOTHING;
        END LOOP;
      END IF;

      FOREACH v_side IN ARRAY ARRAY['home', 'away']
      LOOP
        v_club := CASE
          WHEN v_side = 'home' THEN v_r.home_club_short_name
          ELSE v_r.away_club_short_name
        END;
        IF v_club IS NULL THEN
          CONTINUE;
        END IF;
        IF NOT EXISTS (
          SELECT 1 FROM public."Clubs" c
          WHERE c."ShortName" = v_club
            AND c.owner_id IS NOT NULL
        ) THEN
          CONTINUE;
        END IF;

        IF v_entered IS NOT NULL
           AND upper(btrim(v_club)) = upper(btrim(v_entered)) THEN
          BEGIN
            PERFORM public.owner_inbox_send(
              'match_result_deadline',
              'Result closed — you are not charged',
              format(
                E'The result is now closed %s–%s because your opponent did not confirm.\n'
                || E'You are not charged. Starters are rated 3, with no goals or assists, and the result cannot be edited.',
                v_home_total,
                v_away_total
              ),
              v_club,
              NULL,
              v_r.id,
              NULL, NULL, NULL,
              'matchday.html?fixture=' || v_r.id::text,
              'result_deadline_close_clear:' || v_r.id::text || ':' || v_club,
              v_r.gpsl_month,
              v_r.season_id,
              NULL
            );
          EXCEPTION WHEN OTHERS THEN
            RAISE WARNING 'result deadline close clear inbox %: %', v_r.id, SQLERRM;
          END;
          CONTINUE;
        END IF;

        PERFORM public.competition_apply_club_fine_tariff(
          v_club,
          'match_result_closed',
          v_fine,
          format(
            'Your result was still missing after %sh. Closed %s–%s. Starters rated 3.',
            v_recover,
            v_home_total,
            v_away_total
          ),
          v_r.id,
          v_r.season_id
        );

        BEGIN
          PERFORM public.owner_inbox_send(
            'match_result_deadline',
            'Result closed automatically',
            format(
              E'Another ₿500,000 has been charged to your club. The result is now closed %s–%s.\n'
              || E'Starters are rated 3. No goals, assists, cards, or player of the match were recorded.\n'
              || E'This result cannot be edited.',
              v_home_total,
              v_away_total
            ),
            v_club,
            NULL,
            v_r.id,
            NULL, NULL, NULL,
            'matchday.html?fixture=' || v_r.id::text,
            'result_deadline_close:' || v_r.id::text || ':' || v_club,
            v_r.gpsl_month,
            v_r.season_id,
            NULL
          );
        EXCEPTION WHEN OTHERS THEN
          RAISE WARNING 'result deadline close inbox %: %', v_r.id, SQLERRM;
        END;
      END LOOP;

      IF to_regprocedure('public.competition_settle_fixture_gates(bigint)') IS NOT NULL THEN
        BEGIN
          PERFORM public.competition_settle_fixture_gates(v_r.id);
        EXCEPTION WHEN OTHERS THEN
          RAISE WARNING 'result deadline gates %: %', v_r.id, SQLERRM;
        END;
      END IF;

      IF v_r.competition_type = 'cup'
         AND to_regprocedure('public.competition_cup_on_fixture_played(bigint)') IS NOT NULL THEN
        BEGIN
          PERFORM public.competition_cup_on_fixture_played(v_r.id);
        EXCEPTION WHEN OTHERS THEN
          RAISE WARNING 'result deadline cup %: %', v_r.id, SQLERRM;
        END;
      END IF;

      UPDATE public.fixture_result_deadline
      SET closed_at = now(),
          score_source = v_source
      WHERE fixture_id = v_r.id;

      v_closed := v_closed + 1;
    EXCEPTION WHEN OTHERS THEN
      v_skipped := v_skipped + 1;
      RAISE WARNING 'result deadline fixture %: %', v_r.id, SQLERRM;
    END;
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true,
    'grace_hours', v_grace,
    'recover_hours', v_recover,
    'fine_each', v_fine,
    'reminded', v_reminded,
    'closed', v_closed,
    'skipped', v_skipped
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.match_result_deadline_tick() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.match_result_deadline_tick() TO service_role;

COMMENT ON FUNCTION public.match_result_deadline_tick() IS
  'Result deadline: 72h after the played-month lock, then 24h. Fines only a club that has not entered their side, then closes an open result.';

-- Block a later submit or edit of an auto-closed result.
CREATE OR REPLACE FUNCTION public.trg_result_submission_block_auto_close()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM public.competition_fixtures f
    WHERE f.id = NEW.fixture_id
      AND f.result_auto_closed
  ) THEN
    RAISE EXCEPTION 'This result was closed after the deadline and cannot be changed';
  END IF;
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_result_submission_block_auto_close
  ON public.competition_result_submissions;
CREATE TRIGGER trg_result_submission_block_auto_close
  BEFORE INSERT OR UPDATE ON public.competition_result_submissions
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_result_submission_block_auto_close();

-- One-time stats edit: say why, instead of "already used".
DO $edit$
DECLARE
  v_oid oid;
  v_def text;
  v_old text;
  v_new text;
BEGIN
  v_oid := to_regprocedure('public.competition_match_stats_edit_info(bigint)');
  IF v_oid IS NULL THEN
    RAISE WARNING 'competition_match_stats_edit_info missing — auto-closed results still have the edit flag set';
    RETURN;
  END IF;

  v_def := replace(replace(pg_get_functiondef(v_oid), E'\r\n', E'\n'), E'\r', E'\n');
  IF position('result_auto_closed' IN v_def) > 0 THEN
    RETURN;
  END IF;

  v_old :=
    E'  IF v_f.status IS DISTINCT FROM ''played'' THEN';
  v_new :=
    E'  IF coalesce(v_f.result_auto_closed, false) THEN\n'
    || E'    RETURN jsonb_build_object(\n'
    || E'      ''ok'', true, ''can_edit'', false, ''side'', v_side,\n'
    || E'      ''reason'', ''This result was closed after the deadline. It cannot be edited.'',\n'
    || E'      ''window_month'', v_f.result_posted_gpsl_month,\n'
    || E'      ''edit_used'', true,\n'
    || E'      ''home_goals'', v_f.home_goals,\n'
    || E'      ''away_goals'', v_f.away_goals\n'
    || E'    );\n'
    || E'  END IF;\n\n'
    || v_old;

  IF position(v_old IN v_def) = 0 THEN
    RAISE WARNING 'Could not patch stats edit info — auto-closed results still have the edit flag set';
    RETURN;
  END IF;

  EXECUTE replace(v_def, v_old, v_new);
END
$edit$;

DO $cron$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    RAISE WARNING 'pg_cron not enabled — result deadline will not run on its own';
    RETURN;
  END IF;

  IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'gpsl-result-deadline') THEN
    PERFORM cron.unschedule('gpsl-result-deadline');
  END IF;

  PERFORM cron.schedule(
    'gpsl-result-deadline',
    '*/15 * * * *',
    $q$SELECT public.match_result_deadline_tick();$q$
  );
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING 'Could not schedule result deadline: %', SQLERRM;
END
$cron$;

NOTIFY pgrst, 'reload schema';

SELECT public.match_result_deadline_tick();
