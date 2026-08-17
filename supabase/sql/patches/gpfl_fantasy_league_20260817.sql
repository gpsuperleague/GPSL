-- =============================================================================
-- GPFL — GPSL Fantasy League (optional side-game)
--
-- Fully configurable. Opt-in only. Budget / prices / points NEVER touch
-- competition_finance_ledger or club balances.
--
-- Pool: contracted Super League + Championship A/B players (configurable).
-- Scoring: league fixtures only (configurable). Prices = MV rounded to £1m.
--
-- Run in Supabase SQL Editor. Safe re-run.
-- =============================================================================

SET statement_timeout = '120s';

-- ---------------------------------------------------------------------------
-- Settings (single row — everything tunable)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.gpfl_settings (
  id int PRIMARY KEY DEFAULT 1 CHECK (id = 1),
  enabled boolean NOT NULL DEFAULT true,
  opt_in_only boolean NOT NULL DEFAULT true,
  budget numeric NOT NULL DEFAULT 400000000,
  squad_size int NOT NULL DEFAULT 15,
  starters int NOT NULL DEFAULT 11,
  max_per_club int NOT NULL DEFAULT 3,
  slot_gk int NOT NULL DEFAULT 2,
  slot_def int NOT NULL DEFAULT 5,
  slot_mid int NOT NULL DEFAULT 5,
  slot_fwd int NOT NULL DEFAULT 3,
  price_round_to numeric NOT NULL DEFAULT 1000000,
  price_floor numeric NOT NULL DEFAULT 4000000,
  free_transfers_per_month int NOT NULL DEFAULT 1,
  divisions text[] NOT NULL DEFAULT ARRAY['superleague', 'championship_a', 'championship_b'],
  competition_types text[] NOT NULL DEFAULT ARRAY['league'],
  require_stats_to_score boolean NOT NULL DEFAULT true,
  pts_appear numeric NOT NULL DEFAULT 1,
  pts_goal_gk numeric NOT NULL DEFAULT 6,
  pts_goal_def numeric NOT NULL DEFAULT 6,
  pts_goal_mid numeric NOT NULL DEFAULT 5,
  pts_goal_fwd numeric NOT NULL DEFAULT 4,
  pts_assist numeric NOT NULL DEFAULT 3,
  pts_cs_gk numeric NOT NULL DEFAULT 4,
  pts_cs_def numeric NOT NULL DEFAULT 4,
  pts_cs_mid numeric NOT NULL DEFAULT 1,
  pts_cs_fwd numeric NOT NULL DEFAULT 0,
  pts_yellow numeric NOT NULL DEFAULT -1,
  pts_red numeric NOT NULL DEFAULT -3,
  pts_potm numeric NOT NULL DEFAULT 3,
  captain_multiplier numeric NOT NULL DEFAULT 2,
  updated_at timestamptz NOT NULL DEFAULT now(),
  updated_by uuid
);

INSERT INTO public.gpfl_settings (id)
VALUES (1)
ON CONFLICT (id) DO NOTHING;

-- Ensure new columns exist on re-run of older drafts
ALTER TABLE public.gpfl_settings
  ADD COLUMN IF NOT EXISTS enabled boolean NOT NULL DEFAULT true,
  ADD COLUMN IF NOT EXISTS opt_in_only boolean NOT NULL DEFAULT true,
  ADD COLUMN IF NOT EXISTS budget numeric NOT NULL DEFAULT 400000000,
  ADD COLUMN IF NOT EXISTS squad_size int NOT NULL DEFAULT 15,
  ADD COLUMN IF NOT EXISTS starters int NOT NULL DEFAULT 11,
  ADD COLUMN IF NOT EXISTS max_per_club int NOT NULL DEFAULT 3,
  ADD COLUMN IF NOT EXISTS slot_gk int NOT NULL DEFAULT 2,
  ADD COLUMN IF NOT EXISTS slot_def int NOT NULL DEFAULT 5,
  ADD COLUMN IF NOT EXISTS slot_mid int NOT NULL DEFAULT 5,
  ADD COLUMN IF NOT EXISTS slot_fwd int NOT NULL DEFAULT 3,
  ADD COLUMN IF NOT EXISTS price_round_to numeric NOT NULL DEFAULT 1000000,
  ADD COLUMN IF NOT EXISTS price_floor numeric NOT NULL DEFAULT 4000000,
  ADD COLUMN IF NOT EXISTS free_transfers_per_month int NOT NULL DEFAULT 1,
  ADD COLUMN IF NOT EXISTS divisions text[] NOT NULL DEFAULT ARRAY['superleague', 'championship_a', 'championship_b'],
  ADD COLUMN IF NOT EXISTS competition_types text[] NOT NULL DEFAULT ARRAY['league'],
  ADD COLUMN IF NOT EXISTS require_stats_to_score boolean NOT NULL DEFAULT true,
  ADD COLUMN IF NOT EXISTS pts_appear numeric NOT NULL DEFAULT 1,
  ADD COLUMN IF NOT EXISTS pts_goal_gk numeric NOT NULL DEFAULT 6,
  ADD COLUMN IF NOT EXISTS pts_goal_def numeric NOT NULL DEFAULT 6,
  ADD COLUMN IF NOT EXISTS pts_goal_mid numeric NOT NULL DEFAULT 5,
  ADD COLUMN IF NOT EXISTS pts_goal_fwd numeric NOT NULL DEFAULT 4,
  ADD COLUMN IF NOT EXISTS pts_assist numeric NOT NULL DEFAULT 3,
  ADD COLUMN IF NOT EXISTS pts_cs_gk numeric NOT NULL DEFAULT 4,
  ADD COLUMN IF NOT EXISTS pts_cs_def numeric NOT NULL DEFAULT 4,
  ADD COLUMN IF NOT EXISTS pts_cs_mid numeric NOT NULL DEFAULT 1,
  ADD COLUMN IF NOT EXISTS pts_cs_fwd numeric NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS pts_yellow numeric NOT NULL DEFAULT -1,
  ADD COLUMN IF NOT EXISTS pts_red numeric NOT NULL DEFAULT -3,
  ADD COLUMN IF NOT EXISTS pts_potm numeric NOT NULL DEFAULT 3,
  ADD COLUMN IF NOT EXISTS captain_multiplier numeric NOT NULL DEFAULT 2;

ALTER TABLE public.gpfl_settings ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS gpfl_settings_read ON public.gpfl_settings;
CREATE POLICY gpfl_settings_read
  ON public.gpfl_settings
  FOR SELECT TO authenticated, anon
  USING (true);

COMMENT ON TABLE public.gpfl_settings IS
  'GPFL fantasy config. Play-money only — never posts to club ledgers.';

-- ---------------------------------------------------------------------------
-- Season + frozen prices
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.gpfl_seasons (
  id bigint GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
  competition_season_id bigint NOT NULL REFERENCES public.competition_seasons (id) ON DELETE CASCADE,
  status text NOT NULL DEFAULT 'open'
    CHECK (status IN ('open', 'locked', 'closed')),
  budget_snapshot numeric NOT NULL,
  settings_snapshot jsonb NOT NULL DEFAULT '{}'::jsonb,
  opened_at timestamptz NOT NULL DEFAULT now(),
  closed_at timestamptz,
  UNIQUE (competition_season_id)
);

CREATE TABLE IF NOT EXISTS public.gpfl_player_prices (
  id bigint GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
  gpfl_season_id bigint NOT NULL REFERENCES public.gpfl_seasons (id) ON DELETE CASCADE,
  player_id text NOT NULL,
  player_name text,
  club_short_name text NOT NULL,
  division text,
  position text,
  position_group text NOT NULL CHECK (position_group IN ('gk', 'def', 'mid', 'fwd')),
  market_value_raw numeric,
  price numeric NOT NULL CHECK (price > 0),
  eligible boolean NOT NULL DEFAULT true,
  became_fa_at timestamptz,
  UNIQUE (gpfl_season_id, player_id)
);

CREATE INDEX IF NOT EXISTS gpfl_player_prices_season_pos_idx
  ON public.gpfl_player_prices (gpfl_season_id, position_group, price DESC);

CREATE INDEX IF NOT EXISTS gpfl_player_prices_club_idx
  ON public.gpfl_player_prices (gpfl_season_id, club_short_name);

-- ---------------------------------------------------------------------------
-- Opt-in entries + squad (no GPSL finance)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.gpfl_entries (
  id bigint GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
  gpfl_season_id bigint NOT NULL REFERENCES public.gpfl_seasons (id) ON DELETE CASCADE,
  owner_id uuid NOT NULL,
  club_short_name text,
  team_name text,
  status text NOT NULL DEFAULT 'building'
    CHECK (status IN ('building', 'active', 'withdrawn')),
  budget_remaining numeric NOT NULL,
  total_points numeric NOT NULL DEFAULT 0,
  free_transfers_remaining int NOT NULL DEFAULT 1,
  transfers_used_month text,
  joined_at timestamptz NOT NULL DEFAULT now(),
  confirmed_at timestamptz,
  UNIQUE (gpfl_season_id, owner_id)
);

CREATE INDEX IF NOT EXISTS gpfl_entries_season_points_idx
  ON public.gpfl_entries (gpfl_season_id, total_points DESC);

CREATE TABLE IF NOT EXISTS public.gpfl_squad_players (
  id bigint GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
  entry_id bigint NOT NULL REFERENCES public.gpfl_entries (id) ON DELETE CASCADE,
  player_id text NOT NULL,
  position_group text NOT NULL CHECK (position_group IN ('gk', 'def', 'mid', 'fwd')),
  purchase_price numeric NOT NULL,
  is_starter boolean NOT NULL DEFAULT false,
  is_captain boolean NOT NULL DEFAULT false,
  slot_status text NOT NULL DEFAULT 'active'
    CHECK (slot_status IN ('active', 'needs_replace')),
  acquired_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (entry_id, player_id)
);

CREATE INDEX IF NOT EXISTS gpfl_squad_entry_idx
  ON public.gpfl_squad_players (entry_id);

CREATE TABLE IF NOT EXISTS public.gpfl_entry_month_points (
  id bigint GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
  entry_id bigint NOT NULL REFERENCES public.gpfl_entries (id) ON DELETE CASCADE,
  gpsl_month text NOT NULL,
  points numeric NOT NULL DEFAULT 0,
  scored_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (entry_id, gpsl_month)
);

CREATE TABLE IF NOT EXISTS public.gpfl_player_fixture_points (
  id bigint GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
  gpfl_season_id bigint NOT NULL REFERENCES public.gpfl_seasons (id) ON DELETE CASCADE,
  fixture_id bigint NOT NULL REFERENCES public.competition_fixtures (id) ON DELETE CASCADE,
  player_id text NOT NULL,
  gpsl_month text,
  points numeric NOT NULL DEFAULT 0,
  breakdown jsonb NOT NULL DEFAULT '{}'::jsonb,
  UNIQUE (fixture_id, player_id)
);

ALTER TABLE public.gpfl_seasons ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.gpfl_player_prices ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.gpfl_entries ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.gpfl_squad_players ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.gpfl_entry_month_points ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.gpfl_player_fixture_points ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS gpfl_seasons_read ON public.gpfl_seasons;
CREATE POLICY gpfl_seasons_read ON public.gpfl_seasons
  FOR SELECT TO authenticated, anon USING (true);

DROP POLICY IF EXISTS gpfl_prices_read ON public.gpfl_player_prices;
CREATE POLICY gpfl_prices_read ON public.gpfl_player_prices
  FOR SELECT TO authenticated, anon USING (true);

DROP POLICY IF EXISTS gpfl_entries_read ON public.gpfl_entries;
CREATE POLICY gpfl_entries_read ON public.gpfl_entries
  FOR SELECT TO authenticated
  USING (owner_id = auth.uid() OR public.is_gpsl_admin());

DROP POLICY IF EXISTS gpfl_squad_read ON public.gpfl_squad_players;
CREATE POLICY gpfl_squad_read ON public.gpfl_squad_players
  FOR SELECT TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.gpfl_entries e
      WHERE e.id = entry_id AND (e.owner_id = auth.uid() OR public.is_gpsl_admin())
    )
  );

DROP POLICY IF EXISTS gpfl_month_pts_read ON public.gpfl_entry_month_points;
CREATE POLICY gpfl_month_pts_read ON public.gpfl_entry_month_points
  FOR SELECT TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.gpfl_entries e
      WHERE e.id = entry_id AND (e.owner_id = auth.uid() OR public.is_gpsl_admin())
    )
  );

DROP POLICY IF EXISTS gpfl_fix_pts_read ON public.gpfl_player_fixture_points;
CREATE POLICY gpfl_fix_pts_read ON public.gpfl_player_fixture_points
  FOR SELECT TO authenticated, anon USING (true);

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.gpfl_settings_row()
RETURNS public.gpfl_settings
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT s.* FROM public.gpfl_settings s WHERE s.id = 1;
$$;

CREATE OR REPLACE FUNCTION public.gpfl_settings_get()
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT to_jsonb(s.*) FROM public.gpfl_settings s WHERE s.id = 1;
$$;

CREATE OR REPLACE FUNCTION public.gpfl_round_price(p_mv numeric, p_round_to numeric, p_floor numeric)
RETURNS numeric
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT greatest(
    coalesce(p_floor, 4000000),
    round(coalesce(p_mv, 0) / nullif(greatest(p_round_to, 1), 0)) * greatest(p_round_to, 1)
  );
$$;

CREATE OR REPLACE FUNCTION public.gpfl_position_group(p_position text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE public.competition_player_stat_role(p_position)
    WHEN 'goalkeeper' THEN 'gk'
    WHEN 'defender' THEN 'def'
    WHEN 'midfielder' THEN 'mid'
    WHEN 'forward' THEN 'fwd'
    ELSE 'mid'
  END;
$$;

CREATE OR REPLACE FUNCTION public.gpfl_current_season_id()
RETURNS bigint
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT gs.id
  FROM public.gpfl_seasons gs
  JOIN public.competition_seasons cs ON cs.id = gs.competition_season_id
  WHERE cs.is_current = true
  ORDER BY gs.id DESC
  LIMIT 1;
$$;

GRANT EXECUTE ON FUNCTION public.gpfl_settings_get() TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.gpfl_round_price(numeric, numeric, numeric) TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.gpfl_position_group(text) TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.gpfl_current_season_id() TO authenticated, anon;

-- ---------------------------------------------------------------------------
-- Admin settings
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_gpfl_settings_get()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;
  RETURN public.gpfl_settings_get();
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_gpfl_settings_set(p_settings jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_div text[];
  v_ctypes text[];
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;
  IF p_settings IS NULL OR jsonb_typeof(p_settings) <> 'object' THEN
    RAISE EXCEPTION 'p_settings must be a JSON object';
  END IF;

  IF p_settings ? 'divisions' AND jsonb_typeof(p_settings->'divisions') = 'array' THEN
    SELECT array_agg(x) INTO v_div
    FROM jsonb_array_elements_text(p_settings->'divisions') t(x);
  END IF;
  IF p_settings ? 'competition_types' AND jsonb_typeof(p_settings->'competition_types') = 'array' THEN
    SELECT array_agg(x) INTO v_ctypes
    FROM jsonb_array_elements_text(p_settings->'competition_types') t(x);
  END IF;

  UPDATE public.gpfl_settings SET
    enabled = coalesce((p_settings->>'enabled')::boolean, enabled),
    opt_in_only = coalesce((p_settings->>'opt_in_only')::boolean, opt_in_only),
    budget = greatest(1000000, coalesce((p_settings->>'budget')::numeric, budget)),
    squad_size = greatest(11, least(20, coalesce((p_settings->>'squad_size')::int, squad_size))),
    starters = greatest(11, least(11, coalesce((p_settings->>'starters')::int, starters))),
    max_per_club = greatest(1, least(5, coalesce((p_settings->>'max_per_club')::int, max_per_club))),
    slot_gk = greatest(1, least(3, coalesce((p_settings->>'slot_gk')::int, slot_gk))),
    slot_def = greatest(3, least(6, coalesce((p_settings->>'slot_def')::int, slot_def))),
    slot_mid = greatest(3, least(6, coalesce((p_settings->>'slot_mid')::int, slot_mid))),
    slot_fwd = greatest(1, least(4, coalesce((p_settings->>'slot_fwd')::int, slot_fwd))),
    price_round_to = greatest(100000, coalesce((p_settings->>'price_round_to')::numeric, price_round_to)),
    price_floor = greatest(0, coalesce((p_settings->>'price_floor')::numeric, price_floor)),
    free_transfers_per_month = greatest(0, least(15, coalesce((p_settings->>'free_transfers_per_month')::int, free_transfers_per_month))),
    divisions = coalesce(v_div, divisions),
    competition_types = coalesce(v_ctypes, competition_types),
    require_stats_to_score = coalesce((p_settings->>'require_stats_to_score')::boolean, require_stats_to_score),
    pts_appear = coalesce((p_settings->>'pts_appear')::numeric, pts_appear),
    pts_goal_gk = coalesce((p_settings->>'pts_goal_gk')::numeric, pts_goal_gk),
    pts_goal_def = coalesce((p_settings->>'pts_goal_def')::numeric, pts_goal_def),
    pts_goal_mid = coalesce((p_settings->>'pts_goal_mid')::numeric, pts_goal_mid),
    pts_goal_fwd = coalesce((p_settings->>'pts_goal_fwd')::numeric, pts_goal_fwd),
    pts_assist = coalesce((p_settings->>'pts_assist')::numeric, pts_assist),
    pts_cs_gk = coalesce((p_settings->>'pts_cs_gk')::numeric, pts_cs_gk),
    pts_cs_def = coalesce((p_settings->>'pts_cs_def')::numeric, pts_cs_def),
    pts_cs_mid = coalesce((p_settings->>'pts_cs_mid')::numeric, pts_cs_mid),
    pts_cs_fwd = coalesce((p_settings->>'pts_cs_fwd')::numeric, pts_cs_fwd),
    pts_yellow = coalesce((p_settings->>'pts_yellow')::numeric, pts_yellow),
    pts_red = coalesce((p_settings->>'pts_red')::numeric, pts_red),
    pts_potm = coalesce((p_settings->>'pts_potm')::numeric, pts_potm),
    captain_multiplier = greatest(1, coalesce((p_settings->>'captain_multiplier')::numeric, captain_multiplier)),
    updated_at = now(),
    updated_by = auth.uid()
  WHERE id = 1;

  -- Keep slot totals consistent with squad_size when possible
  UPDATE public.gpfl_settings
  SET squad_size = slot_gk + slot_def + slot_mid + slot_fwd
  WHERE id = 1;

  RETURN public.gpfl_settings_get();
END;
$function$;

GRANT EXECUTE ON FUNCTION public.admin_gpfl_settings_get() TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_gpfl_settings_set(jsonb) TO authenticated;

-- ---------------------------------------------------------------------------
-- Open / refresh season prices
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_gpfl_open_season(
  p_competition_season_id bigint DEFAULT NULL,
  p_refresh_prices boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_cfg public.gpfl_settings%rowtype;
  v_comp_id bigint := p_competition_season_id;
  v_gs_id bigint;
  v_created int := 0;
  v_updated int := 0;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  SELECT * INTO v_cfg FROM public.gpfl_settings WHERE id = 1;
  IF NOT coalesce(v_cfg.enabled, true) THEN
    RAISE EXCEPTION 'GPFL is disabled in settings';
  END IF;

  IF v_comp_id IS NULL THEN
    SELECT id INTO v_comp_id
    FROM public.competition_seasons
    WHERE is_current = true
    ORDER BY id DESC
    LIMIT 1;
  END IF;
  IF v_comp_id IS NULL THEN
    RAISE EXCEPTION 'No competition season';
  END IF;

  SELECT id INTO v_gs_id
  FROM public.gpfl_seasons
  WHERE competition_season_id = v_comp_id;

  IF v_gs_id IS NULL THEN
    INSERT INTO public.gpfl_seasons (competition_season_id, status, budget_snapshot, settings_snapshot)
    VALUES (v_comp_id, 'open', v_cfg.budget, to_jsonb(v_cfg))
    RETURNING id INTO v_gs_id;
  ELSE
    UPDATE public.gpfl_seasons
    SET budget_snapshot = v_cfg.budget,
        settings_snapshot = to_jsonb(v_cfg),
        status = CASE WHEN status = 'closed' THEN status ELSE 'open' END
    WHERE id = v_gs_id;
  END IF;

  -- Upsert prices for contracted players in configured divisions
  WITH pool AS (
    SELECT
      p."Konami_ID"::text AS player_id,
      p."Name" AS player_name,
      p."Contracted_Team" AS club_short_name,
      ccs.division,
      p."Position"::text AS position,
      public.gpfl_position_group(p."Position"::text) AS position_group,
      coalesce(p.market_value::numeric, 0) AS mv,
      public.gpfl_round_price(
        coalesce(p.market_value::numeric, 0),
        v_cfg.price_round_to,
        v_cfg.price_floor
      ) AS price
    FROM public."Players" p
    JOIN public.competition_club_seasons ccs
      ON ccs.club_short_name = p."Contracted_Team"
     AND ccs.season_id = v_comp_id
    WHERE p."Contracted_Team" IS NOT NULL
      AND btrim(p."Contracted_Team") <> ''
      AND ccs.division = ANY (v_cfg.divisions)
  )
  INSERT INTO public.gpfl_player_prices AS t (
    gpfl_season_id, player_id, player_name, club_short_name, division,
    position, position_group, market_value_raw, price, eligible
  )
  SELECT
    v_gs_id, pool.player_id, pool.player_name, pool.club_short_name, pool.division,
    pool.position, pool.position_group, pool.mv, pool.price, true
  FROM pool
  ON CONFLICT (gpfl_season_id, player_id) DO UPDATE
    SET player_name = EXCLUDED.player_name,
        club_short_name = EXCLUDED.club_short_name,
        division = EXCLUDED.division,
        position = EXCLUDED.position,
        position_group = EXCLUDED.position_group,
        market_value_raw = EXCLUDED.market_value_raw,
        price = CASE
          WHEN p_refresh_prices THEN EXCLUDED.price
          ELSE t.price
        END,
        eligible = true,
        became_fa_at = NULL
  ;

  GET DIAGNOSTICS v_created = ROW_COUNT;

  -- Mark players no longer contracted in pool as FA (ineligible)
  UPDATE public.gpfl_player_prices pp
  SET eligible = false,
      became_fa_at = coalesce(pp.became_fa_at, now())
  WHERE pp.gpfl_season_id = v_gs_id
    AND pp.eligible = true
    AND NOT EXISTS (
      SELECT 1
      FROM public."Players" p
      JOIN public.competition_club_seasons ccs
        ON ccs.club_short_name = p."Contracted_Team"
       AND ccs.season_id = v_comp_id
      WHERE p."Konami_ID"::text = pp.player_id
        AND p."Contracted_Team" IS NOT NULL
        AND ccs.division = ANY (v_cfg.divisions)
    );

  GET DIAGNOSTICS v_updated = ROW_COUNT;

  RETURN jsonb_build_object(
    'ok', true,
    'gpfl_season_id', v_gs_id,
    'competition_season_id', v_comp_id,
    'budget', v_cfg.budget,
    'price_rows_touched', v_created,
    'marked_fa', v_updated,
    'note', 'GPFL play-money only — no club ledger impact.'
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.admin_gpfl_open_season(bigint, boolean) TO authenticated;

-- ---------------------------------------------------------------------------
-- Sync FA slots: refund purchase price into GPFL budget; mark needs_replace
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.gpfl_sync_free_agents(p_gpfl_season_id bigint DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_gs_id bigint := p_gpfl_season_id;
  v_cfg public.gpfl_settings%rowtype;
  v_comp_id bigint;
  v_refunded int := 0;
  r record;
BEGIN
  SELECT * INTO v_cfg FROM public.gpfl_settings WHERE id = 1;

  IF v_gs_id IS NULL THEN
    v_gs_id := public.gpfl_current_season_id();
  END IF;
  IF v_gs_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_gpfl_season');
  END IF;

  SELECT competition_season_id INTO v_comp_id
  FROM public.gpfl_seasons WHERE id = v_gs_id;

  -- Refresh eligibility flags
  UPDATE public.gpfl_player_prices pp
  SET eligible = false,
      became_fa_at = coalesce(pp.became_fa_at, now())
  WHERE pp.gpfl_season_id = v_gs_id
    AND pp.eligible = true
    AND NOT EXISTS (
      SELECT 1
      FROM public."Players" p
      JOIN public.competition_club_seasons ccs
        ON ccs.club_short_name = p."Contracted_Team"
       AND ccs.season_id = v_comp_id
      WHERE p."Konami_ID"::text = pp.player_id
        AND p."Contracted_Team" IS NOT NULL
        AND ccs.division = ANY (v_cfg.divisions)
    );

  FOR r IN
    SELECT sp.id AS squad_id, sp.entry_id, sp.purchase_price, sp.player_id
    FROM public.gpfl_squad_players sp
    JOIN public.gpfl_entries e ON e.id = sp.entry_id
    JOIN public.gpfl_player_prices pp
      ON pp.gpfl_season_id = e.gpfl_season_id AND pp.player_id = sp.player_id
    WHERE e.gpfl_season_id = v_gs_id
      AND sp.slot_status = 'active'
      AND pp.eligible = false
  LOOP
    UPDATE public.gpfl_squad_players
    SET slot_status = 'needs_replace',
        is_starter = false,
        is_captain = false
    WHERE id = r.squad_id;

    UPDATE public.gpfl_entries
    SET budget_remaining = budget_remaining + r.purchase_price
    WHERE id = r.entry_id;

    v_refunded := v_refunded + 1;
  END LOOP;

  RETURN jsonb_build_object('ok', true, 'refunded_slots', v_refunded);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.gpfl_sync_free_agents(bigint) TO authenticated;

-- ---------------------------------------------------------------------------
-- Opt-in / join
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.gpfl_join(p_team_name text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_cfg public.gpfl_settings%rowtype;
  v_gs_id bigint;
  v_club text;
  v_entry_id bigint;
  v_budget numeric;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  SELECT * INTO v_cfg FROM public.gpfl_settings WHERE id = 1;
  IF NOT coalesce(v_cfg.enabled, true) THEN
    RAISE EXCEPTION 'GPFL is not open';
  END IF;

  v_gs_id := public.gpfl_current_season_id();
  IF v_gs_id IS NULL THEN
    RAISE EXCEPTION 'No GPFL season open — ask admin to Open GPFL season';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.gpfl_seasons WHERE id = v_gs_id AND status = 'closed'
  ) THEN
    RAISE EXCEPTION 'GPFL season is closed';
  END IF;

  v_club := public.my_club_shortname();
  SELECT budget_snapshot INTO v_budget FROM public.gpfl_seasons WHERE id = v_gs_id;
  v_budget := coalesce(v_budget, v_cfg.budget);

  INSERT INTO public.gpfl_entries (
    gpfl_season_id, owner_id, club_short_name, team_name, status,
    budget_remaining, free_transfers_remaining
  )
  VALUES (
    v_gs_id, v_uid, v_club,
    nullif(btrim(coalesce(p_team_name, '')), ''),
    'building',
    v_budget,
    v_cfg.free_transfers_per_month
  )
  ON CONFLICT (gpfl_season_id, owner_id) DO UPDATE
    SET team_name = coalesce(EXCLUDED.team_name, public.gpfl_entries.team_name),
        club_short_name = coalesce(EXCLUDED.club_short_name, public.gpfl_entries.club_short_name),
        status = CASE
          WHEN public.gpfl_entries.status = 'withdrawn' THEN 'building'
          ELSE public.gpfl_entries.status
        END
  RETURNING id INTO v_entry_id;

  RETURN jsonb_build_object(
    'ok', true,
    'entry_id', v_entry_id,
    'budget_remaining', v_budget,
    'note', 'Optional side-game. GPFL budget is not club money.'
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.gpfl_withdraw()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_gs_id bigint;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;
  v_gs_id := public.gpfl_current_season_id();
  IF v_gs_id IS NULL THEN
    RAISE EXCEPTION 'No GPFL season';
  END IF;

  UPDATE public.gpfl_entries
  SET status = 'withdrawn'
  WHERE gpfl_season_id = v_gs_id AND owner_id = v_uid;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_joined');
  END IF;
  RETURN jsonb_build_object('ok', true);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.gpfl_join(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.gpfl_withdraw() TO authenticated;

-- ---------------------------------------------------------------------------
-- Squad management
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.gpfl_my_entry()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_gs_id bigint;
  v_entry public.gpfl_entries%rowtype;
  v_cfg jsonb;
  v_squad jsonb;
  v_season jsonb;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  v_cfg := public.gpfl_settings_get();
  v_gs_id := public.gpfl_current_season_id();

  IF v_gs_id IS NULL THEN
    RETURN jsonb_build_object(
      'ok', true,
      'enabled', coalesce((v_cfg->>'enabled')::boolean, true),
      'joined', false,
      'gpfl_season_id', null,
      'settings', v_cfg
    );
  END IF;

  SELECT to_jsonb(gs.*) INTO v_season
  FROM public.gpfl_seasons gs WHERE gs.id = v_gs_id;

  SELECT * INTO v_entry
  FROM public.gpfl_entries
  WHERE gpfl_season_id = v_gs_id AND owner_id = v_uid;

  IF NOT FOUND OR v_entry.status = 'withdrawn' THEN
    RETURN jsonb_build_object(
      'ok', true,
      'enabled', coalesce((v_cfg->>'enabled')::boolean, true),
      'joined', false,
      'gpfl_season_id', v_gs_id,
      'season', v_season,
      'settings', v_cfg
    );
  END IF;

  -- Keep FA refunds current when viewing
  PERFORM public.gpfl_sync_free_agents(v_gs_id);
  SELECT * INTO v_entry
  FROM public.gpfl_entries WHERE id = v_entry.id;

  SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY
    CASE x.position_group WHEN 'gk' THEN 1 WHEN 'def' THEN 2 WHEN 'mid' THEN 3 ELSE 4 END,
    x.player_name
  ), '[]'::jsonb)
  INTO v_squad
  FROM (
    SELECT
      sp.id,
      sp.player_id,
      sp.position_group,
      sp.purchase_price,
      sp.is_starter,
      sp.is_captain,
      sp.slot_status,
      pp.player_name,
      pp.club_short_name,
      pp.division,
      pp.position,
      pp.price AS current_price,
      pp.eligible
    FROM public.gpfl_squad_players sp
    LEFT JOIN public.gpfl_player_prices pp
      ON pp.gpfl_season_id = v_gs_id AND pp.player_id = sp.player_id
    WHERE sp.entry_id = v_entry.id
  ) x;

  RETURN jsonb_build_object(
    'ok', true,
    'enabled', coalesce((v_cfg->>'enabled')::boolean, true),
    'joined', true,
    'gpfl_season_id', v_gs_id,
    'season', v_season,
    'settings', v_cfg,
    'entry', to_jsonb(v_entry),
    'squad', v_squad
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.gpfl_list_players(
  p_position_group text DEFAULT NULL,
  p_division text DEFAULT NULL,
  p_club text DEFAULT NULL,
  p_search text DEFAULT NULL,
  p_max_price numeric DEFAULT NULL,
  p_limit int DEFAULT 80,
  p_offset int DEFAULT 0
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_gs_id bigint := public.gpfl_current_season_id();
  v_rows jsonb;
  v_total int;
BEGIN
  IF v_gs_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_gpfl_season', 'players', '[]'::jsonb);
  END IF;

  SELECT count(*)::int INTO v_total
  FROM public.gpfl_player_prices pp
  WHERE pp.gpfl_season_id = v_gs_id
    AND pp.eligible = true
    AND (p_position_group IS NULL OR pp.position_group = lower(p_position_group))
    AND (p_division IS NULL OR pp.division = p_division)
    AND (p_club IS NULL OR pp.club_short_name = p_club)
    AND (p_max_price IS NULL OR pp.price <= p_max_price)
    AND (
      p_search IS NULL OR btrim(p_search) = ''
      OR pp.player_name ILIKE '%' || btrim(p_search) || '%'
      OR pp.club_short_name ILIKE '%' || btrim(p_search) || '%'
    );

  SELECT coalesce(jsonb_agg(to_jsonb(r)), '[]'::jsonb)
  INTO v_rows
  FROM (
    SELECT
      pp.player_id,
      pp.player_name,
      pp.club_short_name,
      pp.division,
      pp.position,
      pp.position_group,
      pp.price,
      pp.market_value_raw
    FROM public.gpfl_player_prices pp
    WHERE pp.gpfl_season_id = v_gs_id
      AND pp.eligible = true
      AND (p_position_group IS NULL OR pp.position_group = lower(p_position_group))
      AND (p_division IS NULL OR pp.division = p_division)
      AND (p_club IS NULL OR pp.club_short_name = p_club)
      AND (p_max_price IS NULL OR pp.price <= p_max_price)
      AND (
        p_search IS NULL OR btrim(p_search) = ''
        OR pp.player_name ILIKE '%' || btrim(p_search) || '%'
        OR pp.club_short_name ILIKE '%' || btrim(p_search) || '%'
      )
    ORDER BY pp.price DESC, pp.player_name
    LIMIT greatest(1, least(coalesce(p_limit, 80), 200))
    OFFSET greatest(0, coalesce(p_offset, 0))
  ) r;

  RETURN jsonb_build_object(
    'ok', true,
    'total', v_total,
    'players', v_rows
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.gpfl_add_player(p_player_id text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_cfg public.gpfl_settings%rowtype;
  v_gs_id bigint;
  v_entry public.gpfl_entries%rowtype;
  v_price public.gpfl_player_prices%rowtype;
  v_count int;
  v_club_count int;
  v_pos_count int;
  v_slot_cap int;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  SELECT * INTO v_cfg FROM public.gpfl_settings WHERE id = 1;
  IF NOT coalesce(v_cfg.enabled, true) THEN RAISE EXCEPTION 'GPFL disabled'; END IF;

  v_gs_id := public.gpfl_current_season_id();
  PERFORM public.gpfl_sync_free_agents(v_gs_id);

  SELECT * INTO v_entry
  FROM public.gpfl_entries
  WHERE gpfl_season_id = v_gs_id AND owner_id = v_uid AND status IN ('building', 'active');
  IF NOT FOUND THEN RAISE EXCEPTION 'Join GPFL first'; END IF;

  SELECT * INTO v_price
  FROM public.gpfl_player_prices
  WHERE gpfl_season_id = v_gs_id AND player_id = p_player_id AND eligible = true;
  IF NOT FOUND THEN RAISE EXCEPTION 'Player not in GPFL pool'; END IF;

  IF EXISTS (
    SELECT 1 FROM public.gpfl_squad_players
    WHERE entry_id = v_entry.id AND player_id = p_player_id AND slot_status = 'active'
  ) THEN
    RAISE EXCEPTION 'Already in your squad';
  END IF;

  -- Replacing an FA slot for same player id should not happen; drop needs_replace row if same id
  DELETE FROM public.gpfl_squad_players
  WHERE entry_id = v_entry.id AND player_id = p_player_id AND slot_status = 'needs_replace';

  SELECT count(*)::int INTO v_count
  FROM public.gpfl_squad_players
  WHERE entry_id = v_entry.id AND slot_status = 'active';
  IF v_count >= v_cfg.squad_size THEN
    RAISE EXCEPTION 'Squad full (% players)', v_cfg.squad_size;
  END IF;

  SELECT count(*)::int INTO v_club_count
  FROM public.gpfl_squad_players sp
  JOIN public.gpfl_player_prices pp
    ON pp.gpfl_season_id = v_gs_id AND pp.player_id = sp.player_id
  WHERE sp.entry_id = v_entry.id
    AND sp.slot_status = 'active'
    AND pp.club_short_name = v_price.club_short_name;
  IF v_club_count >= v_cfg.max_per_club THEN
    RAISE EXCEPTION 'Max % players from one club', v_cfg.max_per_club;
  END IF;

  SELECT count(*)::int INTO v_pos_count
  FROM public.gpfl_squad_players
  WHERE entry_id = v_entry.id
    AND slot_status = 'active'
    AND position_group = v_price.position_group;

  v_slot_cap := CASE v_price.position_group
    WHEN 'gk' THEN v_cfg.slot_gk
    WHEN 'def' THEN v_cfg.slot_def
    WHEN 'mid' THEN v_cfg.slot_mid
    ELSE v_cfg.slot_fwd
  END;
  IF v_pos_count >= v_slot_cap THEN
    RAISE EXCEPTION 'No % slots left', upper(v_price.position_group);
  END IF;

  IF v_entry.budget_remaining < v_price.price THEN
    RAISE EXCEPTION 'Not enough GPFL budget (need ₿%, have ₿%)',
      round(v_price.price), round(v_entry.budget_remaining);
  END IF;

  -- Transfer cost after squad confirmed (forced FA replacements are free)
  IF v_entry.status = 'active' THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.gpfl_squad_players
      WHERE entry_id = v_entry.id AND slot_status = 'needs_replace'
    ) THEN
      IF v_entry.free_transfers_remaining <= 0 THEN
        RAISE EXCEPTION 'No free transfers left this month';
      END IF;
      UPDATE public.gpfl_entries
      SET free_transfers_remaining = free_transfers_remaining - 1
      WHERE id = v_entry.id;
    END IF;
  END IF;

  INSERT INTO public.gpfl_squad_players (
    entry_id, player_id, position_group, purchase_price, slot_status
  ) VALUES (
    v_entry.id, p_player_id, v_price.position_group, v_price.price, 'active'
  );

  UPDATE public.gpfl_entries
  SET budget_remaining = budget_remaining - v_price.price
  WHERE id = v_entry.id;

  RETURN public.gpfl_my_entry();
END;
$function$;

CREATE OR REPLACE FUNCTION public.gpfl_remove_player(p_player_id text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_gs_id bigint;
  v_entry public.gpfl_entries%rowtype;
  v_sp public.gpfl_squad_players%rowtype;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  v_gs_id := public.gpfl_current_season_id();

  SELECT * INTO v_entry
  FROM public.gpfl_entries
  WHERE gpfl_season_id = v_gs_id AND owner_id = v_uid AND status IN ('building', 'active');
  IF NOT FOUND THEN RAISE EXCEPTION 'Join GPFL first'; END IF;

  SELECT * INTO v_sp
  FROM public.gpfl_squad_players
  WHERE entry_id = v_entry.id AND player_id = p_player_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Player not in squad'; END IF;

  -- Outgoing half of a transfer is free; free-transfer token is spent on gpfl_add_player.
  -- Refund purchase price (FA needs_replace already refunded once).
  IF v_sp.slot_status = 'active' THEN
    UPDATE public.gpfl_entries
    SET budget_remaining = budget_remaining + v_sp.purchase_price
    WHERE id = v_entry.id;
  END IF;

  DELETE FROM public.gpfl_squad_players WHERE id = v_sp.id;

  RETURN public.gpfl_my_entry();
END;
$function$;

CREATE OR REPLACE FUNCTION public.gpfl_set_xi(
  p_starter_ids text[],
  p_captain_id text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_cfg public.gpfl_settings%rowtype;
  v_gs_id bigint;
  v_entry public.gpfl_entries%rowtype;
  v_n int;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  SELECT * INTO v_cfg FROM public.gpfl_settings WHERE id = 1;
  v_gs_id := public.gpfl_current_season_id();

  SELECT * INTO v_entry
  FROM public.gpfl_entries
  WHERE gpfl_season_id = v_gs_id AND owner_id = v_uid AND status IN ('building', 'active');
  IF NOT FOUND THEN RAISE EXCEPTION 'Join GPFL first'; END IF;

  IF p_starter_ids IS NULL OR coalesce(array_length(p_starter_ids, 1), 0) <> v_cfg.starters THEN
    RAISE EXCEPTION 'Select exactly % starters', v_cfg.starters;
  END IF;

  SELECT count(*)::int INTO v_n
  FROM public.gpfl_squad_players
  WHERE entry_id = v_entry.id
    AND slot_status = 'active'
    AND player_id = ANY (p_starter_ids);
  IF v_n <> v_cfg.starters THEN
    RAISE EXCEPTION 'All starters must be active squad players';
  END IF;

  IF p_captain_id IS NULL OR NOT (p_captain_id = ANY (p_starter_ids)) THEN
    RAISE EXCEPTION 'Captain must be one of the starters';
  END IF;

  UPDATE public.gpfl_squad_players
  SET is_starter = false, is_captain = false
  WHERE entry_id = v_entry.id;

  UPDATE public.gpfl_squad_players
  SET is_starter = true,
      is_captain = (player_id = p_captain_id)
  WHERE entry_id = v_entry.id
    AND player_id = ANY (p_starter_ids);

  RETURN public.gpfl_my_entry();
END;
$function$;

CREATE OR REPLACE FUNCTION public.gpfl_confirm_squad()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_cfg public.gpfl_settings%rowtype;
  v_gs_id bigint;
  v_entry public.gpfl_entries%rowtype;
  v_n int;
  v_starters int;
  v_caps int;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  SELECT * INTO v_cfg FROM public.gpfl_settings WHERE id = 1;
  v_gs_id := public.gpfl_current_season_id();
  PERFORM public.gpfl_sync_free_agents(v_gs_id);

  SELECT * INTO v_entry
  FROM public.gpfl_entries
  WHERE gpfl_season_id = v_gs_id AND owner_id = v_uid AND status IN ('building', 'active');
  IF NOT FOUND THEN RAISE EXCEPTION 'Join GPFL first'; END IF;

  SELECT count(*)::int INTO v_n
  FROM public.gpfl_squad_players
  WHERE entry_id = v_entry.id AND slot_status = 'active';
  IF v_n <> v_cfg.squad_size THEN
    RAISE EXCEPTION 'Need a full squad of % (have %)', v_cfg.squad_size, v_n;
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.gpfl_squad_players
    WHERE entry_id = v_entry.id AND slot_status = 'needs_replace'
  ) THEN
    RAISE EXCEPTION 'Replace free-agent slots before confirming';
  END IF;

  SELECT count(*) FILTER (WHERE is_starter)::int,
         count(*) FILTER (WHERE is_captain)::int
  INTO v_starters, v_caps
  FROM public.gpfl_squad_players
  WHERE entry_id = v_entry.id AND slot_status = 'active';

  IF v_starters <> v_cfg.starters OR v_caps <> 1 THEN
    RAISE EXCEPTION 'Set % starters and exactly 1 captain', v_cfg.starters;
  END IF;

  UPDATE public.gpfl_entries
  SET status = 'active',
      confirmed_at = coalesce(confirmed_at, now()),
      free_transfers_remaining = v_cfg.free_transfers_per_month
  WHERE id = v_entry.id;

  RETURN public.gpfl_my_entry();
END;
$function$;

GRANT EXECUTE ON FUNCTION public.gpfl_my_entry() TO authenticated;
GRANT EXECUTE ON FUNCTION public.gpfl_list_players(text, text, text, text, numeric, int, int) TO authenticated;
GRANT EXECUTE ON FUNCTION public.gpfl_add_player(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.gpfl_remove_player(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.gpfl_set_xi(text[], text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.gpfl_confirm_squad() TO authenticated;

-- ---------------------------------------------------------------------------
-- Scoring (league fixtures; configurable points; Y/R included)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.gpfl_score_player_fixture(
  p_fixture_id bigint,
  p_player_id text
)
RETURNS numeric
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_cfg public.gpfl_settings%rowtype;
  v_f public.competition_fixtures%rowtype;
  v_m public.competition_match_player_stats%rowtype;
  v_pos_group text;
  v_pts numeric := 0;
  v_conceded int;
  v_breakdown jsonb := '{}'::jsonb;
  v_gs_id bigint;
  v_goal_pts numeric;
  v_cs_pts numeric;
BEGIN
  SELECT * INTO v_cfg FROM public.gpfl_settings WHERE id = 1;
  SELECT * INTO v_f FROM public.competition_fixtures WHERE id = p_fixture_id;
  IF NOT FOUND OR v_f.status <> 'played' THEN
    RETURN 0;
  END IF;
  IF NOT (v_f.competition_type = ANY (v_cfg.competition_types)) THEN
    RETURN 0;
  END IF;

  SELECT * INTO v_m
  FROM public.competition_match_player_stats
  WHERE fixture_id = p_fixture_id AND player_id = p_player_id;

  IF NOT FOUND THEN
    IF v_cfg.require_stats_to_score THEN
      RETURN 0;
    END IF;
    RETURN 0;
  END IF;

  IF NOT coalesce(v_m.appeared, true) THEN
    RETURN 0;
  END IF;

  v_pos_group := public.gpfl_position_group(
    (SELECT p."Position"::text FROM public."Players" p WHERE p."Konami_ID"::text = p_player_id LIMIT 1)
  );

  v_pts := v_pts + v_cfg.pts_appear;
  v_breakdown := v_breakdown || jsonb_build_object('appear', v_cfg.pts_appear);

  v_goal_pts := CASE v_pos_group
    WHEN 'gk' THEN v_cfg.pts_goal_gk
    WHEN 'def' THEN v_cfg.pts_goal_def
    WHEN 'mid' THEN v_cfg.pts_goal_mid
    ELSE v_cfg.pts_goal_fwd
  END;
  IF coalesce(v_m.goals, 0) > 0 THEN
    v_pts := v_pts + v_m.goals * v_goal_pts;
    v_breakdown := v_breakdown || jsonb_build_object('goals', v_m.goals * v_goal_pts);
  END IF;

  IF coalesce(v_m.assists, 0) > 0 THEN
    v_pts := v_pts + v_m.assists * v_cfg.pts_assist;
    v_breakdown := v_breakdown || jsonb_build_object('assists', v_m.assists * v_cfg.pts_assist);
  END IF;

  v_conceded := public.competition_player_conceded_in_fixture(p_fixture_id, v_m.club_short_name);
  IF v_conceded = 0 AND coalesce(v_m.started, false) THEN
    v_cs_pts := CASE v_pos_group
      WHEN 'gk' THEN v_cfg.pts_cs_gk
      WHEN 'def' THEN v_cfg.pts_cs_def
      WHEN 'mid' THEN v_cfg.pts_cs_mid
      ELSE v_cfg.pts_cs_fwd
    END;
    IF v_cs_pts <> 0 THEN
      v_pts := v_pts + v_cs_pts;
      v_breakdown := v_breakdown || jsonb_build_object('clean_sheet', v_cs_pts);
    END IF;
  END IF;

  IF coalesce(v_m.yellow_card, false) THEN
    v_pts := v_pts + v_cfg.pts_yellow;
    v_breakdown := v_breakdown || jsonb_build_object('yellow', v_cfg.pts_yellow);
  END IF;
  IF coalesce(v_m.red_card, false) THEN
    v_pts := v_pts + v_cfg.pts_red;
    v_breakdown := v_breakdown || jsonb_build_object('red', v_cfg.pts_red);
  END IF;
  IF coalesce(v_m.is_player_of_match, false) THEN
    v_pts := v_pts + v_cfg.pts_potm;
    v_breakdown := v_breakdown || jsonb_build_object('potm', v_cfg.pts_potm);
  END IF;

  SELECT id INTO v_gs_id
  FROM public.gpfl_seasons
  WHERE competition_season_id = v_f.season_id
  ORDER BY id DESC
  LIMIT 1;

  IF v_gs_id IS NOT NULL THEN
    INSERT INTO public.gpfl_player_fixture_points (
      gpfl_season_id, fixture_id, player_id, gpsl_month, points, breakdown
    ) VALUES (
      v_gs_id, p_fixture_id, p_player_id, v_f.gpsl_month, v_pts, v_breakdown
    )
    ON CONFLICT (fixture_id, player_id) DO UPDATE
      SET points = EXCLUDED.points,
          breakdown = EXCLUDED.breakdown,
          gpsl_month = EXCLUDED.gpsl_month;
  END IF;

  RETURN v_pts;
END;
$function$;

CREATE OR REPLACE FUNCTION public.gpfl_score_month(p_gpsl_month text, p_gpfl_season_id bigint DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_cfg public.gpfl_settings%rowtype;
  v_gs_id bigint := p_gpfl_season_id;
  v_comp_id bigint;
  v_month text := lower(btrim(coalesce(p_gpsl_month, '')));
  v_entries int := 0;
  v_entry record;
  v_sp record;
  v_fx record;
  v_pts numeric;
  v_line numeric;
  v_mult numeric;
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.is_gpsl_admin()
     AND current_user NOT IN ('postgres', 'supabase_admin', 'service_role') THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  SELECT * INTO v_cfg FROM public.gpfl_settings WHERE id = 1;
  IF v_gs_id IS NULL THEN
    v_gs_id := public.gpfl_current_season_id();
  END IF;
  IF v_gs_id IS NULL THEN
    RAISE EXCEPTION 'No GPFL season';
  END IF;
  IF v_month = '' THEN
    RAISE EXCEPTION 'gpsl_month required';
  END IF;

  SELECT competition_season_id INTO v_comp_id FROM public.gpfl_seasons WHERE id = v_gs_id;

  FOR v_fx IN
    SELECT f.id AS fixture_id, m.player_id
    FROM public.competition_fixtures f
    JOIN public.competition_match_player_stats m ON m.fixture_id = f.id
    WHERE f.season_id = v_comp_id
      AND f.status = 'played'
      AND lower(coalesce(f.gpsl_month, '')) = v_month
      AND f.competition_type = ANY (v_cfg.competition_types)
  LOOP
    PERFORM public.gpfl_score_player_fixture(v_fx.fixture_id, v_fx.player_id);
  END LOOP;

  FOR v_entry IN
    SELECT * FROM public.gpfl_entries
    WHERE gpfl_season_id = v_gs_id AND status = 'active'
  LOOP
    v_pts := 0;
    FOR v_sp IN
      SELECT * FROM public.gpfl_squad_players
      WHERE entry_id = v_entry.id AND slot_status = 'active' AND is_starter = true
    LOOP
      SELECT coalesce(sum(pfp.points), 0) INTO v_line
      FROM public.gpfl_player_fixture_points pfp
      JOIN public.competition_fixtures f ON f.id = pfp.fixture_id
      WHERE pfp.gpfl_season_id = v_gs_id
        AND pfp.player_id = v_sp.player_id
        AND lower(coalesce(pfp.gpsl_month, f.gpsl_month, '')) = v_month;

      v_mult := CASE WHEN v_sp.is_captain THEN v_cfg.captain_multiplier ELSE 1 END;
      v_pts := v_pts + coalesce(v_line, 0) * v_mult;
    END LOOP;

    INSERT INTO public.gpfl_entry_month_points (entry_id, gpsl_month, points, scored_at)
    VALUES (v_entry.id, v_month, v_pts, now())
    ON CONFLICT (entry_id, gpsl_month) DO UPDATE
      SET points = EXCLUDED.points, scored_at = now();

    UPDATE public.gpfl_entries e
    SET total_points = coalesce((
          SELECT sum(m.points) FROM public.gpfl_entry_month_points m WHERE m.entry_id = e.id
        ), 0),
        free_transfers_remaining = v_cfg.free_transfers_per_month,
        transfers_used_month = v_month
    WHERE e.id = v_entry.id;

    v_entries := v_entries + 1;
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true,
    'gpsl_month', v_month,
    'entries_scored', v_entries
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.gpfl_leaderboard(p_limit int DEFAULT 60)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_gs_id bigint := public.gpfl_current_season_id();
  v_rows jsonb;
BEGIN
  IF v_gs_id IS NULL THEN
    RETURN jsonb_build_object('ok', true, 'rows', '[]'::jsonb);
  END IF;

  SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY r.rank), '[]'::jsonb)
  INTO v_rows
  FROM (
    SELECT
      row_number() OVER (ORDER BY e.total_points DESC, e.joined_at)::int AS rank,
      e.team_name,
      e.club_short_name,
      e.total_points,
      e.status,
      e.owner_id = auth.uid() AS is_me
    FROM public.gpfl_entries e
    WHERE e.gpfl_season_id = v_gs_id
      AND e.status IN ('active', 'building')
    ORDER BY e.total_points DESC, e.joined_at
    LIMIT greatest(1, least(coalesce(p_limit, 60), 200))
  ) r;

  RETURN jsonb_build_object('ok', true, 'gpfl_season_id', v_gs_id, 'rows', v_rows);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.gpfl_score_player_fixture(bigint, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.gpfl_score_month(text, bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.gpfl_leaderboard(int) TO authenticated;

-- Public leaderboard view (no owner uuid leak beyond is_me via RPC)
CREATE OR REPLACE VIEW public.gpfl_leaderboard_public
WITH (security_invoker = true)
AS
SELECT
  e.gpfl_season_id,
  e.team_name,
  e.club_short_name,
  e.total_points,
  e.status
FROM public.gpfl_entries e
WHERE e.status IN ('active', 'building');

GRANT SELECT ON public.gpfl_leaderboard_public TO authenticated, anon;
