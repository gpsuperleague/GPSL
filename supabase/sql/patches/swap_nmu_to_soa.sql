-- =============================================================================
-- Franchise swap: New Mexico United (USA)  ->  SOA (Ivory Coast)
-- =============================================================================
-- Societe Omnisports de l'Armee (SOA). Keeps squad, fixtures, league position,
-- finances, ledgers, transfer history, cups, expansions, and owner. Identity
-- changes — incl. Nation (United States -> Côte d'Ivoire) and continent
-- (north_america -> africa).
--
-- PREREQUISITE: run competition_continent_africa.sql first (adds africa to the
-- weather system CHECK + config). Nation spelling matches GPDB: Côte d'Ivoire.
--
-- HOW IT STAYS SAFE (single atomic DO block — any error rolls everything back):
--   1. Captures every FOREIGN KEY referencing public."Clubs"("ShortName").
--   2. Drops those FKs so the primary-key value can change.
--   3. Repoints the parent row + every referencing column (incl. legacy non-FK
--      columns) from the old code -> the new code.
--   4. Recreates the FKs exactly as they were (validates the new data).
--
-- AFTER RUNNING THIS: the app keys image assets by ShortName, so add:
--   images/stadiums/SOA.jpg
--   images/club_badges/SOA.png
--   images/clubs_kits/SOA_{home,away,third}.png  (or upload via admin_club_kits)
--
-- NOTE: existing home fixtures keep weather/pitch baked from north_america.
-- New fixtures use africa. To re-roll existing ones:
--   SELECT public.competition_admin_reapply_fixture_conditions();
-- =============================================================================

DO $$
DECLARE
  v_old        text;                                  -- resolved below
  v_new        text := 'SOA';
  v_old_name   text := 'New Mexico United';
  v_club_name  text := 'Societe Omnisports de l''Armee';
  v_stadium    text := 'Stade Charles Konan Banny';
  v_capacity   integer := 20000;
  v_nation     text := 'Côte d''Ivoire';  -- exact GPDB Players."Nation" spelling
  v_continent  text := 'africa';
  v_matches    int;
  r            record;
BEGIN
  -- ---------------------------------------------------------------------------
  -- 0a. Already swapped (ShortName SOA) — just refresh identity fields & exit.
  --     Happens if a prior run / partial update already renamed NMU → SOA.
  -- ---------------------------------------------------------------------------
  IF EXISTS (SELECT 1 FROM public."Clubs" WHERE "ShortName" = v_new) THEN
    UPDATE public."Clubs"
    SET "Club"     = v_club_name,
        "Stadium"  = v_stadium,
        "Capacity" = v_capacity,
        "Nation"   = v_nation
    WHERE "ShortName" = v_new;

    BEGIN
      EXECUTE 'UPDATE public."Clubs" SET base_capacity = $1 WHERE "ShortName" = $2'
        USING v_capacity, v_new;
    EXCEPTION WHEN undefined_column THEN NULL;
    END;

    BEGIN
      EXECUTE 'UPDATE public."Clubs" SET continent = $1 WHERE "ShortName" = $2'
        USING v_continent, v_new;
    EXCEPTION WHEN undefined_column THEN NULL;
    END;

    RAISE NOTICE
      'SOA already present — identity refreshed (Nation=%, continent=%). No ShortName rewrite.',
      v_nation, v_continent;
    RETURN;
  END IF;

  -- ---------------------------------------------------------------------------
  -- 0b. Resolve New Mexico United (ShortName NMU).
  -- ---------------------------------------------------------------------------
  SELECT count(*) INTO v_matches
  FROM public."Clubs"
  WHERE "ShortName" = 'NMU'
     OR btrim("Club") ILIKE ANY (ARRAY[
       'New Mexico United', 'New Mexico', 'NM United'
     ]);

  IF v_matches <> 1 THEN
    RAISE EXCEPTION
      'Expected exactly 1 source club row but found % — set v_old to the correct ShortName manually.',
      v_matches;
  END IF;

  SELECT "ShortName" INTO v_old
  FROM public."Clubs"
  WHERE "ShortName" = 'NMU'
     OR btrim("Club") ILIKE ANY (ARRAY[
       'New Mexico United', 'New Mexico', 'NM United'
     ]);

  RAISE NOTICE 'Resolved source code: % -> %', v_old, v_new;

  -- ---------------------------------------------------------------------------
  -- 1. Snapshot every FK that points at Clubs("ShortName").
  -- ---------------------------------------------------------------------------
  CREATE TEMP TABLE _club_fks ON COMMIT DROP AS
  SELECT con.conrelid::regclass::text AS tbl,
         att.attname                  AS col,
         con.conname                  AS conname,
         pg_get_constraintdef(con.oid) AS def
  FROM pg_constraint con
  JOIN pg_class      refcl  ON refcl.oid  = con.confrelid
  JOIN pg_namespace  refns  ON refns.oid  = refcl.relnamespace
  JOIN pg_attribute  refatt ON refatt.attrelid = con.confrelid AND refatt.attnum = con.confkey[1]
  JOIN pg_attribute  att    ON att.attrelid    = con.conrelid  AND att.attnum    = con.conkey[1]
  WHERE con.contype = 'f'
    AND refns.nspname = 'public'
    AND refcl.relname = 'Clubs'
    AND refatt.attname = 'ShortName';

  -- ---------------------------------------------------------------------------
  -- 2. Drop those FKs.
  -- ---------------------------------------------------------------------------
  FOR r IN SELECT DISTINCT tbl, conname FROM _club_fks LOOP
    EXECUTE format('ALTER TABLE %s DROP CONSTRAINT %I', r.tbl, r.conname);
  END LOOP;

  -- ---------------------------------------------------------------------------
  -- 3a. Repoint the parent row + change identity (incl. Nation + continent).
  -- ---------------------------------------------------------------------------
  UPDATE public."Clubs"
  SET "ShortName" = v_new,
      "Club"      = v_club_name,
      "Stadium"   = v_stadium,
      "Capacity"  = v_capacity,
      "Nation"    = v_nation
  WHERE "ShortName" = v_old;

  BEGIN
    EXECUTE 'UPDATE public."Clubs" SET base_capacity = $1 WHERE "ShortName" = $2'
      USING v_capacity, v_new;
  EXCEPTION WHEN undefined_column THEN NULL;
  END;

  BEGIN
    EXECUTE 'UPDATE public."Clubs" SET continent = $1 WHERE "ShortName" = $2'
      USING v_continent, v_new;
  EXCEPTION WHEN undefined_column THEN NULL;
  END;

  -- ---------------------------------------------------------------------------
  -- 3b. Repoint every FK-referencing column (data only; FKs are dropped).
  -- ---------------------------------------------------------------------------
  FOR r IN SELECT tbl, col FROM _club_fks LOOP
    EXECUTE format('UPDATE %s SET %I = %L WHERE %I = %L', r.tbl, r.col, v_new, r.col, v_old);
  END LOOP;

  -- ---------------------------------------------------------------------------
  -- 3c. Repoint legacy columns that store a club code but have NO declared FK.
  -- ---------------------------------------------------------------------------
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
      ('public.contract_expiry_wage_bids',       'bidder_club_short_name')
    ) AS t(tbl, col)
  LOOP
    BEGIN
      EXECUTE format('UPDATE %s SET %I = $1 WHERE %I IN ($2, $3)', r.tbl, r.col, r.col)
        USING v_new, v_old, v_old_name;
    EXCEPTION
      WHEN undefined_table OR undefined_column THEN NULL;
    END;
  END LOOP;

  -- ---------------------------------------------------------------------------
  -- 4. Recreate the FKs exactly as captured (validates the new data).
  -- ---------------------------------------------------------------------------
  FOR r IN SELECT DISTINCT tbl, conname, def FROM _club_fks LOOP
    EXECUTE format('ALTER TABLE %s ADD CONSTRAINT %I %s', r.tbl, r.conname, r.def);
  END LOOP;

  RAISE NOTICE 'Swap complete: % -> % (%, %).', v_old, v_new, v_club_name, v_nation;
END $$;

NOTIFY pgrst, 'reload schema';

-- Confirmation — should return SOA and no New Mexico row.
SELECT "ShortName", "Club", "Stadium", "Capacity", base_capacity, "Nation", continent
FROM public."Clubs"
WHERE "ShortName" = 'SOA'
   OR "ShortName" = 'NMU'
   OR btrim("Club") ILIKE '%New Mexico%';
