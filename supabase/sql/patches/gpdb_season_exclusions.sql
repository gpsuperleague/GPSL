-- =============================================================================
-- Season exclusions — players & nations (Season Break / GPDB hygiene)
--
-- Admin-curated list for the current (or chosen) competition season:
--   - Excluded players: hidden from GPDB browse; cannot be signed / drafted /
--     called up to a national team
--   - Excluded nations: cannot be claimed in nation selection; players of that
--     nationality treated as excluded for call-up / GPDB (via nation match)
--
-- Typical use: remove warring nations, or individuals for serious misconduct.
--
-- Run once in Supabase SQL Editor. Safe re-run.
-- After editing exclusions: re-run nation pool refresh + apply selectable
-- (admin_international) so seed/selectable stay in sync.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.gpdb_season_excluded_players (
  season_id bigint NOT NULL REFERENCES public.competition_seasons (id) ON DELETE CASCADE,
  player_id text NOT NULL,
  reason text,
  excluded_at timestamptz NOT NULL DEFAULT now(),
  excluded_by uuid REFERENCES auth.users (id),
  PRIMARY KEY (season_id, player_id)
);

CREATE INDEX IF NOT EXISTS gpdb_season_excluded_players_player_idx
  ON public.gpdb_season_excluded_players (player_id);

CREATE TABLE IF NOT EXISTS public.gpdb_season_excluded_nations (
  season_id bigint NOT NULL REFERENCES public.competition_seasons (id) ON DELETE CASCADE,
  nation_code text NOT NULL REFERENCES public.international_nations (code) ON DELETE CASCADE,
  reason text,
  excluded_at timestamptz NOT NULL DEFAULT now(),
  excluded_by uuid REFERENCES auth.users (id),
  PRIMARY KEY (season_id, nation_code)
);

COMMENT ON TABLE public.gpdb_season_excluded_players IS
  'Season Break: players removed from GPDB / transfers / call-ups for a season.';
COMMENT ON TABLE public.gpdb_season_excluded_nations IS
  'Season Break: nations removed from selection / GPDB nationality pool for a season.';

ALTER TABLE public.gpdb_season_excluded_players ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.gpdb_season_excluded_nations ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS gpdb_excl_players_select ON public.gpdb_season_excluded_players;
CREATE POLICY gpdb_excl_players_select ON public.gpdb_season_excluded_players
  FOR SELECT TO authenticated USING (true);

DROP POLICY IF EXISTS gpdb_excl_players_admin ON public.gpdb_season_excluded_players;
CREATE POLICY gpdb_excl_players_admin ON public.gpdb_season_excluded_players
  FOR ALL TO authenticated
  USING (public.is_gpsl_admin())
  WITH CHECK (public.is_gpsl_admin());

DROP POLICY IF EXISTS gpdb_excl_nations_select ON public.gpdb_season_excluded_nations;
CREATE POLICY gpdb_excl_nations_select ON public.gpdb_season_excluded_nations
  FOR SELECT TO authenticated USING (true);

DROP POLICY IF EXISTS gpdb_excl_nations_admin ON public.gpdb_season_excluded_nations;
CREATE POLICY gpdb_excl_nations_admin ON public.gpdb_season_excluded_nations
  FOR ALL TO authenticated
  USING (public.is_gpsl_admin())
  WITH CHECK (public.is_gpsl_admin());

GRANT SELECT ON public.gpdb_season_excluded_players TO authenticated;
GRANT SELECT ON public.gpdb_season_excluded_nations TO authenticated;

-- ---------------------------------------------------------------------------
-- Season resolution (current / active / latest)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.gpdb_exclusion_season_id(p_season_id bigint DEFAULT NULL)
RETURNS bigint
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT coalesce(
    p_season_id,
    (SELECT id FROM public.competition_seasons WHERE is_current = true ORDER BY id DESC LIMIT 1),
    (SELECT id FROM public.competition_seasons WHERE status IN ('active', 'preseason', 'summer_break', 'setup')
     ORDER BY id DESC LIMIT 1),
    (SELECT id FROM public.competition_seasons ORDER BY id DESC LIMIT 1)
  );
$$;

-- ---------------------------------------------------------------------------
-- Eligibility helpers
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.gpdb_player_is_season_excluded(
  p_player_id text,
  p_season_id bigint DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_pid text := btrim(p_player_id);
BEGIN
  IF v_pid IS NULL OR v_pid = '' THEN
    RETURN false;
  END IF;

  IF p_season_id IS NOT NULL THEN
    IF EXISTS (
      SELECT 1
      FROM public.gpdb_season_excluded_players ep
      WHERE ep.season_id = p_season_id
        AND ep.player_id = v_pid
    ) THEN
      RETURN true;
    END IF;

    IF EXISTS (
      SELECT 1
      FROM public.gpdb_season_excluded_nations en
      WHERE en.season_id = p_season_id
        AND public.international_player_matches_nation(v_pid, en.nation_code)
    ) THEN
      RETURN true;
    END IF;

    RETURN false;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.gpdb_season_excluded_players ep
    JOIN public.competition_seasons s ON s.id = ep.season_id
    WHERE ep.player_id = v_pid
      AND (
        s.is_current = true
        OR s.status IN ('active', 'preseason', 'summer_break', 'setup')
      )
  ) THEN
    RETURN true;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.gpdb_season_excluded_nations en
    JOIN public.competition_seasons s ON s.id = en.season_id
    WHERE (
        s.is_current = true
        OR s.status IN ('active', 'preseason', 'summer_break', 'setup')
      )
      AND public.international_player_matches_nation(v_pid, en.nation_code)
  ) THEN
    RETURN true;
  END IF;

  RETURN false;
END;
$function$;

CREATE OR REPLACE FUNCTION public.gpdb_nation_is_season_excluded(
  p_nation_code text,
  p_season_id bigint DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_code text := upper(btrim(p_nation_code));
BEGIN
  IF v_code IS NULL OR v_code = '' THEN
    RETURN false;
  END IF;

  IF p_season_id IS NOT NULL THEN
    RETURN EXISTS (
      SELECT 1
      FROM public.gpdb_season_excluded_nations en
      WHERE en.season_id = p_season_id
        AND en.nation_code = v_code
    );
  END IF;

  RETURN EXISTS (
    SELECT 1
    FROM public.gpdb_season_excluded_nations en
    JOIN public.competition_seasons s ON s.id = en.season_id
    WHERE en.nation_code = v_code
      AND (
        s.is_current = true
        OR s.status IN ('active', 'preseason', 'summer_break', 'setup')
      )
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.assert_player_not_season_excluded(p_player_id text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF public.gpdb_player_is_season_excluded(p_player_id) THEN
    RAISE EXCEPTION
      'This player is excluded from GPSL for the current season (admin season exclusion).';
  END IF;
END;
$function$;

-- Player IDs directly excluded (for GPDB UI) — all open seasons when p_season_id is null
CREATE OR REPLACE FUNCTION public.gpdb_season_excluded_player_ids(p_season_id bigint DEFAULT NULL)
RETURNS text[]
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT coalesce(array_agg(DISTINCT ep.player_id ORDER BY ep.player_id), ARRAY[]::text[])
  FROM public.gpdb_season_excluded_players ep
  JOIN public.competition_seasons s ON s.id = ep.season_id
  WHERE CASE
    WHEN p_season_id IS NOT NULL THEN ep.season_id = p_season_id
    ELSE s.is_current = true
      OR s.status IN ('active', 'preseason', 'summer_break', 'setup')
  END;
$$;

-- GPDB Nation label strings that map to excluded nation codes
CREATE OR REPLACE FUNCTION public.gpdb_season_excluded_nation_labels(p_season_id bigint DEFAULT NULL)
RETURNS text[]
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season bigint := public.gpdb_exclusion_season_id(p_season_id);
  v_labels text[];
BEGIN
  IF to_regclass('public.international_gpdb_label_map') IS NOT NULL THEN
    SELECT coalesce(array_agg(DISTINCT lab ORDER BY lab), ARRAY[]::text[])
    INTO v_labels
    FROM (
      SELECT m.gpdb_label AS lab
      FROM public.international_gpdb_label_map m
      JOIN public.gpdb_season_excluded_nations en
        ON en.nation_code = m.nation_code AND en.season_id = v_season
      WHERE nullif(btrim(m.gpdb_label), '') IS NOT NULL
      UNION
      SELECT n.name
      FROM public.international_nations n
      JOIN public.gpdb_season_excluded_nations en
        ON en.nation_code = n.code AND en.season_id = v_season
      WHERE nullif(btrim(n.name), '') IS NOT NULL
      UNION
      SELECT n.code
      FROM public.international_nations n
      JOIN public.gpdb_season_excluded_nations en
        ON en.nation_code = n.code AND en.season_id = v_season
    ) x
    WHERE lab IS NOT NULL;
  ELSE
    SELECT coalesce(array_agg(DISTINCT lab ORDER BY lab), ARRAY[]::text[])
    INTO v_labels
    FROM (
      SELECT n.name AS lab
      FROM public.international_nations n
      JOIN public.gpdb_season_excluded_nations en
        ON en.nation_code = n.code AND en.season_id = v_season
      WHERE nullif(btrim(n.name), '') IS NOT NULL
      UNION
      SELECT n.code
      FROM public.international_nations n
      JOIN public.gpdb_season_excluded_nations en
        ON en.nation_code = n.code AND en.season_id = v_season
    ) x
    WHERE lab IS NOT NULL;
  END IF;

  RETURN coalesce(v_labels, ARRAY[]::text[]);
END;
$function$;

-- Bundle for GPDB client
CREATE OR REPLACE FUNCTION public.gpdb_season_exclusions_bundle(p_season_id bigint DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season bigint := public.gpdb_exclusion_season_id(p_season_id);
BEGIN
  RETURN jsonb_build_object(
    'season_id', v_season,
    'player_ids', to_jsonb(public.gpdb_season_excluded_player_ids(v_season)),
    'nation_codes', coalesce(
      (
        SELECT jsonb_agg(en.nation_code ORDER BY en.nation_code)
        FROM public.gpdb_season_excluded_nations en
        WHERE en.season_id = v_season
      ),
      '[]'::jsonb
    ),
    'nation_labels', to_jsonb(public.gpdb_season_excluded_nation_labels(v_season))
  );
END;
$function$;

-- ---------------------------------------------------------------------------
-- Admin list / mutate
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.admin_gpdb_exclusions_list(p_season_id bigint DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season bigint := public.gpdb_exclusion_season_id(p_season_id);
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  RETURN jsonb_build_object(
    'season_id', v_season,
    'season_label', (SELECT label FROM public.competition_seasons WHERE id = v_season),
    'players', coalesce(
      (
        SELECT jsonb_agg(
          jsonb_build_object(
            'player_id', ep.player_id,
            'player_name', p."Name",
            'nation', p."Nation",
            'position', p."Position",
            'rating', p."Rating",
            'club', p."Contracted_Team",
            'reason', ep.reason,
            'excluded_at', ep.excluded_at
          )
          ORDER BY p."Name" NULLS LAST, ep.player_id
        )
        FROM public.gpdb_season_excluded_players ep
        LEFT JOIN public."Players" p ON p."Konami_ID"::text = ep.player_id
        WHERE ep.season_id = v_season
      ),
      '[]'::jsonb
    ),
    'nations', coalesce(
      (
        SELECT jsonb_agg(
          jsonb_build_object(
            'nation_code', en.nation_code,
            'nation_name', n.name,
            'reason', en.reason,
            'excluded_at', en.excluded_at
          )
          ORDER BY n.name NULLS LAST, en.nation_code
        )
        FROM public.gpdb_season_excluded_nations en
        LEFT JOIN public.international_nations n ON n.code = en.nation_code
        WHERE en.season_id = v_season
      ),
      '[]'::jsonb
    )
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_gpdb_exclude_player(
  p_player_id text,
  p_reason text DEFAULT NULL,
  p_season_id bigint DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season bigint := public.gpdb_exclusion_season_id(p_season_id);
  v_pid text := btrim(p_player_id);
  v_name text;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;
  IF v_season IS NULL THEN
    RAISE EXCEPTION 'No competition season found';
  END IF;
  IF v_pid IS NULL OR v_pid = '' THEN
    RAISE EXCEPTION 'player_id required';
  END IF;

  SELECT p."Name" INTO v_name
  FROM public."Players" p
  WHERE p."Konami_ID"::text = v_pid;

  IF v_name IS NULL THEN
    RAISE EXCEPTION 'Player not found';
  END IF;

  INSERT INTO public.gpdb_season_excluded_players (
    season_id, player_id, reason, excluded_by
  )
  VALUES (v_season, v_pid, nullif(btrim(p_reason), ''), auth.uid())
  ON CONFLICT (season_id, player_id) DO UPDATE
  SET reason = excluded.reason,
      excluded_at = now(),
      excluded_by = auth.uid();

  -- Drop from active national squads
  UPDATE public.international_squad_callups
  SET is_active = false,
      released_at = now()
  WHERE player_id = v_pid
    AND is_active = true;

  IF to_regprocedure('public.gpsl_pv_recalc_player_market_value(text)') IS NOT NULL THEN
    PERFORM public.gpsl_pv_recalc_player_market_value(v_pid);
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'season_id', v_season,
    'player_id', v_pid,
    'player_name', v_name
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_gpdb_unexclude_player(
  p_player_id text,
  p_season_id bigint DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season bigint := public.gpdb_exclusion_season_id(p_season_id);
  v_pid text := btrim(p_player_id);
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  DELETE FROM public.gpdb_season_excluded_players
  WHERE season_id = v_season
    AND player_id = v_pid;

  RETURN jsonb_build_object('ok', true, 'season_id', v_season, 'player_id', v_pid);
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_gpdb_exclude_nation(
  p_nation_code text,
  p_reason text DEFAULT NULL,
  p_season_id bigint DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season bigint := public.gpdb_exclusion_season_id(p_season_id);
  v_code text := upper(btrim(p_nation_code));
  v_name text;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;
  IF v_season IS NULL THEN
    RAISE EXCEPTION 'No competition season found';
  END IF;
  IF v_code IS NULL OR v_code = '' THEN
    RAISE EXCEPTION 'nation_code required';
  END IF;

  SELECT n.name INTO v_name
  FROM public.international_nations n
  WHERE n.code = v_code;

  IF v_name IS NULL THEN
    RAISE EXCEPTION 'Nation not found';
  END IF;

  INSERT INTO public.gpdb_season_excluded_nations (
    season_id, nation_code, reason, excluded_by
  )
  VALUES (v_season, v_code, nullif(btrim(p_reason), ''), auth.uid())
  ON CONFLICT (season_id, nation_code) DO UPDATE
  SET reason = excluded.reason,
      excluded_at = now(),
      excluded_by = auth.uid();

  -- Not selectable while excluded
  UPDATE public.international_nations
  SET active = false
  WHERE code = v_code;

  -- Release active call-ups for this nation
  UPDATE public.international_squad_callups
  SET is_active = false,
      released_at = now()
  WHERE nation_code = v_code
    AND is_active = true;

  RETURN jsonb_build_object(
    'ok', true,
    'season_id', v_season,
    'nation_code', v_code,
    'nation_name', v_name
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_gpdb_unexclude_nation(
  p_nation_code text,
  p_season_id bigint DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season bigint := public.gpdb_exclusion_season_id(p_season_id);
  v_code text := upper(btrim(p_nation_code));
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  DELETE FROM public.gpdb_season_excluded_nations
  WHERE season_id = v_season
    AND nation_code = v_code;

  -- Selectable flag restored by international_apply_selectable_from_pool_cache()
  RETURN jsonb_build_object(
    'ok', true,
    'season_id', v_season,
    'nation_code', v_code,
    'note', 'Re-run Refresh selectable / Apply selectable so active flag follows pool rules.'
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_gpdb_search_players_for_exclusion(
  p_query text,
  p_limit integer DEFAULT 25
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_q text := btrim(coalesce(p_query, ''));
  v_lim integer := greatest(1, least(coalesce(p_limit, 25), 50));
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;
  IF length(v_q) < 2 THEN
    RETURN '[]'::jsonb;
  END IF;

  RETURN coalesce(
    (
      SELECT jsonb_agg(row_to_json(x)::jsonb)
      FROM (
        SELECT
          p."Konami_ID"::text AS player_id,
          p."Name" AS player_name,
          p."Nation" AS nation,
          p."Position" AS position,
          p."Rating" AS rating,
          p."Contracted_Team" AS club
        FROM public."Players" p
        WHERE p."Name" ILIKE '%' || v_q || '%'
           OR p."Konami_ID"::text ILIKE v_q || '%'
        ORDER BY p."Rating" DESC NULLS LAST, p."Name"
        LIMIT v_lim
      ) x
    ),
    '[]'::jsonb
  );
END;
$function$;

-- ---------------------------------------------------------------------------
-- Enforce on signing / call-up / nation claim
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.assert_player_available_for_signing(p_player_id text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_status jsonb;
  v_club text;
  v_unlock text;
  v_kind text;
BEGIN
  PERFORM public.assert_player_not_season_excluded(p_player_id);

  IF NOT public.player_foreign_contract_locked(p_player_id) THEN
    RETURN;
  END IF;

  v_status := public.player_foreign_contract_status(p_player_id);
  v_club := coalesce(v_status ->> 'foreign_contract_club', 'their previous club');
  v_unlock := coalesce(v_status ->> 'unlock_season_label', 'next season');
  v_kind := coalesce(v_status ->> 'lock_kind', 'foreign');

  IF v_kind = 'paid_up' THEN
    RAISE EXCEPTION
      'Player is unavailable until % — contract paid up by % (squad overflow release)',
      v_unlock,
      v_club;
  END IF;

  RAISE EXCEPTION
    'Player is unavailable until % — contracted to %',
    v_unlock,
    v_club;
END;
$function$;

-- Ensure call-up cycle app columns exist (also created by international_career_stats_and_mv_boost.sql)
ALTER TABLE public.international_squad_callups
  ADD COLUMN IF NOT EXISTS appearances_in_cycle integer NOT NULL DEFAULT 0;
ALTER TABLE public.international_squad_callups
  ADD COLUMN IF NOT EXISTS prev_cycle_id bigint;
ALTER TABLE public.international_squad_callups
  ADD COLUMN IF NOT EXISTS prev_appearances_in_cycle integer NOT NULL DEFAULT 0;

-- Patch call-up (keeps MV boost / GPDB rules from international_career_stats_and_mv_boost.sql)
CREATE OR REPLACE FUNCTION public.international_call_up_player(p_player_id text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_nation text := public.international_my_nation_code();
  v_cycle_id bigint;
  v_player_club text;
  v_squad_count integer;
  v_pid text := btrim(p_player_id);
BEGIN
  IF v_nation IS NULL THEN
    RAISE EXCEPTION 'You have not been assigned a national team';
  END IF;

  IF public.gpdb_player_is_season_excluded(v_pid) THEN
    RAISE EXCEPTION 'This player is excluded from GPSL for the current season';
  END IF;

  IF public.gpdb_nation_is_season_excluded(v_nation) THEN
    RAISE EXCEPTION 'Your national team is excluded for the current season';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public."Players" p
    WHERE p."Konami_ID"::text = v_pid
  ) THEN
    RAISE EXCEPTION 'Player not found';
  END IF;

  IF NOT public.international_player_matches_nation(v_pid, v_nation) THEN
    RAISE EXCEPTION 'Player nationality does not match your national team';
  END IF;

  SELECT c."ShortName"
  INTO v_player_club
  FROM public."Players" p
  JOIN public."Clubs" c
    ON c."ShortName" = nullif(btrim(p."Contracted_Team"), '')
  WHERE p."Konami_ID"::text = v_pid;

  v_squad_count := public.international_nation_active_squad_count(v_nation);

  IF NOT EXISTS (
    SELECT 1
    FROM public.international_squad_callups sc
    WHERE sc.nation_code = v_nation
      AND sc.player_id = v_pid
      AND sc.is_active = true
  ) AND v_squad_count >= 23 THEN
    RAISE EXCEPTION 'National squad is full (23 players)';
  END IF;

  SELECT id INTO v_cycle_id
  FROM public.international_wc_cycles
  ORDER BY cycle_no DESC
  LIMIT 1;

  UPDATE public.international_squad_callups
  SET is_active = false,
      released_at = now()
  WHERE player_id = v_pid
    AND nation_code <> v_nation
    AND is_active = true;

  IF FOUND AND to_regprocedure('public.gpsl_pv_recalc_player_market_value(text)') IS NOT NULL THEN
    PERFORM public.gpsl_pv_recalc_player_market_value(v_pid);
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.international_squad_callups sc
    WHERE sc.nation_code = v_nation
      AND sc.player_id = v_pid
  ) THEN
    UPDATE public.international_squad_callups sc
    SET is_active = true,
        released_at = NULL,
        called_at = now(),
        club_short_name = v_player_club,
        prev_cycle_id = CASE
          WHEN sc.cycle_id IS DISTINCT FROM v_cycle_id AND sc.cycle_id IS NOT NULL
            THEN sc.cycle_id
          ELSE sc.prev_cycle_id
        END,
        prev_appearances_in_cycle = CASE
          WHEN sc.cycle_id IS DISTINCT FROM v_cycle_id AND sc.cycle_id IS NOT NULL
            THEN coalesce(sc.appearances_in_cycle, 0)
          ELSE sc.prev_appearances_in_cycle
        END,
        cycle_id = v_cycle_id,
        appearances_in_cycle = CASE
          WHEN sc.cycle_id IS DISTINCT FROM v_cycle_id THEN 0
          WHEN sc.is_active THEN coalesce(sc.appearances_in_cycle, 0)
          ELSE 0
        END
    WHERE sc.nation_code = v_nation
      AND sc.player_id = v_pid;
  ELSE
    INSERT INTO public.international_squad_callups (
      nation_code,
      player_id,
      club_short_name,
      cycle_id,
      is_active,
      appearances_in_cycle,
      prev_appearances_in_cycle
    )
    VALUES (
      v_nation,
      v_pid,
      v_player_club,
      v_cycle_id,
      true,
      0,
      0
    );
  END IF;

  IF to_regprocedure('public.gpsl_pv_recalc_player_market_value(text)') IS NOT NULL THEN
    PERFORM public.gpsl_pv_recalc_player_market_value(v_pid);
  END IF;
END;
$function$;

CREATE OR REPLACE FUNCTION public.international_claim_nation(p_nation_code text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := public.my_club_shortname();
  v_window record;
  v_my_pick smallint;
  v_current_pick smallint;
  v_nation text := btrim(upper(p_nation_code));
  v_cycle_id bigint;
  v_next_pick smallint;
  v_nation_name text;
BEGIN
  IF v_club IS NULL OR v_club = '' THEN
    RAISE EXCEPTION 'No club linked to your account';
  END IF;

  IF public.gpdb_nation_is_season_excluded(v_nation) THEN
    RAISE EXCEPTION 'This nation is excluded from GPSL for the current season';
  END IF;

  SELECT * INTO v_window
  FROM public.international_selection_windows
  WHERE is_open = true
  ORDER BY id DESC
  LIMIT 1;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Nation selection is not open';
  END IF;

  SELECT pick_order INTO v_my_pick
  FROM public.international_owner_draft_order()
  WHERE club_short_name = v_club;

  IF v_my_pick IS NULL THEN
    RAISE EXCEPTION 'Your club is not in the owner draft order';
  END IF;

  v_current_pick := v_window.current_pick_rank;

  IF v_my_pick <> v_current_pick THEN
    RAISE EXCEPTION 'Not your pick yet (currently pick #% — you are #%).', v_current_pick, v_my_pick;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.international_nations n
    WHERE n.code = v_nation AND n.active = true
  ) THEN
    RAISE EXCEPTION 'Nation not found';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.international_owner_nations ion
    WHERE ion.nation_code = v_nation AND ion.is_active = true
  ) THEN
    RAISE EXCEPTION 'Nation already taken';
  END IF;

  IF to_regprocedure('public.international_nation_pool_is_selectable(text)') IS NOT NULL
     AND NOT public.international_nation_pool_is_selectable(v_nation) THEN
    RAISE EXCEPTION 'This nation cannot be selected — GPDB pool too small for a squad or GPSL club';
  END IF;

  SELECT n.name INTO v_nation_name FROM public.international_nations n WHERE n.code = v_nation;

  SELECT id INTO v_cycle_id FROM public.international_wc_cycles ORDER BY cycle_no DESC LIMIT 1;

  UPDATE public.international_owner_nations
  SET is_active = false, released_at = now()
  WHERE club_short_name = v_club AND is_active = true;

  INSERT INTO public.international_owner_nations (
    club_short_name, nation_code, cycle_id, selection_phase, is_active, locked_until_cycle_id
  )
  VALUES (v_club, v_nation, v_cycle_id, v_window.phase, true, v_cycle_id);

  SELECT coalesce(min(pick_order), 61)::smallint INTO v_next_pick
  FROM public.international_owner_draft_order() d
  WHERE NOT EXISTS (
    SELECT 1 FROM public.international_owner_nations ion
    WHERE ion.club_short_name = d.club_short_name AND ion.is_active = true
  );

  IF v_next_pick >= 61 THEN
    UPDATE public.international_selection_windows
    SET is_open = false, closes_at = now()
    WHERE id = v_window.id;
  ELSE
    UPDATE public.international_selection_windows
    SET current_pick_rank = v_next_pick
    WHERE id = v_window.id;
    IF to_regprocedure('public.owner_inbox_notify_nation_pick_turn(smallint)') IS NOT NULL THEN
      PERFORM public.owner_inbox_notify_nation_pick_turn(v_next_pick);
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'club', v_club,
    'nation', v_nation,
    'nation_name', v_nation_name,
    'pick', v_my_pick,
    'next_pick', v_next_pick
  );
END;
$function$;

-- Keep excluded nations inactive when applying selectable from pool
CREATE OR REPLACE FUNCTION public.gpdb_force_excluded_nations_inactive(p_season_id bigint DEFAULT NULL)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season bigint := public.gpdb_exclusion_season_id(p_season_id);
  v_n integer := 0;
BEGIN
  UPDATE public.international_nations n
  SET active = false
  FROM public.gpdb_season_excluded_nations en
  WHERE en.season_id = v_season
    AND en.nation_code = n.code
    AND n.active = true;

  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.gpdb_exclusion_season_id(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.gpdb_player_is_season_excluded(text, bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.gpdb_nation_is_season_excluded(text, bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.assert_player_not_season_excluded(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.gpdb_season_excluded_player_ids(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.gpdb_season_excluded_nation_labels(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.gpdb_season_exclusions_bundle(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_gpdb_exclusions_list(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_gpdb_exclude_player(text, text, bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_gpdb_unexclude_player(text, bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_gpdb_exclude_nation(text, text, bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_gpdb_unexclude_nation(text, bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_gpdb_search_players_for_exclusion(text, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.gpdb_force_excluded_nations_inactive(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.assert_player_available_for_signing(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.international_call_up_player(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.international_claim_nation(text) TO authenticated;

NOTIFY pgrst, 'reload schema';
