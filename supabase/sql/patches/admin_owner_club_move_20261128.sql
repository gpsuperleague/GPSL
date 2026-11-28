-- Admin move: owner leaves one club and joins an empty one.
-- The club they leave loses its players and manager. Its bank and records stay.
-- The club they join resets its bank to the starting balance. Its records stay.
-- Owner personal wealth is not touched.
-- The old owner self-serve swap and the identity swap no longer run.
-- Safe to re-run.

CREATE TABLE IF NOT EXISTS public.admin_owner_club_move_log (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  owner_id uuid NOT NULL,
  from_club text NOT NULL,
  to_club text NOT NULL,
  moved_by uuid,
  moved_at timestamptz NOT NULL DEFAULT now(),
  players_released int NOT NULL DEFAULT 0,
  balance_reset_to numeric
);

ALTER TABLE public.admin_owner_club_move_log ENABLE ROW LEVEL SECURITY;

CREATE OR REPLACE FUNCTION public.admin_club_release_squad(p_club text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_short text := upper(btrim(coalesce(p_club, '')));
  v_pid text;
  v_mgr_id bigint;
  v_players int := 0;
  v_listings int := 0;
BEGIN
  IF v_short = '' OR v_short = 'FOREIGN' THEN
    RETURN jsonb_build_object('ok', false, 'players', 0);
  END IF;

  UPDATE public."Player_Transfer_Listings" l
  SET status = 'Closed',
      transfer_completed = false
  WHERE l.status IN ('Active', 'Review', 'Pending Window')
    AND (
      upper(btrim(coalesce(l.seller_club_id, ''))) = v_short
      OR EXISTS (
        SELECT 1
        FROM public."Players" p
        WHERE p."Konami_ID"::text = l.player_id::text
          AND upper(btrim(coalesce(p."Contracted_Team"::text, ''))) = v_short
      )
    );
  GET DIAGNOSTICS v_listings = ROW_COUNT;

  FOR v_pid IN
    SELECT p."Konami_ID"::text
    FROM public."Players" p
    WHERE upper(btrim(coalesce(p."Contracted_Team"::text, ''))) = v_short
  LOOP
    PERFORM public.player_release_from_club(v_pid);
    v_players := v_players + 1;
  END LOOP;

  BEGIN
    UPDATE public.club_emergency_loans
    SET status = 'cancelled',
        completed_at = coalesce(completed_at, now())
    WHERE upper(btrim(club_short_name)) = v_short
      AND status = 'active';
  EXCEPTION WHEN undefined_table OR undefined_column THEN
    NULL;
  END;

  BEGIN
    UPDATE public.club_season_loans
    SET status = 'terminated',
        terminated_at = coalesce(terminated_at, now())
    WHERE upper(btrim(club_short_name)) = v_short
      AND status = 'active';
  EXCEPTION WHEN undefined_table OR undefined_column THEN
    NULL;
  END;

  BEGIN
    DELETE FROM public.club_squad_player_designations
    WHERE upper(btrim(club_short_name)) = v_short;
  EXCEPTION WHEN undefined_table THEN
    NULL;
  END;

  BEGIN
    UPDATE public."Manager_Transfer_Listings"
    SET status = 'Cancelled',
        updated_at = now()
    WHERE status = 'Active'
      AND upper(btrim(coalesce(seller_club_id, ''))) = v_short;
  EXCEPTION WHEN undefined_column THEN
    NULL;
  END;

  SELECT m.id INTO v_mgr_id
  FROM public."Managers" m
  WHERE upper(btrim(coalesce(m.contracted_club::text, ''))) = v_short
  LIMIT 1;

  IF v_mgr_id IS NULL THEN
    SELECT c.manager_id INTO v_mgr_id
    FROM public."Clubs" c
    WHERE c."ShortName" = v_short;
  END IF;

  IF v_mgr_id IS NOT NULL THEN
    BEGIN
      PERFORM public.manager_release_from_club(
        v_mgr_id,
        NULL::text,
        0::numeric,
        'adjustment'::text,
        'Club emptied for a new owner — manager cleared'::text,
        jsonb_build_object('source', 'admin_club_release_squad', 'club', v_short, 'no_payout', true)
      );
    EXCEPTION WHEN OTHERS THEN
      UPDATE public."Managers"
      SET contracted_club = NULL,
          contract_seasons_remaining = 0,
          updated_at = now()
      WHERE id = v_mgr_id;
    END;
  END IF;

  UPDATE public."Clubs"
  SET manager_id = NULL,
      manager_rating = NULL,
      handpick_intake = false
  WHERE "ShortName" = v_short;

  UPDATE public."Managers"
  SET contracted_club = NULL,
      updated_at = now()
  WHERE upper(btrim(coalesce(contracted_club::text, ''))) = v_short;

  RETURN jsonb_build_object(
    'ok', true,
    'club', v_short,
    'players', v_players,
    'listings_closed', v_listings,
    'manager_id', v_mgr_id
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_owner_change_club(
  p_owner_email text,
  p_new_club_short_name text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_email text := lower(btrim(p_owner_email));
  v_to text := upper(btrim(p_new_club_short_name));
  v_user_id uuid;
  v_from text;
  v_from_name text;
  v_to_name text;
  v_tag text;
  v_nation_from text;
  v_registry_status text;
  v_cleared jsonb;
  v_to_cleared jsonb;
  v_start numeric := 650000000;
  v_balance numeric := 0;
  v_delta numeric := 0;
  v_moves int := 0;
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF v_email IS NULL OR v_email = '' THEN
    RAISE EXCEPTION 'Owner email is required';
  END IF;

  IF v_to IS NULL OR v_to = '' OR v_to = 'FOREIGN' THEN
    RAISE EXCEPTION 'New club ShortName is required';
  END IF;

  SELECT u.id INTO v_user_id
  FROM auth.users u
  WHERE lower(u.email) = v_email
  LIMIT 1;

  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'No auth user with email %', p_owner_email;
  END IF;

  SELECT r.status INTO v_registry_status
  FROM public.gpsl_owner_registry r
  WHERE r.owner_id = v_user_id;

  IF v_registry_status = 'archived' THEN
    RAISE EXCEPTION 'Owner is archived — unarchive before changing club';
  END IF;

  SELECT c."ShortName", c."Club", nullif(btrim(c.owner), '')
  INTO v_from, v_from_name, v_tag
  FROM public."Clubs" c
  WHERE c.owner_id = v_user_id
  LIMIT 1;

  IF v_from IS NULL THEN
    RAISE EXCEPTION 'Owner has no club — use Link existing login to club instead';
  END IF;

  IF v_from = v_to THEN
    RAISE EXCEPTION 'Owner is already on club %', v_to;
  END IF;

  SELECT c."Club" INTO v_to_name
  FROM public."Clubs" c
  WHERE c."ShortName" = v_to
    AND coalesce(c.is_archived, false) = false;

  IF v_to_name IS NULL THEN
    RAISE EXCEPTION 'Club ShortName % not found', v_to;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public."Clubs" c
    WHERE c."ShortName" = v_to
      AND c.owner_id IS NOT NULL
  ) THEN
    RAISE EXCEPTION 'Club % already has an owner. Move that owner off it first.', v_to;
  END IF;

  SELECT ion.nation_code INTO v_nation_from
  FROM public.international_owner_nations ion
  WHERE ion.club_short_name = v_from
    AND ion.is_active = true
  LIMIT 1;

  v_cleared := public.admin_club_release_squad(v_from);
  PERFORM public.admin_club_vacate(v_from);

  v_to_cleared := public.admin_club_release_squad(v_to);

  BEGIN
    v_start := greatest(coalesce(public.club_auction_default_starting_balance(), 650000000), 0);
  EXCEPTION WHEN OTHERS THEN
    v_start := 650000000;
  END;

  IF NOT EXISTS (SELECT 1 FROM public."Club_Finances" f WHERE upper(f.club_name) = v_to) THEN
    INSERT INTO public."Club_Finances" (club_name, balance) VALUES (v_to, 0);
  END IF;

  SELECT coalesce(f.balance, 0) INTO v_balance
  FROM public."Club_Finances" f
  WHERE upper(f.club_name) = v_to
  FOR UPDATE;

  v_delta := v_start - coalesce(v_balance, 0);
  IF v_delta <> 0 THEN
    PERFORM public.post_club_ledger(
      v_to,
      'admin_adjustments',
      v_delta,
      'New owner arrival — club bank reset to the starting balance. Past records stay.',
      jsonb_build_object(
        'source', 'admin_owner_change_club',
        'reset_to', v_start,
        'previous_balance', v_balance,
        'owner_id', v_user_id
      ),
      NULL,
      NULL,
      false,
      true
    );
  END IF;

  UPDATE public."Clubs"
  SET owner_id = v_user_id,
      owner = coalesce(v_tag, owner)
  WHERE "ShortName" = v_to;

  INSERT INTO public.gpsl_owner_registry (
    owner_id, status, owner_tag, last_club_short_name, status_changed_at
  )
  VALUES (v_user_id, 'active', v_tag, v_to, now())
  ON CONFLICT (owner_id) DO UPDATE
  SET status = 'active',
      owner_tag = coalesce(excluded.owner_tag, gpsl_owner_registry.owner_tag),
      last_club_short_name = v_to,
      status_note = NULL,
      status_changed_at = now();

  INSERT INTO public.admin_owner_club_move_log (
    owner_id, from_club, to_club, moved_by, players_released, balance_reset_to
  )
  VALUES (
    v_user_id,
    v_from,
    v_to,
    auth.uid(),
    coalesce((v_cleared->>'players')::int, 0),
    v_start
  );

  SELECT count(*)::int INTO v_moves
  FROM public.admin_owner_club_move_log
  WHERE owner_id = v_user_id;

  RETURN jsonb_build_object(
    'owner_id', v_user_id,
    'email', p_owner_email,
    'from_club_short_name', v_from,
    'from_club_name', v_from_name,
    'to_club_short_name', v_to,
    'to_club_name', v_to_name,
    'released_nation', v_nation_from,
    'players_released', coalesce((v_cleared->>'players')::int, 0),
    'destination_players_cleared', coalesce((v_to_cleared->>'players')::int, 0),
    'balance_reset_to', v_start,
    'club_moves', v_moves
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_owner_club_move_counts()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  RETURN coalesce(
    (
      SELECT jsonb_object_agg(x.owner_id::text, x.n)
      FROM (
        SELECT owner_id, count(*)::int AS n
        FROM public.admin_owner_club_move_log
        GROUP BY owner_id
      ) x
    ),
    '{}'::jsonb
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.owner_club_swap_execute(p_to_club_short text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  RAISE EXCEPTION
    'Club swap has been removed. An admin moves an owner from Change owner club.';
END;
$function$;

CREATE OR REPLACE FUNCTION public.owner_club_swap_vacant_list()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  RETURN jsonb_build_object(
    'ok', false,
    'window_open', false,
    'reason', 'Club swap has been removed. An admin moves an owner from Change owner club.'
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_franchise_identity_swap(
  p_left text,
  p_right text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;
  RAISE EXCEPTION
    'Club identity swap has been removed. Use Change owner club. History stays on each club.';
END;
$function$;

REVOKE ALL ON FUNCTION public.admin_club_release_squad(text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_owner_club_move_counts() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_owner_change_club(text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_owner_club_move_counts() TO authenticated;
GRANT EXECUTE ON FUNCTION public.owner_club_swap_execute(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.owner_club_swap_vacant_list() TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_franchise_identity_swap(text, text) TO authenticated;

NOTIFY pgrst, 'reload schema';

SELECT jsonb_build_object(
  'log', to_regclass('public.admin_owner_club_move_log') IS NOT NULL,
  'move', to_regprocedure('public.admin_owner_change_club(text,text)') IS NOT NULL,
  'swap_closed', position(
    'has been removed' IN pg_get_functiondef('public.owner_club_swap_execute(text)'::regprocedure)
  ) > 0
) AS result;
