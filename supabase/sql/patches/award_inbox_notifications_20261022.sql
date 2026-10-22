-- =============================================================================
-- Award / result inbox notifications
--
--   • Owner of the Month (Super League + Championship)
--   • Manager of the Month
--   • Team of the Month (clubs with a selected player)
--   • Cup final — winner congratulations + runner-up commiserations
--   • Season archive — promotion / relegation / playoff / champion notes
--   • Season archive — dedicated Ballon d'Or / Championship POTY / Golden Boot
--
-- Safe re-run. Depends on owner_inbox_send + award tables.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1) Allow new message types
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

  SELECT string_agg(quote_literal(t), ', ' ORDER BY t)
  INTO v_list
  FROM (
    SELECT DISTINCT message_type AS t
    FROM public.competition_inbox
    WHERE message_type IS NOT NULL
    UNION
    SELECT (regexp_matches(coalesce(v_def, ''), '''([^'']+)''', 'g'))[1]
    UNION SELECT 'owner_of_month'
    UNION SELECT 'manager_of_month'
    UNION SELECT 'team_of_month'
    UNION SELECT 'cup_final_result'
    UNION SELECT 'league_movement'
    UNION SELECT 'season_player_award'
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
-- 2) Helpers
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.owner_inbox_gpsl_month_label(p_month text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $function$
  SELECT CASE lower(nullif(btrim(coalesce(p_month, '')), ''))
    WHEN 'august' THEN 'August'
    WHEN 'september' THEN 'September'
    WHEN 'october' THEN 'October'
    WHEN 'november' THEN 'November'
    WHEN 'december' THEN 'December'
    WHEN 'january' THEN 'January'
    WHEN 'february' THEN 'February'
    WHEN 'march' THEN 'March'
    WHEN 'april' THEN 'April'
    WHEN 'may' THEN 'May'
    WHEN 'june' THEN 'June'
    WHEN 'july' THEN 'July'
    WHEN 'playoffs' THEN 'Playoffs'
    ELSE initcap(coalesce(p_month, 'Month'))
  END;
$function$;

CREATE OR REPLACE FUNCTION public.owner_inbox_notify_owner_of_month(p_award_id bigint)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  a public.competition_owner_month_award%ROWTYPE;
  v_club_name text;
  v_scope text;
  v_month text;
  v_id bigint;
BEGIN
  IF to_regprocedure(
    'public.owner_inbox_send(text,text,text,text,uuid,bigint,bigint,bigint,bigint,text,text,text,bigint)'
  ) IS NULL THEN
    RETURN NULL;
  END IF;

  SELECT * INTO a FROM public.competition_owner_month_award WHERE id = p_award_id;
  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  SELECT c."Club" INTO v_club_name
  FROM public."Clubs" c
  WHERE c."ShortName" = a.club_short_name;

  v_scope := CASE a.division_scope
    WHEN 'championship' THEN 'Championship'
    ELSE 'Super League'
  END;
  v_month := public.owner_inbox_gpsl_month_label(a.gpsl_month);

  v_id := public.owner_inbox_send(
    'owner_of_month',
    format('Owner of the Month — %s %s', v_scope, v_month),
    format(
      E'Congratulations %s!\n\nYou are %s Owner of the Month for %s (%s) with %s.\nRecord: %s–%s–%s · %s pts · GD %s (%s–%s).\n\nSee League → Owner of the Month for the full board.',
      coalesce(a.owner_tag, 'Owner'),
      v_scope,
      v_month,
      coalesce(a.season_label, 'this season'),
      coalesce(v_club_name, a.club_short_name),
      a.won, a.drawn, a.lost, a.pts,
      (a.gf - a.ga), a.gf, a.ga
    ),
    a.club_short_name,
    a.owner_id,
    NULL, NULL, NULL, NULL,
    'owner_of_the_month.html',
    format('ootm:%s:%s:%s', a.season_id, a.gpsl_month, a.division_scope),
    a.gpsl_month,
    a.season_id
  );
  RETURN v_id;
END;
$function$;

CREATE OR REPLACE FUNCTION public.owner_inbox_notify_manager_of_month(p_award_id bigint)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  a public.competition_manager_month_award%ROWTYPE;
  v_club_name text;
  v_month text;
  v_id bigint;
BEGIN
  IF to_regprocedure(
    'public.owner_inbox_send(text,text,text,text,uuid,bigint,bigint,bigint,bigint,text,text,text,bigint)'
  ) IS NULL THEN
    RETURN NULL;
  END IF;

  SELECT * INTO a FROM public.competition_manager_month_award WHERE id = p_award_id;
  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  SELECT c."Club" INTO v_club_name
  FROM public."Clubs" c
  WHERE c."ShortName" = a.club_short_name;

  v_month := public.owner_inbox_gpsl_month_label(a.gpsl_month);

  v_id := public.owner_inbox_send(
    'manager_of_month',
    format('Manager of the Month — %s', v_month),
    format(
      E'Your manager %s is Manager of the Month for %s (%s) with %s.\nRecord: %s–%s–%s · %s pts.\n\nView their career page for the award cabinet.',
      coalesce(a.manager_name, 'Manager'),
      v_month,
      coalesce(a.season_label, 'this season'),
      coalesce(v_club_name, a.club_short_name),
      a.won, a.drawn, a.lost, a.pts
    ),
    a.club_short_name,
    NULL,
    NULL, NULL, NULL, NULL,
    format('manager_career.html?id=%s', a.manager_id),
    format('motm:%s:%s', a.season_id, a.gpsl_month),
    a.gpsl_month,
    a.season_id
  );
  RETURN v_id;
END;
$function$;

CREATE OR REPLACE FUNCTION public.owner_inbox_notify_team_of_month(p_team_id bigint)
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  t public.competition_period_team%ROWTYPE;
  v_club text;
  v_names text;
  v_scope text;
  v_month text;
  v_count int := 0;
BEGIN
  IF to_regprocedure(
    'public.owner_inbox_send(text,text,text,text,uuid,bigint,bigint,bigint,bigint,text,text,text,bigint)'
  ) IS NULL THEN
    RETURN 0;
  END IF;

  SELECT * INTO t FROM public.competition_period_team WHERE id = p_team_id;
  IF NOT FOUND OR t.period_kind IS DISTINCT FROM 'month' THEN
    RETURN 0;
  END IF;

  v_scope := CASE t.division_scope
    WHEN 'championship' THEN 'Championship'
    ELSE 'Super League'
  END;
  v_month := public.owner_inbox_gpsl_month_label(t.gpsl_month);

  FOR v_club, v_names IN
    SELECT
      m.club_short_name,
      string_agg(coalesce(p."Name", m.player_id), ', ' ORDER BY coalesce(p."Name", m.player_id))
    FROM public.competition_period_team_member m
    LEFT JOIN public."Players" p ON p."Konami_ID"::text = m.player_id
    WHERE m.team_id = p_team_id
      AND nullif(btrim(m.club_short_name), '') IS NOT NULL
    GROUP BY m.club_short_name
  LOOP
    IF public.owner_inbox_send(
      'team_of_month',
      format('Team of the Month — %s %s', v_scope, v_month),
      format(
        E'Your club contributed to the %s Team of the Month for %s (%s):\n%s\n\nSee League → Stats for the full XI.',
        v_scope,
        v_month,
        coalesce(t.season_label, 'this season'),
        v_names
      ),
      v_club,
      NULL,
      NULL, NULL, NULL, NULL,
      'league_stats.html',
      format('totm:%s:%s:%s:%s', t.season_id, t.gpsl_month, t.division_scope, v_club),
      t.gpsl_month,
      t.season_id
    ) IS NOT NULL THEN
      v_count := v_count + 1;
    END IF;
  END LOOP;

  RETURN v_count;
END;
$function$;

CREATE OR REPLACE FUNCTION public.owner_inbox_notify_cup_final(p_fixture_id bigint)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  f public.competition_fixtures%ROWTYPE;
  v_max_round int;
  v_stage text;
  v_winner text;
  v_loser text;
  v_cup_label text;
  v_score text;
  v_winner_name text;
  v_loser_name text;
BEGIN
  IF to_regprocedure(
    'public.owner_inbox_send(text,text,text,text,uuid,bigint,bigint,bigint,bigint,text,text,text,bigint)'
  ) IS NULL THEN
    RETURN;
  END IF;

  SELECT * INTO f
  FROM public.competition_fixtures
  WHERE id = p_fixture_id
    AND competition_type = 'cup'
    AND status = 'played';

  IF NOT FOUND THEN
    RETURN;
  END IF;

  SELECT max(round_no) INTO v_max_round
  FROM public.competition_cup_bracket_nodes
  WHERE season_id = f.season_id AND cup_code = f.cup_code;

  IF to_regprocedure('public.competition_cup_round_stage(text,integer,integer)') IS NOT NULL THEN
    v_stage := public.competition_cup_round_stage(
      f.cup_code,
      f.cup_round,
      coalesce(v_max_round, f.cup_round)
    );
  ELSE
    v_stage := CASE WHEN f.cup_round = coalesce(v_max_round, f.cup_round) THEN 'final' ELSE 'other' END;
  END IF;

  IF v_stage IS DISTINCT FROM 'final' THEN
    RETURN;
  END IF;

  IF coalesce(btrim(f.cup_pen_winner_club_short_name), '') <> '' THEN
    v_winner := btrim(f.cup_pen_winner_club_short_name);
  ELSIF f.home_goals > f.away_goals THEN
    v_winner := f.home_club_short_name;
  ELSIF f.away_goals > f.home_goals THEN
    v_winner := f.away_club_short_name;
  ELSE
    RETURN;
  END IF;

  IF v_winner = f.home_club_short_name THEN
    v_loser := f.away_club_short_name;
  ELSE
    v_loser := f.home_club_short_name;
  END IF;

  v_cup_label := CASE lower(coalesce(f.cup_code, ''))
    WHEN 'super8' THEN 'Super8'
    WHEN 'plate' THEN 'Plate'
    WHEN 'shield' THEN 'Shield'
    WHEN 'bowl' THEN 'Bowl'
    WHEN 'league_cup' THEN 'League Cup'
    ELSE initcap(replace(coalesce(f.cup_code, 'Cup'), '_', ' '))
  END;

  v_score := format('%s–%s', coalesce(f.home_goals, 0), coalesce(f.away_goals, 0));
  IF coalesce(btrim(f.cup_pen_winner_club_short_name), '') <> '' THEN
    v_score := v_score || ' (pens)';
  END IF;

  SELECT c."Club" INTO v_winner_name FROM public."Clubs" c WHERE c."ShortName" = v_winner;
  SELECT c."Club" INTO v_loser_name FROM public."Clubs" c WHERE c."ShortName" = v_loser;

  PERFORM public.owner_inbox_send(
    'cup_final_result',
    format('Champions — %s', v_cup_label),
    format(
      E'Congratulations!\n\n%s are %s champions (%s vs %s).\n\nSee Cups for the bracket and prize money in Club Finances.',
      coalesce(v_winner_name, v_winner),
      v_cup_label,
      v_score,
      coalesce(v_loser_name, v_loser)
    ),
    v_winner,
    NULL,
    p_fixture_id, NULL, NULL, NULL,
    'cups.html?cup=' || coalesce(f.cup_code, ''),
    format('cup_final_win:%s', p_fixture_id),
    f.gpsl_month,
    f.season_id
  );

  PERFORM public.owner_inbox_send(
    'cup_final_result',
    format('Runner-up — %s', v_cup_label),
    format(
      E'Commiserations.\n\n%s finished runners-up in the %s (%s vs %s).\n\nA strong cup run — prize money (if configured) is in Club Finances.',
      coalesce(v_loser_name, v_loser),
      v_cup_label,
      v_score,
      coalesce(v_winner_name, v_winner)
    ),
    v_loser,
    NULL,
    p_fixture_id, NULL, NULL, NULL,
    'cups.html?cup=' || coalesce(f.cup_code, ''),
    format('cup_final_ru:%s', p_fixture_id),
    f.gpsl_month,
    f.season_id
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.owner_inbox_league_movement_note(
  p_division text,
  p_position int
)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $function$
  SELECT CASE
    WHEN p_position IS NULL OR p_position < 1 THEN NULL
    WHEN p_division = 'superleague' AND p_position = 1 THEN 'champion'
    WHEN p_division = 'superleague' AND p_position = 2 THEN 'runner_up'
    WHEN p_division = 'superleague' AND p_position BETWEEN 16 AND 17 THEN 'sl_playoff'
    WHEN p_division = 'superleague' AND p_position >= 18 THEN 'relegation'
    WHEN p_division IN ('championship_a', 'championship_b') AND p_position = 1 THEN 'champion'
    WHEN p_division IN ('championship_a', 'championship_b') AND p_position = 2 THEN 'promotion'
    WHEN p_division IN ('championship_a', 'championship_b') AND p_position BETWEEN 3 AND 6 THEN 'playoffs'
    ELSE NULL
  END;
$function$;

-- ---------------------------------------------------------------------------
-- 3) Triggers — monthly personal awards
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.trg_owner_month_award_inbox()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  BEGIN
    PERFORM public.owner_inbox_notify_owner_of_month(NEW.id);
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS owner_month_award_inbox ON public.competition_owner_month_award;
CREATE TRIGGER owner_month_award_inbox
  AFTER INSERT OR UPDATE OF owner_id, club_short_name, pts ON public.competition_owner_month_award
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_owner_month_award_inbox();

CREATE OR REPLACE FUNCTION public.trg_manager_month_award_inbox()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  BEGIN
    PERFORM public.owner_inbox_notify_manager_of_month(NEW.id);
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS manager_month_award_inbox ON public.competition_manager_month_award;
CREATE TRIGGER manager_month_award_inbox
  AFTER INSERT OR UPDATE OF manager_id, club_short_name, pts ON public.competition_manager_month_award
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_manager_month_award_inbox();

CREATE OR REPLACE FUNCTION public.trg_period_team_month_inbox()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF NEW.period_kind IS DISTINCT FROM 'month' THEN
    RETURN NEW;
  END IF;
  BEGIN
    -- Members inserted after the team row; defer slightly via statement-level style:
    -- call after members exist by using a deferred notify from member insert instead.
    NULL;
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;
  RETURN NEW;
END;
$function$;

-- Notify once members are present (last member insert for a team is awkward);
-- call from a statement trigger after members: notify on each member insert with dedupe per club.
CREATE OR REPLACE FUNCTION public.trg_period_team_member_totm_inbox()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_kind text;
BEGIN
  SELECT period_kind INTO v_kind
  FROM public.competition_period_team
  WHERE id = NEW.team_id;

  IF v_kind IS DISTINCT FROM 'month' THEN
    RETURN NEW;
  END IF;

  BEGIN
    PERFORM public.owner_inbox_notify_team_of_month(NEW.team_id);
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS period_team_member_totm_inbox ON public.competition_period_team_member;
CREATE TRIGGER period_team_member_totm_inbox
  AFTER INSERT ON public.competition_period_team_member
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_period_team_member_totm_inbox();

-- ---------------------------------------------------------------------------
-- 4) Cup final — fire when a cup tie is marked played
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.trg_cup_fixture_final_inbox()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF NEW.competition_type IS DISTINCT FROM 'cup' THEN
    RETURN NEW;
  END IF;
  IF NEW.status IS DISTINCT FROM 'played' THEN
    RETURN NEW;
  END IF;
  IF TG_OP = 'UPDATE'
     AND OLD.status = 'played'
     AND OLD.home_goals IS NOT DISTINCT FROM NEW.home_goals
     AND OLD.away_goals IS NOT DISTINCT FROM NEW.away_goals
     AND OLD.cup_pen_winner_club_short_name IS NOT DISTINCT FROM NEW.cup_pen_winner_club_short_name
  THEN
    RETURN NEW;
  END IF;

  BEGIN
    PERFORM public.owner_inbox_notify_cup_final(NEW.id);
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS cup_fixture_final_inbox ON public.competition_fixtures;
CREATE TRIGGER cup_fixture_final_inbox
  AFTER INSERT OR UPDATE OF status, home_goals, away_goals, cup_pen_winner_club_short_name
  ON public.competition_fixtures
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_cup_fixture_final_inbox();

-- ---------------------------------------------------------------------------
-- 5) Season archive — movement + major player awards
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.owner_inbox_notify_club_season_archive(
  p_season_id bigint,
  p_season_label text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club record;
  v_award record;
  v_mgr public."Managers"%ROWTYPE;
  v_star text;
  v_award_lines text[] := ARRAY[]::text[];
  v_overview text;
  v_move text;
  v_move_title text;
  v_move_body text;
  v_div_label text;
  v_award_title text;
  v_player_name text;
BEGIN
  IF to_regprocedure(
    'public.owner_inbox_send(text,text,text,text,uuid,bigint,bigint,bigint,bigint,text,text,text,bigint)'
  ) IS NULL THEN
    RETURN;
  END IF;

  FOR v_club IN
    SELECT
      a.club_short_name,
      a.division,
      a.final_position,
      a.pts,
      a.won AS w,
      a.drawn AS d,
      a.lost AS l,
      c."Club" AS club_name
    FROM public.competition_club_season_archive a
    JOIN public."Clubs" c ON c."ShortName" = a.club_short_name
    WHERE a.season_id = p_season_id
      AND EXISTS (
        SELECT 1
        FROM public."Clubs" cx
        WHERE cx."ShortName" = a.club_short_name
          AND cx.owner_id IS NOT NULL
      )
  LOOP
    v_award_lines := ARRAY[]::text[];

    FOR v_award IN
      SELECT aw.award_type, aw.stat_value, aw.detail, p."Name" AS player_name
      FROM public.competition_season_award aw
      LEFT JOIN public."Players" p ON p."Konami_ID"::text = aw.player_id
      WHERE aw.season_id = p_season_id
        AND aw.club_short_name = v_club.club_short_name
        AND aw.gpsl_month IS NULL
      ORDER BY aw.award_type
    LOOP
      v_award_lines := array_append(
        v_award_lines,
        format(
          '%s: %s (%s)',
          replace(v_award.award_type, '_', ' '),
          v_award.player_name,
          v_award.stat_value
        )
      );

      -- Dedicated major awards
      IF v_award.award_type IN ('ballon_dor', 'championship_player_of_season', 'golden_boot') THEN
        v_award_title := CASE v_award.award_type
          WHEN 'ballon_dor' THEN 'Ballon d''Or winner'
          WHEN 'championship_player_of_season' THEN 'Championship Player of the Season'
          WHEN 'golden_boot' THEN 'Golden Boot'
          ELSE replace(v_award.award_type, '_', ' ')
        END;
        v_player_name := coalesce(v_award.player_name, 'Your player');
        PERFORM public.owner_inbox_send(
          'season_player_award',
          format('%s — %s', v_award_title, p_season_label),
          format(
            E'Congratulations!\n\n%s won the %s for %s while at %s.\n\nSee Club History and League Stats for the full awards list.',
            v_player_name,
            v_award_title,
            p_season_label,
            coalesce(v_club.club_name, v_club.club_short_name)
          ),
          v_club.club_short_name,
          NULL,
          NULL, NULL, NULL, NULL,
          'history.html',
          format('season_player_award:%s:%s:%s', p_season_id, v_club.club_short_name, v_award.award_type),
          NULL,
          p_season_id
        );
      END IF;
    END LOOP;

    IF coalesce(array_length(v_award_lines, 1), 0) > 0 THEN
      PERFORM public.owner_inbox_send(
        'player_awards',
        format('Season awards — %s', p_season_label),
        array_to_string(v_award_lines, E'\n'),
        v_club.club_short_name,
        NULL,
        NULL, NULL, NULL, NULL,
        'history.html',
        format('awards:%s:%s', p_season_id, v_club.club_short_name),
        NULL,
        p_season_id
      );
    END IF;

    -- Promotion / relegation / playoff / title notes
    v_move := public.owner_inbox_league_movement_note(
      v_club.division,
      v_club.final_position
    );
    v_div_label := CASE v_club.division
      WHEN 'superleague' THEN 'Super League'
      WHEN 'championship_a' THEN 'Championship A'
      WHEN 'championship_b' THEN 'Championship B'
      ELSE coalesce(v_club.division, 'the league')
    END;

    IF v_move IS NOT NULL THEN
      v_move_title := CASE v_move
        WHEN 'champion' THEN format('Champions — %s', v_div_label)
        WHEN 'runner_up' THEN format('League runners-up — %s', v_div_label)
        WHEN 'promotion' THEN 'Promotion'
        WHEN 'playoffs' THEN 'Promotion playoffs'
        WHEN 'sl_playoff' THEN 'Super League relegation playoff'
        WHEN 'relegation' THEN 'Relegation'
        ELSE 'Season finish'
      END;
      v_move_body := CASE v_move
        WHEN 'champion' THEN format(
          E'Congratulations!\n\n%s finished 1st in %s (%s pts, %sW-%sD-%sL) for %s.',
          coalesce(v_club.club_name, v_club.club_short_name),
          v_div_label, v_club.pts, v_club.w, v_club.d, v_club.l, p_season_label
        )
        WHEN 'runner_up' THEN format(
          E'Silverware nearly — %s finished 2nd in %s (%s pts) for %s.',
          coalesce(v_club.club_name, v_club.club_short_name),
          v_div_label, v_club.pts, p_season_label
        )
        WHEN 'promotion' THEN format(
          E'Congratulations!\n\n%s finished 2nd in %s and earn promotion for %s.',
          coalesce(v_club.club_name, v_club.club_short_name),
          v_div_label, p_season_label
        )
        WHEN 'playoffs' THEN format(
          E'%s finished %s in %s and qualify for the promotion playoffs (%s).',
          coalesce(v_club.club_name, v_club.club_short_name),
          v_club.final_position, v_div_label, p_season_label
        )
        WHEN 'sl_playoff' THEN format(
          E'%s finished %s in the Super League and enter the relegation playoff (%s).',
          coalesce(v_club.club_name, v_club.club_short_name),
          v_club.final_position, p_season_label
        )
        WHEN 'relegation' THEN format(
          E'Commiserations.\n\n%s finished %s in the Super League and are relegated (%s).',
          coalesce(v_club.club_name, v_club.club_short_name),
          v_club.final_position, p_season_label
        )
        ELSE NULL
      END;

      IF v_move_body IS NOT NULL THEN
        PERFORM public.owner_inbox_send(
          'league_movement',
          v_move_title,
          v_move_body || E'\n\nSee Tables and Club History for the full season.',
          v_club.club_short_name,
          NULL,
          NULL, NULL, NULL, NULL,
          'progress.html',
          format('league_movement:%s:%s', p_season_id, v_club.club_short_name),
          NULL,
          p_season_id
        );
      END IF;
    END IF;

    SELECT * INTO v_mgr
    FROM public."Managers" m
    WHERE m.contracted_club = v_club.club_short_name
    LIMIT 1;

    SELECT p."Name" INTO v_star
    FROM public.competition_player_season_archive ps
    JOIN public."Players" p ON p."Konami_ID"::text = ps.player_id
    WHERE ps.season_id = p_season_id
      AND ps.club_short_name = v_club.club_short_name
    ORDER BY ps.ballon_points DESC, ps.goals DESC
    LIMIT 1;

    v_overview := concat_ws(
      E'\n',
      format(
        'Final league position: %s in %s (%s pts, %sW-%sD-%sL)',
        v_club.final_position,
        v_club.division,
        v_club.pts,
        v_club.w,
        v_club.d,
        v_club.l
      ),
      CASE
        WHEN v_mgr.id IS NOT NULL THEN
          format(
            'Manager: %s — %s season(s) on contract',
            v_mgr.name,
            v_mgr.contract_seasons_remaining
          )
        ELSE 'Manager: none signed'
      END,
      CASE WHEN v_star IS NOT NULL THEN 'Star player: ' || v_star ELSE NULL END,
      'See Club History and Owner Rankings for the full season breakdown.'
    );

    PERFORM public.owner_inbox_send(
      'season_overview',
      format('Season overview — %s', p_season_label),
      v_overview,
      v_club.club_short_name,
      NULL,
      NULL, NULL, NULL, NULL,
      'history.html',
      format('season_overview:%s:%s', p_season_id, v_club.club_short_name),
      NULL,
      p_season_id
    );
  END LOOP;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.owner_inbox_notify_owner_of_month(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.owner_inbox_notify_manager_of_month(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.owner_inbox_notify_team_of_month(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.owner_inbox_notify_cup_final(bigint) TO authenticated;

NOTIFY pgrst, 'reload schema';
