-- =============================================================================
-- Fan Favourite / One of our Own: ignore + clean designations for players who
-- are no longer at the club (test-season leftovers). A stale OooO row made the
-- squad page think the club already had an OooO, hiding "Set as Fan Favourite".
-- Run once in the Supabase SQL Editor.
-- =============================================================================

-- 1) Remove leftover rows for players not contracted to that club
DELETE FROM public.club_squad_player_designations d
WHERE NOT EXISTS (
  SELECT 1 FROM public."Players" p
  WHERE p."Konami_ID"::text = d.player_id
    AND p."Contracted_Team" = d.club_short_name
);

-- 2) State only reports OooO / FF holders who are still in the squad
CREATE OR REPLACE FUNCTION public.club_squad_designations_state(p_club_short_name text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := coalesce(nullif(btrim(p_club_short_name), ''), public.my_club_shortname());
  v_cap smallint;
  v_star_count integer;
  v_ooo text;
  v_ff text;
  v_tier text;
  v_min smallint;
  v_ooo_allowed boolean;
  v_edit_open boolean;
BEGIN
  IF v_club IS NULL OR v_club = '' THEN
    RAISE EXCEPTION 'Club required';
  END IF;

  IF NOT public.club_squad_designations_is_privileged()
     AND public.my_club_shortname() IS DISTINCT FROM v_club THEN
    RAISE EXCEPTION 'Not allowed';
  END IF;

  v_cap := public.club_squad_star_cap(v_club);
  v_tier := public.competition_club_division_tier(v_club);
  v_min := public.club_squad_star_min_rating();
  v_ooo_allowed := public.club_nation_has_gpdb_star(v_club);
  v_edit_open := public.club_squad_designation_edit_window_open()
    OR public.is_gpsl_admin();

  SELECT d.player_id INTO v_ooo
  FROM public.club_squad_player_designations d
  JOIN public."Players" p
    ON p."Konami_ID"::text = d.player_id AND p."Contracted_Team" = d.club_short_name
  WHERE d.club_short_name = v_club
    AND d.designation = 'one_of_our_own'
  LIMIT 1;

  SELECT d.player_id INTO v_ff
  FROM public.club_squad_player_designations d
  JOIN public."Players" p
    ON p."Konami_ID"::text = d.player_id AND p."Contracted_Team" = d.club_short_name
  WHERE d.club_short_name = v_club
    AND d.designation = 'fan_favourite'
  LIMIT 1;

  SELECT count(*)::integer INTO v_star_count
  FROM public."Players" p
  WHERE p."Contracted_Team" = v_club
    AND nullif(regexp_replace(coalesce(btrim(p."Rating"::text), ''), '[^0-9]', '', 'g'), '')::integer >= v_min
    AND (v_ooo IS NULL OR p."Konami_ID"::text <> v_ooo);

  RETURN jsonb_build_object(
    'club_short_name', v_club,
    'division_tier', v_tier,
    'star_cap', v_cap,
    'star_count', coalesce(v_star_count, 0),
    'star_min_rating', v_min,
    'one_of_our_own_player_id', v_ooo,
    'fan_favourite_player_id', v_ff,
    'ooo_allowed', v_ooo_allowed,
    'fan_favourite_allowed', true,
    'designation_edit_open', v_edit_open,
    'designation_edit_months', jsonb_build_array(1, 6, 7),
    'designations', coalesce(
      (
        SELECT jsonb_object_agg(d.player_id, d.designation)
        FROM public.club_squad_player_designations d
        INNER JOIN public."Players" p
          ON p."Konami_ID"::text = d.player_id
          AND p."Contracted_Team" = d.club_short_name
        WHERE d.club_short_name = v_club
      ),
      '{}'::jsonb
    )
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.club_squad_designations_state(text) TO authenticated;

-- 3) Clean up automatically when a designated player leaves the club
CREATE OR REPLACE FUNCTION public.club_squad_designation_drop_on_leave()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  DELETE FROM public.club_squad_player_designations
  WHERE player_id = OLD."Konami_ID"::text
    AND club_short_name = OLD."Contracted_Team";
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS players_drop_designation_on_leave ON public."Players";
CREATE TRIGGER players_drop_designation_on_leave
  AFTER UPDATE OF "Contracted_Team" ON public."Players"
  FOR EACH ROW
  WHEN (OLD."Contracted_Team" IS DISTINCT FROM NEW."Contracted_Team")
  EXECUTE FUNCTION public.club_squad_designation_drop_on_leave();

NOTIFY pgrst, 'reload schema';

-- 4) Is the designation window open for owners right now? (admins always bypass)
SELECT public.club_squad_designation_edit_window_open() AS owner_edit_window_open,
       (SELECT count(*) FROM public.club_squad_player_designations) AS designations_remaining;
