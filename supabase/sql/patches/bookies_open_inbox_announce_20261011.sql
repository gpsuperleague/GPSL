-- =============================================================================
-- Bookies open — inbox announcement to every owned club (one-off, safe re-run)
-- Opening markets in admin does NOT send an inbox; run this after opening.
-- Dedupe key per season, so re-running won't double-send.
-- =============================================================================

DO $inbox_types$
DECLARE
  v_def text;
  v_list text;
BEGIN
  SELECT pg_get_constraintdef(c.oid)
  INTO v_def
  FROM pg_constraint c
  WHERE c.conrelid = 'public.competition_inbox'::regclass
    AND c.conname = 'competition_inbox_message_type_check';

  IF v_def IS NOT NULL AND position('''bookies_open''' IN v_def) > 0 THEN
    RETURN;
  END IF;

  SELECT string_agg(quote_literal(t), ', ' ORDER BY t)
  INTO v_list
  FROM (
    SELECT DISTINCT message_type AS t
    FROM public.competition_inbox
    WHERE message_type IS NOT NULL
    UNION
    SELECT (regexp_matches(coalesce(v_def, ''), '''([^'']+)''', 'g'))[1]
    UNION
    SELECT 'bookies_open'
  ) s
  WHERE t IS NOT NULL AND btrim(t) <> '';

  ALTER TABLE public.competition_inbox
    DROP CONSTRAINT IF EXISTS competition_inbox_message_type_check;

  EXECUTE format(
    'ALTER TABLE public.competition_inbox
       ADD CONSTRAINT competition_inbox_message_type_check
       CHECK (message_type IN (%s)) NOT VALID',
    v_list
  );

  ALTER TABLE public.competition_inbox
    VALIDATE CONSTRAINT competition_inbox_message_type_check;
END;
$inbox_types$;

SELECT public.owner_inbox_notify_all_clubs(
  'bookies_open',
  '🎰 The GPSL Bookies is open!',
  E'Season markets are live — league winners, cup winners, top scorers and more.\n\n'
  || E'• Stake up to ₿1,000 per bet from your owner wallet (not club funds)\n'
  || E'• One bet per market — pick wisely\n'
  || E'• Odds move as bets come in, so early prices can be the best\n'
  || E'• Winnings are paid straight into your owner wallet when a market settles\n\n'
  || E'Each option shows the club and its owner tag. Good luck!',
  'bookies.html',
  'bookies_open:' || coalesce(
    (SELECT id::text FROM public.competition_seasons WHERE is_current = true ORDER BY id DESC LIMIT 1),
    'now'
  ),
  (SELECT id FROM public.competition_seasons WHERE is_current = true ORDER BY id DESC LIMIT 1)
) AS clubs_notified;
