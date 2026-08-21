-- =============================================================================
-- Match Day squad composition mins
-- ≥1 GK · ≥2 U21 (whole 23) · ≥2 HG in starting XI · ≥5 HG in whole squad
-- Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.club_save_matchday_squad(
  p_slots jsonb,
  p_pitch_layout jsonb DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := public.my_club_shortname();
  v_row jsonb;
  v_player_id text;
  v_kind text;
  v_pitch_slot text;
  v_sort smallint;
  v_total int := 0;
  v_pitch_count int := 0;
  v_bench_count int := 0;
  v_reserve_count int := 0;
  v_layout jsonb;
  v_mirror_err text;
  v_gk int := 0;
  v_u21 int := 0;
  v_hg_xi int := 0;
  v_hg_total int := 0;
  v_age int;
  v_pos text;
  v_is_hg boolean;
BEGIN
  IF v_club IS NULL OR v_club = '' THEN
    RAISE EXCEPTION 'No club linked to your account';
  END IF;

  IF p_slots IS NULL OR jsonb_typeof(p_slots) <> 'array' THEN
    RAISE EXCEPTION 'p_slots must be a JSON array';
  END IF;

  IF jsonb_array_length(p_slots) > 23 THEN
    RAISE EXCEPTION 'Matchday squad cannot exceed 23 players';
  END IF;

  FOR v_row IN SELECT value FROM jsonb_array_elements(p_slots)
  LOOP
    v_player_id := btrim(v_row->>'player_id');
    v_kind := btrim(v_row->>'slot_kind');
    v_pitch_slot := nullif(btrim(v_row->>'pitch_slot'), '');
    v_sort := coalesce((v_row->>'sort_order')::smallint, 0);

    IF v_player_id IS NULL OR v_player_id = '' THEN
      RAISE EXCEPTION 'Each slot needs player_id';
    END IF;

    IF v_kind NOT IN ('pitch', 'bench', 'reserve') THEN
      RAISE EXCEPTION 'Invalid slot_kind for player %', v_player_id;
    END IF;

    IF v_kind = 'pitch' AND v_pitch_slot IS NULL THEN
      RAISE EXCEPTION 'Pitch players need pitch_slot';
    END IF;

    IF v_kind <> 'pitch' AND v_pitch_slot IS NOT NULL THEN
      RAISE EXCEPTION 'Only pitch players may have pitch_slot';
    END IF;

    IF NOT EXISTS (
      SELECT 1 FROM public."Players" p
      WHERE p."Konami_ID"::text = v_player_id
        AND p."Contracted_Team" = v_club
    ) THEN
      RAISE EXCEPTION 'Player % is not in your contracted squad', v_player_id;
    END IF;

    SELECT
      p."Age",
      upper(btrim(coalesce(p."Position", ''))),
      coalesce(public.is_player_homegrown(v_player_id, v_club), false)
    INTO v_age, v_pos, v_is_hg
    FROM public."Players" p
    WHERE p."Konami_ID"::text = v_player_id
      AND p."Contracted_Team" = v_club;

    IF v_pos IN ('GK', 'GOALKEEPER') THEN
      v_gk := v_gk + 1;
    END IF;
    IF v_age IS NOT NULL AND v_age <= 21 THEN
      v_u21 := v_u21 + 1;
    END IF;
    IF v_is_hg THEN
      v_hg_total := v_hg_total + 1;
      IF v_kind = 'pitch' THEN
        v_hg_xi := v_hg_xi + 1;
      END IF;
    END IF;

    v_total := v_total + 1;
    IF v_kind = 'pitch' THEN v_pitch_count := v_pitch_count + 1;
    ELSIF v_kind = 'bench' THEN v_bench_count := v_bench_count + 1;
    ELSE v_reserve_count := v_reserve_count + 1;
    END IF;
  END LOOP;

  IF v_pitch_count > 11 THEN
    RAISE EXCEPTION 'Maximum 11 players on the pitch (got %)', v_pitch_count;
  END IF;
  IF v_bench_count > 12 THEN
    RAISE EXCEPTION 'Maximum 12 bench players (got %)', v_bench_count;
  END IF;
  IF v_reserve_count > 0 THEN
    RAISE EXCEPTION 'Reserves are no longer used — use bench slots (max 12)';
  END IF;

  IF v_gk < 1 THEN
    RAISE EXCEPTION 'Matchday squad needs at least 1 goalkeeper (have %)', v_gk;
  END IF;
  IF v_u21 < 2 THEN
    RAISE EXCEPTION 'Matchday squad needs at least 2 under-21 players (have %)', v_u21;
  END IF;
  IF v_hg_xi < 2 THEN
    RAISE EXCEPTION 'Starting XI needs at least 2 home-grown players (have %)', v_hg_xi;
  END IF;
  IF v_hg_total < 5 THEN
    RAISE EXCEPTION 'Matchday squad needs at least 5 home-grown players (have %)', v_hg_total;
  END IF;

  v_layout := coalesce(p_pitch_layout, '{}'::jsonb);
  IF jsonb_typeof(v_layout) IS DISTINCT FROM 'object' THEN
    RAISE EXCEPTION 'p_pitch_layout must be a JSON object';
  END IF;

  v_mirror_err := public.validate_pitch_layout_mirroring(v_layout);
  IF v_mirror_err IS NOT NULL THEN
    RAISE EXCEPTION '%', v_mirror_err;
  END IF;

  INSERT INTO public.club_matchday_squad (club_short_name, pitch_layout, updated_at)
  VALUES (v_club, v_layout, now())
  ON CONFLICT (club_short_name) DO UPDATE
  SET pitch_layout = EXCLUDED.pitch_layout,
      updated_at = now();

  DELETE FROM public.club_matchday_squad_player
  WHERE club_short_name = v_club;

  FOR v_row IN SELECT value FROM jsonb_array_elements(p_slots)
  LOOP
    v_player_id := btrim(v_row->>'player_id');
    v_kind := btrim(v_row->>'slot_kind');
    v_pitch_slot := nullif(btrim(v_row->>'pitch_slot'), '');
    v_sort := coalesce((v_row->>'sort_order')::smallint, 0);

    INSERT INTO public.club_matchday_squad_player (
      club_short_name,
      player_id,
      slot_kind,
      pitch_slot,
      sort_order
    )
    VALUES (v_club, v_player_id, v_kind, v_pitch_slot, v_sort);
  END LOOP;

  RETURN jsonb_build_object(
    'club_short_name', v_club,
    'total', v_total,
    'pitch', v_pitch_count,
    'bench', v_bench_count,
    'reserve', v_reserve_count,
    'gk', v_gk,
    'u21', v_u21,
    'hg_xi', v_hg_xi,
    'hg_total', v_hg_total
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.club_save_matchday_squad(jsonb, jsonb) TO authenticated;

NOTIFY pgrst, 'reload schema';
