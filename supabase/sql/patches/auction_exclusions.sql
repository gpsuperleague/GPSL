-- =============================================================================
-- Auction exclusions — reserve GPDB players for special auctions (block draft)
-- UI: admin_auction_exclusions.html (Pre-Season → Auctions → Auction Exclusions)
-- Safe to re-run.
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.auction_exclusion_players (
  player_id text PRIMARY KEY,
  player_name text,
  note text,
  reserved_at timestamptz NOT NULL DEFAULT now(),
  reserved_by uuid REFERENCES auth.users (id) ON DELETE SET NULL
);

CREATE INDEX IF NOT EXISTS auction_exclusion_players_reserved_at_idx
  ON public.auction_exclusion_players (reserved_at DESC);

COMMENT ON TABLE public.auction_exclusion_players IS
  'Players reserved for special auctions — blocked from draft auction bids until unlocked.';

ALTER TABLE public.auction_exclusion_players ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS auction_exclusion_players_select ON public.auction_exclusion_players;
CREATE POLICY auction_exclusion_players_select ON public.auction_exclusion_players
  FOR SELECT TO authenticated
  USING (true);

DROP POLICY IF EXISTS auction_exclusion_players_admin ON public.auction_exclusion_players;
CREATE POLICY auction_exclusion_players_admin ON public.auction_exclusion_players
  FOR ALL TO authenticated
  USING (public.is_gpsl_admin())
  WITH CHECK (public.is_gpsl_admin());

GRANT SELECT ON public.auction_exclusion_players TO authenticated;
GRANT ALL ON public.auction_exclusion_players TO authenticated;

CREATE OR REPLACE FUNCTION public.auction_player_is_excluded(p_player_id text)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.auction_exclusion_players e
    WHERE e.player_id = btrim(coalesce(p_player_id, ''))
  );
$$;

CREATE OR REPLACE FUNCTION public.admin_auction_exclude_player(
  p_player_id text,
  p_note text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_id text := btrim(coalesce(p_player_id, ''));
  v_name text;
  v_club text;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;
  IF v_id = '' THEN
    RAISE EXCEPTION 'player_id required';
  END IF;

  SELECT
    coalesce(nullif(btrim(p."Name"), ''), v_id),
    nullif(btrim(p."Contracted_Team"), '')
  INTO v_name, v_club
  FROM public."Players" p
  WHERE p."Konami_ID"::text = v_id
  LIMIT 1;

  IF NOT FOUND OR v_name IS NULL THEN
    RAISE EXCEPTION 'Player % not found in GPDB', v_id;
  END IF;

  IF v_club IS NOT NULL THEN
    RAISE EXCEPTION 'Player is already contracted to % — free agents only', v_club;
  END IF;

  INSERT INTO public.auction_exclusion_players (player_id, player_name, note, reserved_by)
  VALUES (v_id, v_name, nullif(btrim(coalesce(p_note, '')), ''), auth.uid())
  ON CONFLICT (player_id) DO UPDATE
  SET player_name = EXCLUDED.player_name,
      note = COALESCE(EXCLUDED.note, auction_exclusion_players.note),
      reserved_at = now(),
      reserved_by = auth.uid();

  RETURN jsonb_build_object('ok', true, 'player_id', v_id, 'player_name', v_name);
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_auction_unexclude_player(p_player_id text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_id text := btrim(coalesce(p_player_id, ''));
  v_deleted int;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;
  DELETE FROM public.auction_exclusion_players WHERE player_id = v_id;
  GET DIAGNOSTICS v_deleted = ROW_COUNT;
  RETURN jsonb_build_object('ok', true, 'player_id', v_id, 'removed', v_deleted > 0);
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_auction_exclusion_list()
RETURNS TABLE (
  player_id text,
  player_name text,
  note text,
  reserved_at timestamptz,
  player_position text,
  rating int,
  market_value numeric
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    e.player_id,
    coalesce(nullif(btrim(p."Name"), ''), e.player_name, e.player_id) AS player_name,
    e.note,
    e.reserved_at,
    p."Position"::text AS player_position,
    p."Rating"::int AS rating,
    p.market_value::numeric AS market_value
  FROM public.auction_exclusion_players e
  LEFT JOIN public."Players" p ON p."Konami_ID"::text = e.player_id
  ORDER BY e.reserved_at DESC, e.player_id;
$$;

DROP FUNCTION IF EXISTS public.admin_auction_search_players_for_exclusion(text, int);
DROP FUNCTION IF EXISTS public.admin_auction_search_players_for_exclusion(text, int, text[], text[], text[], int, int, int, int, numeric, numeric);
DROP FUNCTION IF EXISTS public.admin_auction_search_players_for_exclusion(text, int, jsonb);

CREATE OR REPLACE FUNCTION public.admin_auction_search_players_for_exclusion(
  p_query text,
  p_limit int,
  p_filters jsonb
)
RETURNS TABLE (
  player_id text,
  player_name text,
  player_position text,
  nation text,
  age int,
  playstyle text,
  rating int,
  market_value numeric,
  already_excluded boolean
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_q text := btrim(coalesce(p_query, ''));
  v_f jsonb := coalesce(p_filters, '{}'::jsonb);
  v_positions text[] := CASE
    WHEN jsonb_typeof(v_f->'positions') = 'array' THEN ARRAY(SELECT jsonb_array_elements_text(v_f->'positions'))
    ELSE NULL
  END;
  v_nations text[] := CASE
    WHEN jsonb_typeof(v_f->'nations') = 'array' THEN ARRAY(SELECT jsonb_array_elements_text(v_f->'nations'))
    ELSE NULL
  END;
  v_playstyles text[] := CASE
    WHEN jsonb_typeof(v_f->'playstyles') = 'array' THEN ARRAY(SELECT jsonb_array_elements_text(v_f->'playstyles'))
    ELSE NULL
  END;
  v_age_min int := NULLIF(v_f->>'age_min', '')::int;
  v_age_max int := NULLIF(v_f->>'age_max', '')::int;
  v_rating_min int := NULLIF(v_f->>'rating_min', '')::int;
  v_rating_max int := NULLIF(v_f->>'rating_max', '')::int;
  v_mv_min numeric := NULLIF(v_f->>'mv_min', '')::numeric;
  v_mv_max numeric := NULLIF(v_f->>'mv_max', '')::numeric;
BEGIN
  IF coalesce(auth.jwt() ->> 'role', '') = 'authenticated'
     AND NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  RETURN QUERY
  SELECT
    p."Konami_ID"::text AS player_id,
    p."Name"::text AS player_name,
    p."Position"::text AS player_position,
    p."Nation"::text AS nation,
    CASE
      WHEN nullif(btrim(p."Age"::text), '') ~ '^[0-9]+$'
      THEN nullif(btrim(p."Age"::text), '')::int
      ELSE NULL
    END AS age,
    p."Playstyle"::text AS playstyle,
    CASE
      WHEN nullif(btrim(p."Rating"::text), '') ~ '^[0-9]+$'
      THEN nullif(btrim(p."Rating"::text), '')::int
      ELSE NULL
    END AS rating,
    nullif(btrim(p.market_value::text), '')::numeric AS market_value,
    EXISTS (
      SELECT 1 FROM public.auction_exclusion_players e WHERE e.player_id = p."Konami_ID"::text
    ) AS already_excluded
  FROM public."Players" p
  WHERE (p."Contracted_Team" IS NULL OR btrim(p."Contracted_Team") = '')
    AND (
      v_q = ''
      OR p."Konami_ID"::text ILIKE '%' || v_q || '%'
      OR p."Name" ILIKE '%' || v_q || '%'
    )
    AND (
      v_positions IS NULL OR cardinality(v_positions) = 0
      OR p."Position"::text = ANY (v_positions)
    )
    AND (
      v_nations IS NULL OR cardinality(v_nations) = 0
      OR p."Nation"::text = ANY (v_nations)
    )
    AND (
      v_playstyles IS NULL OR cardinality(v_playstyles) = 0
      OR p."Playstyle"::text = ANY (v_playstyles)
    )
    AND (
      v_age_min IS NULL
      OR (
        nullif(btrim(p."Age"::text), '') ~ '^[0-9]+$'
        AND nullif(btrim(p."Age"::text), '')::int >= v_age_min
      )
    )
    AND (
      v_age_max IS NULL
      OR (
        nullif(btrim(p."Age"::text), '') ~ '^[0-9]+$'
        AND nullif(btrim(p."Age"::text), '')::int <= v_age_max
      )
    )
    AND (
      v_rating_min IS NULL
      OR (
        nullif(btrim(p."Rating"::text), '') ~ '^[0-9]+$'
        AND nullif(btrim(p."Rating"::text), '')::int >= v_rating_min
      )
    )
    AND (
      v_rating_max IS NULL
      OR (
        nullif(btrim(p."Rating"::text), '') ~ '^[0-9]+$'
        AND nullif(btrim(p."Rating"::text), '')::int <= v_rating_max
      )
    )
    AND (
      v_mv_min IS NULL
      OR nullif(btrim(p.market_value::text), '')::numeric >= v_mv_min
    )
    AND (
      v_mv_max IS NULL
      OR nullif(btrim(p.market_value::text), '')::numeric <= v_mv_max
    )
  ORDER BY
    CASE
      WHEN nullif(btrim(p."Rating"::text), '') ~ '^[0-9]+$'
      THEN nullif(btrim(p."Rating"::text), '')::int
      ELSE NULL
    END DESC NULLS LAST,
    p."Name"
  LIMIT greatest(1, least(coalesce(p_limit, 40), 80));
END;
$function$;

CREATE OR REPLACE FUNCTION public.trg_player_transfer_bids_auction_exclusion()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_is_draft boolean;
  v_pid text;
BEGIN
  v_is_draft := (
    COALESCE(NEW.is_first_draft_bid, false)
    OR COALESCE(NEW.is_draft_join, false)
    OR (
      NEW.listing_id IS NOT NULL
      AND EXISTS (
        SELECT 1 FROM public."Player_Transfer_Listings" l
        WHERE l.id = NEW.listing_id AND l.listing_type = 'draft'
      )
    )
    OR (COALESCE(NEW.is_direct, false) AND NEW.seller_club_id IS NULL)
  );

  IF NOT v_is_draft THEN
    RETURN NEW;
  END IF;

  v_pid := nullif(btrim(coalesce(NEW.player_id, '')), '');
  IF v_pid IS NULL AND NEW.listing_id IS NOT NULL THEN
    SELECT nullif(btrim(l.player_id), '')
    INTO v_pid
    FROM public."Player_Transfer_Listings" l
    WHERE l.id = NEW.listing_id;
  END IF;

  IF v_pid IS NOT NULL AND public.auction_player_is_excluded(v_pid) THEN
    RAISE EXCEPTION 'Player is reserved for special auctions and cannot be bid on in the draft';
  END IF;

  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS player_transfer_bids_auction_exclusion ON public."Player_Transfer_Bids";
CREATE TRIGGER player_transfer_bids_auction_exclusion
  BEFORE INSERT ON public."Player_Transfer_Bids"
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_player_transfer_bids_auction_exclusion();

GRANT EXECUTE ON FUNCTION public.auction_player_is_excluded(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_auction_exclude_player(text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_auction_unexclude_player(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_auction_exclusion_list() TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_auction_search_players_for_exclusion(text, int, jsonb) TO authenticated;
