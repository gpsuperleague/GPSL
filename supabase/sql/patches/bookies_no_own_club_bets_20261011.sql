-- =============================================================================
-- Bookies: owners cannot bet on their own club or their own players
--
-- Blocks any bet where the selection is:
--   • the owner's club (title, relegation, cup winner … markets), or
--   • a player at the owner's club (top scorer etc.) — checks the player's
--     current club as well as the club recorded when the market opened.
-- Enforced by a BEFORE INSERT trigger on bookies_bets so it survives any
-- later rewrite of bookies_place_bet. Safe re-run.
-- Final SELECT lists any own-club bets placed before this rule existed.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.bookies_selection_is_own(
  p_selection_id bigint,
  p_owner_id uuid,
  p_club text
)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_sel public.bookies_selections%rowtype;
  v_clubs text[];
  v_player_club text;
BEGIN
  SELECT * INTO v_sel FROM public.bookies_selections WHERE id = p_selection_id;
  IF NOT FOUND THEN
    RETURN false;
  END IF;

  SELECT coalesce(array_agg(DISTINCT upper(btrim(x))), ARRAY[]::text[])
  INTO v_clubs
  FROM (
    SELECT c."ShortName" AS x FROM public."Clubs" c
    WHERE p_owner_id IS NOT NULL AND c.owner_id = p_owner_id
    UNION ALL
    SELECT p_club
  ) s
  WHERE nullif(btrim(coalesce(x, '')), '') IS NOT NULL;

  IF cardinality(v_clubs) = 0 THEN
    RETURN false;
  END IF;

  -- Club selection
  IF upper(btrim(coalesce(v_sel.selection_key, ''))) = ANY (v_clubs) THEN
    RETURN true;
  END IF;

  -- Player selection: club at market open
  IF upper(btrim(coalesce(v_sel.metadata->>'club', ''))) = ANY (v_clubs) THEN
    RETURN true;
  END IF;

  -- Player selection: club now
  SELECT p."Contracted_Team" INTO v_player_club
  FROM public."Players" p
  WHERE p."Konami_ID"::text = btrim(coalesce(v_sel.selection_key, ''))
  LIMIT 1;

  RETURN upper(btrim(coalesce(v_player_club, ''))) = ANY (v_clubs);
END;
$function$;

REVOKE ALL ON FUNCTION public.bookies_selection_is_own(bigint, uuid, text) FROM PUBLIC;

CREATE OR REPLACE FUNCTION public.trg_bookies_bets_block_own_club()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF public.bookies_selection_is_own(NEW.selection_id, NEW.owner_id, NEW.club_short_name) THEN
    RAISE EXCEPTION 'You can''t bet on your own club or your own players';
  END IF;
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS bookies_bets_00_block_own_club ON public.bookies_bets;
CREATE TRIGGER bookies_bets_00_block_own_club
  BEFORE INSERT ON public.bookies_bets
  FOR EACH ROW EXECUTE FUNCTION public.trg_bookies_bets_block_own_club();

NOTIFY pgrst, 'reload schema';

-- Report: open/settled bets that break the rule (placed before it existed)
SELECT
  b.id AS bet_id,
  b.club_short_name AS bettor_club,
  m.title AS market,
  s.label AS selection,
  b.stake,
  b.potential_return,
  b.status,
  b.placed_at AT TIME ZONE 'Europe/London' AS placed_uk
FROM (SELECT 1) one
LEFT JOIN public.bookies_bets b
  ON b.status IS DISTINCT FROM 'void'
 AND public.bookies_selection_is_own(b.selection_id, b.owner_id, b.club_short_name)
LEFT JOIN public.bookies_selections s ON s.id = b.selection_id
LEFT JOIN public.bookies_markets m ON m.id = b.market_id
ORDER BY b.placed_at;
