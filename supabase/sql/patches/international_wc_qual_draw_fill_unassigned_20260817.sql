-- =============================================================================
-- WC qual draw: owned nations + fill with unassigned active nations to 60
--
-- Previously required exactly 60 owner-assigned nations.
-- Now: take all active owner nations, then top unassigned active nations by
-- seed_rank until 60 (12×5). Safe re-run.
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
  v_unassigned_active integer;
  v_fillers_needed integer;
  v_clubs_no_nation text;
  v_inactive_nations text;
  v_ok boolean;
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

  SELECT count(*)::integer INTO v_unassigned_active
  FROM public.international_nations n
  WHERE n.active = true
    AND NOT EXISTS (
      SELECT 1
      FROM public.international_owner_nations o
      WHERE o.nation_code = n.code
        AND o.is_active = true
    );

  v_fillers_needed := greatest(0, 60 - v_active_assigned);
  v_ok := v_active_assigned <= 60
    AND (v_active_assigned + v_unassigned_active) >= 60;

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
    'ok', v_ok,
    'owned_clubs', v_owned,
    'active_assigned_nations', v_active_assigned,
    'unassigned_active_nations', v_unassigned_active,
    'fillers_needed', v_fillers_needed,
    'needed', 60,
    'clubs_without_nation', coalesce(v_clubs_no_nation, ''),
    'assigned_inactive_nations', coalesce(v_inactive_nations, ''),
    'note',
      'Draw uses owned active nations first, then fills with unassigned active nations by seed_rank.'
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
  v_owned text[];
  v_fillers text[];
  v_nations text[];
  v_pot text[];
  v_groups text[] := ARRAY['A','B','C','D','E','F','G','H','I','J','K','L'];
  v_group_ids bigint[] := ARRAY[]::bigint[];
  v_gid bigint;
  v_i int;
  v_pot_no int;
  v_code text;
  v_owned_n int;
  v_need_fill int;
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

  -- 1) Owner-held active nations (seed order)
  SELECT coalesce(array_agg(x.code ORDER BY x.seed_rank, x.code), ARRAY[]::text[])
  INTO v_owned
  FROM (
    SELECT n.code, n.seed_rank
    FROM public.international_owner_nations o
    JOIN public.international_nations n ON n.code = o.nation_code
    WHERE o.is_active = true
      AND n.active = true
    ORDER BY n.seed_rank ASC, n.code ASC
  ) x;

  v_owned_n := coalesce(array_length(v_owned, 1), 0);

  IF v_owned_n > 60 THEN
    RAISE EXCEPTION
      'Too many owner nations for a 60-team draw (have %). Release extras first.',
      v_owned_n;
  END IF;

  v_need_fill := 60 - v_owned_n;

  -- 2) Fill with unassigned active nations (best seed_rank first)
  IF v_need_fill > 0 THEN
    SELECT coalesce(array_agg(x.code ORDER BY x.seed_rank, x.code), ARRAY[]::text[])
    INTO v_fillers
    FROM (
      SELECT n.code, n.seed_rank
      FROM public.international_nations n
      WHERE n.active = true
        AND NOT EXISTS (
          SELECT 1
          FROM public.international_owner_nations o
          WHERE o.nation_code = n.code
            AND o.is_active = true
        )
      ORDER BY n.seed_rank ASC, n.code ASC
      LIMIT v_need_fill
    ) x;

    IF coalesce(array_length(v_fillers, 1), 0) < v_need_fill THEN
      v_ready := public.international_admin_qual_draw_readiness();
      v_msg := format(
        'Need 60 nations for qualifying draw (have %s owned + %s unassigned fillers available; need %s fillers).',
        v_owned_n,
        coalesce(v_ready->>'unassigned_active_nations', '?'),
        v_need_fill
      );
      IF nullif(v_ready->>'assigned_inactive_nations', '') IS NOT NULL THEN
        v_msg := v_msg || ' Assigned but inactive: ' || (v_ready->>'assigned_inactive_nations') || '.';
      END IF;
      v_msg := v_msg || ' Run Setup → Apply selectable (or assign more nations), then retry.';
      RAISE EXCEPTION '%', v_msg;
    END IF;

    v_nations := v_owned || v_fillers;
  ELSE
    v_fillers := ARRAY[]::text[];
    v_nations := v_owned;
  END IF;

  -- Re-sort full field by seed so pots stay 1–12 / 13–24 / …
  SELECT array_agg(x.code ORDER BY x.seed_rank, x.code)
  INTO v_nations
  FROM (
    SELECT n.code, n.seed_rank
    FROM public.international_nations n
    WHERE n.code = ANY (v_nations)
  ) x;

  IF coalesce(array_length(v_nations, 1), 0) <> 60 THEN
    RAISE EXCEPTION 'Internal error: draw field size is % (expected 60)',
      coalesce(array_length(v_nations, 1), 0);
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
    'owned_nations', v_owned_n,
    'filler_nations', v_need_fill,
    'status', 'qualifying'
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.international_admin_qual_draw_readiness() TO authenticated;
GRANT EXECUTE ON FUNCTION public.international_admin_draw_qual_groups(bigint) TO authenticated;

NOTIFY pgrst, 'reload schema';
