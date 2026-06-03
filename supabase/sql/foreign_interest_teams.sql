-- =============================================================================
-- Foreign interest teams (pool + per-club tracking names)
-- Run AFTER sell_to_foreign_club.sql in Supabase SQL Editor.
-- =============================================================================

-- Pool of real-world clubs (not rows in GPSL Clubs)
CREATE TABLE IF NOT EXISTS public."Foreign_Interest_Teams" (
  id   serial PRIMARY KEY,
  name text NOT NULL UNIQUE,
  nation text
);

INSERT INTO public."Foreign_Interest_Teams" (name, nation)
SELECT v.name, v.nation
FROM (VALUES
  ('Bayern Munich', 'GER'),
  ('RB Leipzig', 'GER'),
  ('Schalke 04', 'GER'),
  ('Napoli', 'ITA'),
  ('Torino', 'ITA'),
  ('Sampdoria', 'ITA'),
  ('Sevilla', 'ESP'),
  ('Real Sociedad', 'ESP'),
  ('Athletic Bilbao', 'ESP'),
  ('Braga', 'POR'),
  ('Sporting Gijón', 'ESP'),
  ('Gent', 'BEL'),
  ('Standard Liège', 'BEL'),
  ('FC Basel', 'SUI'),
  ('Young Boys', 'SUI'),
  ('Red Star Belgrade', 'SRB'),
  ('Dinamo Zagreb', 'CRO'),
  ('Shakhtar Donetsk', 'UKR'),
  ('Dynamo Kyiv', 'UKR'),
  ('Galatasaray', 'TUR'),
  ('Fenerbahçe', 'TUR'),
  ('Rapid Vienna', 'AUT'),
  ('Red Bull Salzburg', 'AUT'),
  ('Malmö FF', 'SWE'),
  ('Rosenborg', 'NOR')
) AS v(name, nation)
WHERE NOT EXISTS (
  SELECT 1 FROM public."Foreign_Interest_Teams" t WHERE t.name = v.name
);

-- Per-club list of foreign clubs currently "tracking"
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'Clubs'
      AND column_name = 'foreign_tracking_teams'
  ) THEN
    ALTER TABLE public."Clubs"
      ADD COLUMN foreign_tracking_teams text[] NOT NULL DEFAULT '{}';
  END IF;
END $$;

-- Display name on transfer history (buyer_club_id stays FOREIGN for FK)
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'Transfer_History'
      AND column_name = 'foreign_buyer_name'
  ) THEN
    ALTER TABLE public."Transfer_History"
      ADD COLUMN foreign_buyer_name text;
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.gpsl_club_display_names()
RETURNS SETOF text
LANGUAGE sql
STABLE
AS $$
  SELECT btrim(c."Club")
  FROM public."Clubs" c
  WHERE c."ShortName" <> 'FOREIGN'
    AND btrim(coalesce(c."Club", '')) <> '';
$$;

CREATE OR REPLACE FUNCTION public.pick_foreign_tracking_teams(
  p_club_short text,
  p_count int
)
RETURNS text[]
LANGUAGE sql
STABLE
AS $$
  SELECT coalesce(array_agg(sub.name ORDER BY sub.ord), '{}')
  FROM (
    SELECT
      t.name,
      md5(p_club_short || ':' || t.name) AS ord
    FROM public."Foreign_Interest_Teams" t
    WHERE p_count > 0
      AND NOT EXISTS (
        SELECT 1
        FROM public.gpsl_club_display_names() g
        WHERE lower(g) = lower(t.name)
      )
    ORDER BY md5(p_club_short || ':' || t.name)
    LIMIT greatest(p_count, 0)
  ) sub;
$$;

CREATE OR REPLACE FUNCTION public.sync_club_foreign_tracking(p_club_short text)
RETURNS text[]
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_need   int;
  v_current text[];
BEGIN
  SELECT
    greatest(coalesce(c.foreign_interest_remaining, 0), 0),
    coalesce(c.foreign_tracking_teams, '{}')
  INTO v_need, v_current
  FROM public."Clubs" c
  WHERE c."ShortName" = p_club_short
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN '{}';
  END IF;

  IF v_need <= 0 THEN
    UPDATE public."Clubs" c
    SET foreign_tracking_teams = '{}'
    WHERE c."ShortName" = p_club_short;
    RETURN '{}';
  END IF;

  IF coalesce(array_length(v_current, 1), 0) = v_need THEN
    RETURN v_current;
  END IF;

  v_current := public.pick_foreign_tracking_teams(p_club_short, v_need);

  UPDATE public."Clubs" c
  SET foreign_tracking_teams = v_current
  WHERE c."ShortName" = p_club_short;

  RETURN v_current;
END;
$function$;

CREATE OR REPLACE FUNCTION public.club_foreign_interest_state()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text;
  v_remaining int;
  v_teams text[];
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  v_club := public.my_club_shortname();
  IF v_club IS NULL OR btrim(v_club) = '' THEN
    RAISE EXCEPTION 'No club linked to this account';
  END IF;

  v_teams := public.sync_club_foreign_tracking(v_club);

  SELECT greatest(coalesce(c.foreign_interest_remaining, 0), 0)
  INTO v_remaining
  FROM public."Clubs" c
  WHERE c."ShortName" = v_club;

  RETURN jsonb_build_object(
    'club_shortname', v_club,
    'foreign_interest_remaining', v_remaining,
    'tracking_teams', to_jsonb(v_teams)
  );
END;
$function$;

DROP FUNCTION IF EXISTS public.sell_player_to_foreign_club(text);

CREATE OR REPLACE FUNCTION public.sell_player_to_foreign_club(
  p_player_id text,
  p_foreign_team_name text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club           text;
  v_player         public."Players"%rowtype;
  v_pid            text;
  v_fee            numeric;
  v_seller_balance numeric;
  v_buyer          text := 'FOREIGN';
  v_interest       int;
  v_interest_after int;
  v_teams          text[];
  v_team           text;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  PERFORM public.ensure_foreign_buyer_club();

  v_club := public.my_club_shortname();
  IF v_club IS NULL OR btrim(v_club) = '' THEN
    RAISE EXCEPTION 'No club linked to this account';
  END IF;

  SELECT c.foreign_interest_remaining, coalesce(c.foreign_tracking_teams, '{}')
  INTO v_interest, v_teams
  FROM public."Clubs" c
  WHERE c."ShortName" = v_club
  FOR UPDATE;

  IF coalesce(v_interest, 0) <= 0 THEN
    RAISE EXCEPTION
      'No foreign clubs are interested in your players (maximum foreign sales reached).';
  END IF;

  v_teams := public.sync_club_foreign_tracking(v_club);

  v_team := btrim(coalesce(p_foreign_team_name, ''));
  IF v_team = '' THEN
    RAISE EXCEPTION 'Choose which foreign club to sell to.';
  END IF;

  IF NOT (v_team = ANY (v_teams)) THEN
    RAISE EXCEPTION 'That club is not currently tracking your players.';
  END IF;

  v_pid := btrim(p_player_id);

  SELECT *
  INTO v_player
  FROM public."Players"
  WHERE "Konami_ID"::text = v_pid
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Player not found';
  END IF;

  IF public.player_contracted_club_key(v_player."Contracted_Team") IS DISTINCT FROM v_club THEN
    RAISE EXCEPTION 'Player is not at your club';
  END IF;

  PERFORM public.assert_player_transferable(v_pid);

  v_fee := greatest(coalesce(v_player.market_value::numeric, 0::numeric), 0::numeric);

  SELECT balance
  INTO v_seller_balance
  FROM public."Club_Finances"
  WHERE club_name = v_club
  FOR UPDATE;

  IF v_seller_balance IS NULL THEN
    RAISE EXCEPTION 'Club finances not found for %', v_club;
  END IF;

  UPDATE public."Player_Transfer_Listings" l
  SET status = 'Closed',
      transfer_completed = false,
      winning_bid = null,
      winning_club = null
  WHERE l.player_id::text = v_pid
    AND l.seller_club_id = v_club
    AND l.status IN ('Active', 'Review');

  UPDATE public."Player_Transfer_Bids" b
  SET status = 'rejected'
  WHERE b.is_direct = true
    AND b.listing_id IS NULL
    AND lower(coalesce(b.status::text, '')) = 'active'
    AND (
      (b.player_id IS NOT NULL AND btrim(b.player_id::text) = v_pid)
      OR (b.direct_bid_id IS NOT NULL AND btrim(b.direct_bid_id::text) = v_pid)
    );

  PERFORM public.player_release_from_club(v_pid);

  UPDATE public."Club_Finances"
  SET balance = v_seller_balance + v_fee
  WHERE club_name = v_club;

  v_teams := array_remove(v_teams, v_team);

  UPDATE public."Clubs" c
  SET foreign_interest_remaining = foreign_interest_remaining - 1,
      foreign_tracking_teams = v_teams
  WHERE c."ShortName" = v_club
  RETURNING c.foreign_interest_remaining INTO v_interest_after;

  INSERT INTO public."Transfer_History" (
    player_id,
    seller_club_id,
    buyer_club_id,
    fee,
    agent_fee,
    transfer_time,
    listing_id,
    foreign_buyer_name
  )
  VALUES (
    v_player."Konami_ID",
    v_club,
    v_buyer,
    v_fee,
    0,
    now(),
    NULL,
    v_team
  );

  RETURN jsonb_build_object(
    'ok', true,
    'player_id', v_player."Konami_ID",
    'player_name', v_player."Name",
    'seller_club_id', v_club,
    'buyer_club_id', v_buyer,
    'foreign_buyer_name', v_team,
    'fee', v_fee,
    'new_balance', v_seller_balance + v_fee,
    'foreign_interest_remaining', v_interest_after,
    'tracking_teams', to_jsonb(v_teams)
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.club_foreign_interest_state() TO authenticated;
GRANT EXECUTE ON FUNCTION public.sync_club_foreign_tracking(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.sell_player_to_foreign_club(text, text) TO authenticated;

-- Backfill tracking lists for clubs with interest remaining
DO $$
DECLARE
  r record;
BEGIN
  FOR r IN
    SELECT c."ShortName"
    FROM public."Clubs" c
    WHERE c."ShortName" <> 'FOREIGN'
      AND coalesce(c.foreign_interest_remaining, 0) > 0
  LOOP
    PERFORM public.sync_club_foreign_tracking(r."ShortName");
  END LOOP;
END $$;

SELECT count(*) AS foreign_interest_pool_size
FROM public."Foreign_Interest_Teams";
