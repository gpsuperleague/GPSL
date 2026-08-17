-- =============================================================================
-- Unowned GPSL clubs: give ₿650m starting balance if they have none
--
-- • Only clubs with owner_id IS NULL
-- • Only if Club_Finances row is missing OR balance is 0 / null
-- • Owned clubs and any club with a positive balance are left untouched
--
-- Safe re-run. Not GPFL — Club_Finances only.
-- =============================================================================

DO $seed$
DECLARE
  v_start numeric := coalesce(public.club_auction_default_starting_balance(), 650000000);
  v_inserted int := 0;
  v_updated int := 0;
BEGIN
  -- Insert missing finance rows for vacant clubs
  WITH ins AS (
    INSERT INTO public."Club_Finances" (club_name, balance)
    SELECT c."ShortName", v_start
    FROM public."Clubs" c
    WHERE c.owner_id IS NULL
      AND NOT EXISTS (
        SELECT 1
        FROM public."Club_Finances" f
        WHERE f.club_name = c."ShortName"
      )
    RETURNING 1
  )
  SELECT count(*)::int INTO v_inserted FROM ins;

  -- Zero / null balance vacant clubs → starting balance
  WITH upd AS (
    UPDATE public."Club_Finances" f
    SET balance = v_start
    FROM public."Clubs" c
    WHERE f.club_name = c."ShortName"
      AND c.owner_id IS NULL
      AND coalesce(f.balance, 0) <= 0
    RETURNING 1
  )
  SELECT count(*)::int INTO v_updated FROM upd;

  RAISE NOTICE 'unowned starting balance: inserted %, updated % (amount ₿%)',
    v_inserted, v_updated, round(v_start);
END;
$seed$;
