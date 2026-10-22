-- =============================================================================
-- Discord / mutual lock: either club can decline (not only the requester)
--
-- match_schedule_fixture_context previously hid Cancel from the recipient
-- (can_cancel only if requester or already confirmed). Cancel RPC already
-- allowed both clubs — this exposes it and notifies the other side.
-- Safe re-run.
-- =============================================================================

DO $ctx$
DECLARE
  v_def text;
  v_old text :=
    'v_can_cancel_override := v_my_override_confirmed OR v_override.requested_by_club = v_club;';
  v_new text :=
    'v_can_cancel_override := true; -- either club may decline / cancel a pending Discord lock';
BEGIN
  IF to_regprocedure('public.match_schedule_fixture_context(bigint)') IS NULL THEN
    RAISE EXCEPTION 'match_schedule_fixture_context missing';
  END IF;

  SELECT replace(pg_get_functiondef('public.match_schedule_fixture_context(bigint)'::regprocedure), E'\r\n', E'\n')
  INTO v_def;

  IF position(v_new IN v_def) > 0 THEN
    RAISE NOTICE 'can_cancel already open to both clubs';
  ELSIF position(v_old IN v_def) = 0 THEN
    RAISE WARNING 'can_cancel needle not found — UI may still hide Decline';
  ELSE
    EXECUTE replace(v_def, v_old, v_new);
    RAISE NOTICE 'can_cancel opened to both clubs';
  END IF;
END;
$ctx$;

CREATE OR REPLACE FUNCTION public.fixture_mutual_override_cancel(p_fixture_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text;
  v_fixture public.competition_fixtures;
  v_override public.competition_fixture_mutual_override;
  v_n integer;
  v_other text;
  v_fmt text;
  v_declined boolean;
BEGIN
  v_club := public.my_club_shortname();
  IF v_club IS NULL OR v_club = '' THEN
    RAISE EXCEPTION 'No club linked to this account';
  END IF;

  SELECT * INTO v_fixture FROM public.competition_fixtures WHERE id = p_fixture_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Fixture not found';
  END IF;

  IF v_club NOT IN (v_fixture.home_club_short_name, v_fixture.away_club_short_name) THEN
    RAISE EXCEPTION 'You are not in this fixture';
  END IF;

  SELECT * INTO v_override
  FROM public.competition_fixture_mutual_override
  WHERE fixture_id = p_fixture_id
    AND status = 'pending'
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'ok', false,
      'code', 'no_pending',
      'message', 'No pending mutual override to cancel.'
    );
  END IF;

  v_declined := v_override.requested_by_club IS DISTINCT FROM v_club;
  v_other := CASE
    WHEN v_club = v_fixture.home_club_short_name THEN v_fixture.away_club_short_name
    ELSE v_fixture.home_club_short_name
  END;

  UPDATE public.competition_fixture_mutual_override
  SET status = 'cancelled'
  WHERE id = v_override.id
    AND status = 'pending';

  GET DIAGNOSTICS v_n = ROW_COUNT;
  IF v_n = 0 THEN
    RETURN jsonb_build_object(
      'ok', false,
      'code', 'no_pending',
      'message', 'No pending mutual override to cancel.'
    );
  END IF;

  BEGIN
    v_fmt := to_char(
      timezone('Europe/London', v_override.proposed_kickoff_at),
      'Dy DD Mon YYYY HH24:MI'
    ) || ' UK';
  EXCEPTION WHEN OTHERS THEN
    v_fmt := coalesce(v_override.proposed_kickoff_at::text, 'the proposed time');
  END;

  IF v_declined AND v_other IS NOT NULL
     AND to_regprocedure(
       'public.owner_inbox_send(text,text,text,text,uuid,bigint,bigint,bigint,bigint,text,text,text,bigint,timestamptz)'
     ) IS NOT NULL THEN
    BEGIN
      PERFORM public.owner_inbox_send(
        'match_mutual_override_cancelled',
        'Discord kick-off declined',
        coalesce(public.club_display_name(v_club), v_club)
          || ' declined the Discord lock for '
          || v_fmt
          || E'.\nPropose a time on Schedule match, or agree on Discord and lock again.',
        v_other,
        NULL,
        p_fixture_id,
        NULL, NULL, NULL,
        'fixture_schedule.html?fixture=' || p_fixture_id::text,
        'mutual_declined:' || p_fixture_id::text || ':' || v_override.id::text,
        v_fixture.gpsl_month,
        v_fixture.season_id,
        NULL
      );
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'mutual decline inbox failed: %', SQLERRM;
    END;
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'declined', v_declined,
    'message', CASE
      WHEN v_declined THEN 'Declined — Discord lock cancelled. Propose or agree a different time.'
      ELSE 'Mutual override cancelled.'
    END
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.fixture_mutual_override_cancel(bigint) TO authenticated;

-- Allow cancelled message type on inbox if constrained
DO $inbox$
DECLARE
  v_def text;
  v_list text;
BEGIN
  SELECT pg_get_constraintdef(c.oid) INTO v_def
  FROM pg_constraint c
  WHERE c.conrelid = 'public.competition_inbox'::regclass
    AND c.conname = 'competition_inbox_message_type_check';

  IF v_def IS NULL OR position('''match_mutual_override_cancelled''' IN v_def) > 0 THEN
    RETURN;
  END IF;

  SELECT string_agg(quote_literal(t), ', ' ORDER BY t) INTO v_list
  FROM (
    SELECT DISTINCT message_type AS t FROM public.competition_inbox WHERE message_type IS NOT NULL
    UNION
    SELECT (regexp_matches(coalesce(v_def, ''), '''([^'']+)''', 'g'))[1]
    UNION SELECT 'match_mutual_override_cancelled'
  ) s
  WHERE t IS NOT NULL AND btrim(t) <> '';

  ALTER TABLE public.competition_inbox DROP CONSTRAINT IF EXISTS competition_inbox_message_type_check;
  EXECUTE format(
    'ALTER TABLE public.competition_inbox ADD CONSTRAINT competition_inbox_message_type_check CHECK (message_type IN (%s)) NOT VALID',
    v_list
  );
  ALTER TABLE public.competition_inbox VALIDATE CONSTRAINT competition_inbox_message_type_check;
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING 'inbox message_type check update skipped: %', SQLERRM;
END;
$inbox$;

NOTIFY pgrst, 'reload schema';

SELECT position(
  'v_can_cancel_override := true;' IN
  replace(pg_get_functiondef('public.match_schedule_fixture_context(bigint)'::regprocedure), E'\r\n', E'\n')
) > 0 AS can_cancel_open;
