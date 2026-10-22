-- =============================================================================
-- Challenge big prize = first to 6 (of up to 10) per half-season — 2026-10-22
-- =============================================================================
-- Live setting was still on the old default of 5, so the table showed x/5.
-- Each window (Start / Mid): first club to complete 6 wins the big prize;
-- others can keep completing the remaining challenges for individual cash.
-- Safe re-run.
-- =============================================================================

ALTER TABLE public.global_settings
  ADD COLUMN IF NOT EXISTS challenge_big_prize_required smallint NOT NULL DEFAULT 6,
  ADD COLUMN IF NOT EXISTS challenge_max_per_window smallint NOT NULL DEFAULT 10;

-- Force the season rule the league uses
UPDATE public.global_settings
SET
  challenge_big_prize_required = 6,
  challenge_max_per_window = greatest(coalesce(challenge_max_per_window, 10), 6)
WHERE id = 1;

ALTER TABLE public.global_settings
  ALTER COLUMN challenge_big_prize_required SET DEFAULT 6;

CREATE OR REPLACE FUNCTION public.competition_challenge_required_to_win(
  p_season_id bigint,
  p_window_phase text
)
RETURNS int
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  WITH s AS (
    SELECT coalesce(
      (SELECT challenge_big_prize_required FROM public.global_settings WHERE id = 1),
      6
    )::int AS req
  ), n AS (
    SELECT count(*)::int AS total
    FROM public.competition_challenge_config c
    WHERE c.season_id = p_season_id
      AND c.window_phase = p_window_phase
      AND c.is_active = true
  )
  SELECT CASE
    WHEN n.total = 0 THEN s.req
    ELSE least(s.req, n.total)
  END
  FROM s, n;
$$;

REVOKE ALL ON FUNCTION public.competition_challenge_required_to_win(bigint, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.competition_challenge_required_to_win(bigint, text)
  TO authenticated, anon, service_role;

-- Refresh packs view so required_to_win reflects 6
DROP VIEW IF EXISTS public.competition_challenge_period_packs_public;
CREATE VIEW public.competition_challenge_period_packs_public
WITH (security_invoker = false)
AS
SELECT
  pk.window_phase,
  pk.cash_amount,
  pk.pack,
  public.competition_challenge_pack_summary(pk.pack, pk.cash_amount) AS pack_summary,
  public.competition_challenge_pack_display_name(pk.window_phase, pk.pack_name) AS pack_name,
  public.competition_challenge_required_to_win(cur.id, pk.window_phase) AS required_to_win,
  (
    SELECT count(*)::int
    FROM public.competition_challenge_config c
    WHERE c.season_id = cur.id
      AND c.window_phase = pk.window_phase
      AND c.is_active = true
  ) AS active_challenges
FROM public.competition_challenge_period_pack pk
LEFT JOIN LATERAL (
  SELECT s.id
  FROM public.competition_seasons s
  WHERE s.is_current = true
  ORDER BY s.id DESC
  LIMIT 1
) cur ON true;

GRANT SELECT ON public.competition_challenge_period_packs_public TO authenticated, anon;

NOTIFY pgrst, 'reload schema';

DO $$
DECLARE
  v_req int;
BEGIN
  SELECT challenge_big_prize_required INTO v_req
  FROM public.global_settings WHERE id = 1;
  RAISE NOTICE 'challenge_big_prize_required is now % (expect 6)', v_req;
END $$;
