-- =============================================================================
-- Draft auction favourites (per club) — star/save threads for owners
-- Run once in Supabase SQL Editor (requires my_club_shortname from special_auctions.sql)
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.draft_auction_favourites (
  club_id text NOT NULL,
  player_id text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (club_id, player_id)
);

CREATE INDEX IF NOT EXISTS draft_auction_favourites_club_idx
  ON public.draft_auction_favourites (club_id);

COMMENT ON TABLE public.draft_auction_favourites IS
  'Owner-saved draft auction player threads (Konami_ID), scoped to club ShortName.';

ALTER TABLE public.draft_auction_favourites ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS draft_auction_favourites_select ON public.draft_auction_favourites;
CREATE POLICY draft_auction_favourites_select ON public.draft_auction_favourites
  FOR SELECT TO authenticated
  USING (club_id = public.my_club_shortname());

DROP POLICY IF EXISTS draft_auction_favourites_insert ON public.draft_auction_favourites;
CREATE POLICY draft_auction_favourites_insert ON public.draft_auction_favourites
  FOR INSERT TO authenticated
  WITH CHECK (club_id = public.my_club_shortname());

DROP POLICY IF EXISTS draft_auction_favourites_delete ON public.draft_auction_favourites;
CREATE POLICY draft_auction_favourites_delete ON public.draft_auction_favourites
  FOR DELETE TO authenticated
  USING (club_id = public.my_club_shortname());

GRANT SELECT, INSERT, DELETE ON public.draft_auction_favourites TO authenticated;

CREATE OR REPLACE FUNCTION public.draft_auction_toggle_favourite(p_player_id text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text;
  v_pid text;
  v_exists boolean;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  v_club := public.my_club_shortname();
  IF v_club IS NULL OR btrim(v_club) = '' THEN
    RAISE EXCEPTION 'No club linked to this account';
  END IF;

  v_pid := btrim(p_player_id);
  IF v_pid IS NULL OR v_pid = '' THEN
    RAISE EXCEPTION 'Player id is required';
  END IF;

  SELECT EXISTS (
    SELECT 1
    FROM public.draft_auction_favourites f
    WHERE f.club_id = v_club
      AND f.player_id = v_pid
  )
  INTO v_exists;

  IF v_exists THEN
    DELETE FROM public.draft_auction_favourites f
    WHERE f.club_id = v_club
      AND f.player_id = v_pid;

    RETURN jsonb_build_object('favourited', false, 'player_id', v_pid);
  END IF;

  INSERT INTO public.draft_auction_favourites (club_id, player_id)
  VALUES (v_club, v_pid);

  RETURN jsonb_build_object('favourited', true, 'player_id', v_pid);
END;
$function$;

REVOKE ALL ON FUNCTION public.draft_auction_toggle_favourite(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.draft_auction_toggle_favourite(text) TO authenticated;
