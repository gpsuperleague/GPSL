-- =============================================================================
-- Underperformance transfer request: young players protected (2026-10-14)
-- =============================================================================
-- Same age brackets as the expiry auction exemption:
--   home-grown (for this club) aged 23 or under
--   not home-grown aged 21 or under
-- are never picked for the season-end transfer request, alongside One of our
-- Own and Fan Favourite. The group drop-down chain is unchanged, so another
-- eligible player is still listed when the usual group empties.
--
-- club_underperformance_pool_players() calls this function, so the pick
-- (club_underperformance_pick_player) and the Season Review candidate list
-- (season_review_listing_pool) both recalculate automatically.
-- Requires underperformance_protect_ooo_ff_20261007.sql. Safe to re-run.
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
  SELECT
    EXISTS (
      SELECT 1 FROM public.club_squad_player_designations d
      WHERE d.club_short_name = p_club_short_name
        AND d.player_id = p_player_id
        AND d.designation IN ('one_of_our_own', 'fan_favourite')
    )
    OR EXISTS (
      SELECT 1
      FROM public."Players" p
      CROSS JOIN LATERAL (
        SELECT public.player_age_numeric(p."Age"::text) AS age
      ) a
      WHERE p."Konami_ID"::text = p_player_id
        AND a.age IS NOT NULL
        AND (
          a.age <= 21
          OR (a.age <= 23 AND public.is_player_homegrown(p_player_id, p_club_short_name))
        )
    );
$$;

COMMENT ON FUNCTION public.club_player_transfer_request_protected(text, text) IS
  'Never asked to leave on underperformance: OooO, Fan Favourite, HG aged ≤23, non-HG aged ≤21.';

GRANT EXECUTE ON FUNCTION public.club_player_transfer_request_protected(text, text) TO authenticated;

NOTIFY pgrst, 'reload schema';

-- Report: players now protected by age, per club
SELECT
  public.player_contracted_club_key(p."Contracted_Team") AS club,
  p."Name" AS player,
  public.player_rating_numeric(p."Rating"::text) AS rating,
  public.player_age_numeric(p."Age"::text) AS age,
  public.is_player_homegrown(p."Konami_ID"::text, public.player_contracted_club_key(p."Contracted_Team")) AS home_grown
FROM public."Players" p
WHERE public.player_contracted_club_key(p."Contracted_Team") IS NOT NULL
  AND public.player_age_numeric(p."Age"::text) <= 23
  AND public.club_player_transfer_request_protected(
        public.player_contracted_club_key(p."Contracted_Team"),
        p."Konami_ID"::text
      )
ORDER BY club, rating DESC NULLS LAST;
