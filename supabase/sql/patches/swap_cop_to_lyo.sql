-- =============================================================================
-- Two-way franchise swap. Installs admin_franchise_identity_swap only.
-- =============================================================================
-- This file does not swap Copenhagen and Lyon by itself. Run it, then use
-- Admin → Club Management → Swap club identities and pick the two clubs.
-- Running the swap twice swaps them back.
--
-- What moves with each franchise (owner, squad, money, transfers):
--   fixtures, forfeits, scores, league slot, ledger, players, manager.
-- What stays on the club code (the real club):
--   name, stadium, capacity, nation, continent, kits, badge, stadium photo,
--   stadium expansion orders.
-- Scores are not recalculated. Existing home fixtures keep the weather already
-- stored on those rows.
--
-- Home-grown follows the nation of the code the squad lands on. The squad
-- that arrives at LYO is judged as French.
--
-- Admin menu (after this file is applied, and the page is published):
--   admin_franchise_swap.html
-- =============================================================================

CREATE OR REPLACE FUNCTION public.admin_franchise_identity_swap(
  p_left text,
  p_right text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_left text := upper(btrim(coalesce(p_left, '')));
  v_right text := upper(btrim(coalesce(p_right, '')));
  v_temp text := 'ZZ9';
  v_left_name text;
  v_right_name text;
  v_left_stadium text;
  v_right_stadium text;
  v_left_cap integer;
  v_right_cap integer;
  v_left_nation text;
  v_right_nation text;
  v_left_base integer;
  v_right_base integer;
  v_left_cont text;
  v_right_cont text;
  v_has_base boolean;
  v_has_cont boolean;
  v_src text;
  v_dst text;
  v_ord integer;
  v_moved integer;
  r record;
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF v_left = '' OR v_right = '' OR v_left = v_right THEN
    RAISE EXCEPTION 'Pick two different club codes';
  END IF;

  IF v_left IN ('FOREIGN', v_temp) OR v_right IN ('FOREIGN', v_temp) THEN
    RAISE EXCEPTION 'That club code cannot be swapped';
  END IF;

  IF EXISTS (SELECT 1 FROM public."Clubs" WHERE "ShortName" = v_temp) THEN
    RAISE EXCEPTION 'Temporary code % is already a club. Rename that row first.', v_temp;
  END IF;

  PERFORM 1 FROM public."Clubs" WHERE "ShortName" = v_left FOR UPDATE;
  PERFORM 1 FROM public."Clubs" WHERE "ShortName" = v_right FOR UPDATE;

  SELECT c."Club", c."Stadium", c."Capacity", c."Nation"
  INTO v_left_name, v_left_stadium, v_left_cap, v_left_nation
  FROM public."Clubs" c
  WHERE c."ShortName" = v_left;

  SELECT c."Club", c."Stadium", c."Capacity", c."Nation"
  INTO v_right_name, v_right_stadium, v_right_cap, v_right_nation
  FROM public."Clubs" c
  WHERE c."ShortName" = v_right;

  IF v_left_name IS NULL THEN
    RAISE EXCEPTION 'Club % not found', v_left;
  END IF;
  IF v_right_name IS NULL THEN
    RAISE EXCEPTION 'Club % not found', v_right;
  END IF;

  SELECT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'Clubs' AND column_name = 'base_capacity'
  ) INTO v_has_base;

  SELECT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'Clubs' AND column_name = 'continent'
  ) INTO v_has_cont;

  IF v_has_base THEN
    EXECUTE 'SELECT base_capacity FROM public."Clubs" WHERE "ShortName" = $1'
      INTO v_left_base USING v_left;
    EXECUTE 'SELECT base_capacity FROM public."Clubs" WHERE "ShortName" = $1'
      INTO v_right_base USING v_right;
  END IF;

  IF v_has_cont THEN
    EXECUTE 'SELECT continent FROM public."Clubs" WHERE "ShortName" = $1'
      INTO v_left_cont USING v_left;
    EXECUTE 'SELECT continent FROM public."Clubs" WHERE "ShortName" = $1'
      INTO v_right_cont USING v_right;
  END IF;

  CREATE TEMP TABLE _club_fks ON COMMIT DROP AS
  SELECT con.conrelid::regclass::text AS tbl,
         att.attname AS col,
         con.conname AS conname,
         pg_get_constraintdef(con.oid) AS def
  FROM pg_constraint con
  JOIN pg_class refcl ON refcl.oid = con.confrelid
  JOIN pg_namespace refns ON refns.oid = refcl.relnamespace
  JOIN pg_attribute refatt ON refatt.attrelid = con.confrelid AND refatt.attnum = con.confkey[1]
  JOIN pg_attribute att ON att.attrelid = con.conrelid AND att.attnum = con.conkey[1]
  WHERE con.contype = 'f'
    AND refns.nspname = 'public'
    AND refcl.relname = 'Clubs'
    AND refatt.attname = 'ShortName';

  FOR r IN SELECT DISTINCT tbl, conname FROM _club_fks LOOP
    EXECUTE format('ALTER TABLE %s DROP CONSTRAINT %I', r.tbl, r.conname);
  END LOOP;

  -- Move the codes one at a time. A direct COP -> LYO hits Clubs_pkey while
  -- LYO is still there. ZZ9 is only a stepping stone and is checked above.
  CREATE TEMP TABLE _hops (
    ord int PRIMARY KEY,
    src text NOT NULL,
    dst text NOT NULL
  ) ON COMMIT DROP;

  INSERT INTO _hops (ord, src, dst) VALUES (1, v_left, v_temp);
  INSERT INTO _hops (ord, src, dst) VALUES (2, v_right, v_left);
  INSERT INTO _hops (ord, src, dst) VALUES (3, v_temp, v_right);

  FOR v_ord, v_src, v_dst IN
    SELECT h.ord, h.src, h.dst
    FROM _hops h
    ORDER BY h.ord
  LOOP
    UPDATE public."Clubs"
    SET "ShortName" = v_dst
    WHERE "ShortName" = v_src;
    GET DIAGNOSTICS v_moved = ROW_COUNT;
    IF v_moved <> 1 THEN
      RAISE EXCEPTION
        'Club code move % (%) -> % changed % rows. Swap stopped; nothing was saved.',
        v_ord, v_src, v_dst, v_moved;
    END IF;
  END LOOP;

  FOR v_ord, v_src, v_dst IN
    SELECT h.ord, h.src, h.dst
    FROM _hops h
    ORDER BY h.ord
  LOOP
    FOR r IN
      SELECT tbl, col
      FROM _club_fks
      WHERE tbl NOT IN ('"Clubs"', 'public."Clubs"', 'Clubs')
    LOOP
      EXECUTE format('UPDATE %s SET %I = $1 WHERE %I = $2', r.tbl, r.col, r.col)
        USING v_dst, v_src;
    END LOOP;

    FOR r IN
      SELECT * FROM (VALUES
        ('public."Players"',                       'Contracted_Team'),
        ('public."Club_Finances"',                 'club_name'),
        ('public."Transfer_History"',              'seller_club_id'),
        ('public."Transfer_History"',              'buyer_club_id'),
        ('public."Player_Transfer_Listings"',      'seller_club_id'),
        ('public."Player_Transfer_Listings"',      'current_highest_bidder'),
        ('public."Player_Transfer_Bids"',          'bidder_club_id'),
        ('public."Player_Transfer_Bids"',          'seller_club_id'),
        ('public.club_squad_player_designations',  'club_short_name'),
        ('public.competition_cup_first_round_byes','club_short_name'),
        ('public.competition_fixtures',            'cup_pen_winner_club_short_name'),
        ('public.competition_result_submissions',  'pen_winner_club_short_name'),
        ('public.special_auctions',                'winning_club_id'),
        ('public.special_auction_bids',            'club_id'),
        ('public.draft_auction_favourites',        'club_id'),
        ('public.contract_expiry_wage_bids',       'bidder_club_short_name'),
        ('public.club_auction_max_bids',           'club_short_name'),
        ('public.gpsl_owner_registry',             'last_club_short_name')
      ) AS t(tbl, col)
    LOOP
      BEGIN
        EXECUTE format('UPDATE %s SET %I = $1 WHERE %I = $2', r.tbl, r.col, r.col)
          USING v_dst, v_src;
      EXCEPTION
        WHEN undefined_table OR undefined_column THEN NULL;
      END;
    END LOOP;
  END LOOP;

  -- Expansion rows followed the franchise. Put them back on the stadium's code.
  IF to_regclass('public.stadium_expansion_orders') IS NOT NULL THEN
    UPDATE public.stadium_expansion_orders SET club_short_name = v_temp WHERE club_short_name = v_left;
    UPDATE public.stadium_expansion_orders SET club_short_name = v_left WHERE club_short_name = v_right;
    UPDATE public.stadium_expansion_orders SET club_short_name = v_right WHERE club_short_name = v_temp;
  END IF;

  IF to_regclass('public.stadium_expansion_quotes') IS NOT NULL THEN
    UPDATE public.stadium_expansion_quotes SET club_short_name = v_temp WHERE club_short_name = v_left;
    UPDATE public.stadium_expansion_quotes SET club_short_name = v_left WHERE club_short_name = v_right;
    UPDATE public.stadium_expansion_quotes SET club_short_name = v_right WHERE club_short_name = v_temp;
  END IF;

  UPDATE public."Clubs"
  SET "Club" = v_left_name,
      "Stadium" = v_left_stadium,
      "Capacity" = v_left_cap,
      "Nation" = v_left_nation
  WHERE "ShortName" = v_left;

  UPDATE public."Clubs"
  SET "Club" = v_right_name,
      "Stadium" = v_right_stadium,
      "Capacity" = v_right_cap,
      "Nation" = v_right_nation
  WHERE "ShortName" = v_right;

  IF v_has_base THEN
    EXECUTE 'UPDATE public."Clubs" SET base_capacity = $1 WHERE "ShortName" = $2'
      USING v_left_base, v_left;
    EXECUTE 'UPDATE public."Clubs" SET base_capacity = $1 WHERE "ShortName" = $2'
      USING v_right_base, v_right;
  END IF;

  IF v_has_cont THEN
    EXECUTE 'UPDATE public."Clubs" SET continent = $1 WHERE "ShortName" = $2'
      USING v_left_cont, v_left;
    EXECUTE 'UPDATE public."Clubs" SET continent = $1 WHERE "ShortName" = $2'
      USING v_right_cont, v_right;
  END IF;

  FOR r IN SELECT DISTINCT tbl, conname, def FROM _club_fks LOOP
    EXECUTE format('ALTER TABLE %s ADD CONSTRAINT %I %s', r.tbl, r.conname, r.def);
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true,
    'left', v_left,
    'right', v_right,
    'left_name', v_left_name,
    'right_name', v_right_name,
    'left_stadium', v_left_stadium,
    'right_stadium', v_right_stadium
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.admin_franchise_identity_swap(text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_franchise_identity_swap(text, text) TO authenticated;

NOTIFY pgrst, 'reload schema';
