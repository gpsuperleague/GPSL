-- =============================================================================
-- One-off: insert a single PESDB player into GPDB as free agent
--
-- Use from Admin → GPDB Player Sync → "Add missing from PESDB (Konami ID)".
-- Does NOT run full sync apply (avoids marking others unavailable).
--
-- Safe re-run: refuses if Konami_ID already exists.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.gpdb_pesdb_insert_one_free_agent(p_row jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_kid text := nullif(btrim(coalesce(p_row->>'konami_id', p_row->>'player_id', '')), '');
  v_name text := nullif(btrim(coalesce(p_row->>'player_name', '')), '');
  v_pos text := coalesce(nullif(btrim(p_row->>'position'), ''), 'CF');
  v_nation text := coalesce(nullif(btrim(p_row->>'nationality'), ''), 'Unknown');
  v_age text := coalesce(nullif(btrim(p_row->>'age'), ''), '25');
  v_rating text := coalesce(nullif(btrim(p_row->>'rating'), ''), '60');
  v_pot text := coalesce(
    nullif(btrim(p_row->>'max_level_rating'), ''),
    nullif(btrim(p_row->>'rating'), ''),
    '60'
  );
  v_calc text := coalesce(
    nullif(btrim(p_row->>'calc_potential'), ''),
    v_pot
  );
  v_ps text := coalesce(nullif(btrim(p_row->>'playing_style'), ''), 'None');
  v_mv numeric := coalesce(nullif(btrim(p_row->>'market_value'), '')::numeric, 5000000);
  v_reserve numeric := coalesce(
    nullif(btrim(p_row->>'maximum_reserve_price'), '')::numeric,
    round(v_mv * 1.5, 0)
  );
  v_height int;
  v_foot text := nullif(btrim(p_row->>'stronger_foot'), '');
  v_wfu text := nullif(btrim(p_row->>'weak_foot_usage'), '');
  v_wfa text := nullif(btrim(p_row->>'weak_foot_accuracy'), '');
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF v_kid IS NULL THEN
    RAISE EXCEPTION 'konami_id required';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public."Players" p WHERE p."Konami_ID"::text = v_kid
  ) THEN
    RAISE EXCEPTION 'Player % already exists in GPDB', v_kid;
  END IF;

  IF v_name IS NULL THEN
    RAISE EXCEPTION 'player_name required (PESDB lookup may have failed)';
  END IF;

  BEGIN
    v_height := nullif(btrim(p_row->>'height_cm'), '')::int;
  EXCEPTION WHEN OTHERS THEN
    v_height := NULL;
  END;

  INSERT INTO public."Players" (
    "Konami_ID",
    "Name",
    "Position",
    "Nation",
    "Age",
    "Rating",
    "Potential",
    "Calc_Potential",
    "Playstyle",
    "Height",
    "Stronger_Foot",
    "Weak_Foot_Usage",
    "Weak_Foot_Accuracy",
    market_value,
    "Maximum_Reserve_Price",
    "Contracted_Team",
    pesdb_unavailable
  )
  VALUES (
    v_kid,
    v_name,
    v_pos,
    v_nation,
    v_age,
    v_rating,
    v_pot,
    v_calc,
    v_ps,
    v_height,
    v_foot,
    v_wfu,
    v_wfa,
    v_mv,
    v_reserve,
    NULL,
    false
  );

  RETURN jsonb_build_object(
    'ok', true,
    'konami_id', v_kid,
    'name', v_name,
    'position', v_pos,
    'nation', v_nation,
    'age', v_age,
    'rating', v_rating,
    'potential', v_pot,
    'playstyle', v_ps,
    'market_value', v_mv,
    'contracted_team', NULL
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.gpdb_pesdb_insert_one_free_agent(jsonb) TO authenticated;

COMMENT ON FUNCTION public.gpdb_pesdb_insert_one_free_agent(jsonb) IS
  'Admin one-off: insert a single PESDB-scraped player as GPDB free agent by Konami_ID.';

NOTIFY pgrst, 'reload schema';
