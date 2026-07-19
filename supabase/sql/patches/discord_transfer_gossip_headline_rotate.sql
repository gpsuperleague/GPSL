-- =============================================================================
-- Discord gossip headlines: rotate through the 5 RUMOUR lines (not random)
-- So consecutive posts don't repeat the same wording.
-- Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.gpsl_rumour_discord_headline(
  p_club_name text,
  p_player_name text
)
RETURNS text
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := coalesce(nullif(btrim(p_club_name), ''), 'A GPSL club');
  v_player text := coalesce(nullif(btrim(p_player_name), ''), 'a target');
  v_n int;
  v_pick int;
BEGIN
  -- Next slot in rotation based on how many Discord rumours already exist
  SELECT count(*)::int INTO v_n
  FROM public.gpsl_transfer_rumours
  WHERE source = 'discord';

  v_pick := (coalesce(v_n, 0) % 5) + 1;

  RETURN CASE v_pick
    WHEN 1 THEN format('RUMOUR: %s are tracking %s', v_club, v_player)
    WHEN 2 THEN format('RUMOUR: %s are considering an approach for %s', v_club, v_player)
    WHEN 3 THEN format(
      'RUMOUR: %s have been scouting %s, offer imminent according to sources',
      v_club, v_player
    )
    WHEN 4 THEN format('RUMOUR: %s in private discussions with %s', v_player, v_club)
    ELSE format(
      'RUMOUR: %s sporting director at odds with manager on transfer targets as %s causes divide',
      v_club, v_player
    )
  END;
END;
$function$;

COMMENT ON FUNCTION public.gpsl_rumour_discord_headline(text, text) IS
  'Cycles through 5 Discord rumour phrasings (round-robin by discord rumour count).';
