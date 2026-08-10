-- Minimal deploy: prestige seed admin RPCs (table already exists)
CREATE OR REPLACE FUNCTION public.admin_set_club_prestige_seed_ranks(p_ranks jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_row jsonb;
  v_club text;
  v_rank int;
  v_count int := 0;
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF p_ranks IS NULL OR jsonb_typeof(p_ranks) <> 'array' OR jsonb_array_length(p_ranks) = 0 THEN
    RAISE EXCEPTION 'Provide a JSON array of {club_short_name, seed_rank} objects';
  END IF;

  DELETE FROM public.competition_club_prestige_seed;

  FOR v_row IN SELECT value FROM jsonb_array_elements(p_ranks)
  LOOP
    v_club := btrim(v_row ->> 'club_short_name');
    v_rank := (v_row ->> 'seed_rank')::int;

    IF v_club IS NULL OR v_club = '' OR v_rank IS NULL OR v_rank < 1 THEN
      RAISE EXCEPTION 'Invalid seed row: %', v_row;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM public."Clubs" c WHERE c."ShortName" = v_club) THEN
      RAISE EXCEPTION 'Unknown club: %', v_club;
    END IF;

    INSERT INTO public.competition_club_prestige_seed (club_short_name, seed_rank, updated_at)
    VALUES (v_club, v_rank::smallint, now());

    v_count := v_count + 1;
  END LOOP;

  RETURN jsonb_build_object('ok', true, 'clubs_seeded', v_count);
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_apply_prestige_seed_to_start_fill()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club record;
  v_fill numeric;
  v_count int := 0;
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  FOR v_club IN
    SELECT c."ShortName" AS club_short_name
    FROM public."Clubs" c
    WHERE c."ShortName" <> 'FOREIGN'
  LOOP
    v_fill := public.competition_stadium_prestige_base_fill(v_club.club_short_name);

    UPDATE public."Clubs" c
    SET
      stadium_display_fill_pct = v_fill,
      stadium_season_start_fill_pct = v_fill,
      stadium_fill_target_pct = v_fill,
      stadium_fill_updated_at = now()
    WHERE c."ShortName" = v_club.club_short_name;

    v_count := v_count + 1;
  END LOOP;

  RETURN jsonb_build_object('ok', true, 'clubs_updated', v_count);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.admin_set_club_prestige_seed_ranks(jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_apply_prestige_seed_to_start_fill() TO authenticated;

NOTIFY pgrst, 'reload schema';

SELECT
  to_regprocedure('public.admin_apply_prestige_seed_to_start_fill()') AS apply_fn,
  to_regprocedure('public.admin_set_club_prestige_seed_ranks(jsonb)') AS set_ranks_fn;
