-- =============================================================================
-- Fan Favourite / OooO edit window: GPSL calendar, not real-world months
-- =============================================================================
-- Open when:
--   • current season status is preseason / setup, OR
--   • active GPSL month is june, july, or january
-- Admins still bypass in club_squad_set_designation.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.club_squad_designation_edit_window_open()
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season_id bigint;
  v_status text;
  v_month text;
BEGIN
  IF to_regprocedure('public.competition_finances_current_season_id()') IS NOT NULL THEN
    v_season_id := public.competition_finances_current_season_id();
  ELSIF to_regprocedure('public.current_gpsl_season_id()') IS NOT NULL THEN
    v_season_id := public.current_gpsl_season_id();
  ELSE
    SELECT s.id INTO v_season_id
    FROM public.competition_seasons s
    WHERE s.is_current = true
    ORDER BY s.id DESC
    LIMIT 1;
  END IF;

  IF v_season_id IS NULL THEN
    RETURN false;
  END IF;

  SELECT s.status INTO v_status
  FROM public.competition_seasons s
  WHERE s.id = v_season_id;

  -- Whole preseason / setup block (Season 1 now, summer break create, etc.)
  IF v_status IN ('preseason', 'setup') THEN
    RETURN true;
  END IF;

  IF to_regprocedure('public.competition_active_gpsl_month(bigint, timestamptz)') IS NOT NULL THEN
    v_month := lower(btrim(coalesce(
      public.competition_active_gpsl_month(v_season_id, now()),
      ''
    )));
  END IF;

  -- Mid-season January change window + GPSL June/July if calendar unlocked while active
  RETURN v_month IN ('june', 'july', 'january');
END;
$function$;

COMMENT ON FUNCTION public.club_squad_designation_edit_window_open() IS
  'OooO / Fan Favourite editable in GPSL preseason/setup, or GPSL months june/july/january.';

GRANT EXECUTE ON FUNCTION public.club_squad_designation_edit_window_open() TO authenticated;

-- Keep exception text aligned
CREATE OR REPLACE FUNCTION public.club_squad_set_designation(
  p_player_id text,
  p_designation text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := public.my_club_shortname();
  v_player text := btrim(p_player_id);
  v_desig text := nullif(lower(btrim(coalesce(p_designation, ''))), '');
  v_current text;
  v_admin boolean := public.is_gpsl_admin();
BEGIN
  IF v_club IS NULL OR v_club = '' THEN
    RAISE EXCEPTION 'No club linked to your account';
  END IF;

  IF v_player IS NULL OR v_player = '' THEN
    RAISE EXCEPTION 'Player required';
  END IF;

  IF v_desig = 'star' THEN
    RAISE EXCEPTION 'Star players are automatic (rating-based) — set One of our own or Fan Favourite only';
  END IF;

  IF v_desig IS NOT NULL
     AND v_desig NOT IN ('one_of_our_own', 'fan_favourite') THEN
    RAISE EXCEPTION 'Invalid designation';
  END IF;

  IF NOT v_admin AND NOT public.club_squad_designation_edit_window_open() THEN
    RAISE EXCEPTION
      'One of our own / Fan Favourite can only be changed in GPSL preseason (June/July) or January';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public."Players" p
    WHERE p."Konami_ID"::text = v_player
      AND p."Contracted_Team" = v_club
  ) THEN
    RAISE EXCEPTION 'Player is not on your squad';
  END IF;

  SELECT d.designation INTO v_current
  FROM public.club_squad_player_designations d
  WHERE d.club_short_name = v_club
    AND d.player_id = v_player;

  IF v_desig IS NULL THEN
    DELETE FROM public.club_squad_player_designations
    WHERE club_short_name = v_club AND player_id = v_player;
    RETURN public.club_squad_designations_state(v_club);
  END IF;

  IF v_desig = 'one_of_our_own' THEN
    IF NOT public.club_nation_has_gpdb_star(v_club) THEN
      RAISE EXCEPTION
        'Your nation has no 79+ stars in the GPDB pool — Fan Favourite only';
    END IF;
    IF NOT public.club_squad_player_eligible_one_of_our_own(v_player, v_club) THEN
      RAISE EXCEPTION
        'One of our own must be home-grown (Nation matches club) and rated % or higher',
        public.club_squad_star_min_rating();
    END IF;

    DELETE FROM public.club_squad_player_designations
    WHERE club_short_name = v_club
      AND designation IN ('one_of_our_own', 'fan_favourite')
      AND player_id <> v_player;
  END IF;

  IF v_desig = 'fan_favourite' THEN
    IF NOT public.club_squad_player_eligible_fan_favourite(v_player, v_club) THEN
      RAISE EXCEPTION 'Fan Favourite must be a squad player rated 76, 77, or 78';
    END IF;

    DELETE FROM public.club_squad_player_designations
    WHERE club_short_name = v_club
      AND designation IN ('one_of_our_own', 'fan_favourite')
      AND player_id <> v_player;
  END IF;

  INSERT INTO public.club_squad_player_designations (club_short_name, player_id, designation)
  VALUES (v_club, v_player, v_desig)
  ON CONFLICT (club_short_name, player_id) DO UPDATE
    SET designation = excluded.designation,
        assigned_at = now();

  RETURN public.club_squad_designations_state(v_club);
END;
$function$;

CREATE OR REPLACE FUNCTION public.club_assign_random_one_of_our_own(p_club_short_name text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := btrim(p_club_short_name);
  v_player text;
BEGIN
  IF NOT public.club_squad_designations_is_privileged()
     AND public.my_club_shortname() IS DISTINCT FROM v_club THEN
    RAISE EXCEPTION 'Not allowed';
  END IF;

  IF NOT public.is_gpsl_admin()
     AND NOT public.club_squad_designation_edit_window_open() THEN
    RAISE EXCEPTION
      'One of our own / Fan Favourite can only be changed in GPSL preseason (June/July) or January';
  END IF;

  IF NOT public.club_nation_has_gpdb_star(v_club) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'nation_no_star_pool');
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.club_squad_player_designations d
    WHERE d.club_short_name = v_club AND d.designation = 'one_of_our_own'
  ) THEN
    RETURN public.club_squad_designations_state(v_club);
  END IF;

  SELECT p."Konami_ID"::text INTO v_player
  FROM public."Players" p
  WHERE p."Contracted_Team" = v_club
    AND public.club_squad_player_eligible_one_of_our_own(p."Konami_ID"::text, v_club)
  ORDER BY
    CASE
      WHEN public.club_squad_player_age(p."Konami_ID"::text) IS NOT NULL
           AND public.club_squad_player_age(p."Konami_ID"::text) <= 28 THEN 0
      ELSE 1
    END,
    public.club_squad_player_rating(p."Konami_ID"::text) DESC NULLS LAST,
    random()
  LIMIT 1;

  IF v_player IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_eligible_homegrown_star');
  END IF;

  DELETE FROM public.club_squad_player_designations
  WHERE club_short_name = v_club
    AND designation = 'fan_favourite';

  INSERT INTO public.club_squad_player_designations (club_short_name, player_id, designation)
  VALUES (v_club, v_player, 'one_of_our_own')
  ON CONFLICT (club_short_name, player_id) DO UPDATE
    SET designation = 'one_of_our_own',
        assigned_at = now();

  RETURN jsonb_build_object(
    'ok', true,
    'player_id', v_player,
    'state', public.club_squad_designations_state(v_club)
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.club_squad_set_designation(text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.club_assign_random_one_of_our_own(text) TO authenticated;

NOTIFY pgrst, 'reload schema';
