-- =============================================================================
-- medical_apply_specialist_token: allow forcing a Medical Room specialist consult
-- instead of auto-picking a prize medical token when p_inventory_id is null.
-- Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.medical_apply_specialist_token(
  p_injury_id bigint,
  p_inventory_id bigint DEFAULT NULL,
  p_prefer_specialist boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := public.my_club_shortname();
  v_inj public.competition_player_injuries%rowtype;
  v_remove int := 2;
  v_applied int := 0;
  v_tokens int;
  v_inv public.club_prize_inventory%rowtype;
  v_use_inventory boolean := false;
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

  IF p_inventory_id IS NOT NULL THEN
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
  ELSIF coalesce(p_prefer_specialist, false) THEN
    SELECT specialist_tokens INTO v_tokens
    FROM public.club_medical_centre
    WHERE club_short_name = v_club
    FOR UPDATE;

    IF coalesce(v_tokens, 0) < 1 THEN
      RAISE EXCEPTION 'No specialist tokens available';
    END IF;
    v_remove := 2;
  ELSE
    -- Prefer an available inventory medical token if present
    SELECT * INTO v_inv
    FROM public.club_prize_inventory
    WHERE club_short_name = v_club
      AND prize_type = 'medical_token'
      AND status = 'available'
    ORDER BY param_int DESC, id
    LIMIT 1
    FOR UPDATE;

    IF FOUND THEN
      v_remove := v_inv.param_int;
      v_use_inventory := true;
      p_inventory_id := v_inv.id;
    ELSE
      SELECT specialist_tokens INTO v_tokens
      FROM public.club_medical_centre
      WHERE club_short_name = v_club
      FOR UPDATE;

      IF coalesce(v_tokens, 0) < 1 THEN
        RAISE EXCEPTION 'No specialist tokens available';
      END IF;
      v_remove := 2;
    END IF;
  END IF;

  IF coalesce(v_inj.matches_out_remaining, 0) > 0 THEN
    v_applied := least(v_remove, v_inj.matches_out_remaining);
    UPDATE public.competition_player_injuries
    SET matches_out_remaining = matches_out_remaining - v_applied
    WHERE id = p_injury_id;
  ELSIF coalesce(v_inj.recovery_remaining, 0) > 0 THEN
    v_applied := least(v_remove, v_inj.recovery_remaining);
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

  IF v_use_inventory THEN
    UPDATE public.club_prize_inventory
    SET status = 'consumed',
        consumed_at = now(),
        updated_at = now(),
        metadata = coalesce(metadata, '{}'::jsonb) || jsonb_build_object(
          'injury_id', p_injury_id,
          'matches_removed', v_applied
        )
    WHERE id = p_inventory_id;
  ELSE
    UPDATE public.club_medical_centre
    SET specialist_tokens = specialist_tokens - 1,
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
    'inventory_id', p_inventory_id,
    'tokens_left', coalesce(v_tokens, 0)
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.medical_apply_specialist_token(bigint, bigint, boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.medical_apply_specialist_token(bigint, bigint) TO authenticated;

NOTIFY pgrst, 'reload schema';
