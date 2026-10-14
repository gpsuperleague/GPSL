-- =============================================================================
-- Test security_rls_lockdown_20261014.sql WITHOUT changing anything.
--
-- Pretends to be a real (non-admin) owner, then a logged-out visitor, and
-- tries listings / deletes / reads. Everything happens inside a block that is
-- always rolled back — no listing is created, nothing is deleted.
--
-- In the SQL editor is_gpsl_admin() is always true (session_user = postgres),
-- so the test swaps in a JWT-only version for the duration of the block
-- (also rolled back).
-- =============================================================================

DROP TABLE IF EXISTS _rls_test;
CREATE TEMP TABLE _rls_test (
  n int,
  test text,
  expected text,
  result text
);

DO $$
DECLARE
  v_owner uuid;
  v_email text;
  v_club text;
  v_other_club text;
  v_player public."Player_Transfer_Listings".player_id%TYPE;
  v_n int;
  r text[] := ARRAY[]::text[];
  v_has_wrapper boolean := to_regprocedure('public.rollover_season_base()') IS NOT NULL;
BEGIN
  SELECT c.owner_id, u.email, c."ShortName", p."Konami_ID"
  INTO v_owner, v_email, v_club, v_player
  FROM public."Clubs" c
  JOIN auth.users u ON u.id = c.owner_id
  JOIN public."Players" p ON p."Contracted_Team" = c."ShortName"
  WHERE lower(coalesce(u.email, '')) <> 'rotavator66@outlook.com'
  ORDER BY c."ShortName"
  LIMIT 1;

  SELECT c."ShortName" INTO v_other_club
  FROM public."Clubs" c
  WHERE c."ShortName" IS DISTINCT FROM v_club
  ORDER BY c."ShortName"
  LIMIT 1;

  IF v_owner IS NULL THEN
    RAISE EXCEPTION 'No non-admin owner with a player found to test with.';
  END IF;

  r := r || ARRAY['test owner', coalesce(v_email, '?') || ' (' || v_club || '), player ' || v_player::text];

  BEGIN
    EXECUTE $f$
      CREATE OR REPLACE FUNCTION public.is_gpsl_admin()
      RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
      AS $b$
        SELECT lower(coalesce(auth.jwt() ->> 'email', '')) = 'rotavator66@outlook.com'
          OR coalesce(auth.jwt() ->> 'role', '') = 'service_role';
      $b$
    $f$;

    -- ---------- Logged-in owner ----------
    PERFORM set_config(
      'request.jwt.claims',
      json_build_object('sub', v_owner, 'role', 'authenticated', 'email', v_email)::text,
      true
    );
    EXECUTE 'SET LOCAL ROLE authenticated';

    BEGIN
      INSERT INTO public."Player_Transfer_Listings"
        (player_id, seller_club_id, reserve_price, status, listing_type, created_at)
      VALUES (v_player, v_club, 1, 'Pending Window', 'standard', now());
      r := r || ARRAY['owner lists own player', 'ALLOWED'];
    EXCEPTION
      WHEN insufficient_privilege THEN
        r := r || ARRAY['owner lists own player', 'BLOCKED BY RLS: ' || SQLERRM];
      WHEN OTHERS THEN
        r := r || ARRAY['owner lists own player', 'passed security, stopped by game rule: ' || SQLERRM];
    END;

    BEGIN
      INSERT INTO public."Player_Transfer_Listings"
        (player_id, seller_club_id, reserve_price, status, listing_type, created_at)
      VALUES (v_player, v_other_club, 1, 'Pending Window', 'standard', now());
      r := r || ARRAY['owner lists for another club', 'ALLOWED'];
    EXCEPTION
      WHEN insufficient_privilege THEN
        r := r || ARRAY['owner lists for another club', 'BLOCKED BY RLS'];
      WHEN OTHERS THEN
        r := r || ARRAY['owner lists for another club', 'other error: ' || SQLERRM];
    END;

    BEGIN
      DELETE FROM public."Club_Finances";
      GET DIAGNOSTICS v_n = ROW_COUNT;
      r := r || ARRAY['owner deletes Club_Finances', v_n || ' row(s) deleted'];
    EXCEPTION WHEN OTHERS THEN
      r := r || ARRAY['owner deletes Club_Finances', 'BLOCKED: ' || SQLERRM];
    END;

    BEGIN
      SELECT count(*) INTO v_n FROM public."Club_Finances";
      r := r || ARRAY['owner reads Club_Finances', v_n || ' row(s) visible'];
    EXCEPTION WHEN OTHERS THEN
      r := r || ARRAY['owner reads Club_Finances', 'ERROR: ' || SQLERRM];
    END;

    IF v_has_wrapper THEN
      BEGIN
        PERFORM public.rollover_season();
        r := r || ARRAY['owner runs rollover_season', 'RAN'];
      EXCEPTION WHEN OTHERS THEN
        r := r || ARRAY['owner runs rollover_season', 'BLOCKED: ' || SQLERRM];
      END;
    ELSE
      r := r || ARRAY['owner runs rollover_season', 'skipped (wrapper not installed)'];
    END IF;

    -- ---------- Logged-out visitor ----------
    EXECUTE 'RESET ROLE';
    PERFORM set_config('request.jwt.claims', json_build_object('role', 'anon')::text, true);
    EXECUTE 'SET LOCAL ROLE anon';

    BEGIN
      INSERT INTO public."Player_Transfer_Listings"
        (player_id, seller_club_id, reserve_price, status, listing_type, created_at)
      VALUES (v_player, v_club, 1, 'Pending Window', 'standard', now());
      r := r || ARRAY['visitor creates listing', 'ALLOWED'];
    EXCEPTION
      WHEN insufficient_privilege THEN
        r := r || ARRAY['visitor creates listing', 'BLOCKED BY RLS'];
      WHEN OTHERS THEN
        r := r || ARRAY['visitor creates listing', 'other error: ' || SQLERRM];
    END;

    BEGIN
      DELETE FROM public."Club_Finances";
      GET DIAGNOSTICS v_n = ROW_COUNT;
      r := r || ARRAY['visitor deletes Club_Finances', v_n || ' row(s) deleted'];
    EXCEPTION WHEN OTHERS THEN
      r := r || ARRAY['visitor deletes Club_Finances', 'BLOCKED: ' || SQLERRM];
    END;

    BEGIN
      DELETE FROM public.bank_ledger;
      GET DIAGNOSTICS v_n = ROW_COUNT;
      r := r || ARRAY['visitor deletes bank_ledger', v_n || ' row(s) deleted'];
    EXCEPTION WHEN OTHERS THEN
      r := r || ARRAY['visitor deletes bank_ledger', 'BLOCKED: ' || SQLERRM];
    END;

    BEGIN
      DELETE FROM public."Transfer_History";
      GET DIAGNOSTICS v_n = ROW_COUNT;
      r := r || ARRAY['visitor deletes Transfer_History', v_n || ' row(s) deleted'];
    EXCEPTION WHEN OTHERS THEN
      r := r || ARRAY['visitor deletes Transfer_History', 'BLOCKED: ' || SQLERRM];
    END;

    BEGIN
      SELECT count(*) INTO v_n FROM public."Transfer_History";
      r := r || ARRAY['visitor reads Transfer_History', v_n || ' row(s) visible'];
    EXCEPTION WHEN OTHERS THEN
      r := r || ARRAY['visitor reads Transfer_History', 'ERROR: ' || SQLERRM];
    END;

    RAISE EXCEPTION 'undo everything' USING ERRCODE = 'P0099';
  EXCEPTION WHEN SQLSTATE 'P0099' THEN
    NULL;
  END;

  FOR i IN 1 .. array_length(r, 1) / 2 LOOP
    INSERT INTO _rls_test (n, test, expected, result)
    VALUES (
      i,
      r[i * 2 - 1],
      CASE r[i * 2 - 1]
        WHEN 'owner lists own player' THEN 'ALLOWED (or a game rule like season lock)'
        WHEN 'owner lists for another club' THEN 'BLOCKED BY RLS'
        WHEN 'owner deletes Club_Finances' THEN '0 row(s) deleted'
        WHEN 'owner reads Club_Finances' THEN 'more than 0 rows'
        WHEN 'owner runs rollover_season' THEN 'BLOCKED: Admin only'
        WHEN 'visitor creates listing' THEN 'BLOCKED BY RLS'
        WHEN 'visitor deletes Club_Finances' THEN '0 row(s) deleted'
        WHEN 'visitor deletes bank_ledger' THEN '0 row(s) deleted'
        WHEN 'visitor deletes Transfer_History' THEN '0 row(s) deleted'
        WHEN 'visitor reads Transfer_History' THEN 'more than 0 rows'
        ELSE ''
      END,
      r[i * 2]
    );
  END LOOP;
END $$;

SELECT test, expected, result FROM _rls_test ORDER BY n;
