-- =============================================================================
-- Prize money templates that survive league reset
--
-- Cup + league prize configs are season-scoped and CASCADE-delete with seasons.
-- These global template tables have no season_id, so a full league reset keeps them.
--
-- Flow:
--   1) Admin → Cup / League prize money → "Save as reset template"
--      (optional: reset also auto-snapshots the latest season before wipe)
--   2) After reset, create a new season → templates are applied automatically
--      (previous-season copy still preferred when a prior season exists)
--
-- Safe re-run.
-- =============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- Tables (no season FK — survive DELETE FROM competition_seasons)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.competition_cup_prize_template (
  cup_code text NOT NULL,
  stage text NOT NULL,
  amount numeric(14, 2) NOT NULL DEFAULT 0 CHECK (amount >= 0),
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (cup_code, stage)
);

CREATE TABLE IF NOT EXISTS public.competition_league_prize_template (
  division text NOT NULL,
  position smallint NOT NULL CHECK (position BETWEEN 1 AND 20),
  amount numeric(14, 2) NOT NULL DEFAULT 0 CHECK (amount >= 0),
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (division, position)
);

COMMENT ON TABLE public.competition_cup_prize_template IS
  'Global cup prize amounts — survives league reset; applied when creating a season with no prior season config.';
COMMENT ON TABLE public.competition_league_prize_template IS
  'Global league prize amounts — survives league reset; applied when creating a season with no prior season config.';

ALTER TABLE public.competition_cup_prize_template ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.competition_league_prize_template ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS competition_cup_prize_template_select ON public.competition_cup_prize_template;
CREATE POLICY competition_cup_prize_template_select
  ON public.competition_cup_prize_template
  FOR SELECT TO authenticated
  USING (true);

DROP POLICY IF EXISTS competition_league_prize_template_select ON public.competition_league_prize_template;
CREATE POLICY competition_league_prize_template_select
  ON public.competition_league_prize_template
  FOR SELECT TO authenticated
  USING (true);

GRANT SELECT ON public.competition_cup_prize_template TO authenticated;
GRANT SELECT ON public.competition_league_prize_template TO authenticated;

-- ---------------------------------------------------------------------------
-- Snapshot season → templates
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.competition_admin_save_cup_prize_template(
  p_season_id bigint DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season_id bigint := p_season_id;
  v_n int := 0;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF v_season_id IS NULL THEN
    SELECT id INTO v_season_id
    FROM public.competition_seasons
    WHERE is_current = true
    ORDER BY id DESC
    LIMIT 1;
  END IF;
  IF v_season_id IS NULL THEN
    SELECT id INTO v_season_id
    FROM public.competition_seasons
    ORDER BY id DESC
    LIMIT 1;
  END IF;
  IF v_season_id IS NULL THEN
    RAISE EXCEPTION 'No season to snapshot';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.competition_cup_prize_config WHERE season_id = v_season_id
  ) THEN
    RAISE EXCEPTION 'Season % has no cup prize config to save', v_season_id;
  END IF;

  DELETE FROM public.competition_cup_prize_template WHERE true;

  INSERT INTO public.competition_cup_prize_template (cup_code, stage, amount, updated_at)
  SELECT c.cup_code, c.stage, c.amount, now()
  FROM public.competition_cup_prize_config c
  WHERE c.season_id = v_season_id;

  GET DIAGNOSTICS v_n = ROW_COUNT;

  RETURN jsonb_build_object(
    'ok', true,
    'season_id', v_season_id,
    'rows_saved', v_n
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.competition_admin_save_league_prize_template(
  p_season_id bigint DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season_id bigint := p_season_id;
  v_n int := 0;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF v_season_id IS NULL THEN
    SELECT id INTO v_season_id
    FROM public.competition_seasons
    WHERE is_current = true
    ORDER BY id DESC
    LIMIT 1;
  END IF;
  IF v_season_id IS NULL THEN
    SELECT id INTO v_season_id
    FROM public.competition_seasons
    ORDER BY id DESC
    LIMIT 1;
  END IF;
  IF v_season_id IS NULL THEN
    RAISE EXCEPTION 'No season to snapshot';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.competition_league_prize_config WHERE season_id = v_season_id
  ) THEN
    RAISE EXCEPTION 'Season % has no league prize config to save', v_season_id;
  END IF;

  DELETE FROM public.competition_league_prize_template WHERE true;

  INSERT INTO public.competition_league_prize_template (division, position, amount, updated_at)
  SELECT c.division, c.position, c.amount, now()
  FROM public.competition_league_prize_config c
  WHERE c.season_id = v_season_id;

  GET DIAGNOSTICS v_n = ROW_COUNT;

  RETURN jsonb_build_object(
    'ok', true,
    'season_id', v_season_id,
    'rows_saved', v_n
  );
END;
$function$;

-- Snapshot both (used by reset + combined admin action)
CREATE OR REPLACE FUNCTION public.competition_admin_save_prize_templates(
  p_season_id bigint DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season_id bigint := p_season_id;
  v_cup jsonb := '{}'::jsonb;
  v_league jsonb := '{}'::jsonb;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF v_season_id IS NULL THEN
    SELECT id INTO v_season_id
    FROM public.competition_seasons
    WHERE is_current = true
    ORDER BY id DESC
    LIMIT 1;
  END IF;
  IF v_season_id IS NULL THEN
    SELECT id INTO v_season_id
    FROM public.competition_seasons
    ORDER BY id DESC
    LIMIT 1;
  END IF;

  IF v_season_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_season');
  END IF;

  BEGIN
    v_cup := public.competition_admin_save_cup_prize_template(v_season_id);
  EXCEPTION WHEN OTHERS THEN
    v_cup := jsonb_build_object('ok', false, 'error', SQLERRM);
  END;

  BEGIN
    v_league := public.competition_admin_save_league_prize_template(v_season_id);
  EXCEPTION WHEN OTHERS THEN
    v_league := jsonb_build_object('ok', false, 'error', SQLERRM);
  END;

  RETURN jsonb_build_object(
    'ok', coalesce((v_cup->>'ok')::boolean, false)
      OR coalesce((v_league->>'ok')::boolean, false),
    'season_id', v_season_id,
    'cup', v_cup,
    'league', v_league
  );
END;
$function$;

-- ---------------------------------------------------------------------------
-- Apply templates → season
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.competition_admin_apply_cup_prize_template(
  p_season_id bigint DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season_id bigint := p_season_id;
  v_n int := 0;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF v_season_id IS NULL THEN
    SELECT id INTO v_season_id
    FROM public.competition_seasons
    WHERE is_current = true
    ORDER BY id DESC
    LIMIT 1;
  END IF;
  IF v_season_id IS NULL THEN
    RAISE EXCEPTION 'No target season';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM public.competition_cup_prize_template) THEN
    RETURN jsonb_build_object(
      'ok', false,
      'reason', 'no_template',
      'season_id', v_season_id,
      'rows_applied', 0
    );
  END IF;

  INSERT INTO public.competition_cup_prize_config (season_id, cup_code, stage, amount)
  SELECT v_season_id, t.cup_code, t.stage, t.amount
  FROM public.competition_cup_prize_template t
  ON CONFLICT (season_id, cup_code, stage)
  DO UPDATE SET amount = EXCLUDED.amount;

  GET DIAGNOSTICS v_n = ROW_COUNT;

  RETURN jsonb_build_object(
    'ok', true,
    'season_id', v_season_id,
    'rows_applied', v_n
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.competition_admin_apply_league_prize_template(
  p_season_id bigint DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season_id bigint := p_season_id;
  v_n int := 0;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF v_season_id IS NULL THEN
    SELECT id INTO v_season_id
    FROM public.competition_seasons
    WHERE is_current = true
    ORDER BY id DESC
    LIMIT 1;
  END IF;
  IF v_season_id IS NULL THEN
    RAISE EXCEPTION 'No target season';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM public.competition_league_prize_template) THEN
    RETURN jsonb_build_object(
      'ok', false,
      'reason', 'no_template',
      'season_id', v_season_id,
      'rows_applied', 0
    );
  END IF;

  INSERT INTO public.competition_league_prize_config (
    season_id, division, position, amount
  )
  SELECT v_season_id, t.division, t.position, t.amount
  FROM public.competition_league_prize_template t
  ON CONFLICT (season_id, division, position)
  DO UPDATE SET amount = EXCLUDED.amount, updated_at = now();

  GET DIAGNOSTICS v_n = ROW_COUNT;

  RETURN jsonb_build_object(
    'ok', true,
    'season_id', v_season_id,
    'rows_applied', v_n
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.competition_admin_apply_prize_templates(
  p_season_id bigint DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_cup jsonb;
  v_league jsonb;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  v_cup := public.competition_admin_apply_cup_prize_template(p_season_id);
  v_league := public.competition_admin_apply_league_prize_template(p_season_id);

  RETURN jsonb_build_object(
    'ok', coalesce((v_cup->>'ok')::boolean, false)
      OR coalesce((v_league->>'ok')::boolean, false),
    'cup', v_cup,
    'league', v_league
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_admin_save_cup_prize_template(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.competition_admin_save_league_prize_template(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.competition_admin_save_prize_templates(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.competition_admin_apply_cup_prize_template(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.competition_admin_apply_league_prize_template(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.competition_admin_apply_prize_templates(bigint) TO authenticated;

-- ---------------------------------------------------------------------------
-- Create season: prefer previous season copy; else apply reset templates
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.competition_create_season(p_label text)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_label text := trim(p_label);
  v_season_id bigint;
  v_club_count bigint;
  v_prev bigint;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF v_label IS NULL OR v_label = '' THEN
    RAISE EXCEPTION 'Season label is required';
  END IF;

  INSERT INTO public.competition_seasons (label, status, is_current)
  VALUES (v_label, 'preseason', false)
  RETURNING id INTO v_season_id;

  INSERT INTO public.competition_club_seasons (season_id, club_short_name, division)
  SELECT v_season_id, c."ShortName", 'unassigned'
  FROM public."Clubs" c
  WHERE c."ShortName" <> 'FOREIGN'
  ORDER BY c."ShortName";

  GET DIAGNOSTICS v_club_count = ROW_COUNT;

  IF v_club_count <> 60 THEN
    RAISE EXCEPTION 'Expected 60 clubs, found %', v_club_count;
  END IF;

  SELECT s.id INTO v_prev
  FROM public.competition_seasons s
  WHERE s.id < v_season_id
  ORDER BY s.id DESC
  LIMIT 1;

  IF v_prev IS NOT NULL THEN
    IF to_regprocedure('public.admin_gpdb_copy_season_exclusions(bigint, bigint)') IS NOT NULL
       AND (
         EXISTS (
           SELECT 1 FROM public.gpdb_season_excluded_players ep WHERE ep.season_id = v_prev
         )
         OR EXISTS (
           SELECT 1 FROM public.gpdb_season_excluded_nations en WHERE en.season_id = v_prev
         )
       )
    THEN
      PERFORM public.admin_gpdb_copy_season_exclusions(v_prev, v_season_id);
    END IF;

    IF to_regprocedure('public.competition_admin_copy_cup_prizes(bigint, bigint)') IS NOT NULL
       AND EXISTS (
         SELECT 1 FROM public.competition_cup_prize_config c WHERE c.season_id = v_prev
       )
    THEN
      PERFORM public.competition_admin_copy_cup_prizes(v_prev, v_season_id);
    ELSIF EXISTS (SELECT 1 FROM public.competition_cup_prize_template) THEN
      PERFORM public.competition_admin_apply_cup_prize_template(v_season_id);
    END IF;

    IF to_regprocedure('public.competition_admin_copy_league_prizes(bigint, bigint)') IS NOT NULL
       AND to_regclass('public.competition_league_prize_config') IS NOT NULL
       AND EXISTS (
         SELECT 1 FROM public.competition_league_prize_config c WHERE c.season_id = v_prev
       )
    THEN
      PERFORM public.competition_admin_copy_league_prizes(v_prev, v_season_id);
    ELSIF EXISTS (SELECT 1 FROM public.competition_league_prize_template) THEN
      PERFORM public.competition_admin_apply_league_prize_template(v_season_id);
    END IF;
  ELSE
    -- First season after reset (or inaugural): restore from templates if present
    IF EXISTS (SELECT 1 FROM public.competition_cup_prize_template) THEN
      PERFORM public.competition_admin_apply_cup_prize_template(v_season_id);
    END IF;
    IF EXISTS (SELECT 1 FROM public.competition_league_prize_template) THEN
      PERFORM public.competition_admin_apply_league_prize_template(v_season_id);
    END IF;
  END IF;

  -- Contract tick is intentionally NOT here — call contract_tick_season_rollover()
  -- as a separate admin step (avoids API gateway timeouts).

  RETURN v_season_id;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_create_season(text) TO authenticated;

-- ---------------------------------------------------------------------------
-- League reset: auto-snapshot prizes before seasons are wiped
-- ---------------------------------------------------------------------------
DO $hook_reset$
DECLARE
  v_def text;
  v_new text;
  v_marker text := 'DELETE FROM public.competition_seasons WHERE true;';
  v_inject text :=
    E'-- Snapshot cup/league prize templates (survive season wipe)\n'
    || E'  IF to_regprocedure(''public.competition_admin_save_prize_templates(bigint)'') IS NOT NULL THEN\n'
    || E'    BEGIN\n'
    || E'      PERFORM public.competition_admin_save_prize_templates(NULL);\n'
    || E'    EXCEPTION WHEN OTHERS THEN\n'
    || E'      RAISE NOTICE ''prize template snapshot skipped: %'', SQLERRM;\n'
    || E'    END;\n'
    || E'  END IF;\n\n'
    || E'  DELETE FROM public.competition_seasons WHERE true;';
BEGIN
  IF to_regprocedure('public.admin_test_reset_execute(text, jsonb)') IS NULL THEN
    RAISE NOTICE 'admin_test_reset_execute not found — skip reset hook';
    RETURN;
  END IF;

  SELECT pg_get_functiondef('public.admin_test_reset_execute(text, jsonb)'::regprocedure)
  INTO v_def;

  IF v_def IS NULL THEN
    RAISE NOTICE 'Could not read admin_test_reset_execute def';
    RETURN;
  END IF;

  IF position('competition_admin_save_prize_templates' IN v_def) > 0 THEN
    RAISE NOTICE 'Reset already snapshots prize templates';
    RETURN;
  END IF;

  IF position(v_marker IN v_def) = 0 THEN
    RAISE NOTICE 'Reset marker not found — skip hook';
    RETURN;
  END IF;

  v_new := replace(v_def, v_marker, v_inject);
  IF v_new = v_def THEN
    RAISE NOTICE 'Reset hook replace made no change';
    RETURN;
  END IF;

  EXECUTE v_new;
  RAISE NOTICE 'admin_test_reset_execute now snapshots prize templates before season wipe';
END;
$hook_reset$;

NOTIFY pgrst, 'reload schema';

COMMIT;
