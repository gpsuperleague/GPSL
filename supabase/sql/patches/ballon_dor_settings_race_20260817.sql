-- =============================================================================
-- Ballon d'Or v2 — configurable weights, min 20 apps, trophies, live race
-- Championship players excluded (own Championship Player of the Season).
-- Safe re-run.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Settings (single row)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.competition_ballon_settings (
  id int PRIMARY KEY DEFAULT 1 CHECK (id = 1),
  min_appearances int NOT NULL DEFAULT 20,
  weight_rating numeric NOT NULL DEFAULT 12,
  weight_goals_att_am numeric NOT NULL DEFAULT 10,
  weight_goals_other numeric NOT NULL DEFAULT 4,
  weight_assists_mid_att_fb numeric NOT NULL DEFAULT 7,
  weight_assists_other numeric NOT NULL DEFAULT 2,
  weight_cs_gk_def_dmf numeric NOT NULL DEFAULT 14,
  weight_cs_other numeric NOT NULL DEFAULT 0,
  weight_potm numeric NOT NULL DEFAULT 8,
  weight_apps numeric NOT NULL DEFAULT 0.25,
  trophy_superleague numeric NOT NULL DEFAULT 40,
  trophy_super8 numeric NOT NULL DEFAULT 25,
  trophy_plate numeric NOT NULL DEFAULT 18,
  trophy_shield numeric NOT NULL DEFAULT 18,
  trophy_world_cup numeric NOT NULL DEFAULT 30,
  champ_min_appearances int NOT NULL DEFAULT 20,
  updated_at timestamptz NOT NULL DEFAULT now(),
  updated_by uuid
);

INSERT INTO public.competition_ballon_settings (id)
VALUES (1)
ON CONFLICT (id) DO NOTHING;

ALTER TABLE public.competition_ballon_settings ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS competition_ballon_settings_read ON public.competition_ballon_settings;
CREATE POLICY competition_ballon_settings_read
  ON public.competition_ballon_settings
  FOR SELECT TO authenticated, anon
  USING (true);

COMMENT ON TABLE public.competition_ballon_settings IS
  'Ballon d''Or / Champ POTY scoring weights and eligibility (admin editable).';

CREATE OR REPLACE FUNCTION public.competition_ballon_settings_get()
RETURNS public.competition_ballon_settings
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT s.*
  FROM public.competition_ballon_settings s
  WHERE s.id = 1;
$$;

CREATE OR REPLACE FUNCTION public.admin_ballon_settings_get()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v public.competition_ballon_settings%rowtype;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;
  SELECT * INTO v FROM public.competition_ballon_settings WHERE id = 1;
  RETURN to_jsonb(v);
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_ballon_settings_set(p_settings jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v public.competition_ballon_settings%rowtype;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;
  IF p_settings IS NULL OR jsonb_typeof(p_settings) <> 'object' THEN
    RAISE EXCEPTION 'p_settings must be a JSON object';
  END IF;

  UPDATE public.competition_ballon_settings SET
    min_appearances = greatest(1, coalesce((p_settings->>'min_appearances')::int, min_appearances)),
    weight_rating = coalesce((p_settings->>'weight_rating')::numeric, weight_rating),
    weight_goals_att_am = coalesce((p_settings->>'weight_goals_att_am')::numeric, weight_goals_att_am),
    weight_goals_other = coalesce((p_settings->>'weight_goals_other')::numeric, weight_goals_other),
    weight_assists_mid_att_fb = coalesce((p_settings->>'weight_assists_mid_att_fb')::numeric, weight_assists_mid_att_fb),
    weight_assists_other = coalesce((p_settings->>'weight_assists_other')::numeric, weight_assists_other),
    weight_cs_gk_def_dmf = coalesce((p_settings->>'weight_cs_gk_def_dmf')::numeric, weight_cs_gk_def_dmf),
    weight_cs_other = coalesce((p_settings->>'weight_cs_other')::numeric, weight_cs_other),
    weight_potm = coalesce((p_settings->>'weight_potm')::numeric, weight_potm),
    weight_apps = coalesce((p_settings->>'weight_apps')::numeric, weight_apps),
    trophy_superleague = coalesce((p_settings->>'trophy_superleague')::numeric, trophy_superleague),
    trophy_super8 = coalesce((p_settings->>'trophy_super8')::numeric, trophy_super8),
    trophy_plate = coalesce((p_settings->>'trophy_plate')::numeric, trophy_plate),
    trophy_shield = coalesce((p_settings->>'trophy_shield')::numeric, trophy_shield),
    trophy_world_cup = coalesce((p_settings->>'trophy_world_cup')::numeric, trophy_world_cup),
    champ_min_appearances = greatest(1, coalesce((p_settings->>'champ_min_appearances')::int, champ_min_appearances)),
    updated_at = now(),
    updated_by = auth.uid()
  WHERE id = 1
  RETURNING * INTO v;

  RETURN to_jsonb(v);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_ballon_settings_get() TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.admin_ballon_settings_get() TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_ballon_settings_set(jsonb) TO authenticated;

-- ---------------------------------------------------------------------------
-- Position helpers
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.competition_ballon_is_att_am(p_position text)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT upper(btrim(coalesce(p_position, ''))) IN ('CF', 'SS', 'AMF', 'WG');
$$;

CREATE OR REPLACE FUNCTION public.competition_ballon_is_mid_att_fb(p_position text)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT upper(btrim(coalesce(p_position, ''))) IN (
    'CF', 'SS', 'AMF', 'WG', 'CMF', 'LMF', 'RMF',
    'LB', 'RB', 'LWB', 'RWB'
  );
$$;

CREATE OR REPLACE FUNCTION public.competition_ballon_is_cs_role(p_position text)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT upper(btrim(coalesce(p_position, ''))) IN (
    'GK', 'CB', 'LB', 'RB', 'LWB', 'RWB', 'DMF'
  );
$$;

-- Clean sheets: GK / DEF / DMF (was GK+defender role already; keep explicit)
CREATE OR REPLACE FUNCTION public.competition_player_clean_sheets(
  p_season_id bigint,
  p_player_id text,
  p_club_short_name text DEFAULT NULL,
  p_include_cups boolean DEFAULT true
)
RETURNS int
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT count(*)::int
  FROM public.competition_match_player_stats m
  JOIN public.competition_fixtures f ON f.id = m.fixture_id
  JOIN public."Players" p ON p."Konami_ID"::text = m.player_id
  WHERE m.season_id = p_season_id
    AND m.player_id = btrim(p_player_id)
    AND m.started = true
    AND f.status = 'played'
    AND (
      p_include_cups
      OR f.competition_type = 'league'
    )
    AND (
      p_club_short_name IS NULL
      OR m.club_short_name = btrim(p_club_short_name)
    )
    AND public.competition_ballon_is_cs_role(p."Position")
    AND public.competition_player_conceded_in_fixture(f.id, m.club_short_name) = 0;
$$;

-- ---------------------------------------------------------------------------
-- Trophy bonus (club medals player contributed to + WC nation title)
-- ---------------------------------------------------------------------------
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
AS $function$
DECLARE
  v public.competition_ballon_settings%rowtype;
  v_bonus numeric := 0;
  v_club text := btrim(p_club_short_name);
  v_player text := btrim(p_player_id);
  v_nation text;
BEGIN
  SELECT * INTO v FROM public.competition_ballon_settings WHERE id = 1;
  IF NOT FOUND THEN
    RETURN 0;
  END IF;

  -- Super League title (archived final_position = 1)
  IF EXISTS (
    SELECT 1
    FROM public.competition_club_season_archive a
    WHERE a.season_id = p_season_id
      AND a.club_short_name = v_club
      AND a.division = 'superleague'
      AND a.final_position = 1
  ) THEN
    IF to_regprocedure('public.competition_player_league_appearances(bigint,text,text)') IS NULL
       OR public.competition_player_league_appearances(p_season_id, v_player, v_club) >= 5 THEN
      v_bonus := v_bonus + coalesce(v.trophy_superleague, 0);
    END IF;
  END IF;

  -- Cups: Super8 / Plate / Shield
  IF to_regclass('public.competition_cup_season_winner') IS NOT NULL THEN
    IF EXISTS (
      SELECT 1 FROM public.competition_cup_season_winner w
      WHERE w.season_id = p_season_id
        AND w.winner_club_short_name = v_club
        AND w.cup_code = 'super8'
    ) AND (
      to_regprocedure('public.competition_player_cup_appearances(bigint,text,text,text)') IS NULL
      OR public.competition_player_cup_appearances(p_season_id, v_player, v_club, 'super8') >= 1
    ) THEN
      v_bonus := v_bonus + coalesce(v.trophy_super8, 0);
    END IF;

    IF EXISTS (
      SELECT 1 FROM public.competition_cup_season_winner w
      WHERE w.season_id = p_season_id
        AND w.winner_club_short_name = v_club
        AND w.cup_code = 'plate'
    ) AND (
      to_regprocedure('public.competition_player_cup_appearances(bigint,text,text,text)') IS NULL
      OR public.competition_player_cup_appearances(p_season_id, v_player, v_club, 'plate') >= 1
    ) THEN
      v_bonus := v_bonus + coalesce(v.trophy_plate, 0);
    END IF;

    IF EXISTS (
      SELECT 1 FROM public.competition_cup_season_winner w
      WHERE w.season_id = p_season_id
        AND w.winner_club_short_name = v_club
        AND w.cup_code = 'shield'
    ) AND (
      to_regprocedure('public.competition_player_cup_appearances(bigint,text,text,text)') IS NULL
      OR public.competition_player_cup_appearances(p_season_id, v_player, v_club, 'shield') >= 1
    ) THEN
      v_bonus := v_bonus + coalesce(v.trophy_shield, 0);
    END IF;
  END IF;

  -- World Cup: player's nation won a WC cycle overlapping this GPSL season label year
  SELECT nullif(btrim(p."Nation"), '') INTO v_nation
  FROM public."Players" p
  WHERE p."Konami_ID"::text = v_player
  LIMIT 1;

  IF v_nation IS NOT NULL AND to_regclass('public.international_world_cups') IS NOT NULL THEN
    BEGIN
      IF EXISTS (
        SELECT 1
        FROM public.international_world_cups wc
        WHERE wc.champion_nation IS NOT NULL
          AND upper(btrim(wc.champion_nation)) = upper(v_nation)
      ) THEN
        -- Prefer cycles tied to this GPSL season when a link column exists
        v_bonus := v_bonus + coalesce(v.trophy_world_cup, 0);
      END IF;
    EXCEPTION
      WHEN undefined_column OR undefined_table THEN
        NULL;
    END;
  END IF;

  RETURN round(v_bonus, 2);
EXCEPTION
  WHEN undefined_table OR undefined_column THEN
    RETURN round(v_bonus, 2);
END;
$function$;

-- ---------------------------------------------------------------------------
-- Scoring (reads settings; position-aware)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.competition_player_ballon_points(
  p_appearances int,
  p_goals int,
  p_assists int,
  p_avg_rating numeric,
  p_potm int,
  p_clean_sheets int,
  p_stat_role text,
  p_position text DEFAULT NULL,
  p_trophy_bonus numeric DEFAULT 0
)
RETURNS numeric
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
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
  v_goal_w numeric;
  v_ast_w numeric;
  v_cs_w numeric;
  v_total numeric;
BEGIN
  SELECT * INTO v FROM public.competition_ballon_settings WHERE id = 1;
  IF NOT FOUND THEN
    -- Fallback if settings missing
    RETURN round(
      v_goals * 8 + v_assists * 5 + v_potm * 8 + v_rating * 10 + v_apps * 0.25
        + coalesce(p_trophy_bonus, 0),
      2
    );
  END IF;

  -- Infer position bucket from role when position blank
  IF v_pos = '' THEN
    v_pos := CASE v_role
      WHEN 'goalkeeper' THEN 'GK'
      WHEN 'defender' THEN 'CB'
      WHEN 'midfielder' THEN 'CMF'
      WHEN 'forward' THEN 'CF'
      ELSE ''
    END;
  END IF;

  v_goal_w := CASE
    WHEN public.competition_ballon_is_att_am(v_pos) THEN v.weight_goals_att_am
    ELSE v.weight_goals_other
  END;
  v_ast_w := CASE
    WHEN public.competition_ballon_is_mid_att_fb(v_pos) THEN v.weight_assists_mid_att_fb
    ELSE v.weight_assists_other
  END;
  v_cs_w := CASE
    WHEN public.competition_ballon_is_cs_role(v_pos) THEN v.weight_cs_gk_def_dmf
    ELSE v.weight_cs_other
  END;

  v_total :=
    v_rating * v.weight_rating
    + v_goals * v_goal_w
    + v_assists * v_ast_w
    + v_cs * v_cs_w
    + v_potm * v.weight_potm
    + v_apps * v.weight_apps
    + coalesce(p_trophy_bonus, 0);

  RETURN round(v_total, 2);
END;
$function$;

-- Aggregate helper: include trophy bonus + position
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
AS $function$
DECLARE
  v_apps int;
  v_starts int;
  v_goals int;
  v_assists int;
  v_avg numeric;
  v_potm int;
  v_cs int;
  v_pos text;
  v_role text;
  v_trophy numeric;
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

  SELECT p."Position"
  INTO v_pos
  FROM public."Players" p
  WHERE p."Konami_ID"::text = btrim(p_player_id)
  LIMIT 1;

  v_role := public.competition_player_stat_role(v_pos);
  v_cs := public.competition_player_clean_sheets(
    p_season_id, p_player_id, p_club_short_name, true
  );
  v_trophy := public.competition_player_ballon_trophy_bonus(
    p_season_id, p_player_id, p_club_short_name
  );

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
      v_avg, coalesce(v_potm, 0), coalesce(v_cs, 0), v_role, v_pos, v_trophy
    );
END;
$function$;

-- ---------------------------------------------------------------------------
-- Finalize awards (min apps from settings; SL-only Ballon)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.competition_compute_championship_player_of_season(p_season_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_label text;
  v_winner record;
  v_min int;
BEGIN
  SELECT label INTO v_label FROM public.competition_seasons WHERE id = p_season_id;
  SELECT champ_min_appearances INTO v_min FROM public.competition_ballon_settings WHERE id = 1;
  v_min := coalesce(v_min, 20);

  DELETE FROM public.competition_season_award
  WHERE season_id = p_season_id
    AND award_type = 'championship_player_of_season';

  SELECT
    a.player_id,
    a.club_short_name,
    a.division,
    public.competition_player_selection_score(
      a.stat_role, a.player_position, a.appearances, a.goals, a.assists, a.avg_rating, a.clean_sheets
    ) AS selection_score,
    a.goals, a.assists, a.avg_rating, a.appearances
  INTO v_winner
  FROM public.competition_player_season_archive a
  WHERE a.season_id = p_season_id
    AND a.division IN ('championship_a', 'championship_b')
    AND a.appearances >= v_min
  ORDER BY
    public.competition_player_selection_score(
      a.stat_role, a.player_position, a.appearances, a.goals, a.assists, a.avg_rating, a.clean_sheets
    ) DESC,
    a.goals DESC,
    a.assists DESC
  LIMIT 1;

  IF NOT FOUND OR coalesce(v_winner.selection_score, 0) <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_eligible_player', 'min_appearances', v_min);
  END IF;

  INSERT INTO public.competition_season_award (
    season_id, season_label, award_type, player_id, club_short_name, stat_value, detail
  )
  VALUES (
    p_season_id, v_label, 'championship_player_of_season',
    v_winner.player_id, v_winner.club_short_name, v_winner.selection_score,
    jsonb_build_object(
      'division', v_winner.division,
      'goals', v_winner.goals,
      'assists', v_winner.assists,
      'avg_rating', v_winner.avg_rating,
      'appearances', v_winner.appearances,
      'min_appearances', v_min
    )
  );

  RETURN jsonb_build_object(
    'ok', true,
    'player_id', v_winner.player_id,
    'club_short_name', v_winner.club_short_name,
    'division', v_winner.division,
    'min_appearances', v_min
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.competition_finalize_season_player_awards(
  p_season_id bigint,
  p_season_label text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_ballon record;
  v_boot record;
  v_play record;
  v_potm record;
  v_glove record;
  v_ballon_id text := null;
  v_tots jsonb;
  v_champ jsonb;
  v_min int;
  v_trophy numeric;
BEGIN
  SELECT min_appearances INTO v_min FROM public.competition_ballon_settings WHERE id = 1;
  v_min := coalesce(v_min, 20);

  DELETE FROM public.competition_season_award
  WHERE season_id = p_season_id
    AND award_type IN (
      'ballon_dor',
      'golden_boot',
      'golden_playmaker',
      'golden_glove',
      'season_potm',
      'championship_player_of_season',
      'team_of_season'
    );

  -- Recompute ballon_points on archive with trophy bonuses before picking winner
  UPDATE public.competition_player_season_archive a
  SET ballon_points = public.competition_player_ballon_points(
    a.appearances, a.goals, a.assists, a.avg_rating, a.potm_awards, a.clean_sheets,
    a.stat_role, a.player_position,
    public.competition_player_ballon_trophy_bonus(a.season_id, a.player_id, a.club_short_name)
  )
  WHERE a.season_id = p_season_id;

  SELECT a.*
  INTO v_ballon
  FROM public.competition_player_season_archive a
  WHERE a.season_id = p_season_id
    AND a.division = 'superleague'
    AND a.appearances >= v_min
  ORDER BY a.ballon_points DESC, a.goals DESC, a.assists DESC
  LIMIT 1;

  IF FOUND AND v_ballon.ballon_points > 0 THEN
    v_trophy := public.competition_player_ballon_trophy_bonus(
      p_season_id, v_ballon.player_id, v_ballon.club_short_name
    );
    INSERT INTO public.competition_season_award (
      season_id, season_label, award_type, player_id, club_short_name,
      stat_value, detail
    )
    VALUES (
      p_season_id, p_season_label, 'ballon_dor',
      v_ballon.player_id, v_ballon.club_short_name,
      v_ballon.ballon_points,
      jsonb_build_object(
        'goals', v_ballon.goals,
        'assists', v_ballon.assists,
        'potm', v_ballon.potm_awards,
        'clean_sheets', v_ballon.clean_sheets,
        'avg_rating', v_ballon.avg_rating,
        'stat_role', v_ballon.stat_role,
        'position', v_ballon.player_position,
        'division', v_ballon.division,
        'appearances', v_ballon.appearances,
        'min_appearances', v_min,
        'trophy_bonus', v_trophy
      )
    );
    v_ballon_id := v_ballon.player_id;
  END IF;

  SELECT a.* INTO v_boot
  FROM public.competition_player_season_archive a
  WHERE a.season_id = p_season_id AND a.goals > 0
  ORDER BY a.goals DESC, a.assists DESC LIMIT 1;
  IF FOUND THEN
    INSERT INTO public.competition_season_award (
      season_id, season_label, award_type, player_id, club_short_name, stat_value
    ) VALUES (
      p_season_id, p_season_label, 'golden_boot',
      v_boot.player_id, v_boot.club_short_name, v_boot.goals
    );
  END IF;

  SELECT a.* INTO v_play
  FROM public.competition_player_season_archive a
  WHERE a.season_id = p_season_id AND a.assists > 0
  ORDER BY a.assists DESC, a.goals DESC LIMIT 1;
  IF FOUND THEN
    INSERT INTO public.competition_season_award (
      season_id, season_label, award_type, player_id, club_short_name, stat_value
    ) VALUES (
      p_season_id, p_season_label, 'golden_playmaker',
      v_play.player_id, v_play.club_short_name, v_play.assists
    );
  END IF;

  SELECT a.* INTO v_potm
  FROM public.competition_player_season_archive a
  WHERE a.season_id = p_season_id AND a.potm_awards > 0
  ORDER BY a.potm_awards DESC, a.goals DESC LIMIT 1;
  IF FOUND THEN
    INSERT INTO public.competition_season_award (
      season_id, season_label, award_type, player_id, club_short_name, stat_value
    ) VALUES (
      p_season_id, p_season_label, 'season_potm',
      v_potm.player_id, v_potm.club_short_name, v_potm.potm_awards
    );
  END IF;

  SELECT a.* INTO v_glove
  FROM public.competition_player_season_archive a
  WHERE a.season_id = p_season_id
    AND a.stat_role = 'goalkeeper'
    AND a.clean_sheets > 0
  ORDER BY a.clean_sheets DESC, a.avg_rating DESC NULLS LAST LIMIT 1;
  IF FOUND THEN
    INSERT INTO public.competition_season_award (
      season_id, season_label, award_type, player_id, club_short_name, stat_value
    ) VALUES (
      p_season_id, p_season_label, 'golden_glove',
      v_glove.player_id, v_glove.club_short_name, v_glove.clean_sheets
    );
  END IF;

  v_tots := public.competition_compute_team_of_season(p_season_id);
  v_champ := public.competition_compute_championship_player_of_season(p_season_id);

  RETURN jsonb_build_object(
    'team_of_season', v_tots,
    'championship_player_of_season', v_champ,
    'ballon_dor_player_id', v_ballon_id,
    'ballon_min_appearances', v_min
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_finalize_season_player_awards(bigint, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.competition_compute_championship_player_of_season(bigint) TO authenticated;

-- ---------------------------------------------------------------------------
-- Live race: top N Super League candidates (and Champ POTY race)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.competition_ballon_race_public(
  p_season_id bigint DEFAULT NULL,
  p_limit int DEFAULT 20,
  p_scope text DEFAULT 'ballon'
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
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

  WITH live AS (
    SELECT
      m.player_id,
      p."Name" AS player_name,
      m.club_short_name,
      c."Club" AS club_name,
      ccs.division,
      p."Position" AS player_position,
      public.competition_player_stat_role(p."Position") AS stat_role,
      count(*) FILTER (WHERE m.appeared)::int AS appearances,
      coalesce(sum(m.goals), 0)::int AS goals,
      coalesce(sum(m.assists), 0)::int AS assists,
      round(avg(m.rating) FILTER (WHERE m.rating IS NOT NULL), 2) AS avg_rating,
      count(*) FILTER (WHERE m.is_player_of_match)::int AS potm_awards,
      public.competition_player_clean_sheets(v_season_id, m.player_id, m.club_short_name, true) AS clean_sheets
    FROM public.competition_match_player_stats m
    JOIN public.competition_fixtures f ON f.id = m.fixture_id
    JOIN public."Players" p ON p."Konami_ID"::text = m.player_id
    JOIN public."Clubs" c ON c."ShortName" = m.club_short_name
    JOIN public.competition_club_seasons ccs
      ON ccs.season_id = m.season_id
     AND ccs.club_short_name = m.club_short_name
    WHERE m.season_id = v_season_id
      AND f.status = 'played'
      AND (
        (v_scope = 'championship' AND ccs.division IN ('championship_a', 'championship_b'))
        OR (v_scope <> 'championship' AND ccs.division = 'superleague')
      )
    GROUP BY m.player_id, p."Name", m.club_short_name, c."Club", ccs.division, p."Position"
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
            l.appearances, l.goals, l.assists, l.avg_rating, l.potm_awards, l.clean_sheets,
            l.stat_role, l.player_position,
            public.competition_player_ballon_trophy_bonus(v_season_id, l.player_id, l.club_short_name)
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
$function$;

GRANT EXECUTE ON FUNCTION public.competition_ballon_race_public(bigint, int, text) TO authenticated, anon;

NOTIFY pgrst, 'reload schema';
