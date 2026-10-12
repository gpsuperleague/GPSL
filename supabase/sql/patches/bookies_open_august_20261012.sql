-- =============================================================================
-- Bookies opens in GPSL August (2026-10-12)
-- =============================================================================
-- Was July. Opening when GPSL flicks from July to August means every June and
-- July friendly is already in the club odds.
--
--   * bookies_shop_open(season) → true once the season's August has unlocked
--   * market state reason / market-create block now say "August"
--   * bookies_shop_status() → { open, opens_at, open_markets } for the
--     Owners Shop reminder and the Bookies page
--   * bookies_open_announce_tick() (hourly cron): once the shop is open and at
--     least one market is open, reprices club odds from the final friendlies
--     and sends the "Bookies is open" inbox to every owned club (once per club
--     per season — owners who join later get it on the next tick)
-- Requires bookies_running_competitions_20261011.sql. Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.bookies_shop_open(p_season_id bigint)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
  SELECT coalesce(
    (SELECT min(c.unlock_at) <= now()
     FROM public.competition_season_calendar c
     WHERE c.season_id = p_season_id AND lower(c.gpsl_month) = 'august'
     HAVING count(*) > 0),
    true
  );
$function$;

GRANT EXECUTE ON FUNCTION public.bookies_shop_open(bigint) TO authenticated;

CREATE OR REPLACE FUNCTION public.trg_bookies_markets_block_before_july()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF NOT public.bookies_shop_open(NEW.season_id) THEN
    RAISE EXCEPTION 'The bookies opens in GPSL August — markets can''t be opened before then';
  END IF;
  RETURN NEW;
END;
$function$;

DO $reason$
DECLARE
  v_def text;
BEGIN
  SELECT pg_get_functiondef('public.bookies_market_state(bigint)'::regprocedure) INTO v_def;
  IF position('Betting opens in July' IN v_def) > 0 THEN
    EXECUTE replace(v_def, 'Betting opens in July', 'Betting opens in GPSL August');
  END IF;
END
$reason$;

CREATE OR REPLACE FUNCTION public.bookies_current_season_id()
RETURNS bigint
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT id FROM public.competition_seasons WHERE is_current = true ORDER BY id DESC LIMIT 1;
$$;

CREATE OR REPLACE FUNCTION public.bookies_shop_status()
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT jsonb_build_object(
    'season_id', s.id,
    'open', public.bookies_shop_open(s.id),
    'opens_at', (
      SELECT min(c.unlock_at) FROM public.competition_season_calendar c
      WHERE c.season_id = s.id AND lower(c.gpsl_month) = 'august'
    ),
    'open_markets', (
      SELECT count(*) FROM public.bookies_markets m
      WHERE m.season_id = s.id AND m.status = 'open'
    )
  )
  FROM (SELECT public.bookies_current_season_id() AS id) s;
$$;

GRANT EXECUTE ON FUNCTION public.bookies_shop_status() TO authenticated;

-- ---------------------------------------------------------------------------
-- Inbox type
-- ---------------------------------------------------------------------------
DO $inbox_types$
DECLARE
  v_def text;
  v_list text;
BEGIN
  SELECT pg_get_constraintdef(c.oid) INTO v_def
  FROM pg_constraint c
  WHERE c.conrelid = 'public.competition_inbox'::regclass
    AND c.conname = 'competition_inbox_message_type_check';

  IF v_def IS NULL OR position('''bookies_open''' IN v_def) > 0 THEN
    RETURN;
  END IF;

  SELECT string_agg(quote_literal(t), ', ' ORDER BY t) INTO v_list
  FROM (
    SELECT DISTINCT message_type AS t FROM public.competition_inbox WHERE message_type IS NOT NULL
    UNION
    SELECT (regexp_matches(v_def, '''([^'']+)''', 'g'))[1]
    UNION
    SELECT 'bookies_open'
  ) s
  WHERE t IS NOT NULL AND btrim(t) <> '';

  ALTER TABLE public.competition_inbox DROP CONSTRAINT IF EXISTS competition_inbox_message_type_check;
  EXECUTE format(
    'ALTER TABLE public.competition_inbox ADD CONSTRAINT competition_inbox_message_type_check CHECK (message_type IN (%s)) NOT VALID',
    v_list
  );
  ALTER TABLE public.competition_inbox VALIDATE CONSTRAINT competition_inbox_message_type_check;
END
$inbox_types$;

-- ---------------------------------------------------------------------------
-- Opening announcement (hourly)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.bookies_open_announce_tick()
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season bigint := public.bookies_current_season_id();
  v_first boolean;
  v_sent int;
BEGIN
  IF v_season IS NULL OR NOT public.bookies_shop_open(v_season) THEN
    RETURN 0;
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.bookies_markets m WHERE m.season_id = v_season AND m.status = 'open'
  ) THEN
    RETURN 0;
  END IF;

  v_first := NOT EXISTS (
    SELECT 1 FROM public.competition_inbox i
    WHERE i.dedupe_key LIKE 'bookies_open_aug:' || v_season || ':%'
  );

  IF v_first AND to_regprocedure('public.admin_bookies_recompute_club_odds(bigint)') IS NOT NULL THEN
    BEGIN
      PERFORM public.admin_bookies_recompute_club_odds(v_season);
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'bookies open: odds recompute failed: %', SQLERRM;
    END;
  END IF;

  v_sent := public.owner_inbox_notify_all_clubs(
    'bookies_open',
    '🎰 The GPSL Bookies is open!',
    E'GPSL August is here and the Bookies is open for the season — league champions, cup winners and top scorers.\n\n'
    || E'Club odds are built from June and July friendly results, squad strength, club prestige and owner rankings. Competitions not yet drawn are greyed out until their draw is made.\n\n'
    || E'• Stake up to ₿1,000 per bet from your owner wallet (not club funds)\n'
    || E'• One bet per market — pick wisely\n'
    || E'• No betting on your own club or your own players\n'
    || E'• Odds move as bets come in, so early prices can be the best\n'
    || E'• Winnings are paid straight into your owner wallet when a market settles\n\n'
    || E'Good luck!',
    'bookies.html',
    'bookies_open_aug:' || v_season,
    v_season
  );

  RETURN v_sent;
END;
$function$;

REVOKE ALL ON FUNCTION public.bookies_open_announce_tick() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.bookies_open_announce_tick() TO service_role;

DO $cron$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.unschedule(jobid) FROM cron.job WHERE jobname = 'gpsl-bookies-open-announce';
    PERFORM cron.schedule(
      'gpsl-bookies-open-announce',
      '7 * * * *',
      'SELECT public.bookies_open_announce_tick();'
    );
  END IF;
END
$cron$;

NOTIFY pgrst, 'reload schema';

SELECT
  public.bookies_shop_status() AS shop_status,
  to_char((public.bookies_shop_status()->>'opens_at')::timestamptz AT TIME ZONE 'Europe/London',
          'Dy DD Mon YYYY HH24:MI') AS opens_uk,
  (SELECT schedule FROM cron.job WHERE jobname = 'gpsl-bookies-open-announce') AS cron_schedule;
