-- =============================================================================
-- Franchise swap: Urawa Reds (URD)  ->  Jubilo Iwata (JUB)
-- =============================================================================
-- Straight identity replacement. The club KEEPS everything it currently owns
-- (squad/player registrations, fixtures, league position, finances, ledgers,
-- transfer history, cups, stadium expansions, owner) — only its identity and
-- ShortName code change.
--
-- HOW IT STAYS SAFE:
--   1. Captures every FOREIGN KEY that references public."Clubs"("ShortName").
--   2. Drops those FKs (so the primary-key value can be changed).
--   3. Repoints the parent row + every referencing column from URD -> JUB,
--      including legacy columns that have no declared FK.
--   4. Recreates the FKs exactly as they were (validates the new data).
-- The whole thing is a single atomic DO block: any error rolls everything back,
-- including the dropped constraints.
--
-- AFTER RUNNING THIS: rename the image assets (the app keys them by ShortName):
--   images/stadiums/URD.jpg      -> images/stadiums/JUB.jpg   (Yamaha Stadium photo)
--   images/club_badges/JUB.png   (drop in the Jubilo Iwata badge)
--
-- Edit the two codes / identity values below if you want a different code.
-- =============================================================================

DO $$
DECLARE
  v_old        text := 'URD';
  v_new        text := 'JUB';
  v_old_name   text := 'Urawa Reds';          -- legacy full-name value (if any)
  v_club_name  text := 'Jubilo Iwata';
  v_stadium    text := 'Yamaha Stadium';
  v_capacity   integer := 15165;
  r            record;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public."Clubs" WHERE "ShortName" = v_old) THEN
    RAISE EXCEPTION 'Source club code % not found in Clubs', v_old;
  END IF;
  IF EXISTS (SELECT 1 FROM public."Clubs" WHERE "ShortName" = v_new) THEN
    RAISE EXCEPTION 'Target club code % already exists in Clubs', v_new;
  END IF;

  -- ---------------------------------------------------------------------------
  -- 1. Snapshot every FK that points at Clubs("ShortName") (table, column,
  --    constraint name, full definition for recreation).
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
  -- 3a. Repoint the parent row + change identity.
  -- ---------------------------------------------------------------------------
  UPDATE public."Clubs"
  SET "ShortName"   = v_new,
      "Club"        = v_club_name,
      "Stadium"     = v_stadium,
      "Capacity"    = v_capacity
  WHERE "ShortName" = v_old;

  -- base_capacity exists only after stadium_expansion.sql — guard it.
  BEGIN
    EXECUTE 'UPDATE public."Clubs" SET base_capacity = $1 WHERE "ShortName" = $2'
      USING v_capacity, v_new;
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
  --     Each guarded so a missing table/column is skipped silently. Legacy id
  --     columns occasionally hold the full club NAME, so match both.
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
  -- 4. Recreate the FKs exactly as captured (validates JUB data).
  -- ---------------------------------------------------------------------------
  FOR r IN SELECT DISTINCT tbl, conname, def FROM _club_fks LOOP
    EXECUTE format('ALTER TABLE %s ADD CONSTRAINT %I %s', r.tbl, r.conname, r.def);
  END LOOP;

  RAISE NOTICE 'Swap complete: % -> % (%).', v_old, v_new, v_club_name;
END $$;

-- Refresh PostgREST so the API picks up the renamed rows immediately.
NOTIFY pgrst, 'reload schema';

-- Confirmation — should return the new Jubilo Iwata row and zero URD leftovers.
SELECT "ShortName", "Club", "Stadium", "Capacity", "Nation"
FROM public."Clubs"
WHERE "ShortName" IN ('JUB', 'URD');
