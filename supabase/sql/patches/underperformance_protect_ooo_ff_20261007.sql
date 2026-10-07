-- =============================================================================
-- Underperformance transfer request: One of our Own + Fan Favourite protected
-- (2026-10-07)
-- =============================================================================
-- A player designated 'one_of_our_own' or 'fan_favourite' at the club is never
-- picked for the season-end transfer request. "Top 4 rated" is still ranked
-- across the whole squad — a protected top-4 player is simply skipped.
-- Same rules as season_expectation_outcomes_refine_20260924.sql otherwise.
-- Safe to re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.club_player_transfer_request_protected(
  p_club_short_name text,
  p_player_id text
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.club_squad_player_designations d
    WHERE d.club_short_name = p_club_short_name
      AND d.player_id = p_player_id
      AND d.designation IN ('one_of_our_own', 'fan_favourite')
  );
$$;

CREATE OR REPLACE FUNCTION public.club_underperformance_pick_player(
  p_club_short_name text,
  p_tier text,
  p_band text DEFAULT NULL
)
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_player_id text;
  v_band text := lower(coalesce(nullif(btrim(p_band), ''), 'bad'));
  v_slight boolean := (v_band = 'slight');
BEGIN
  IF p_tier = 'big' THEN
    IF v_slight THEN
      SELECT p."Konami_ID"::text INTO v_player_id
      FROM public."Players" p
      WHERE public.player_contracted_club_key(p."Contracted_Team") = p_club_short_name
        AND public.player_rating_numeric(p."Rating"::text) IS NOT NULL
        AND public.player_rating_numeric(p."Rating"::text) <= 76
        AND p."Konami_ID" NOT IN (
          SELECT x."Konami_ID" FROM (
            SELECT p2."Konami_ID"
            FROM public."Players" p2
            WHERE public.player_contracted_club_key(p2."Contracted_Team") = p_club_short_name
            ORDER BY public.player_rating_numeric(p2."Rating"::text) DESC NULLS LAST, p2."Konami_ID"
            LIMIT 4
          ) x
        )
        AND NOT public.club_player_transfer_request_protected(p_club_short_name, p."Konami_ID"::text)
        AND NOT EXISTS (
          SELECT 1 FROM public."Player_Transfer_Listings" l
          WHERE l.player_id = p."Konami_ID"::text
            AND l.perpetual_renew = true
            AND l.status IN ('Active', 'Review', 'Seller Review')
        )
      ORDER BY random()
      LIMIT 1;
    END IF;

    IF v_player_id IS NULL THEN
      SELECT p."Konami_ID"::text INTO v_player_id
      FROM (
        SELECT p2."Konami_ID", public.player_rating_numeric(p2."Rating"::text) AS rnk
        FROM public."Players" p2
        WHERE public.player_contracted_club_key(p2."Contracted_Team") = p_club_short_name
        ORDER BY rnk DESC NULLS LAST, p2."Konami_ID"
        LIMIT 4
      ) top4
      JOIN public."Players" p ON p."Konami_ID" = top4."Konami_ID"
      WHERE NOT public.club_player_transfer_request_protected(p_club_short_name, p."Konami_ID"::text)
        AND NOT EXISTS (
          SELECT 1 FROM public."Player_Transfer_Listings" l
          WHERE l.player_id = p."Konami_ID"::text
            AND l.perpetual_renew = true
            AND l.status IN ('Active', 'Review', 'Seller Review')
        )
      ORDER BY random()
      LIMIT 1;
    END IF;

  ELSIF p_tier = 'medium' THEN
    IF v_slight THEN
      SELECT p."Konami_ID"::text INTO v_player_id
      FROM public."Players" p
      WHERE public.player_contracted_club_key(p."Contracted_Team") = p_club_short_name
        AND public.player_rating_numeric(p."Rating"::text) BETWEEN 68 AND 73
        AND public.player_age_numeric(p."Age"::text) > 21
        AND NOT public.club_player_transfer_request_protected(p_club_short_name, p."Konami_ID"::text)
        AND NOT EXISTS (
          SELECT 1 FROM public."Player_Transfer_Listings" l
          WHERE l.player_id = p."Konami_ID"::text
            AND l.perpetual_renew = true
            AND l.status IN ('Active', 'Review', 'Seller Review')
        )
      ORDER BY random()
      LIMIT 1;
    END IF;

    IF v_player_id IS NULL THEN
      SELECT p."Konami_ID"::text INTO v_player_id
      FROM public."Players" p
      WHERE public.player_contracted_club_key(p."Contracted_Team") = p_club_short_name
        AND public.player_rating_numeric(p."Rating"::text) BETWEEN 74 AND 78
        AND public.player_age_numeric(p."Age"::text) > 21
        AND NOT public.club_player_transfer_request_protected(p_club_short_name, p."Konami_ID"::text)
        AND NOT EXISTS (
          SELECT 1 FROM public."Player_Transfer_Listings" l
          WHERE l.player_id = p."Konami_ID"::text
            AND l.perpetual_renew = true
            AND l.status IN ('Active', 'Review', 'Seller Review')
        )
      ORDER BY random()
      LIMIT 1;
    END IF;

  ELSIF p_tier = 'low' THEN
    SELECT p."Konami_ID"::text INTO v_player_id
    FROM public."Players" p
    WHERE public.player_contracted_club_key(p."Contracted_Team") = p_club_short_name
      AND public.player_rating_numeric(p."Rating"::text) <= 72
      AND NOT public.club_player_transfer_request_protected(p_club_short_name, p."Konami_ID"::text)
      AND NOT EXISTS (
        SELECT 1 FROM public."Player_Transfer_Listings" l
        WHERE l.player_id = p."Konami_ID"::text
          AND l.perpetual_renew = true
          AND l.status IN ('Active', 'Review', 'Seller Review')
      )
    ORDER BY random()
    LIMIT 1;
  END IF;

  RETURN v_player_id;
END;
$fn$;

GRANT EXECUTE ON FUNCTION public.club_player_transfer_request_protected(text, text) TO authenticated;

NOTIFY pgrst, 'reload schema';
