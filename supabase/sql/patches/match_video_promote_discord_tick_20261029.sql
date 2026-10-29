-- =============================================================================
-- Match videos: after pending promote, upgrade Discord ⏳ → ✅
--
-- Cause: promote is SQL-only; Discord reaction was set once at ingest (⏳) and
-- never refreshed when the GPSL result confirmed and the video matched.
--
-- Fix:
--   • Edge mode upgrade_reactions (deploy discord-match-videos-ingest)
--   • pg_net notify after successful promote
--   • Admin backfill for already-matched rows still showing ⏳
--
-- Safe re-run. Deploy edge function, then run this SQL.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.gpsl_discord_match_videos_request_upgrade_reactions(
  p_messages jsonb DEFAULT '[]'::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions, net
AS $function$
DECLARE
  v_url text;
  v_key text;
  v_msgs jsonb := coalesce(p_messages, '[]'::jsonb);
  v_req_id bigint;
  v_n int;
BEGIN
  IF jsonb_typeof(v_msgs) <> 'array' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'messages_must_be_array');
  END IF;

  SELECT count(*)::int INTO v_n
  FROM jsonb_array_elements(v_msgs) m
  WHERE nullif(btrim(coalesce(m->>'channel_id', m->>'discord_channel_id', '')), '') IS NOT NULL
    AND nullif(btrim(coalesce(m->>'message_id', m->>'discord_message_id', '')), '') IS NOT NULL;

  IF coalesce(v_n, 0) <= 0 THEN
    RETURN jsonb_build_object('ok', true, 'queued', 0, 'reason', 'no_messages');
  END IF;

  SELECT s.edge_function_url, s.invoke_key
  INTO v_url, v_key
  FROM public.gpsl_discord_match_videos_settings s
  WHERE s.id = 1;

  IF v_url IS NULL OR btrim(v_url) = '' THEN
    v_url := 'https://omyyogfumrjoaweuawjn.supabase.co/functions/v1/discord-match-videos-ingest';
  END IF;

  IF v_key IS NULL OR btrim(v_key) = '' THEN
    RETURN jsonb_build_object(
      'ok', false,
      'reason', 'No invoke key in match videos settings'
    );
  END IF;

  SELECT net.http_post(
    url := v_url,
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || v_key
    ),
    body := jsonb_build_object(
      'mode', 'upgrade_reactions',
      'upgrade_reactions', true,
      'messages', v_msgs
    ),
    timeout_milliseconds := 180000
  ) INTO v_req_id;

  RETURN jsonb_build_object(
    'ok', true,
    'queued', v_n,
    'request_id', v_req_id
  );
EXCEPTION
  WHEN undefined_function THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'pg_net missing');
  WHEN OTHERS THEN
    RETURN jsonb_build_object('ok', false, 'reason', SQLERRM);
END;
$function$;

REVOKE ALL ON FUNCTION public.gpsl_discord_match_videos_request_upgrade_reactions(jsonb)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.gpsl_discord_match_videos_request_upgrade_reactions(jsonb)
  TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.match_video_promote_pending_for_fixture(p_fixture_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_fixture public.competition_fixtures%ROWTYPE;
  v_pend public.fixture_match_video_pending%ROWTYPE;
  v_check jsonb;
  v_n int := 0;
  v_fail int := 0;
  v_ingest jsonb;
  v_msgs jsonb := '[]'::jsonb;
  v_chan text;
  v_msg text;
  v_discord jsonb;
BEGIN
  PERFORM set_config('gpsl.match_video_internal', '1', true);

  SELECT * INTO v_fixture
  FROM public.competition_fixtures f
  WHERE f.id = p_fixture_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'fixture_not_found');
  END IF;

  IF v_fixture.status IS DISTINCT FROM 'played'
     OR v_fixture.home_goals IS NULL
     OR v_fixture.away_goals IS NULL
  THEN
    RETURN jsonb_build_object('ok', true, 'promoted', 0, 'reason', 'not_played_yet');
  END IF;

  FOR v_pend IN
    SELECT * FROM public.fixture_match_video_pending p
    WHERE p.fixture_id = p_fixture_id
    ORDER BY p.id
  LOOP
    v_check := public.match_video_scores_match_fixture(v_fixture, v_pend.parsed);
    IF coalesce((v_check->>'ok')::boolean, false) IS NOT TRUE THEN
      v_fail := v_fail + 1;
      CONTINUE;
    END IF;

    v_ingest := public.match_video_ingest_attachment(
      v_pend.discord_message_id,
      v_pend.discord_channel_id,
      v_pend.discord_attachment_id,
      v_pend.discord_user_id,
      v_pend.club_short_name,
      coalesce(v_pend.filename, ''),
      v_pend.video_url,
      v_pend.gpsl_month,
      v_pend.source
    );

    IF coalesce((v_ingest->>'ok')::boolean, false)
       AND coalesce(v_ingest->>'status', '') IN ('matched', 'duplicate') THEN
      DELETE FROM public.fixture_match_video_pending WHERE id = v_pend.id;
      v_n := v_n + 1;

      v_chan := nullif(btrim(coalesce(v_pend.discord_channel_id, '')), '');
      v_msg := nullif(btrim(coalesce(v_pend.discord_message_id, '')), '');
      IF v_chan IS NOT NULL AND v_msg IS NOT NULL THEN
        IF NOT EXISTS (
          SELECT 1
          FROM jsonb_array_elements(v_msgs) x
          WHERE x->>'channel_id' = v_chan
            AND x->>'message_id' = v_msg
        ) THEN
          v_msgs := v_msgs || jsonb_build_array(
            jsonb_build_object(
              'channel_id', v_chan,
              'message_id', v_msg
            )
          );
        END IF;
      END IF;
    ELSE
      v_fail := v_fail + 1;
    END IF;
  END LOOP;

  IF jsonb_array_length(v_msgs) > 0
     AND to_regprocedure(
           'public.gpsl_discord_match_videos_request_upgrade_reactions(jsonb)'
         ) IS NOT NULL THEN
    BEGIN
      v_discord := public.gpsl_discord_match_videos_request_upgrade_reactions(v_msgs);
    EXCEPTION WHEN OTHERS THEN
      v_discord := jsonb_build_object('ok', false, 'reason', SQLERRM);
    END;
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'fixture_id', p_fixture_id,
    'promoted', v_n,
    'failed', v_fail,
    'discord_upgrade', coalesce(v_discord, jsonb_build_object('queued', 0))
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.match_video_promote_pending_for_fixture(bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.match_video_promote_pending_for_fixture(bigint)
  TO authenticated, service_role;

-- Backfill: upgrade Discord reactions for matched videos (stuck ⏳)
CREATE OR REPLACE FUNCTION public.admin_match_video_upgrade_discord_reactions(
  p_fixture_id bigint DEFAULT NULL,
  p_days int DEFAULT 14
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_msgs jsonb := '[]'::jsonb;
  v_days int := greatest(1, least(coalesce(p_days, 14), 90));
  v_out jsonb;
BEGIN
  IF NOT public.is_gpsl_admin()
     AND coalesce(auth.role(), '') <> 'service_role'
     AND current_user NOT IN ('postgres', 'supabase_admin') THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  SELECT coalesce(jsonb_agg(x.msg), '[]'::jsonb)
  INTO v_msgs
  FROM (
    SELECT DISTINCT ON (v.discord_channel_id, v.discord_message_id)
      jsonb_build_object(
        'channel_id', v.discord_channel_id,
        'message_id', v.discord_message_id
      ) AS msg
    FROM public.fixture_match_videos v
    WHERE nullif(btrim(coalesce(v.discord_channel_id, '')), '') IS NOT NULL
      AND nullif(btrim(coalesce(v.discord_message_id, '')), '') IS NOT NULL
      AND (
        p_fixture_id IS NULL
        OR v.fixture_id = p_fixture_id
      )
      AND (
        p_fixture_id IS NOT NULL
        OR v.created_at >= now() - make_interval(days => v_days)
      )
    ORDER BY v.discord_channel_id, v.discord_message_id
  ) x;

  v_out := public.gpsl_discord_match_videos_request_upgrade_reactions(v_msgs);

  RETURN jsonb_build_object(
    'ok', coalesce((v_out->>'ok')::boolean, false),
    'messages', v_msgs,
    'message_count', jsonb_array_length(v_msgs),
    'request', v_out
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.admin_match_video_upgrade_discord_reactions(bigint, int)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_match_video_upgrade_discord_reactions(bigint, int)
  TO authenticated, service_role;

-- Drop zero-arg overload if a prior run created it (clashes with DEFAULT args)
DROP FUNCTION IF EXISTS public.admin_match_video_upgrade_discord_reactions();

NOTIFY pgrst, 'reload schema';

-- Optional one-shot backfill (last 14 days of matched Discord videos)
SELECT public.admin_match_video_upgrade_discord_reactions(NULL::bigint, 14)
  AS backfill_upgrade;
