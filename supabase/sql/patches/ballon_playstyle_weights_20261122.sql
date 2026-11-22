-- Ballon d'Or: playstyle weights, goal contributions, podium places,
-- and a league-points multiplier (club points / 100).
-- Championship Player of the Season is unchanged.

CREATE OR REPLACE FUNCTION public.competition_ballon_default_playstyle_weights()
RETURNS jsonb
LANGUAGE sql
IMMUTABLE
AS $gpsl$
  SELECT jsonb_build_object(
    'goal_poacher', jsonb_build_object('rating', 5, 'contributions', 5, 'clean_sheet', 1, 'potm', 2.5),
    'fox_in_the_box', jsonb_build_object('rating', 5.14, 'contributions', 5.81, 'clean_sheet', 1.16, 'potm', 3.13),
    'deep_lying_forward', jsonb_build_object('rating', 5.22, 'contributions', 5.56, 'clean_sheet', 1.11, 'potm', 2.88),
    'target_man', jsonb_build_object('rating', 5.29, 'contributions', 5.81, 'clean_sheet', 1.16, 'potm', 4.17),
    'dummy_runner', jsonb_build_object('rating', 5.37, 'contributions', 6.10, 'clean_sheet', 1.22, 'potm', 3.41),
    'hole_player', jsonb_build_object('rating', 5.14, 'contributions', 5.56, 'clean_sheet', 1.11, 'potm', 2.68),
    'creative_playmaker', jsonb_build_object('rating', 5.22, 'contributions', 5.81, 'clean_sheet', 1.16, 'potm', 2.88),
    'classic_10', jsonb_build_object('rating', 5.37, 'contributions', 6.76, 'clean_sheet', 1.35, 'potm', 4.17),
    'prolific_winger', jsonb_build_object('rating', 5.07, 'contributions', 5.21, 'clean_sheet', 1.04, 'potm', 2.68),
    'roaming_flank', jsonb_build_object('rating', 5.22, 'contributions', 5.56, 'clean_sheet', 1.11, 'potm', 3.13),
    'cross_specialist', jsonb_build_object('rating', 5.37, 'contributions', 6.25, 'clean_sheet', 1.25, 'potm', 4.17),
    'box_to_box', jsonb_build_object('rating', 5.54, 'contributions', 9.26, 'clean_sheet', 1.85, 'potm', 6.25),
    'orchestrator', jsonb_build_object('rating', 5.71, 'contributions', 11.36, 'clean_sheet', 2.27, 'potm', 9.38),
    'anchor_man', jsonb_build_object('rating', 5.9, 'contributions', 25, 'clean_sheet', 5, 'potm', 18.75),
    'destroyer', jsonb_build_object('rating', 6, 'contributions', 25, 'clean_sheet', 5, 'potm', 12.5),
    'offensive_full_back', jsonb_build_object('rating', 5.71, 'contributions', 11.36, 'clean_sheet', 2.27, 'potm', 7.5),
    'full_back_finisher', jsonb_build_object('rating', 5.63, 'contributions', 11.9, 'clean_sheet', 2.38, 'potm', 6.25),
    'defensive_full_back', jsonb_build_object('rating', 6.1, 'contributions', 31.25, 'clean_sheet', 6.25, 'potm', 18.75),
    'build_up', jsonb_build_object('rating', 6.21, 'contributions', 50, 'clean_sheet', 10, 'potm', 37.5),
    'extra_frontman', jsonb_build_object('rating', 5.9, 'contributions', 25, 'clean_sheet', 5, 'potm', 12.5),
    'goalkeeper', jsonb_build_object('rating', 5.81, 'contributions', 100, 'clean_sheet', 20, 'potm', 18.75)
  );
$gpsl$;

ALTER TABLE public.competition_ballon_settings
  ADD COLUMN IF NOT EXISTS playstyle_weights jsonb,
  ADD COLUMN IF NOT EXISTS trophy_superleague_runner_up numeric NOT NULL DEFAULT 125,
  ADD COLUMN IF NOT EXISTS trophy_superleague_third numeric NOT NULL DEFAULT 62.5,
  ADD COLUMN IF NOT EXISTS trophy_world_cup_runner_up numeric NOT NULL DEFAULT 125,
  ADD COLUMN IF NOT EXISTS trophy_world_cup_third numeric NOT NULL DEFAULT 62.5,
  ADD COLUMN IF NOT EXISTS trophy_super8_runner_up numeric NOT NULL DEFAULT 75,
  ADD COLUMN IF NOT EXISTS trophy_league_cup_runner_up numeric NOT NULL DEFAULT 50,
  ADD COLUMN IF NOT EXISTS trophy_plate_runner_up numeric NOT NULL DEFAULT 37.5,
  ADD COLUMN IF NOT EXISTS trophy_shield_runner_up numeric NOT NULL DEFAULT 25,
  ADD COLUMN IF NOT EXISTS trophy_bowl numeric NOT NULL DEFAULT 25,
  ADD COLUMN IF NOT EXISTS trophy_bowl_runner_up numeric NOT NULL DEFAULT 12.5,
  ADD COLUMN IF NOT EXISTS trophy_premier_challenge numeric NOT NULL DEFAULT 60,
  ADD COLUMN IF NOT EXISTS trophy_premier_challenge_runner_up numeric NOT NULL DEFAULT 25;

UPDATE public.competition_ballon_settings
SET playstyle_weights = public.competition_ballon_default_playstyle_weights()
WHERE id = 1
  AND playstyle_weights IS NULL;

ALTER TABLE public.competition_ballon_settings
  ALTER COLUMN playstyle_weights SET DEFAULT public.competition_ballon_default_playstyle_weights(),
  ALTER COLUMN playstyle_weights SET NOT NULL;

DO $cup$
DECLARE
  r record;
BEGIN
  FOR r IN
    SELECT conname
    FROM pg_constraint
    WHERE conrelid = 'public.competition_cup_season_winner'::regclass
      AND contype = 'c'
      AND pg_get_constraintdef(oid) ILIKE '%cup_code%'
  LOOP
    EXECUTE format('ALTER TABLE public.competition_cup_season_winner DROP CONSTRAINT %I', r.conname);
  END LOOP;
END;
$cup$;

ALTER TABLE public.competition_cup_season_winner
  ADD CONSTRAINT competition_cup_season_winner_cup_code_check
  CHECK (cup_code = ANY (ARRAY[
    'super8', 'plate', 'shield', 'bowl', 'league_cup', 'premier_challenge'
  ]::text[]));

CREATE OR REPLACE FUNCTION public.competition_ballon_playstyle_key(
  p_playstyle text,
  p_position text
)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $gpsl$
  SELECT CASE regexp_replace(lower(btrim(coalesce(p_playstyle, ''))), '[^a-z0-9]+', '', 'g')
    WHEN 'goalpoacher' THEN 'goal_poacher'
    WHEN 'foxinthebox' THEN 'fox_in_the_box'
    WHEN 'deeplyingforward' THEN 'deep_lying_forward'
    WHEN 'targetman' THEN 'target_man'
    WHEN 'dummyrunner' THEN 'dummy_runner'
    WHEN 'holeplayer' THEN 'hole_player'
    WHEN 'creativeplaymaker' THEN 'creative_playmaker'
    WHEN 'classicno10' THEN 'classic_10'
    WHEN 'classic10' THEN 'classic_10'
    WHEN 'prolificwinger' THEN 'prolific_winger'
    WHEN 'roamingflank' THEN 'roaming_flank'
    WHEN 'crossspecialist' THEN 'cross_specialist'
    WHEN 'boxtobox' THEN 'box_to_box'
    WHEN 'orchestrator' THEN 'orchestrator'
    WHEN 'anchorman' THEN 'anchor_man'
    WHEN 'thedestroyer' THEN 'destroyer'
    WHEN 'destroyer' THEN 'destroyer'
    WHEN 'offensivefullback' THEN 'offensive_full_back'
    WHEN 'fullbackfinisher' THEN 'full_back_finisher'
    WHEN 'defensivefullback' THEN 'defensive_full_back'
    WHEN 'buildup' THEN 'build_up'
    WHEN 'extrafrontman' THEN 'extra_frontman'
    WHEN 'offensivegoalkeeper' THEN 'goalkeeper'
    WHEN 'defensivegoalkeeper' THEN 'goalkeeper'
    WHEN 'goalkeeper' THEN 'goalkeeper'
    ELSE CASE public.competition_player_stat_role(p_position)
      WHEN 'goalkeeper' THEN 'goalkeeper'
      WHEN 'defender' THEN 'build_up'
      WHEN 'forward' THEN 'goal_poacher'
      ELSE 'box_to_box'
    END
  END;
$gpsl$;

CREATE OR REPLACE FUNCTION public.competition_club_league_points(
  p_season_id bigint,
  p_club_short_name text
)
RETURNS numeric
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $gpsl$
  SELECT coalesce(
    (
      SELECT a.pts::numeric
      FROM public.competition_club_season_archive a
      WHERE a.season_id = p_season_id
        AND a.club_short_name = btrim(p_club_short_name)
        AND a.division = 'superleague'
      LIMIT 1
    ),
    (
      SELECT s.pts::numeric
      FROM public.competition_standings_public s
      WHERE s.season_id = p_season_id
        AND s.club_short_name = btrim(p_club_short_name)
        AND s.division = 'superleague'
      LIMIT 1
    ),
    0
  );
$gpsl$;

CREATE OR REPLACE FUNCTION public.competition_player_ballon_clean_sheets(
  p_season_id bigint,
  p_player_id text,
  p_club_short_name text DEFAULT NULL
)
RETURNS int
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $gpsl$
  SELECT count(*)::int
  FROM public.competition_match_player_stats m
  JOIN public.competition_fixtures f ON f.id = m.fixture_id
  WHERE m.season_id = p_season_id
    AND m.player_id = btrim(p_player_id)
    AND m.started = true
    AND f.status = 'played'
    AND (
      p_club_short_name IS NULL
      OR m.club_short_name = btrim(p_club_short_name)
    )
    AND public.competition_player_conceded_in_fixture(f.id, m.club_short_name) = 0;
$gpsl$;

CREATE OR REPLACE FUNCTION public.competition_player_ballon_points(
  p_appearances integer,
  p_goals integer,
  p_assists integer,
  p_avg_rating numeric,
  p_potm integer,
  p_clean_sheets integer,
  p_stat_role text,
  p_position text DEFAULT NULL,
  p_trophy_bonus numeric DEFAULT 0,
  p_playstyle text DEFAULT NULL,
  p_league_points numeric DEFAULT NULL
)
RETURNS numeric
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $gpsl$
DECLARE
  v public.competition_ballon_settings%rowtype;
  v_pos text := upper(btrim(coalesce(p_position, '')));
  v_role text := coalesce(p_stat_role, 'outfield');
  v_apps numeric := greatest(coalesce(p_appearances, 0), 0);
  v_goals numeric := greatest(coalesce(p_goals, 0), 0);
  v_assists numeric := greatest(coalesce(p_assists, 0), 0);
  v_rating numeric := coalesce(p_avg_rating, 0);
  v_potm numeric := greatest(coalesce(p_potm, 0), 0);
  v_cs numeric := greatest(coalesce(p_clean_sheets, 0), 0);
  v_key text;
  v_w jsonb;
  v_total numeric;
  v_mult numeric;
BEGIN
  SELECT * INTO v FROM public.competition_ballon_settings WHERE id = 1;
  IF NOT FOUND THEN
    RETURN 0;
  END IF;

  IF v_pos = '' THEN
    v_pos := CASE v_role
      WHEN 'goalkeeper' THEN 'GK'
      WHEN 'defender' THEN 'CB'
      WHEN 'midfielder' THEN 'CMF'
      WHEN 'forward' THEN 'CF'
      ELSE ''
    END;
  END IF;

  v_key := public.competition_ballon_playstyle_key(p_playstyle, v_pos);
  v_w := coalesce(v.playstyle_weights, public.competition_ballon_default_playstyle_weights()) -> v_key;
  IF v_w IS NULL THEN
    v_w := public.competition_ballon_default_playstyle_weights() -> v_key;
  END IF;

  v_total :=
    v_rating * coalesce((v_w->>'rating')::numeric, 0)
    + (v_goals + v_assists) * coalesce((v_w->>'contributions')::numeric, 0)
    + v_cs * coalesce((v_w->>'clean_sheet')::numeric, 0)
    + v_potm * coalesce((v_w->>'potm')::numeric, 0)
    + v_apps * coalesce(v.weight_apps, 0)
    + coalesce(p_trophy_bonus, 0);

  IF p_league_points IS NULL THEN
    v_mult := 1;
  ELSE
    v_mult := greatest(p_league_points, 0) / 100;
  END IF;

  RETURN round(v_total * v_mult, 2);
END;
$gpsl$;

CREATE OR REPLACE FUNCTION public.competition_player_ballon_trophy_bonus(
  p_season_id bigint,
  p_player_id text,
  p_club_short_name text
)
RETURNS numeric
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $gpsl$
DECLARE
  v public.competition_ballon_settings%rowtype;
  v_bonus numeric := 0;
  v_club text := btrim(p_club_short_name);
  v_player text := btrim(p_player_id);
  v_nation text;
  v_pos int;
  v_league_apps int := 0;
  v_cup record;
  v_winner text;
  v_runner text;
  v_cup_apps int;
BEGIN
  SELECT * INTO v FROM public.competition_ballon_settings WHERE id = 1;
  IF NOT FOUND THEN
    RETURN 0;
  END IF;

  IF to_regprocedure('public.competition_player_league_appearances(bigint,text,text)') IS NOT NULL THEN
    v_league_apps := public.competition_player_league_appearances(p_season_id, v_player, v_club);
  ELSE
    v_league_apps := 5;
  END IF;

  SELECT a.final_position
  INTO v_pos
  FROM public.competition_club_season_archive a
  WHERE a.season_id = p_season_id
    AND a.club_short_name = v_club
    AND a.division = 'superleague'
  LIMIT 1;

  IF v_league_apps >= 5 AND v_pos IS NOT NULL THEN
    IF v_pos = 1 THEN
      v_bonus := v_bonus + coalesce(v.trophy_superleague, 0);
    ELSIF v_pos = 2 THEN
      v_bonus := v_bonus + coalesce(v.trophy_superleague_runner_up, 0);
    ELSIF v_pos = 3 THEN
      v_bonus := v_bonus + coalesce(v.trophy_superleague_third, 0);
    END IF;
  END IF;

  IF to_regclass('public.competition_cup_season_winner') IS NOT NULL THEN
    FOR v_cup IN
      SELECT *
      FROM (
        VALUES
          ('super8', coalesce(v.trophy_super8, 0), coalesce(v.trophy_super8_runner_up, 0)),
          ('plate', coalesce(v.trophy_plate, 0), coalesce(v.trophy_plate_runner_up, 0)),
          ('shield', coalesce(v.trophy_shield, 0), coalesce(v.trophy_shield_runner_up, 0)),
          ('league_cup', coalesce(v.trophy_league_cup, 0), coalesce(v.trophy_league_cup_runner_up, 0)),
          ('bowl', coalesce(v.trophy_bowl, 0), coalesce(v.trophy_bowl_runner_up, 0)),
          ('premier_challenge', coalesce(v.trophy_premier_challenge, 0), coalesce(v.trophy_premier_challenge_runner_up, 0))
      ) AS t(code, win_pts, run_pts)
    LOOP
      SELECT w.winner_club_short_name, w.runner_up_club_short_name
      INTO v_winner, v_runner
      FROM public.competition_cup_season_winner w
      WHERE w.season_id = p_season_id
        AND w.cup_code = v_cup.code
      LIMIT 1;

      IF v_winner IS NULL AND v_runner IS NULL THEN
        CONTINUE;
      END IF;

      v_cup_apps := 1;
      IF to_regprocedure('public.competition_player_cup_appearances(bigint,text,text,text)') IS NOT NULL THEN
        v_cup_apps := public.competition_player_cup_appearances(p_season_id, v_player, v_club, v_cup.code);
      END IF;
      IF coalesce(v_cup_apps, 0) < 1 THEN
        CONTINUE;
      END IF;

      IF v_winner = v_club THEN
        v_bonus := v_bonus + v_cup.win_pts;
      END IF;
      IF v_runner = v_club THEN
        v_bonus := v_bonus + v_cup.run_pts;
      END IF;
    END LOOP;
  END IF;

  SELECT nullif(btrim(p."Nation"), '')
  INTO v_nation
  FROM public."Players" p
  WHERE p."Konami_ID"::text = v_player
  LIMIT 1;

  IF v_nation IS NOT NULL AND to_regclass('public.international_wc_cycles') IS NOT NULL THEN
    IF EXISTS (
      SELECT 1
      FROM public.international_wc_cycles wc
      LEFT JOIN public.international_nations n ON n.code = wc.champion_nation
      WHERE wc.finals_after_season_id = p_season_id
        AND wc.champion_nation IS NOT NULL
        AND (
          upper(btrim(wc.champion_nation)) = upper(v_nation)
          OR upper(btrim(coalesce(n.name, ''))) = upper(v_nation)
        )
    ) THEN
      v_bonus := v_bonus + coalesce(v.trophy_world_cup, 0);
    END IF;

    IF EXISTS (
      SELECT 1
      FROM public.international_wc_cycles wc
      LEFT JOIN public.international_nations n ON n.code = wc.runner_up_nation
      WHERE wc.finals_after_season_id = p_season_id
        AND wc.runner_up_nation IS NOT NULL
        AND (
          upper(btrim(wc.runner_up_nation)) = upper(v_nation)
          OR upper(btrim(coalesce(n.name, ''))) = upper(v_nation)
        )
    ) THEN
      v_bonus := v_bonus + coalesce(v.trophy_world_cup_runner_up, 0);
    END IF;

    IF EXISTS (
      SELECT 1
      FROM public.international_wc_cycles wc
      LEFT JOIN public.international_nations n ON n.code = wc.third_place_nation
      WHERE wc.finals_after_season_id = p_season_id
        AND wc.third_place_nation IS NOT NULL
        AND (
          upper(btrim(wc.third_place_nation)) = upper(v_nation)
          OR upper(btrim(coalesce(n.name, ''))) = upper(v_nation)
        )
    ) THEN
      v_bonus := v_bonus + coalesce(v.trophy_world_cup_third, 0);
    END IF;
  END IF;

  RETURN round(v_bonus, 2);
END;
$gpsl$;

CREATE OR REPLACE FUNCTION public.admin_ballon_settings_set(p_settings jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $gpsl$
DECLARE
  v public.competition_ballon_settings%rowtype;
  v_weights jsonb;
  v_key text;
  v_row jsonb;
  v_prev jsonb;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;
  IF p_settings IS NULL OR jsonb_typeof(p_settings) <> 'object' THEN
    RAISE EXCEPTION 'p_settings must be a JSON object';
  END IF;

  SELECT coalesce(playstyle_weights, public.competition_ballon_default_playstyle_weights())
  INTO v_weights
  FROM public.competition_ballon_settings
  WHERE id = 1;

  IF p_settings ? 'playstyle_weights'
     AND jsonb_typeof(p_settings->'playstyle_weights') = 'object' THEN
    FOR v_key IN
      SELECT jsonb_object_keys(p_settings->'playstyle_weights')
    LOOP
      v_row := p_settings->'playstyle_weights'->v_key;
      v_prev := coalesce(v_weights->v_key, '{}'::jsonb);
      IF jsonb_typeof(v_row) = 'object' THEN
        v_weights := jsonb_set(
          v_weights,
          ARRAY[v_key],
          jsonb_build_object(
            'rating', coalesce((v_row->>'rating')::numeric, (v_prev->>'rating')::numeric, 0),
            'contributions', coalesce((v_row->>'contributions')::numeric, (v_prev->>'contributions')::numeric, 0),
            'clean_sheet', coalesce((v_row->>'clean_sheet')::numeric, (v_prev->>'clean_sheet')::numeric, 0),
            'potm', coalesce((v_row->>'potm')::numeric, (v_prev->>'potm')::numeric, 0)
          ),
          true
        );
      END IF;
    END LOOP;
  END IF;

  UPDATE public.competition_ballon_settings SET
    min_appearances = greatest(1, coalesce((p_settings->>'min_appearances')::int, min_appearances)),
    champ_min_appearances = greatest(1, coalesce((p_settings->>'champ_min_appearances')::int, champ_min_appearances)),
    weight_apps = coalesce((p_settings->>'weight_apps')::numeric, weight_apps),
    playstyle_weights = v_weights,
    trophy_superleague = coalesce((p_settings->>'trophy_superleague')::numeric, trophy_superleague),
    trophy_superleague_runner_up = coalesce((p_settings->>'trophy_superleague_runner_up')::numeric, trophy_superleague_runner_up),
    trophy_superleague_third = coalesce((p_settings->>'trophy_superleague_third')::numeric, trophy_superleague_third),
    trophy_super8 = coalesce((p_settings->>'trophy_super8')::numeric, trophy_super8),
    trophy_super8_runner_up = coalesce((p_settings->>'trophy_super8_runner_up')::numeric, trophy_super8_runner_up),
    trophy_plate = coalesce((p_settings->>'trophy_plate')::numeric, trophy_plate),
    trophy_plate_runner_up = coalesce((p_settings->>'trophy_plate_runner_up')::numeric, trophy_plate_runner_up),
    trophy_shield = coalesce((p_settings->>'trophy_shield')::numeric, trophy_shield),
    trophy_shield_runner_up = coalesce((p_settings->>'trophy_shield_runner_up')::numeric, trophy_shield_runner_up),
    trophy_league_cup = coalesce((p_settings->>'trophy_league_cup')::numeric, trophy_league_cup),
    trophy_league_cup_runner_up = coalesce((p_settings->>'trophy_league_cup_runner_up')::numeric, trophy_league_cup_runner_up),
    trophy_bowl = coalesce((p_settings->>'trophy_bowl')::numeric, trophy_bowl),
    trophy_bowl_runner_up = coalesce((p_settings->>'trophy_bowl_runner_up')::numeric, trophy_bowl_runner_up),
    trophy_premier_challenge = coalesce((p_settings->>'trophy_premier_challenge')::numeric, trophy_premier_challenge),
    trophy_premier_challenge_runner_up = coalesce((p_settings->>'trophy_premier_challenge_runner_up')::numeric, trophy_premier_challenge_runner_up),
    trophy_world_cup = coalesce((p_settings->>'trophy_world_cup')::numeric, trophy_world_cup),
    trophy_world_cup_runner_up = coalesce((p_settings->>'trophy_world_cup_runner_up')::numeric, trophy_world_cup_runner_up),
    trophy_world_cup_third = coalesce((p_settings->>'trophy_world_cup_third')::numeric, trophy_world_cup_third),
    updated_at = now(),
    updated_by = auth.uid()
  WHERE id = 1
  RETURNING * INTO v;

  RETURN to_jsonb(v);
END;
$gpsl$;

CREATE OR REPLACE FUNCTION public.competition_aggregate_player_season_row(
  p_season_id bigint,
  p_player_id text,
  p_club_short_name text
)
RETURNS TABLE (
  appearances int,
  starts int,
  goals int,
  assists int,
  avg_rating numeric,
  potm_awards int,
  clean_sheets int,
  player_position text,
  stat_role text,
  ballon_points numeric
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $gpsl$
DECLARE
  v_apps int;
  v_starts int;
  v_goals int;
  v_assists int;
  v_avg numeric;
  v_potm int;
  v_cs int;
  v_pos text;
  v_style text;
  v_role text;
  v_trophy numeric;
  v_pts numeric;
BEGIN
  SELECT
    count(*) FILTER (WHERE m.appeared)::int,
    count(*) FILTER (WHERE m.started)::int,
    coalesce(sum(m.goals), 0)::int,
    coalesce(sum(m.assists), 0)::int,
    round(avg(m.rating) FILTER (WHERE m.rating IS NOT NULL), 2),
    count(*) FILTER (WHERE m.is_player_of_match)::int
  INTO v_apps, v_starts, v_goals, v_assists, v_avg, v_potm
  FROM public.competition_match_player_stats m
  JOIN public.competition_fixtures f ON f.id = m.fixture_id
  WHERE m.season_id = p_season_id
    AND m.player_id = btrim(p_player_id)
    AND m.club_short_name = btrim(p_club_short_name)
    AND f.status = 'played';

  SELECT p."Position", p."Playstyle"
  INTO v_pos, v_style
  FROM public."Players" p
  WHERE p."Konami_ID"::text = btrim(p_player_id)
  LIMIT 1;

  v_role := public.competition_player_stat_role(v_pos);
  v_cs := public.competition_player_ballon_clean_sheets(
    p_season_id, p_player_id, p_club_short_name
  );
  v_trophy := public.competition_player_ballon_trophy_bonus(
    p_season_id, p_player_id, p_club_short_name
  );
  v_pts := public.competition_club_league_points(p_season_id, p_club_short_name);

  RETURN QUERY
  SELECT
    coalesce(v_apps, 0),
    coalesce(v_starts, 0),
    coalesce(v_goals, 0),
    coalesce(v_assists, 0),
    v_avg,
    coalesce(v_potm, 0),
    coalesce(v_cs, 0),
    v_pos,
    v_role,
    public.competition_player_ballon_points(
      coalesce(v_apps, 0), coalesce(v_goals, 0), coalesce(v_assists, 0),
      v_avg, coalesce(v_potm, 0), coalesce(v_cs, 0), v_role, v_pos, v_trophy,
      v_style, v_pts
    );
END;
$gpsl$;

CREATE OR REPLACE FUNCTION public.competition_ballon_race_public(
  p_season_id bigint DEFAULT NULL,
  p_limit integer DEFAULT 20,
  p_scope text DEFAULT 'ballon'
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $gpsl$
DECLARE
  v_season_id bigint;
  v_label text;
  v_min int;
  v_scope text := lower(btrim(coalesce(p_scope, 'ballon')));
  v_rows jsonb := '[]'::jsonb;
BEGIN
  IF p_season_id IS NULL THEN
    SELECT s.id, s.label INTO v_season_id, v_label
    FROM public.competition_seasons s
    WHERE s.status = 'active'
    ORDER BY s.id DESC
    LIMIT 1;
  ELSE
    SELECT s.id, s.label INTO v_season_id, v_label
    FROM public.competition_seasons s
    WHERE s.id = p_season_id;
  END IF;

  IF v_season_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'No season', 'rows', '[]'::jsonb);
  END IF;

  IF v_scope = 'championship' THEN
    SELECT champ_min_appearances INTO v_min FROM public.competition_ballon_settings WHERE id = 1;
  ELSE
    SELECT min_appearances INTO v_min FROM public.competition_ballon_settings WHERE id = 1;
  END IF;
  v_min := coalesce(v_min, 20);

  WITH ballon_cs AS (
    SELECT
      m.player_id,
      m.club_short_name,
      count(*)::int AS clean_sheets
    FROM public.competition_match_player_stats m
    JOIN public.competition_fixtures f ON f.id = m.fixture_id
    WHERE m.season_id = v_season_id
      AND m.started = true
      AND f.status = 'played'
      AND public.competition_player_conceded_in_fixture(f.id, m.club_short_name) = 0
    GROUP BY m.player_id, m.club_short_name
  ),
  club_pts AS (
    SELECT a.club_short_name, a.pts::numeric AS pts
    FROM public.competition_club_season_archive a
    WHERE a.season_id = v_season_id
      AND a.division = 'superleague'
    UNION ALL
    SELECT s.club_short_name, s.pts::numeric
    FROM public.competition_standings_public s
    WHERE s.season_id = v_season_id
      AND s.division = 'superleague'
      AND NOT EXISTS (
        SELECT 1
        FROM public.competition_club_season_archive a
        WHERE a.season_id = v_season_id
          AND a.division = 'superleague'
          AND a.club_short_name = s.club_short_name
      )
  ),
  live AS (
    SELECT
      m.player_id,
      p."Name" AS player_name,
      m.club_short_name,
      c."Club" AS club_name,
      ccs.division,
      p."Position" AS player_position,
      p."Playstyle" AS playstyle,
      public.competition_player_stat_role(p."Position") AS stat_role,
      count(*) FILTER (WHERE m.appeared)::int AS appearances,
      coalesce(sum(m.goals), 0)::int AS goals,
      coalesce(sum(m.assists), 0)::int AS assists,
      round(avg(m.rating) FILTER (WHERE m.rating IS NOT NULL), 2) AS avg_rating,
      count(*) FILTER (WHERE m.is_player_of_match)::int AS potm_awards,
      public.competition_player_clean_sheets(v_season_id, m.player_id, m.club_short_name, true) AS clean_sheets,
      coalesce(bcs.clean_sheets, 0) AS ballon_clean_sheets,
      coalesce(cp.pts, 0) AS league_points
    FROM public.competition_match_player_stats m
    JOIN public.competition_fixtures f ON f.id = m.fixture_id
    JOIN public."Players" p ON p."Konami_ID"::text = m.player_id
    JOIN public."Clubs" c ON c."ShortName" = m.club_short_name
    JOIN public.competition_club_seasons ccs
      ON ccs.season_id = m.season_id
     AND ccs.club_short_name = m.club_short_name
    LEFT JOIN ballon_cs bcs
      ON bcs.player_id = m.player_id
     AND bcs.club_short_name = m.club_short_name
    LEFT JOIN club_pts cp
      ON cp.club_short_name = m.club_short_name
    WHERE m.season_id = v_season_id
      AND f.status = 'played'
      AND (
        (v_scope = 'championship' AND ccs.division IN ('championship_a', 'championship_b'))
        OR (v_scope <> 'championship' AND ccs.division = 'superleague')
      )
    GROUP BY
      m.player_id, p."Name", m.club_short_name, c."Club", ccs.division,
      p."Position", p."Playstyle", bcs.clean_sheets, cp.pts
  ),
  scored AS (
    SELECT
      l.*,
      public.competition_player_ballon_trophy_bonus(v_season_id, l.player_id, l.club_short_name) AS trophy_bonus,
      CASE
        WHEN v_scope = 'championship' THEN
          public.competition_player_selection_score(
            l.stat_role, l.player_position, l.appearances, l.goals, l.assists, l.avg_rating, l.clean_sheets
          )
        ELSE
          public.competition_player_ballon_points(
            l.appearances, l.goals, l.assists, l.avg_rating, l.potm_awards, l.ballon_clean_sheets,
            l.stat_role, l.player_position,
            public.competition_player_ballon_trophy_bonus(v_season_id, l.player_id, l.club_short_name),
            l.playstyle,
            l.league_points
          )
      END AS score
    FROM live l
    WHERE l.appearances >= v_min
  )
  SELECT coalesce(jsonb_agg(to_jsonb(s) ORDER BY s.score DESC, s.goals DESC, s.assists DESC), '[]'::jsonb)
  INTO v_rows
  FROM (
    SELECT *
    FROM scored
    ORDER BY score DESC, goals DESC, assists DESC
    LIMIT greatest(1, least(coalesce(p_limit, 20), 50))
  ) s;

  RETURN jsonb_build_object(
    'ok', true,
    'season_id', v_season_id,
    'season_label', v_label,
    'scope', CASE WHEN v_scope = 'championship' THEN 'championship' ELSE 'ballon' END,
    'min_appearances', v_min,
    'rows', v_rows
  );
END;
$gpsl$;

DO $patch$
DECLARE
  v_def text;
  v_old text;
  v_new text;
BEGIN
  v_def := replace(
    pg_get_functiondef('public.competition_admin_archive_season(bigint)'::regprocedure),
    E'\r\n', E'\n'
  );
  v_def := replace(v_def, '$function$', '$gpsl$');

  v_old := replace($old$      AND public.competition_player_stat_role(p."Position") IN ('goalkeeper', 'defender')
$old$, E'\r\n', E'\n');
  IF position(v_old IN v_def) = 0 THEN
    RAISE EXCEPTION 'archive clean-sheet role filter missing';
  END IF;
  v_def := replace(v_def, v_old, '');

  v_old := replace($old$      public.competition_player_ballon_points(
        b.appearances,
        b.goals,
        b.assists,
        b.avg_rating,
        b.potm_awards,
        coalesce(c.clean_sheets, 0),
        public.competition_player_stat_role(p."Position")
      ) AS ballon_points$old$, E'\r\n', E'\n');
  v_new := replace($new$      public.competition_player_ballon_points(
        b.appearances,
        b.goals,
        b.assists,
        b.avg_rating,
        b.potm_awards,
        coalesce(c.clean_sheets, 0),
        public.competition_player_stat_role(p."Position"),
        p."Position",
        public.competition_player_ballon_trophy_bonus(v_season.id, b.player_id, b.club_short_name),
        p."Playstyle",
        public.competition_club_league_points(v_season.id, b.club_short_name)
      ) AS ballon_points$new$, E'\r\n', E'\n');
  IF position(v_old IN v_def) = 0 THEN
    RAISE EXCEPTION 'archive ballon call missing';
  END IF;
  EXECUTE replace(v_def, v_old, v_new);

  v_def := replace(
    pg_get_functiondef('public.competition_finalize_season_player_awards(bigint, text)'::regprocedure),
    E'\r\n', E'\n'
  );
  v_def := replace(v_def, '$function$', '$gpsl$');
  v_old := replace($old$  SET ballon_points = public.competition_player_ballon_points(
    a.appearances, a.goals, a.assists, a.avg_rating, a.potm_awards, a.clean_sheets,
    a.stat_role, a.player_position,
    public.competition_player_ballon_trophy_bonus(a.season_id, a.player_id, a.club_short_name)
  )$old$, E'\r\n', E'\n');
  v_new := replace($new$  SET ballon_points = public.competition_player_ballon_points(
    a.appearances, a.goals, a.assists, a.avg_rating, a.potm_awards,
    public.competition_player_ballon_clean_sheets(a.season_id, a.player_id, a.club_short_name),
    a.stat_role, a.player_position,
    public.competition_player_ballon_trophy_bonus(a.season_id, a.player_id, a.club_short_name),
    (SELECT pl."Playstyle" FROM public."Players" pl WHERE pl."Konami_ID"::text = a.player_id LIMIT 1),
    public.competition_club_league_points(a.season_id, a.club_short_name)
  )$new$, E'\r\n', E'\n');
  IF position(v_old IN v_def) = 0 THEN
    RAISE EXCEPTION 'finalize ballon call missing';
  END IF;
  EXECUTE replace(v_def, v_old, v_new);
END;
$patch$;

CREATE OR REPLACE VIEW public.competition_player_career_public AS
 SELECT a.season_id,
    a.season_label,
    a.player_id,
    p."Name" AS player_name,
    a.club_short_name,
    c."Club" AS club_name,
    a.division,
    a.player_position,
    a.stat_role,
    a.appearances,
    a.starts,
    a.goals,
    a.assists,
    a.avg_rating,
    a.potm_awards,
    a.clean_sheets,
    a.ballon_points,
    false AS is_live,
    a.archived_at AS as_of
   FROM public.competition_player_season_archive a
     JOIN public."Players" p ON p."Konami_ID" = a.player_id
     JOIN public."Clubs" c ON c."ShortName" = a.club_short_name
UNION ALL
 SELECT m.season_id,
    s.label AS season_label,
    m.player_id,
    p."Name" AS player_name,
    m.club_short_name,
    c."Club" AS club_name,
    COALESCE(ccs.division, ca.division) AS division,
    p."Position" AS player_position,
    public.competition_player_stat_role(p."Position") AS stat_role,
    count(*) FILTER (WHERE m.appeared)::integer AS appearances,
    count(*) FILTER (WHERE m.started)::integer AS starts,
    COALESCE(sum(m.goals), 0::bigint)::integer AS goals,
    COALESCE(sum(m.assists), 0::bigint)::integer AS assists,
    round(avg(m.rating) FILTER (WHERE m.rating IS NOT NULL), 2) AS avg_rating,
    count(*) FILTER (WHERE m.is_player_of_match)::integer AS potm_awards,
    public.competition_player_clean_sheets(m.season_id, m.player_id, m.club_short_name, true) AS clean_sheets,
    public.competition_player_ballon_points(
      count(*) FILTER (WHERE m.appeared)::integer,
      COALESCE(sum(m.goals), 0::bigint)::integer,
      COALESCE(sum(m.assists), 0::bigint)::integer,
      round(avg(m.rating) FILTER (WHERE m.rating IS NOT NULL), 2),
      count(*) FILTER (WHERE m.is_player_of_match)::integer,
      public.competition_player_ballon_clean_sheets(m.season_id, m.player_id, m.club_short_name),
      public.competition_player_stat_role(p."Position"),
      p."Position",
      public.competition_player_ballon_trophy_bonus(m.season_id, m.player_id, m.club_short_name),
      p."Playstyle",
      public.competition_club_league_points(m.season_id, m.club_short_name)
    ) AS ballon_points,
    true AS is_live,
    now() AS as_of
   FROM public.competition_match_player_stats m
     JOIN public.competition_fixtures f ON f.id = m.fixture_id
     JOIN public.competition_seasons s ON s.id = m.season_id
     JOIN public."Players" p ON p."Konami_ID" = m.player_id
     JOIN public."Clubs" c ON c."ShortName" = m.club_short_name
     LEFT JOIN public.competition_club_seasons ccs ON ccs.season_id = m.season_id AND ccs.club_short_name = m.club_short_name
     LEFT JOIN public.competition_club_season_archive ca ON ca.season_id = m.season_id AND ca.club_short_name = m.club_short_name
  WHERE f.status = 'played'::text
    AND public.competition_fixture_counts_in_tables(f.id)
    AND NOT (EXISTS ( SELECT 1
           FROM public.competition_player_season_archive ar
          WHERE ar.season_id = m.season_id AND ar.player_id = m.player_id AND ar.club_short_name = m.club_short_name))
  GROUP BY m.season_id, s.label, m.player_id, p."Name", m.club_short_name, c."Club", ccs.division, ca.division, p."Position", p."Playstyle";

DROP FUNCTION IF EXISTS public.competition_player_ballon_points(integer, integer, integer, numeric, integer, integer, text, text, numeric);

GRANT EXECUTE ON FUNCTION public.competition_ballon_playstyle_key(text, text) TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.competition_club_league_points(bigint, text) TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.competition_player_ballon_clean_sheets(bigint, text, text) TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.competition_player_ballon_points(integer, integer, integer, numeric, integer, integer, text, text, numeric, text, numeric) TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.competition_player_ballon_trophy_bonus(bigint, text, text) TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.admin_ballon_settings_set(jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.competition_aggregate_player_season_row(bigint, text, text) TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.competition_ballon_race_public(bigint, integer, text) TO authenticated, anon;

NOTIFY pgrst, 'reload schema';

SELECT jsonb_build_object(
  'goal_poacher', public.competition_player_ballon_points(20, 10, 5, 7.5, 2, 3, 'forward', 'CF', 40, 'Goal Poacher', 80),
  'none_cb', public.competition_player_ballon_points(20, 10, 5, 7.5, 2, 3, 'defender', 'CB', 0, 'None', 100),
  'destroyer', public.competition_ballon_playstyle_key('The Destroyer', 'DMF'),
  'gk', public.competition_ballon_playstyle_key('Offensive Goalkeeper', 'GK'),
  'wg_none', public.competition_ballon_playstyle_key('None', 'WG'),
  'fwd_none', public.competition_ballon_playstyle_key('None', 'CF'),
  'def_none', public.competition_ballon_playstyle_key('None', 'CB'),
  'archive_patched', position(
    'p."Playstyle"' IN pg_get_functiondef('public.competition_admin_archive_season(bigint)'::regprocedure)
  ) > 0,
  'finalize_patched', position(
    'competition_player_ballon_clean_sheets' IN pg_get_functiondef('public.competition_finalize_season_player_awards(bigint, text)'::regprocedure)
  ) > 0,
  'bowl', (SELECT trophy_bowl FROM public.competition_ballon_settings WHERE id = 1),
  'sl_runner', (SELECT trophy_superleague_runner_up FROM public.competition_ballon_settings WHERE id = 1)
);
