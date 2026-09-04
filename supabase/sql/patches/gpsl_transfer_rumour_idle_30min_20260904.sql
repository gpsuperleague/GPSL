-- =============================================================================
-- Idle fun fillers: refresh every 30 minutes
--
-- Discord gossip still lasts to UK day end.
-- Idle rows expire after 30 minutes; ensure_idle rotates in fresh lines.
-- Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.gpsl_rumour_ensure_idle(
  p_season_id bigint,
  p_need int DEFAULT 2
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_have int;
  v_need int := greatest(0, least(coalesce(p_need, 2), 3));
  v_i int;
  v_tpl text;
  v_club_short text;
  v_club_name text;
  v_player_id text;
  v_player_name text;
  v_headline text;
  v_expires timestamptz := now() + interval '30 minutes';
  v_templates text[] := public.gpsl_rumour_idle_templates();
BEGIN
  IF p_season_id IS NULL OR v_need < 1 THEN
    RETURN;
  END IF;

  -- Drop idle fillers older than 30 minutes (also clears prior day-long idle rows)
  UPDATE public.gpsl_transfer_rumours r
  SET expires_at = least(r.expires_at, now())
  WHERE r.season_id = p_season_id
    AND r.source = 'idle'
    AND r.expires_at > now()
    AND r.created_at <= now() - interval '30 minutes';

  SELECT count(*)::int INTO v_have
  FROM public.gpsl_transfer_rumours r
  WHERE r.season_id = p_season_id
    AND r.source = 'idle'
    AND r.expires_at > now();

  FOR v_i IN 1..(v_need - coalesce(v_have, 0)) LOOP
    SELECT c."ShortName", c."Club"
    INTO v_club_short, v_club_name
    FROM public."Clubs" c
    WHERE c.owner_id IS NOT NULL
      AND coalesce(c."ShortName", '') NOT IN ('FOREIGN', 'GPDB')
    ORDER BY random()
    LIMIT 1;

    IF v_club_short IS NULL THEN
      EXIT;
    END IF;

    SELECT p."Konami_ID"::text, p."Name"
    INTO v_player_id, v_player_name
    FROM public."Players" p
    WHERE nullif(btrim(p."Contracted_Team"), '') IS NOT NULL
      AND (
        upper(btrim(p."Contracted_Team")) = upper(v_club_short)
        OR lower(btrim(p."Contracted_Team")) = lower(v_club_name)
      )
    ORDER BY random()
    LIMIT 1;

    IF v_player_name IS NULL THEN
      SELECT p."Konami_ID"::text, p."Name"
      INTO v_player_id, v_player_name
      FROM public."Players" p
      WHERE nullif(btrim(p."Contracted_Team"), '') IS NOT NULL
      ORDER BY random()
      LIMIT 1;
    END IF;

    IF v_player_name IS NULL THEN
      v_player_name := 'a key player';
    END IF;

    v_tpl := v_templates[1 + floor(random() * array_length(v_templates, 1))::int];
    v_headline := replace(v_tpl, '{club}', coalesce(v_club_name, v_club_short));
    v_headline := replace(v_headline, '{player}', coalesce(v_player_name, 'a key player'));

    INSERT INTO public.gpsl_transfer_rumours (
      season_id, source, kind, club_short_name, club_name,
      player_id, player_name, headline, expires_at
    )
    VALUES (
      p_season_id, 'idle', 'idle', v_club_short, v_club_name,
      v_player_id, v_player_name, v_headline, v_expires
    );
  END LOOP;
END;
$function$;

COMMENT ON FUNCTION public.gpsl_rumour_ensure_idle(bigint, int) IS
  'Keeps idle fun fillers topped up; each idle line lasts 30 minutes then rotates.';

GRANT EXECUTE ON FUNCTION public.gpsl_rumour_ensure_idle(bigint, int)
  TO authenticated, service_role;
