-- Prepare Copenhagen (COP) for a new owner.
--
-- Releases the squad to free agents (no fee, no transfer-history row),
-- clears the manager with no payout, ends active emergency / season loans,
-- and removes the current owner.
-- The owner is put on break, not on the waiting list, so they can be
-- linked to another club later.
-- Club cash, fixtures, and results stay as they are.
-- Run once in the Supabase SQL editor.

SELECT
  'before' AS stage,
  c."ShortName" AS club,
  c."Club" AS club_name,
  c.owner AS owner_tag,
  u.email AS owner_email,
  c.manager_id,
  m.name AS manager_name,
  (SELECT count(*) FROM public."Players" p
    WHERE upper(btrim(p."Contracted_Team"::text)) = 'COP') AS players,
  (SELECT count(*) FROM public.club_emergency_loans l
    WHERE l.club_short_name = 'COP' AND l.status = 'active') AS emergency_loans,
  (SELECT count(*) FROM public.club_season_loans l
    WHERE l.club_short_name = 'COP' AND l.status = 'active') AS season_loans,
  f.balance
FROM public."Clubs" c
LEFT JOIN auth.users u ON u.id = c.owner_id
LEFT JOIN public."Managers" m ON m.id = c.manager_id
LEFT JOIN public."Club_Finances" f ON upper(f.club_name) = 'COP'
WHERE c."ShortName" = 'COP';

DO $prep$
DECLARE
  v_owner uuid;
  v_pid text;
  v_mgr_id bigint;
  v_released int := 0;
  v_listings int := 0;
  v_detach jsonb;
BEGIN
  SELECT c.owner_id INTO v_owner
  FROM public."Clubs" c
  WHERE c."ShortName" = 'COP';

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Club COP not found';
  END IF;

  UPDATE public."Player_Transfer_Listings" l
  SET status = 'Closed',
      transfer_completed = false
  WHERE l.status IN ('Active', 'Review')
    AND EXISTS (
      SELECT 1 FROM public."Players" p
      WHERE p."Konami_ID"::text = l.player_id::text
        AND upper(btrim(p."Contracted_Team"::text)) = 'COP'
    );
  GET DIAGNOSTICS v_listings = ROW_COUNT;

  FOR v_pid IN
    SELECT p."Konami_ID"::text
    FROM public."Players" p
    WHERE upper(btrim(p."Contracted_Team"::text)) = 'COP'
  LOOP
    PERFORM public.player_release_from_club(v_pid);
    v_released := v_released + 1;
  END LOOP;

  UPDATE public.club_emergency_loans
  SET status = 'cancelled',
      completed_at = coalesce(completed_at, now())
  WHERE club_short_name = 'COP'
    AND status = 'active';

  UPDATE public.club_season_loans
  SET status = 'terminated',
      terminated_at = coalesce(terminated_at, now())
  WHERE club_short_name = 'COP'
    AND status = 'active';

  DELETE FROM public.club_squad_player_designations
  WHERE club_short_name = 'COP';

  SELECT m.id INTO v_mgr_id
  FROM public."Managers" m
  WHERE upper(btrim(m.contracted_club::text)) = 'COP'
  LIMIT 1;

  IF v_mgr_id IS NULL THEN
    SELECT c.manager_id INTO v_mgr_id
    FROM public."Clubs" c
    WHERE c."ShortName" = 'COP';
  END IF;

  IF v_mgr_id IS NOT NULL THEN
    BEGIN
      PERFORM public.manager_release_from_club(
        v_mgr_id,
        NULL,
        0,
        'adjustment',
        'Copenhagen prepared for a new owner — manager cleared',
        jsonb_build_object(
          'source', 'prepare_cop_for_new_owner',
          'club', 'COP',
          'no_payout', true
        )
      );
    EXCEPTION WHEN OTHERS THEN
      UPDATE public."Managers"
      SET contracted_club = NULL,
          contract_seasons_remaining = 0,
          weekly_wage = 0,
          updated_at = now()
      WHERE id = v_mgr_id;
      UPDATE public."Clubs"
      SET manager_id = NULL,
          manager_rating = NULL
      WHERE "ShortName" = 'COP';
    END;
  END IF;

  IF v_owner IS NOT NULL THEN
    v_detach := public.admin_owner_detach_core(
      v_owner,
      'on_break',
      'Copenhagen prepared for a new owner'
    );
  END IF;

  UPDATE public."Clubs"
  SET handpick_intake = false,
      manager_id = NULL,
      manager_rating = NULL
  WHERE "ShortName" = 'COP';

  RAISE NOTICE 'COP prepared: % players released, % listings closed, owner %',
    v_released, v_listings, coalesce(v_detach->>'email', '(already vacant)');
END;
$prep$;

SELECT
  'after' AS stage,
  c."ShortName" AS club,
  c.owner_id IS NULL AS vacant,
  c.manager_id IS NULL AS no_manager,
  c.handpick_intake,
  (SELECT count(*) FROM public."Players" p
    WHERE upper(btrim(p."Contracted_Team"::text)) = 'COP') AS players_left,
  (SELECT count(*) FROM public."Managers" m
    WHERE upper(btrim(m.contracted_club::text)) = 'COP') AS managers_left,
  r.status AS former_owner_status,
  r.owner_tag,
  f.balance
FROM public."Clubs" c
LEFT JOIN LATERAL (
  SELECT r.status, r.owner_tag
  FROM public.gpsl_owner_registry r
  WHERE r.last_club_short_name = 'COP'
    AND r.status_note = 'Copenhagen prepared for a new owner'
  ORDER BY r.status_changed_at DESC NULLS LAST
  LIMIT 1
) r ON true
LEFT JOIN public."Club_Finances" f ON upper(f.club_name) = 'COP'
WHERE c."ShortName" = 'COP';
