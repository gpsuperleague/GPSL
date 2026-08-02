-- =============================================================================
-- National team managers (separate from club managers)
--
-- - Appointed when a nation is claimed in selection (no fee)
-- - One active manager per nation; one nation per manager (no duplicates)
-- - Uses Managers catalog only as identity — does NOT touch contracted_club /
--   Clubs.manager_id / transfer market
-- - Cleared with nation release (admin clear, admin release, post-WC reselection)
--
-- Safe re-run.
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.international_nation_managers (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  nation_code text NOT NULL REFERENCES public.international_nations (code) ON DELETE CASCADE,
  manager_id bigint NOT NULL REFERENCES public."Managers" (id) ON DELETE RESTRICT,
  appointed_by_club text REFERENCES public."Clubs" ("ShortName") ON DELETE SET NULL,
  selection_phase text,
  cycle_id bigint REFERENCES public.international_wc_cycles (id) ON DELETE SET NULL,
  is_active boolean NOT NULL DEFAULT true,
  appointed_at timestamptz NOT NULL DEFAULT now(),
  released_at timestamptz
);

CREATE UNIQUE INDEX IF NOT EXISTS international_nation_managers_active_nation_uidx
  ON public.international_nation_managers (nation_code)
  WHERE is_active;

CREATE UNIQUE INDEX IF NOT EXISTS international_nation_managers_active_manager_uidx
  ON public.international_nation_managers (manager_id)
  WHERE is_active;

CREATE INDEX IF NOT EXISTS international_nation_managers_manager_idx
  ON public.international_nation_managers (manager_id);

COMMENT ON TABLE public.international_nation_managers IS
  'National-team manager appointments. Separate from club manager contracts.';

ALTER TABLE public.international_nation_managers ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS international_nation_managers_select ON public.international_nation_managers;
CREATE POLICY international_nation_managers_select ON public.international_nation_managers
  FOR SELECT TO authenticated, anon
  USING (true);

GRANT SELECT ON public.international_nation_managers TO authenticated, anon;

-- ---------------------------------------------------------------------------
-- Release helpers
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.international_release_nation_managers(
  p_nation_code text DEFAULT NULL
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_count integer := 0;
  v_nation text := nullif(btrim(upper(coalesce(p_nation_code, ''))), '');
BEGIN
  UPDATE public.international_nation_managers
  SET is_active = false,
      released_at = now()
  WHERE is_active = true
    AND (v_nation IS NULL OR nation_code = v_nation);

  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$function$;

CREATE OR REPLACE FUNCTION public.international_appoint_nation_manager(
  p_nation_code text,
  p_manager_id bigint,
  p_appointed_by_club text DEFAULT NULL,
  p_selection_phase text DEFAULT NULL,
  p_cycle_id bigint DEFAULT NULL
)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_nation text := btrim(upper(coalesce(p_nation_code, '')));
  v_id bigint;
  v_cycle_id bigint := p_cycle_id;
BEGIN
  IF v_nation = '' THEN
    RAISE EXCEPTION 'Nation is required';
  END IF;
  IF p_manager_id IS NULL THEN
    RAISE EXCEPTION 'Manager is required';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM public."Managers" m WHERE m.id = p_manager_id) THEN
    RAISE EXCEPTION 'Manager not found';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.international_nation_managers inm
    WHERE inm.manager_id = p_manager_id
      AND inm.is_active = true
      AND inm.nation_code IS DISTINCT FROM v_nation
  ) THEN
    RAISE EXCEPTION 'That manager is already appointed to another national team';
  END IF;

  -- Replace any active appointment for this nation
  PERFORM public.international_release_nation_managers(v_nation);

  IF v_cycle_id IS NULL THEN
    SELECT id INTO v_cycle_id
    FROM public.international_wc_cycles
    ORDER BY cycle_no DESC
    LIMIT 1;
  END IF;

  INSERT INTO public.international_nation_managers (
    nation_code,
    manager_id,
    appointed_by_club,
    selection_phase,
    cycle_id,
    is_active
  )
  VALUES (
    v_nation,
    p_manager_id,
    nullif(btrim(coalesce(p_appointed_by_club, '')), ''),
    nullif(btrim(coalesce(p_selection_phase, '')), ''),
    v_cycle_id,
    true
  )
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$function$;

-- ---------------------------------------------------------------------------
-- Claim nation + appoint manager (no fee)
-- ---------------------------------------------------------------------------

DROP FUNCTION IF EXISTS public.international_claim_nation(text);

CREATE OR REPLACE FUNCTION public.international_claim_nation(
  p_nation_code text,
  p_manager_id bigint
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := public.my_club_shortname();
  v_window record;
  v_my_pick smallint;
  v_current_pick smallint;
  v_nation text := btrim(upper(p_nation_code));
  v_cycle_id bigint;
  v_next_pick smallint;
  v_nation_name text;
  v_mode text;
  v_has_nation boolean;
  v_waiting integer;
  v_mgr_name text;
  v_appointment_id bigint;
  v_prev_nation text;
BEGIN
  IF v_club IS NULL OR v_club = '' THEN
    RAISE EXCEPTION 'No club linked to your account';
  END IF;

  IF p_manager_id IS NULL THEN
    RAISE EXCEPTION 'Choose a national team manager when claiming a nation';
  END IF;

  SELECT * INTO v_window
  FROM public.international_selection_windows
  WHERE is_open = true
  ORDER BY id DESC
  LIMIT 1;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Nation selection is not open';
  END IF;

  v_mode := coalesce(v_window.pick_mode, 'ordered');

  SELECT pick_order INTO v_my_pick
  FROM public.international_owner_draft_order()
  WHERE club_short_name = v_club;

  IF v_my_pick IS NULL THEN
    RAISE EXCEPTION 'Your club is not in the owner draft order';
  END IF;

  SELECT EXISTS (
    SELECT 1 FROM public.international_owner_nations ion
    WHERE ion.club_short_name = v_club AND ion.is_active = true
  ) INTO v_has_nation;

  IF v_mode = 'free_for_all' THEN
    IF v_has_nation THEN
      RAISE EXCEPTION 'You already have a national team — free-for-all is only for clubs still without a nation';
    END IF;
  ELSE
    v_current_pick := v_window.current_pick_rank;
    IF v_my_pick <> v_current_pick THEN
      RAISE EXCEPTION 'Not your pick yet (currently pick #% — you are #%).', v_current_pick, v_my_pick;
    END IF;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.international_nations n
    WHERE n.code = v_nation AND n.active = true
  ) THEN
    RAISE EXCEPTION 'Nation not found';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.international_owner_nations ion
    WHERE ion.nation_code = v_nation AND ion.is_active = true
  ) THEN
    RAISE EXCEPTION 'Nation already taken';
  END IF;

  IF to_regprocedure('public.international_nation_pool_is_selectable(text)') IS NOT NULL
     AND NOT public.international_nation_pool_is_selectable(v_nation) THEN
    RAISE EXCEPTION 'This nation cannot be selected — GPDB pool too small for a squad or GPSL club';
  END IF;

  SELECT m.name INTO v_mgr_name
  FROM public."Managers" m
  WHERE m.id = p_manager_id;

  IF v_mgr_name IS NULL THEN
    RAISE EXCEPTION 'Manager not found';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.international_nation_managers inm
    WHERE inm.manager_id = p_manager_id
      AND inm.is_active = true
  ) THEN
    RAISE EXCEPTION '% is already appointed to another national team', v_mgr_name;
  END IF;

  SELECT n.name INTO v_nation_name FROM public.international_nations n WHERE n.code = v_nation;

  SELECT id INTO v_cycle_id FROM public.international_wc_cycles ORDER BY cycle_no DESC LIMIT 1;

  -- Release prior nation + its manager for this club (should be none in normal flow)
  SELECT ion.nation_code INTO v_prev_nation
  FROM public.international_owner_nations ion
  WHERE ion.club_short_name = v_club AND ion.is_active = true
  ORDER BY ion.id DESC
  LIMIT 1;

  IF v_prev_nation IS NOT NULL THEN
    PERFORM public.international_release_nation_managers(v_prev_nation);
  END IF;

  UPDATE public.international_owner_nations
  SET is_active = false, released_at = now()
  WHERE club_short_name = v_club AND is_active = true;

  INSERT INTO public.international_owner_nations (
    club_short_name, nation_code, cycle_id, selection_phase, is_active, locked_until_cycle_id
  )
  VALUES (v_club, v_nation, v_cycle_id, v_window.phase, true, v_cycle_id);

  v_appointment_id := public.international_appoint_nation_manager(
    v_nation,
    p_manager_id,
    v_club,
    v_window.phase,
    v_cycle_id
  );

  SELECT count(*)::integer INTO v_waiting
  FROM public.international_owner_draft_order() d
  WHERE NOT EXISTS (
    SELECT 1 FROM public.international_owner_nations ion
    WHERE ion.club_short_name = d.club_short_name AND ion.is_active = true
  );

  SELECT coalesce(min(pick_order), 61)::smallint INTO v_next_pick
  FROM public.international_owner_draft_order() d
  WHERE NOT EXISTS (
    SELECT 1 FROM public.international_owner_nations ion
    WHERE ion.club_short_name = d.club_short_name AND ion.is_active = true
  );

  IF v_waiting = 0 OR v_next_pick >= 61 THEN
    UPDATE public.international_selection_windows
    SET is_open = false, closes_at = now()
    WHERE id = v_window.id;
  ELSIF v_mode = 'ordered' THEN
    UPDATE public.international_selection_windows
    SET current_pick_rank = v_next_pick
    WHERE id = v_window.id;
    IF to_regprocedure('public.owner_inbox_notify_nation_pick_turn(smallint)') IS NOT NULL THEN
      PERFORM public.owner_inbox_notify_nation_pick_turn(v_next_pick);
    ELSIF to_regprocedure('public.owner_inbox_notify_nation_pick_turn(integer)') IS NOT NULL THEN
      PERFORM public.owner_inbox_notify_nation_pick_turn(v_next_pick::integer);
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'club', v_club,
    'nation', v_nation,
    'nation_name', v_nation_name,
    'manager_id', p_manager_id,
    'manager_name', v_mgr_name,
    'appointment_id', v_appointment_id,
    'pick', v_my_pick,
    'next_pick', v_next_pick,
    'pick_mode', v_mode,
    'waiting', v_waiting
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.international_claim_nation(text, bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.international_appoint_nation_manager(text, bigint, text, text, bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.international_release_nation_managers(text) TO authenticated;

-- ---------------------------------------------------------------------------
-- Admin assign / release / clear — also manage national managers
-- ---------------------------------------------------------------------------

DROP FUNCTION IF EXISTS public.international_admin_assign_nation(text, text);

CREATE OR REPLACE FUNCTION public.international_admin_assign_nation(
  p_club text,
  p_nation_code text,
  p_manager_id bigint DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_cycle_id bigint;
  v_club text := btrim(p_club);
  v_nation text := btrim(upper(p_nation_code));
  v_prev_nation text;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  SELECT id INTO v_cycle_id
  FROM public.international_wc_cycles
  ORDER BY cycle_no DESC
  LIMIT 1;

  -- Release managers for club's previous nation and target nation
  SELECT ion.nation_code INTO v_prev_nation
  FROM public.international_owner_nations ion
  WHERE ion.club_short_name = v_club AND ion.is_active = true
  ORDER BY ion.id DESC
  LIMIT 1;

  IF v_prev_nation IS NOT NULL THEN
    PERFORM public.international_release_nation_managers(v_prev_nation);
  END IF;

  PERFORM public.international_release_nation_managers(v_nation);

  UPDATE public.international_owner_nations
  SET is_active = false,
      released_at = now()
  WHERE club_short_name = v_club
    AND is_active = true;

  UPDATE public.international_owner_nations
  SET is_active = false,
      released_at = now()
  WHERE nation_code = v_nation
    AND is_active = true;

  INSERT INTO public.international_owner_nations (
    club_short_name,
    nation_code,
    cycle_id,
    selection_phase,
    is_active,
    locked_until_cycle_id
  )
  VALUES (
    v_club,
    v_nation,
    v_cycle_id,
    'admin',
    true,
    v_cycle_id
  );

  IF p_manager_id IS NOT NULL THEN
    PERFORM public.international_appoint_nation_manager(
      v_nation,
      p_manager_id,
      v_club,
      'admin',
      v_cycle_id
    );
  END IF;
END;
$function$;

CREATE OR REPLACE FUNCTION public.international_admin_release_nation(p_club text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := btrim(coalesce(p_club, ''));
  v_nation text;
  v_nation_name text;
  v_count integer := 0;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF v_club = '' THEN
    RAISE EXCEPTION 'Club is required';
  END IF;

  SELECT ion.nation_code INTO v_nation
  FROM public.international_owner_nations ion
  WHERE ion.club_short_name = v_club
    AND ion.is_active = true
  ORDER BY ion.id DESC
  LIMIT 1;

  IF v_nation IS NULL THEN
    RAISE EXCEPTION '% has no active national team', v_club;
  END IF;

  SELECT n.name INTO v_nation_name
  FROM public.international_nations n
  WHERE n.code = v_nation;

  PERFORM public.international_release_nation_managers(v_nation);

  UPDATE public.international_owner_nations
  SET is_active = false,
      released_at = now()
  WHERE club_short_name = v_club
    AND is_active = true;

  GET DIAGNOSTICS v_count = ROW_COUNT;

  RETURN jsonb_build_object(
    'ok', true,
    'club', v_club,
    'nation_code', v_nation,
    'nation_name', coalesce(v_nation_name, v_nation),
    'released', v_count
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.international_admin_clear_nation_assignments()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_count integer := 0;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  UPDATE public.international_selection_windows
  SET is_open = false,
      closes_at = coalesce(closes_at, now())
  WHERE is_open = true;

  PERFORM public.international_release_nation_managers(NULL);

  UPDATE public.international_owner_nations
  SET is_active = false,
      released_at = now()
  WHERE is_active = true;

  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$function$;

CREATE OR REPLACE FUNCTION public.international_admin_complete_wc_and_open_reselection(
  p_cycle_id bigint
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_cycle public.international_wc_cycles;
  v_cleared int;
  v_managers_cleared int;
  v_window_id bigint;
BEGIN
  v_cycle := public.international_assert_cycle_admin(p_cycle_id);

  UPDATE public.international_wc_cycles SET status = 'complete' WHERE id = p_cycle_id;

  IF to_regprocedure('public.competition_owner_ranking_recompute_all()') IS NOT NULL THEN
    PERFORM public.competition_owner_ranking_recompute_all();
  END IF;

  -- Managers leave after WC finals, before next nation selection
  v_managers_cleared := public.international_release_nation_managers(NULL);

  UPDATE public.international_owner_nations
  SET is_active = false, released_at = now()
  WHERE is_active = true;
  GET DIAGNOSTICS v_cleared = ROW_COUNT;

  UPDATE public.international_selection_windows
  SET is_open = false, closes_at = coalesce(closes_at, now())
  WHERE is_open = true;

  INSERT INTO public.international_selection_windows (phase, is_open, opens_at, current_pick_rank)
  VALUES ('post_world_cup', true, now(), 1)
  RETURNING id INTO v_window_id;

  IF to_regprocedure('public.owner_inbox_notify_all_clubs(text,text,text,text,text,bigint)') IS NOT NULL THEN
    PERFORM public.owner_inbox_notify_all_clubs(
      'nation_selection_open',
      'Post–World Cup nation re-selection is open',
      E'The World Cup is complete. All nations and national managers are free — pick again in ranking order.',
      'nation_select.html',
      'post_wc_open:' || v_window_id::text,
      NULL
    );
  END IF;

  IF to_regprocedure('public.owner_inbox_notify_nation_pick_turn(integer)') IS NOT NULL THEN
    PERFORM public.owner_inbox_notify_nation_pick_turn(1);
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'cycle_id', p_cycle_id,
    'nations_released', v_cleared,
    'managers_released', v_managers_cleared,
    'selection_window_id', v_window_id
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.international_admin_assign_nation(text, text, bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.international_admin_release_nation(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.international_admin_clear_nation_assignments() TO authenticated;
GRANT EXECUTE ON FUNCTION public.international_admin_complete_wc_and_open_reselection(bigint) TO authenticated;

-- ---------------------------------------------------------------------------
-- Public views
-- ---------------------------------------------------------------------------

DROP VIEW IF EXISTS public.international_nation_managers_public;
CREATE VIEW public.international_nation_managers_public
WITH (security_invoker = false)
AS
SELECT
  inm.id,
  inm.nation_code,
  n.name AS nation_name,
  inm.manager_id,
  m.name AS manager_name,
  m.rating AS manager_rating,
  m.nation AS manager_nation,
  inm.appointed_by_club,
  inm.selection_phase,
  inm.cycle_id,
  inm.is_active,
  inm.appointed_at,
  inm.released_at
FROM public.international_nation_managers inm
JOIN public.international_nations n ON n.code = inm.nation_code
JOIN public."Managers" m ON m.id = inm.manager_id;

GRANT SELECT ON public.international_nation_managers_public TO authenticated, anon;

DROP VIEW IF EXISTS public.international_nations_public;
CREATE VIEW public.international_nations_public
WITH (security_invoker = false)
AS
SELECT
  n.code,
  n.name,
  n.flag_emoji,
  n.seed_rank,
  ion.club_short_name AS owner_club,
  c."Club" AS owner_club_name,
  coalesce(nullif(btrim(c.owner), ''), c."ShortName") AS owner_tag,
  (ion.id IS NOT NULL) AS is_taken,
  inm.manager_id,
  m.name AS manager_name,
  m.rating AS manager_rating
FROM public.international_nations n
LEFT JOIN public.international_owner_nations ion
  ON ion.nation_code = n.code AND ion.is_active = true
LEFT JOIN public."Clubs" c ON c."ShortName" = ion.club_short_name
LEFT JOIN public.international_nation_managers inm
  ON inm.nation_code = n.code AND inm.is_active = true
LEFT JOIN public."Managers" m ON m.id = inm.manager_id
WHERE n.active = true
ORDER BY n.seed_rank;

GRANT SELECT ON public.international_nations_public TO authenticated;

-- Managers free for national appointment (not already on a nation)
DROP VIEW IF EXISTS public.international_available_nation_managers_public;
CREATE VIEW public.international_available_nation_managers_public
WITH (security_invoker = false)
AS
SELECT
  m.id,
  m.name,
  m.nation,
  m.rating,
  m.age
FROM public."Managers" m
WHERE NOT EXISTS (
  SELECT 1
  FROM public.international_nation_managers inm
  WHERE inm.manager_id = m.id
    AND inm.is_active = true
)
ORDER BY m.rating DESC, m.name ASC;

GRANT SELECT ON public.international_available_nation_managers_public TO authenticated;

NOTIFY pgrst, 'reload schema';
