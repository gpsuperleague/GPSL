-- =============================================================================
-- Replace Foreign_Interest_Teams pool with curated list (25 clubs)
-- Run in Supabase SQL Editor if you already ran an older foreign_interest_teams.sql
-- Requires functions from foreign_interest_teams.sql (sync_club_foreign_tracking).
-- =============================================================================

TRUNCATE public."Foreign_Interest_Teams" RESTART IDENTITY;

INSERT INTO public."Foreign_Interest_Teams" (name, nation)
VALUES
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
  ('Rosenborg', 'NOR');

-- Force each club to pick fresh trackers from the new pool
UPDATE public."Clubs" c
SET foreign_tracking_teams = '{}'
WHERE c."ShortName" <> 'FOREIGN'
  AND coalesce(c.foreign_interest_remaining, 0) > 0;

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
