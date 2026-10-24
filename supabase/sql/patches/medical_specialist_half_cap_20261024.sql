-- =============================================================================
-- Specialist / medical tokens: max reduction = half of current remaining length.
-- Example: 18 matches out + −10 token → remove 9 → 9 left (not 8).
-- Integer half (floor). Applies to out phase and recovery phase.
-- Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.medical_specialist_max_reduction(p_remaining int)
RETURNS int
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT greatest(0, coalesce(p_remaining, 0) / 2);
$$;

COMMENT ON FUNCTION public.medical_specialist_max_reduction(int) IS
  'Max matches a specialist consult may remove: floor(remaining / 2).';

CREATE OR REPLACE FUNCTION public.medical_apply_specialist_token(
  p_injury_id bigint,
  p_inventory_id bigint DEFAULT NULL,
  p_prefer_specialist boolean DEFAULT false,
  p_consult_id bigint DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := public.my_club_shortname();
  v_inj public.competition_player_injuries%ROWTYPE;
  v_remove int := 2;
  v_applied int := 0;
  v_remaining int := 0;
  v_cap int := 0;
  v_tokens int;
  v_inv public.club_prize_inventory%ROWTYPE;
  v_use_inventory boolean := false;
  v_consult public.club_medical_consults%ROWTYPE;
  v_label text;
  v_phase text;
BEGIN
  IF v_club IS NULL THEN RAISE EXCEPTION 'No club linked to this account'; END IF;
  IF NOT public.medical_club_has_doctor(v_club) THEN
    RAISE EXCEPTION 'A club doctor is required before using specialist consultants';
  END IF;

  SELECT * INTO v_inj
  FROM public.competition_player_injuries
  WHERE id = p_injury_id
  FOR UPDATE;

  IF NOT FOUND OR v_inj.club_short_name IS DISTINCT FROM v_club THEN
    RAISE EXCEPTION 'Injury not found for your club';
  END IF;
  IF v_inj.status <> 'active' THEN
    RAISE EXCEPTION 'Injury is not active';
  END IF;
  IF EXISTS (SELECT 1 FROM public.club_medical_token_use WHERE injury_id = p_injury_id) THEN
    RAISE EXCEPTION 'A specialist consult was already used on this injury';
  END IF;

  PERFORM public.medical_ensure_centre(v_club);
  PERFORM public.medical_sync_named_consults(v_club);

  IF p_consult_id IS NOT NULL THEN
    SELECT * INTO v_consult
    FROM public.club_medical_consults
    WHERE id = p_consult_id
    FOR UPDATE;

    IF NOT FOUND OR v_consult.club_short_name IS DISTINCT FROM v_club THEN
      RAISE EXCEPTION 'Consult not found';
    END IF;
    IF v_consult.status <> 'available' THEN
      RAISE EXCEPTION 'Consult not available';
    END IF;

    v_remove := v_consult.matches_removed;
    v_label := v_consult.label;
    p_inventory_id := v_consult.inventory_id;
    IF p_inventory_id IS NOT NULL THEN
      v_use_inventory := true;
    END IF;
  ELSIF p_inventory_id IS NOT NULL THEN
    SELECT * INTO v_consult
    FROM public.club_medical_consults
    WHERE inventory_id = p_inventory_id
      AND status = 'available'
    ORDER BY id
    LIMIT 1
    FOR UPDATE;

    IF FOUND THEN
      p_consult_id := v_consult.id;
      v_remove := v_consult.matches_removed;
      v_label := v_consult.label;
      v_use_inventory := true;
    ELSE
      SELECT * INTO v_inv
      FROM public.club_prize_inventory
      WHERE id = p_inventory_id
      FOR UPDATE;
      IF NOT FOUND OR v_inv.club_short_name IS DISTINCT FROM v_club THEN
        RAISE EXCEPTION 'Medical token not found';
      END IF;
      IF v_inv.prize_type <> 'medical_token' OR v_inv.status <> 'available' THEN
        RAISE EXCEPTION 'Medical token not available';
      END IF;
      v_remove := v_inv.param_int;
      v_use_inventory := true;
      v_label := coalesce(v_inv.metadata->>'label', v_inv.metadata->>'consultancy_label');
    END IF;
  ELSIF coalesce(p_prefer_specialist, false) THEN
    SELECT * INTO v_consult
    FROM public.club_medical_consults
    WHERE club_short_name = v_club
      AND status = 'available'
      AND inventory_id IS NULL
    ORDER BY id
    LIMIT 1
    FOR UPDATE;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'No specialist tokens available';
    END IF;
    p_consult_id := v_consult.id;
    v_remove := v_consult.matches_removed;
    v_label := v_consult.label;
  ELSE
    SELECT * INTO v_consult
    FROM public.club_medical_consults
    WHERE club_short_name = v_club
      AND status = 'available'
    ORDER BY matches_removed DESC, id
    LIMIT 1
    FOR UPDATE;

    IF FOUND THEN
      p_consult_id := v_consult.id;
      v_remove := v_consult.matches_removed;
      v_label := v_consult.label;
      p_inventory_id := v_consult.inventory_id;
      v_use_inventory := (v_consult.inventory_id IS NOT NULL);
    ELSE
      RAISE EXCEPTION 'No specialist tokens available';
    END IF;
  END IF;

  IF coalesce(v_inj.matches_out_remaining, 0) > 0 THEN
    v_phase := 'out';
    v_remaining := v_inj.matches_out_remaining;
    v_cap := public.medical_specialist_max_reduction(v_remaining);
    v_applied := least(v_remove, v_cap, v_remaining);
    IF v_applied < 1 THEN
      RAISE EXCEPTION
        'Specialist consult cannot shorten this injury further (max is half of remaining matches; currently % left)',
        v_remaining;
    END IF;
    UPDATE public.competition_player_injuries
    SET matches_out_remaining = matches_out_remaining - v_applied
    WHERE id = p_injury_id;
  ELSIF coalesce(v_inj.recovery_remaining, 0) > 0 THEN
    v_phase := 'recovery';
    v_remaining := v_inj.recovery_remaining;
    v_cap := public.medical_specialist_max_reduction(v_remaining);
    v_applied := least(v_remove, v_cap, v_remaining);
    IF v_applied < 1 THEN
      RAISE EXCEPTION
        'Specialist consult cannot shorten this injury further (max is half of remaining matches; currently % left)',
        v_remaining;
    END IF;
    UPDATE public.competition_player_injuries
    SET recovery_remaining = recovery_remaining - v_applied
    WHERE id = p_injury_id;
  ELSE
    RAISE EXCEPTION 'Nothing left to shorten on this injury';
  END IF;

  UPDATE public.competition_player_injuries i
  SET status = 'recovered',
      recovered_at = coalesce(i.recovered_at, now())
  WHERE i.id = p_injury_id
    AND coalesce(i.matches_out_remaining, 0) <= 0
    AND coalesce(i.recovery_remaining, 0) <= 0;

  INSERT INTO public.club_medical_token_use (club_short_name, injury_id, matches_removed)
  VALUES (v_club, p_injury_id, v_applied);

  IF p_consult_id IS NOT NULL THEN
    UPDATE public.club_medical_consults
    SET status = 'consumed',
        consumed_at = now()
    WHERE id = p_consult_id;
  END IF;

  IF v_use_inventory AND p_inventory_id IS NOT NULL THEN
    UPDATE public.club_prize_inventory
    SET status = 'consumed',
        consumed_at = now(),
        updated_at = now(),
        metadata = coalesce(metadata, '{}'::jsonb) || jsonb_build_object(
          'injury_id', p_injury_id,
          'matches_removed', v_applied,
          'token_tier', v_remove,
          'max_half_cap', v_cap,
          'phase', v_phase,
          'label', v_label
        )
    WHERE id = p_inventory_id;
  ELSIF p_consult_id IS NOT NULL AND NOT v_use_inventory THEN
    UPDATE public.club_medical_centre
    SET specialist_tokens = greatest(0, specialist_tokens - 1),
        updated_at = now()
    WHERE club_short_name = v_club;
  END IF;

  IF to_regprocedure('public.competition_injury_assign_fixtures(bigint)') IS NOT NULL THEN
    PERFORM public.competition_injury_assign_fixtures(p_injury_id);
  END IF;

  SELECT specialist_tokens INTO v_tokens
  FROM public.club_medical_centre
  WHERE club_short_name = v_club;

  RETURN jsonb_build_object(
    'ok', true,
    'matches_removed', v_applied,
    'token_tier', v_remove,
    'max_half_cap', v_cap,
    'remaining_before', v_remaining,
    'remaining_after', v_remaining - v_applied,
    'phase', v_phase,
    'inventory_id', p_inventory_id,
    'consult_id', p_consult_id,
    'label', v_label,
    'tokens_left', coalesce(v_tokens, 0)
  );
END;
$function$;

-- Keep shorter overloads as thin wrappers onto the 4-arg function.
CREATE OR REPLACE FUNCTION public.medical_apply_specialist_token(
  p_injury_id bigint,
  p_inventory_id bigint DEFAULT NULL,
  p_prefer_specialist boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT public.medical_apply_specialist_token(
    p_injury_id,
    p_inventory_id,
    p_prefer_specialist,
    NULL::bigint
  );
$$;

CREATE OR REPLACE FUNCTION public.medical_apply_specialist_token(
  p_injury_id bigint,
  p_inventory_id bigint DEFAULT NULL
)
RETURNS jsonb
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT public.medical_apply_specialist_token(
    p_injury_id,
    p_inventory_id,
    false,
    NULL::bigint
  );
$$;

GRANT EXECUTE ON FUNCTION public.medical_specialist_max_reduction(int) TO authenticated;
GRANT EXECUTE ON FUNCTION public.medical_apply_specialist_token(bigint, bigint, boolean, bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.medical_apply_specialist_token(bigint, bigint, boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.medical_apply_specialist_token(bigint, bigint) TO authenticated;

NOTIFY pgrst, 'reload schema';

SELECT
  public.medical_specialist_max_reduction(18) AS cap_18,
  public.medical_specialist_max_reduction(17) AS cap_17,
  public.medical_specialist_max_reduction(1) AS cap_1,
  public.medical_specialist_max_reduction(2) AS cap_2;
