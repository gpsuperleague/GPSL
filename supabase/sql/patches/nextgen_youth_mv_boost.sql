-- =============================================================================
-- Next Gen Youth list (current season) + 10% market value boost
--
-- Admin refreshes the list for the current competition season (replace-all).
-- Players on that list get +10% MV (after international boost, if any).
-- When removed / not on the current-season list, MV returns to normal on recalc.
--
-- Run in Supabase SQL Editor after international_career_stats_and_mv_boost.sql
-- (or any patch that defines gpsl_pv_apply_international_boost / recalc).
-- Safe re-run.
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.nextgen_youth_players (
  season_id bigint NOT NULL REFERENCES public.competition_seasons (id) ON DELETE CASCADE,
  player_id text NOT NULL,
  added_at timestamptz NOT NULL DEFAULT now(),
  added_by uuid REFERENCES auth.users (id),
  PRIMARY KEY (season_id, player_id)
);

CREATE INDEX IF NOT EXISTS nextgen_youth_players_player_idx
  ON public.nextgen_youth_players (player_id);

CREATE TABLE IF NOT EXISTS public.nextgen_youth_list_meta (
  season_id bigint PRIMARY KEY REFERENCES public.competition_seasons (id) ON DELETE CASCADE,
  refreshed_at timestamptz NOT NULL DEFAULT now(),
  refreshed_by uuid REFERENCES auth.users (id),
  player_count integer NOT NULL DEFAULT 0,
  note text
);

COMMENT ON TABLE public.nextgen_youth_players IS
  'Next Gen Youth membership for a competition season. Only the current season list applies MV boost.';
COMMENT ON TABLE public.nextgen_youth_list_meta IS
  'Last refresh metadata for Next Gen Youth per season.';

ALTER TABLE public.nextgen_youth_players ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.nextgen_youth_list_meta ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS nextgen_youth_players_select ON public.nextgen_youth_players;
CREATE POLICY nextgen_youth_players_select ON public.nextgen_youth_players
  FOR SELECT TO authenticated USING (true);

DROP POLICY IF EXISTS nextgen_youth_players_admin ON public.nextgen_youth_players;
CREATE POLICY nextgen_youth_players_admin ON public.nextgen_youth_players
  FOR ALL TO authenticated
  USING (public.is_gpsl_admin())
  WITH CHECK (public.is_gpsl_admin());

DROP POLICY IF EXISTS nextgen_youth_meta_select ON public.nextgen_youth_list_meta;
CREATE POLICY nextgen_youth_meta_select ON public.nextgen_youth_list_meta
  FOR SELECT TO authenticated USING (true);

DROP POLICY IF EXISTS nextgen_youth_meta_admin ON public.nextgen_youth_list_meta;
CREATE POLICY nextgen_youth_meta_admin ON public.nextgen_youth_list_meta
  FOR ALL TO authenticated
  USING (public.is_gpsl_admin())
  WITH CHECK (public.is_gpsl_admin());

GRANT SELECT ON public.nextgen_youth_players TO authenticated;
GRANT SELECT ON public.nextgen_youth_list_meta TO authenticated;

CREATE OR REPLACE FUNCTION public.nextgen_youth_season_id(p_season_id bigint DEFAULT NULL)
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

CREATE OR REPLACE FUNCTION public.gpsl_pv_nextgen_boost_pct()
RETURNS numeric
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT 0.10::numeric;
$$;

CREATE OR REPLACE FUNCTION public.gpsl_pv_nextgen_boost_eligible(p_player_id text)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_pid text := btrim(p_player_id);
  v_season bigint;
BEGIN
  IF v_pid IS NULL OR v_pid = '' THEN
    RETURN false;
  END IF;

  v_season := public.nextgen_youth_season_id(NULL);
  IF v_season IS NULL THEN
    RETURN false;
  END IF;

  RETURN EXISTS (
    SELECT 1
    FROM public.nextgen_youth_players n
    WHERE n.season_id = v_season
      AND n.player_id = v_pid
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.gpsl_pv_apply_nextgen_boost(
  p_base_mv numeric,
  p_player_id text
)
RETURNS numeric
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT CASE
    WHEN p_base_mv IS NULL THEN NULL
    WHEN public.gpsl_pv_nextgen_boost_eligible(p_player_id)
      THEN round(p_base_mv * (1 + public.gpsl_pv_nextgen_boost_pct()))
    ELSE round(p_base_mv)
  END;
$$;

CREATE OR REPLACE FUNCTION public.gpsl_pv_apply_stored_boosts(
  p_base_mv numeric,
  p_player_id text
)
RETURNS numeric
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT public.gpsl_pv_apply_nextgen_boost(
    public.gpsl_pv_apply_international_boost(p_base_mv, p_player_id),
    p_player_id
  );
$$;

CREATE OR REPLACE FUNCTION public.gpsl_pv_recalc_player_market_value(p_player_id text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_row record;
  v_base numeric;
  v_mv numeric;
  v_calc integer;
BEGIN
  SELECT
    public.gpsl_pv_int(p."Rating"::text) AS rating,
    coalesce(
      public.gpsl_pv_int(p."Potential"::text),
      public.gpsl_pv_int(p."Rating"::text)
    ) AS pes_max,
    public.gpsl_pv_int(p."Age"::text) AS age,
    p."Position"::text AS position
  INTO v_row
  FROM public."Players" p
  WHERE p."Konami_ID"::text = btrim(p_player_id);

  IF v_row.rating IS NULL THEN
    RETURN;
  END IF;

  v_calc := public.gpsl_pv_calc_potential(v_row.rating, v_row.pes_max, v_row.age);
  v_base := public.gpsl_pv_market_value(
    v_row.rating,
    v_row.pes_max,
    v_row.age,
    v_row.position
  );
  v_mv := public.gpsl_pv_apply_stored_boosts(v_base, btrim(p_player_id));

  UPDATE public."Players" p
  SET
    "Calc_Potential" = v_calc,
    market_value = v_mv,
    "Maximum_Reserve_Price" = round(v_mv * 1.5)
  WHERE p."Konami_ID"::text = btrim(p_player_id);
END;
$function$;

CREATE OR REPLACE FUNCTION public.apply_calc_value()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public
AS $function$
DECLARE
  v_rating integer;
  v_pes_max integer;
  v_age integer;
  v_base numeric;
BEGIN
  v_rating := public.gpsl_pv_int(NEW."Rating"::text);
  v_pes_max := coalesce(
    public.gpsl_pv_int(NEW."Potential"::text),
    v_rating
  );
  v_age := public.gpsl_pv_int(NEW."Age"::text);

  IF v_rating IS NULL THEN
    RETURN NEW;
  END IF;

  NEW."Calc_Potential" := public.gpsl_pv_calc_potential(v_rating, v_pes_max, v_age);
  v_base := public.gpsl_pv_market_value(
    v_rating,
    v_pes_max,
    v_age,
    NEW."Position"::text
  );
  NEW."market_value" := public.gpsl_pv_apply_stored_boosts(
    v_base,
    NEW."Konami_ID"::text
  );

  RETURN NEW;
END;
$function$;

COMMENT ON FUNCTION public.apply_calc_value() IS
  'BEFORE INSERT/UPDATE on Players: Calc_Potential + market_value via gpsl_pv_* with intl (+5%) and Next Gen Youth (+10%) boosts when eligible.';

CREATE OR REPLACE FUNCTION public.gpsl_player_value_recalc_apply()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_updated integer := 0;
  v_eligible integer := 0;
BEGIN
  SELECT count(*)::integer INTO v_eligible
  FROM public."Players" p
  WHERE public.gpsl_pv_int(p."Rating"::text) IS NOT NULL;

  WITH calc AS (
    SELECT
      p."Konami_ID"::text AS konami_id,
      public.gpsl_pv_apply_stored_boosts(
        public.gpsl_pv_market_value(
          public.gpsl_pv_int(p."Rating"::text),
          coalesce(
            public.gpsl_pv_int(p."Potential"::text),
            public.gpsl_pv_int(p."Rating"::text)
          ),
          public.gpsl_pv_int(p."Age"::text),
          p."Position"::text
        ),
        p."Konami_ID"::text
      ) AS new_mv,
      public.gpsl_pv_calc_potential(
        public.gpsl_pv_int(p."Rating"::text),
        coalesce(
          public.gpsl_pv_int(p."Potential"::text),
          public.gpsl_pv_int(p."Rating"::text)
        ),
        public.gpsl_pv_int(p."Age"::text)
      ) AS new_calc
    FROM public."Players" p
    WHERE public.gpsl_pv_int(p."Rating"::text) IS NOT NULL
  ),
  touched AS (
    UPDATE public."Players" p
    SET
      market_value = c.new_mv,
      "Maximum_Reserve_Price" = round(c.new_mv * 1.5),
      "Calc_Potential" = c.new_calc
    FROM calc c
    WHERE p."Konami_ID"::text = c.konami_id
      AND c.new_mv IS NOT NULL
      AND c.new_calc IS NOT NULL
    RETURNING p."Konami_ID"::text
  )
  SELECT count(*)::integer INTO v_updated FROM touched;

  RETURN jsonb_build_object(
    'ok', true,
    'eligible', v_eligible,
    'updated', v_updated
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.nextgen_youth_list(p_season_id bigint DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season bigint := public.nextgen_youth_season_id(p_season_id);
  v_meta public.nextgen_youth_list_meta%ROWTYPE;
BEGIN
  IF v_season IS NULL THEN
    RETURN jsonb_build_object(
      'season_id', NULL,
      'players', '[]'::jsonb,
      'boost_pct', public.gpsl_pv_nextgen_boost_pct()
    );
  END IF;

  SELECT * INTO v_meta FROM public.nextgen_youth_list_meta WHERE season_id = v_season;

  RETURN jsonb_build_object(
    'season_id', v_season,
    'season_label', (SELECT label FROM public.competition_seasons WHERE id = v_season),
    'boost_pct', public.gpsl_pv_nextgen_boost_pct(),
    'refreshed_at', v_meta.refreshed_at,
    'player_count', coalesce(v_meta.player_count, 0),
    'players', coalesce(
      (
        SELECT jsonb_agg(
          jsonb_build_object(
            'player_id', n.player_id,
            'player_name', p."Name",
            'nation', p."Nation",
            'position', p."Position",
            'age', p."Age",
            'rating', p."Rating",
            'club', p."Contracted_Team",
            'market_value', p.market_value,
            'added_at', n.added_at
          )
          ORDER BY p."Name" NULLS LAST, n.player_id
        )
        FROM public.nextgen_youth_players n
        LEFT JOIN public."Players" p ON p."Konami_ID"::text = n.player_id
        WHERE n.season_id = v_season
      ),
      '[]'::jsonb
    )
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_nextgen_youth_refresh(
  p_player_ids text[],
  p_season_id bigint DEFAULT NULL,
  p_note text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season bigint := public.nextgen_youth_season_id(p_season_id);
  v_old text[];
  v_new text[];
  v_touched text[];
  v_pid text;
  v_count integer := 0;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;
  IF v_season IS NULL THEN
    RAISE EXCEPTION 'No competition season found';
  END IF;

  SELECT coalesce(array_agg(n.player_id), ARRAY[]::text[])
  INTO v_old
  FROM public.nextgen_youth_players n
  WHERE n.season_id = v_season;

  SELECT coalesce(
    array_agg(DISTINCT btrim(x)),
    ARRAY[]::text[]
  )
  INTO v_new
  FROM unnest(coalesce(p_player_ids, ARRAY[]::text[])) AS x
  WHERE btrim(x) <> '';

  DELETE FROM public.nextgen_youth_players WHERE season_id = v_season;

  IF cardinality(v_new) > 0 THEN
    INSERT INTO public.nextgen_youth_players (season_id, player_id, added_by)
    SELECT v_season, pid, auth.uid()
    FROM unnest(v_new) AS pid
    ON CONFLICT DO NOTHING;
  END IF;

  SELECT count(*)::integer INTO v_count
  FROM public.nextgen_youth_players
  WHERE season_id = v_season;

  INSERT INTO public.nextgen_youth_list_meta (season_id, refreshed_at, refreshed_by, player_count, note)
  VALUES (v_season, now(), auth.uid(), v_count, nullif(btrim(coalesce(p_note, '')), ''))
  ON CONFLICT (season_id) DO UPDATE
  SET
    refreshed_at = excluded.refreshed_at,
    refreshed_by = excluded.refreshed_by,
    player_count = excluded.player_count,
    note = excluded.note;

  SELECT coalesce(
    array_agg(DISTINCT t),
    ARRAY[]::text[]
  )
  INTO v_touched
  FROM (
    SELECT unnest(v_old) AS t
    UNION
    SELECT unnest(v_new) AS t
  ) s
  WHERE t IS NOT NULL AND btrim(t) <> '';

  FOREACH v_pid IN ARRAY v_touched
  LOOP
    PERFORM public.gpsl_pv_recalc_player_market_value(v_pid);
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true,
    'season_id', v_season,
    'season_label', (SELECT label FROM public.competition_seasons WHERE id = v_season),
    'player_count', v_count,
    'added', (
      SELECT count(*)::integer
      FROM unnest(v_new) n
      WHERE n <> ALL (coalesce(v_old, ARRAY[]::text[]))
    ),
    'removed', (
      SELECT count(*)::integer
      FROM unnest(v_old) o
      WHERE o <> ALL (coalesce(v_new, ARRAY[]::text[]))
    ),
    'recalculated', cardinality(v_touched),
    'boost_pct', public.gpsl_pv_nextgen_boost_pct()
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.nextgen_youth_season_id(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.gpsl_pv_nextgen_boost_pct() TO authenticated;
GRANT EXECUTE ON FUNCTION public.gpsl_pv_nextgen_boost_eligible(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.gpsl_pv_apply_nextgen_boost(numeric, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.gpsl_pv_apply_stored_boosts(numeric, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.nextgen_youth_list(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_nextgen_youth_refresh(text[], bigint, text) TO authenticated;

-- =============================================================================
-- Goal.com NXGN source URL (admin-editable; used by nextgen-goal-fetch)
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.nextgen_youth_settings (
  id smallint PRIMARY KEY DEFAULT 1 CHECK (id = 1),
  source_url text,
  updated_at timestamptz NOT NULL DEFAULT now(),
  updated_by uuid REFERENCES auth.users (id)
);

COMMENT ON TABLE public.nextgen_youth_settings IS
  'Singleton settings for Next Gen Youth (Goal NXGN source URL).';

INSERT INTO public.nextgen_youth_settings (id, source_url)
VALUES (
  1,
  'https://www.goal.com/en/lists/nxgn-2026-best-teenage-wonderkids-football/blt2f8486395140dacd'
)
ON CONFLICT (id) DO NOTHING;

ALTER TABLE public.nextgen_youth_settings ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS nextgen_youth_settings_select ON public.nextgen_youth_settings;
CREATE POLICY nextgen_youth_settings_select ON public.nextgen_youth_settings
  FOR SELECT TO authenticated USING (true);

DROP POLICY IF EXISTS nextgen_youth_settings_admin ON public.nextgen_youth_settings;
CREATE POLICY nextgen_youth_settings_admin ON public.nextgen_youth_settings
  FOR ALL TO authenticated
  USING (public.is_gpsl_admin())
  WITH CHECK (public.is_gpsl_admin());

GRANT SELECT ON public.nextgen_youth_settings TO authenticated;

CREATE OR REPLACE FUNCTION public.nextgen_youth_settings_get()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_row public.nextgen_youth_settings%ROWTYPE;
BEGIN
  SELECT * INTO v_row FROM public.nextgen_youth_settings WHERE id = 1;
  RETURN jsonb_build_object(
    'source_url', v_row.source_url,
    'updated_at', v_row.updated_at
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_nextgen_youth_settings_set(
  p_source_url text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_url text := nullif(btrim(coalesce(p_source_url, '')), '');
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF v_url IS NOT NULL AND v_url !~* '^https?://' THEN
    RAISE EXCEPTION 'Source URL must start with http:// or https://';
  END IF;

  INSERT INTO public.nextgen_youth_settings (id, source_url, updated_at, updated_by)
  VALUES (1, v_url, now(), auth.uid())
  ON CONFLICT (id) DO UPDATE
  SET
    source_url = excluded.source_url,
    updated_at = excluded.updated_at,
    updated_by = excluded.updated_by;

  RETURN public.nextgen_youth_settings_get();
END;
$function$;

GRANT EXECUTE ON FUNCTION public.nextgen_youth_settings_get() TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_nextgen_youth_settings_set(text) TO authenticated;
