-- =============================================================================
-- WC qual draw: clearer readiness when not exactly 60 owner nations
--
-- Error now lists clubs missing a nation and assigned nations that are inactive.
-- Also adds international_admin_qual_draw_readiness() for the admin UI.
--
-- Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.international_admin_qual_draw_readiness()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_owned integer;
  v_active_assigned integer;
  v_clubs_no_nation text;
  v_inactive_nations text;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  SELECT count(*)::integer INTO v_owned
  FROM public."Clubs" c
  WHERE c.owner_id IS NOT NULL
    AND c."ShortName" <> 'FOREIGN';

  SELECT count(*)::integer INTO v_active_assigned
  FROM public.international_owner_nations o
  JOIN public.international_nations n ON n.code = o.nation_code
  WHERE o.is_active = true
    AND n.active = true;

  SELECT string_agg(x.club, ', ' ORDER BY x.club)
  INTO v_clubs_no_nation
  FROM (
    SELECT coalesce(c."Club", c."ShortName") || ' [' || c."ShortName" || ']' AS club
    FROM public."Clubs" c
    WHERE c.owner_id IS NOT NULL
      AND c."ShortName" <> 'FOREIGN'
      AND NOT EXISTS (
        SELECT 1
        FROM public.international_owner_nations o
        WHERE o.club_short_name = c."ShortName"
          AND o.is_active = true
      )
    ORDER BY c."ShortName"
    LIMIT 15
  ) x;

  SELECT string_agg(x.lbl, ', ' ORDER BY x.lbl)
  INTO v_inactive_nations
  FROM (
    SELECT o.nation_code || ' (' || coalesce(n.name, '?') || ') → ' || o.club_short_name AS lbl
    FROM public.international_owner_nations o
    JOIN public.international_nations n ON n.code = o.nation_code
    WHERE o.is_active = true
      AND n.active IS DISTINCT FROM true
    ORDER BY o.nation_code
    LIMIT 15
  ) x;

  RETURN jsonb_build_object(
    'ok', v_active_assigned = 60,
    'owned_clubs', v_owned,
    'active_assigned_nations', v_active_assigned,
    'needed', 60,
    'clubs_without_nation', coalesce(v_clubs_no_nation, ''),
    'assigned_inactive_nations', coalesce(v_inactive_nations, '')
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.international_admin_draw_qual_groups(p_cycle_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_cycle public.international_wc_cycles;
  v_nations text[];
  v_pot text[];
  v_groups text[] := ARRAY['A','B','C','D','E','F','G','H','I','J','K','L'];
  v_group_ids bigint[] := ARRAY[]::bigint[];
  v_gid bigint;
  v_i int;
  v_pot_no int;
  v_code text;
  v_have int;
  v_ready jsonb;
  v_msg text;
BEGIN
  v_cycle := public.international_assert_cycle_admin(p_cycle_id);

  IF v_cycle.status NOT IN ('setup', 'qualifying') THEN
    RAISE EXCEPTION 'Qualifying draw only allowed in setup/qualifying';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.international_fixtures f
    WHERE f.cycle_id = p_cycle_id AND f.phase = 'qualifying' AND f.played = true
  ) THEN
    RAISE EXCEPTION 'Cannot re-draw: qualifying fixtures already played';
  END IF;

  SELECT array_agg(x.code ORDER BY x.seed_rank, x.code)
  INTO v_nations
  FROM (
    SELECT n.code, n.seed_rank
    FROM public.international_owner_nations o
    JOIN public.international_nations n ON n.code = o.nation_code
    WHERE o.is_active = true
      AND n.active = true
    ORDER BY n.seed_rank ASC, n.code ASC
  ) x;

  v_have := coalesce(array_length(v_nations, 1), 0);

  IF v_have <> 60 THEN
    v_ready := public.international_admin_qual_draw_readiness();
    v_msg := format(
      'Need exactly 60 active owner nations for qualifying draw (have %s).',
      v_have
    );
    IF nullif(v_ready->>'clubs_without_nation', '') IS NOT NULL THEN
      v_msg := v_msg || ' Clubs without a nation: ' || (v_ready->>'clubs_without_nation') || '.';
    END IF;
    IF nullif(v_ready->>'assigned_inactive_nations', '') IS NOT NULL THEN
      v_msg := v_msg || ' Assigned but inactive nations: ' || (v_ready->>'assigned_inactive_nations') || '.';
    END IF;
    v_msg := v_msg || ' Assign the missing nation (or re-activate it) then retry.';
    RAISE EXCEPTION '%', v_msg;
  END IF;

  DELETE FROM public.international_fixtures
  WHERE cycle_id = p_cycle_id AND phase = 'qualifying';

  DELETE FROM public.international_qual_group_members m
  USING public.international_qual_groups g
  WHERE m.group_id = g.id AND g.cycle_id = p_cycle_id;

  DELETE FROM public.international_qual_groups WHERE cycle_id = p_cycle_id;

  FOREACH v_code IN ARRAY v_groups LOOP
    INSERT INTO public.international_qual_groups (cycle_id, group_code)
    VALUES (p_cycle_id, v_code)
    RETURNING id INTO v_gid;
    v_group_ids := v_group_ids || v_gid;
  END LOOP;

  FOR v_pot_no IN 1..5 LOOP
    v_pot := v_nations[((v_pot_no - 1) * 12 + 1):(v_pot_no * 12)];
    v_pot := public.international_shuffle_text_array(v_pot);
    FOR v_i IN 1..12 LOOP
      INSERT INTO public.international_qual_group_members (group_id, nation_code)
      VALUES (v_group_ids[v_i], v_pot[v_i]);
    END LOOP;
  END LOOP;

  IF v_cycle.status = 'setup' THEN
    UPDATE public.international_wc_cycles SET status = 'qualifying' WHERE id = p_cycle_id;
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'cycle_id', p_cycle_id,
    'groups', 12,
    'nations', 60,
    'status', 'qualifying'
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.international_admin_qual_draw_readiness() TO authenticated;
GRANT EXECUTE ON FUNCTION public.international_admin_draw_qual_groups(bigint) TO authenticated;

NOTIFY pgrst, 'reload schema';
