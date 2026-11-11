-- Record Barcelona's sixth Start challenge (The October Wall) and the
-- Recovery & Redemption pack, then tell the winner and every other owner.
-- The clean sheet that completed it is fixture 9053 (ACM 0-8 BAR), posted
-- 11 Nov 2026 20:10 UTC. Confirm kept the result and swallowed the prize pass.
-- Safe to re-run: a pack row already stored stops the script before a second grant.

SET statement_timeout = '120s';

DROP POLICY IF EXISTS competition_challenge_period_bonus_anon_select
  ON public.competition_challenge_period_bonus_awarded;
CREATE POLICY competition_challenge_period_bonus_anon_select
  ON public.competition_challenge_period_bonus_awarded
  FOR SELECT TO anon
  USING (true);

DO $award$
DECLARE
  v_ok boolean;
  v_pack boolean;
  v_season bigint;
BEGIN
  SELECT c.season_id INTO v_season
  FROM public.competition_challenge_config c
  WHERE c.id = 99;

  IF v_season IS NULL THEN
    RAISE EXCEPTION 'October Wall challenge is missing';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.competition_challenge_period_bonus_awarded
    WHERE season_id = v_season
      AND window_phase = 'start'
  ) THEN
    RAISE EXCEPTION 'start pack already awarded — notices were not sent again';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.competition_challenge_awarded
    WHERE challenge_id = 99
      AND club_short_name = 'BAR'
  ) THEN
    v_ok := public.competition_award_challenge(99, 'BAR', 2, false);
    IF NOT coalesce(v_ok, false) THEN
      RAISE EXCEPTION 'October Wall was not awarded';
    END IF;

    UPDATE public.competition_challenge_awarded
    SET awarded_at = (
      SELECT f.result_posted_at
      FROM public.competition_fixtures f
      WHERE f.id = 9053
    )
    WHERE challenge_id = 99
      AND club_short_name = 'BAR';
  END IF;

  v_pack := public.competition_try_award_period_bonus(v_season, 'BAR', 'start', false);
  IF NOT coalesce(v_pack, false) THEN
    RAISE EXCEPTION 'pack false done=% required=% earliest=% finish=% window=% fallback=% wall_at=%',
      (
        SELECT count(*)
        FROM public.competition_challenge_awarded a
        JOIN public.competition_challenge_config c ON c.id = a.challenge_id
        WHERE a.season_id = v_season
          AND a.club_short_name = 'BAR'
          AND c.window_phase = 'start'
          AND c.is_active
      ),
      public.competition_challenge_required_to_win(v_season, 'start'),
      (
        SELECT e.club_short_name
        FROM public.competition_challenge_earliest_finisher(v_season, 'start', 6) e
      ),
      (
        SELECT e.finished_at
        FROM public.competition_challenge_earliest_finisher(v_season, 'start', 6) e
      ),
      public.competition_challenge_window_open(
        v_season,
        'start',
        (
          SELECT max(c.gpsl_month_to)
          FROM public.competition_challenge_config c
          WHERE c.season_id = v_season
            AND c.window_phase = 'start'
            AND c.is_active
        )
      ),
      (SELECT challenge_period_bonus FROM public.global_settings WHERE id = 1),
      (
        SELECT a.awarded_at
        FROM public.competition_challenge_awarded a
        WHERE a.challenge_id = 99 AND a.club_short_name = 'BAR'
      );
  END IF;
END;
$award$;

SELECT jsonb_build_object(
  'winner', (
    SELECT jsonb_build_object(
      'club', b.club_short_name,
      'amount', b.amount,
      'at', b.awarded_at,
      'finished', b.pack_snapshot->>'finished_at'
    )
    FROM public.competition_challenge_period_bonus_awarded b
    JOIN public.competition_seasons s ON s.id = b.season_id AND s.is_current
    WHERE b.window_phase = 'start'
  ),
  'wall_paid', (
    SELECT a.amount
    FROM public.competition_challenge_awarded a
    WHERE a.challenge_id = 99 AND a.club_short_name = 'BAR'
  ),
  'winner_inbox', (
    SELECT count(*)
    FROM public.competition_inbox i
    WHERE i.dedupe_key LIKE 'challenge_big_prize_winner:%:start:BAR'
  ),
  'other_inbox', (
    SELECT count(*)
    FROM public.competition_inbox i
    WHERE i.dedupe_key LIKE 'challenge_big_prize_league:%:start:%'
      AND i.dedupe_key NOT LIKE '%:BAR'
  ),
  'discord', (
    SELECT coalesce(jsonb_agg(jsonb_build_object(
      'id', q.id,
      'event', q.event_type,
      'status', q.status,
      'headline', q.headline,
      'error', q.last_error
    )), '[]'::jsonb)
    FROM public.gpsl_discord_feed_queue q
    WHERE q.dedupe_key LIKE 'challenge_big_prize:%:start'
  )
);
