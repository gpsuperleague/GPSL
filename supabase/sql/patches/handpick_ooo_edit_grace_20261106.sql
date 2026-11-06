-- =============================================================================
-- Mid-season handpick owners may set OooO / Fan Favourite after the window
-- =============================================================================
-- Everyone else stays on the normal window: GPSL preseason / June / July /
-- January.
--
-- Grace (this club only) when ALL of:
--   • the normal window is closed
--   • the current owner was appointed AFTER the last window closed
--     (owners already in place before that deadline do not get a second chance)
--   • this appointment is the handpick cycle (owner_assigned_at is at or after
--     handpick_started_at — a long-standing owner who is later put through
--     handpick does not qualify)
--   • handpick intake is finished (wishlist approved / intake turned off),
--     so the signed squad is on Squad
--
-- Grace ends by itself when the next June / July / January window closes,
-- because owner_assigned_at is then before that new deadline.
-- Run once in the Supabase SQL Editor.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.club_squad_designation_edit_reason(p_club_short_name text)
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := btrim(coalesce(p_club_short_name, ''));
  v_assigned timestamptz;
  v_started timestamptz;
  v_intake boolean;
  v_closed timestamptz;
  v_season_id bigint;
BEGIN
  IF public.club_squad_designation_edit_window_open() THEN
    RETURN 'window';
  END IF;

  IF v_club = '' THEN
    RETURN 'closed';
  END IF;

  SELECT c.owner_assigned_at, c.handpick_started_at, coalesce(c.handpick_intake, false)
  INTO v_assigned, v_started, v_intake
  FROM public."Clubs" c
  WHERE upper(c."ShortName") = upper(v_club);

  -- Still building the wishlist: squad was cleared, nothing to designate yet.
  IF v_assigned IS NULL OR v_started IS NULL OR v_intake THEN
    RETURN 'closed';
  END IF;

  -- Same tenure as this handpick. A owner appointed earlier fails this test.
  IF v_assigned < v_started - interval '1 minute' THEN
    RETURN 'closed';
  END IF;

  SELECT s.id INTO v_season_id
  FROM public.competition_seasons s
  WHERE s.is_current = true
  ORDER BY s.id DESC
  LIMIT 1;

  IF v_season_id IS NULL
     AND to_regprocedure('public.competition_finances_current_season_id()') IS NOT NULL THEN
    v_season_id := public.competition_finances_current_season_id();
  END IF;

  IF v_season_id IS NULL THEN
    RETURN 'closed';
  END IF;

  -- Last time the shared window shut: latest June / July / January lock already
  -- passed, else the moment this season's calendar started (preseason ended).
  SELECT max(c.lock_at) INTO v_closed
  FROM public.competition_season_calendar c
  WHERE c.season_id = v_season_id
    AND lower(btrim(c.gpsl_month)) IN ('june', 'july', 'january')
    AND c.lock_at <= now();

  IF v_closed IS NULL THEN
    SELECT min(c.unlock_at) INTO v_closed
    FROM public.competition_season_calendar c
    WHERE c.season_id = v_season_id
      AND c.unlock_at <= now();
  END IF;

  IF v_closed IS NULL OR v_assigned <= v_closed THEN
    RETURN 'closed';
  END IF;

  RETURN 'handpick_new_owner';
END;
$function$;

COMMENT ON FUNCTION public.club_squad_designation_edit_reason(text) IS
  'window | handpick_new_owner | closed. Handpick grace is only for an owner appointed after the last OooO deadline, on the handpick cycle that is now finished.';

CREATE OR REPLACE FUNCTION public.club_squad_designation_edit_open_for_club(p_club_short_name text)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT public.club_squad_designation_edit_reason(p_club_short_name) IS DISTINCT FROM 'closed';
$$;

COMMENT ON FUNCTION public.club_squad_designation_edit_open_for_club(text) IS
  'True in the normal OooO window, or for a finished mid-season handpick owner who missed that window.';

GRANT EXECUTE ON FUNCTION public.club_squad_designation_edit_reason(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.club_squad_designation_edit_open_for_club(text) TO authenticated;

-- State: surface the grace so Squad can show Set as One of our own.
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
  v_reason text;
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
  v_reason := public.club_squad_designation_edit_reason(v_club);
  -- Admin bypass only on the admin's own club. The squad dropdown preview of
  -- another club must match that owner: a closed window stays closed.
  IF v_reason = 'closed'
     AND public.is_gpsl_admin()
     AND upper(coalesce(public.my_club_shortname(), '')) = upper(v_club) THEN
    v_reason := 'admin';
  END IF;
  v_edit_open := v_reason IS DISTINCT FROM 'closed';

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
    'designation_edit_reason', v_reason,
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

  IF NOT v_admin AND NOT public.club_squad_designation_edit_open_for_club(v_club) THEN
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
     AND NOT public.club_squad_designation_edit_open_for_club(v_club) THEN
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

-- Staff dropdown on Squad reads the same private bits the owner sees
-- (new-owner slots, sale marks, scouting badges). Writes stay on the owner RPCs.
CREATE OR REPLACE FUNCTION public.club_squad_staff_owner_snapshot(
  p_club text,
  p_player_ids text[] DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := upper(btrim(coalesce(p_club, '')));
  v_season_id bigint;
  v_assigned bigint;
  v_remaining int;
  v_eligible boolean;
  v_window boolean;
  v_active_listings int;
  v_marks jsonb;
  v_scout jsonb;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;
  IF v_club = '' THEN
    RAISE EXCEPTION 'Club required';
  END IF;
  IF NOT public.is_gpsl_admin()
     AND NOT coalesce(public.is_gpsl_mod(), false)
     AND upper(coalesce(public.my_club_shortname(), '')) IS DISTINCT FROM v_club THEN
    RAISE EXCEPTION 'Not allowed';
  END IF;

  SELECT id INTO v_season_id
  FROM public.competition_seasons
  WHERE is_current = true
  ORDER BY id DESC
  LIMIT 1;

  SELECT c.owner_assigned_season_id, c.new_owner_releases_remaining
  INTO v_assigned, v_remaining
  FROM public."Clubs" c
  WHERE upper(c."ShortName") = v_club;

  SELECT count(*)::int INTO v_active_listings
  FROM public."Player_Transfer_Listings" l
  WHERE l.seller_club_id = v_club
    AND coalesce(l.new_owner_slot, false) = true
    AND coalesce(l.new_owner_slot_settled, false) = false
    AND l.status IN ('Active', 'Review', 'Seller Review');

  v_eligible := public.club_is_new_owner_release_eligible(v_club);
  v_window := public.club_new_owner_release_window_open();

  SELECT coalesce(jsonb_agg(row_to_json(x)::jsonb), '[]'::jsonb)
  INTO v_marks
  FROM (
    SELECT
      m.player_id,
      m.note,
      m.updated_at,
      p."Name" AS player_name
    FROM public.club_player_sale_marks m
    JOIN public."Players" p
      ON p."Konami_ID"::text = m.player_id
     AND upper(nullif(btrim(p."Contracted_Team"), '')) = v_club
    WHERE m.club_short_name = v_club
      AND (
        p_player_ids IS NULL
        OR cardinality(p_player_ids) = 0
        OR m.player_id = ANY (p_player_ids)
      )
  ) x;

  SELECT coalesce(jsonb_object_agg(z.player_id, z.clubs), '{}'::jsonb)
  INTO v_scout
  FROM (
    SELECT
      y.player_id,
      jsonb_agg(
        jsonb_build_object(
          'club_short_name', y.club_short_name,
          'club_name', y.club_name,
          'owner_tag', y.owner_tag,
          'tier', y.tier,
          'is_active_target', y.is_active_target
        )
        ORDER BY y.club_name
      ) AS clubs
    FROM (
      SELECT DISTINCT ON (t.player_id, c."ShortName")
        t.player_id::text AS player_id,
        c."ShortName" AS club_short_name,
        coalesce(nullif(btrim(c."Club"), ''), c."ShortName") AS club_name,
        coalesce(
          nullif(btrim(public.owner_registry_resolve_tag(c.owner_id)), ''),
          nullif(btrim(c.owner), ''),
          '—'
        ) AS owner_tag,
        t.tier,
        coalesce(t.is_active_target, false) AS is_active_target
      FROM public.owner_scouting_targets t
      JOIN public."Clubs" c
        ON c.owner_id = t.owner_id
       AND upper(c."ShortName") IS DISTINCT FROM v_club
      JOIN public."Players" p
        ON p."Konami_ID"::text = t.player_id::text
       AND upper(nullif(btrim(p."Contracted_Team"), '')) = v_club
      WHERE (
        p_player_ids IS NULL
        OR cardinality(p_player_ids) = 0
        OR t.player_id::text = ANY (p_player_ids)
      )
      ORDER BY t.player_id, c."ShortName", coalesce(t.is_active_target, false) DESC, t.tier ASC
    ) y
    GROUP BY y.player_id
  ) z;

  RETURN jsonb_build_object(
    'ok', true,
    'club', v_club,
    'new_owner', jsonb_build_object(
      'new_owner_releases_remaining', coalesce(v_remaining, 0),
      'new_owner_slots_remaining', coalesce(v_remaining, 0),
      'active_new_owner_listings', coalesce(v_active_listings, 0),
      'first_season_at_club', (
        v_assigned IS NOT NULL AND v_season_id IS NOT NULL AND v_assigned = v_season_id
      ),
      'window_open', v_window,
      'available_now', (v_eligible AND v_window),
      'list_available_now', (v_eligible AND v_window)
    ),
    'sale_marks', coalesce(v_marks, '[]'::jsonb),
    'scouting_by_player', coalesce(v_scout, '{}'::jsonb)
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.club_squad_staff_owner_snapshot(text, text[]) TO authenticated;

NOTIFY pgrst, 'reload schema';

-- Who gets the grace right now (handpick_new_owner = can set OooO).
SELECT
  c."ShortName",
  c."Club",
  c.handpick_intake,
  c.handpick_started_at,
  c.owner_assigned_at,
  public.club_squad_designation_edit_reason(c."ShortName") AS edit_reason
FROM public."Clubs" c
WHERE c.owner_id IS NOT NULL
  AND (
    c.handpick_started_at IS NOT NULL
    OR c.owner_assigned_at >= timestamptz '2026-10-01'
  )
ORDER BY c.owner_assigned_at DESC NULLS LAST;
