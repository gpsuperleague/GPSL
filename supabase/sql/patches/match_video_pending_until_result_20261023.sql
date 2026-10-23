-- =============================================================================
-- Match videos: hold early Discord uploads until GPSL result is confirmed
-- =============================================================================
-- Problem: owners post to Discord before entering/confirming the result →
-- score verify fails → Discord ⚠️. Poll cursor often skips that message later.
--
-- Fix:
--   • Fixture matched but not yet played → store PENDING (no payout yet)
--   • Ingest returns ok=true, status=pending (edge reacts ⏳)
--   • When fixture becomes played → promote if label score matches → ✓ + payout
-- Safe re-run.
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.fixture_match_video_pending (
  id bigserial PRIMARY KEY,
  season_id bigint NOT NULL REFERENCES public.competition_seasons(id) ON DELETE CASCADE,
  fixture_id bigint NOT NULL REFERENCES public.competition_fixtures(id) ON DELETE CASCADE,
  side text NOT NULL CHECK (side IN ('home', 'away')),
  club_short_name text NOT NULL,
  video_url text NOT NULL,
  filename text,
  tag text,
  gpsl_month text,
  parsed jsonb NOT NULL DEFAULT '{}'::jsonb,
  discord_message_id text,
  discord_channel_id text,
  discord_attachment_id text,
  discord_user_id text,
  source text NOT NULL DEFAULT 'discord',
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT fixture_match_video_pending_fixture_side_uidx UNIQUE (fixture_id, side)
);

CREATE UNIQUE INDEX IF NOT EXISTS fixture_match_video_pending_attachment_uidx
  ON public.fixture_match_video_pending (discord_attachment_id)
  WHERE discord_attachment_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS fixture_match_video_pending_fixture_idx
  ON public.fixture_match_video_pending (fixture_id);

ALTER TABLE public.fixture_match_video_pending ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS fixture_match_video_pending_select ON public.fixture_match_video_pending;
CREATE POLICY fixture_match_video_pending_select
  ON public.fixture_match_video_pending
  FOR SELECT TO authenticated
  USING (true);

GRANT SELECT ON public.fixture_match_video_pending TO authenticated;
GRANT ALL ON public.fixture_match_video_pending TO service_role;
GRANT USAGE, SELECT ON SEQUENCE public.fixture_match_video_pending_id_seq TO service_role;

CREATE OR REPLACE FUNCTION public.match_video_scores_match_fixture(
  p_fixture public.competition_fixtures,
  p_parsed jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE
AS $function$
DECLARE
  v_club_a text := upper(p_parsed->>'club_a');
  v_club_b text := upper(p_parsed->>'club_b');
  v_sa int;
  v_sb int;
  v_home text := upper(p_fixture.home_club_short_name);
  v_away text := upper(p_fixture.away_club_short_name);
  v_hg int := p_fixture.home_goals;
  v_ag int := p_fixture.away_goals;
BEGIN
  IF p_parsed->>'score_a' IS NULL AND p_parsed->>'score_home' IS NULL THEN
    RETURN jsonb_build_object(
      'ok', false,
      'code', 'score_missing',
      'reason', 'Score missing — include it in the name, e.g. ARS 2-0 CHE [SL-MD5]'
    );
  END IF;

  v_sa := coalesce((p_parsed->>'score_a')::int, (p_parsed->>'score_home')::int);
  v_sb := coalesce((p_parsed->>'score_b')::int, (p_parsed->>'score_away')::int);

  IF v_sa IS NULL OR v_sb IS NULL THEN
    RETURN jsonb_build_object(
      'ok', false,
      'code', 'score_missing',
      'reason', 'Score missing — include it in the name, e.g. ARS 2-0 CHE [SL-MD5]'
    );
  END IF;

  IF p_fixture.status IS DISTINCT FROM 'played'
     OR v_hg IS NULL
     OR v_ag IS NULL
  THEN
    RETURN jsonb_build_object(
      'ok', false,
      'code', 'awaiting_result',
      'reason', 'Holding video until the GPSL result is confirmed — no need to re-post'
    );
  END IF;

  IF v_club_a = v_home AND v_club_b = v_away THEN
    IF v_sa = v_hg AND v_sb = v_ag THEN
      RETURN jsonb_build_object('ok', true, 'code', 'match');
    END IF;
    RETURN jsonb_build_object(
      'ok', false,
      'code', 'score_mismatch',
      'reason', format(
        'Score mismatch — label %s-%s but result is %s-%s',
        v_sa, v_sb, v_hg, v_ag
      )
    );
  END IF;

  IF v_club_a = v_away AND v_club_b = v_home THEN
    IF v_sa = v_ag AND v_sb = v_hg THEN
      RETURN jsonb_build_object('ok', true, 'code', 'match');
    END IF;
    RETURN jsonb_build_object(
      'ok', false,
      'code', 'score_mismatch',
      'reason', format(
        'Score mismatch — label %s-%s (away listed first) but result is %s-%s',
        v_sa, v_sb, v_hg, v_ag
      )
    );
  END IF;

  RETURN jsonb_build_object(
    'ok', false,
    'code', 'clubs_mismatch',
    'reason', 'Clubs in label do not match fixture home/away'
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.match_video_store_pending(
  p_season_id bigint,
  p_fixture_id bigint,
  p_side text,
  p_club text,
  p_url text,
  p_filename text,
  p_parsed jsonb,
  p_channel_month text,
  p_discord_message_id text,
  p_discord_channel_id text,
  p_discord_attachment_id text,
  p_discord_user_id text,
  p_source text DEFAULT 'discord'
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_id bigint;
  v_gpsl text;
BEGIN
  SELECT f.gpsl_month INTO v_gpsl
  FROM public.competition_fixtures f
  WHERE f.id = p_fixture_id;

  INSERT INTO public.fixture_match_video_pending (
    season_id, fixture_id, side, club_short_name, video_url,
    filename, tag, gpsl_month, parsed,
    discord_message_id, discord_channel_id, discord_attachment_id,
    discord_user_id, source, updated_at
  ) VALUES (
    p_season_id, p_fixture_id, p_side, upper(btrim(p_club)), p_url,
    p_filename, p_parsed->>'tag', coalesce(v_gpsl, p_channel_month),
    coalesce(p_parsed, '{}'::jsonb),
    p_discord_message_id, p_discord_channel_id, p_discord_attachment_id,
    p_discord_user_id, coalesce(nullif(btrim(p_source), ''), 'discord'), now()
  )
  ON CONFLICT (fixture_id, side) DO UPDATE SET
    video_url = EXCLUDED.video_url,
    filename = EXCLUDED.filename,
    tag = EXCLUDED.tag,
    gpsl_month = EXCLUDED.gpsl_month,
    parsed = EXCLUDED.parsed,
    discord_message_id = coalesce(EXCLUDED.discord_message_id, fixture_match_video_pending.discord_message_id),
    discord_channel_id = coalesce(EXCLUDED.discord_channel_id, fixture_match_video_pending.discord_channel_id),
    discord_attachment_id = coalesce(EXCLUDED.discord_attachment_id, fixture_match_video_pending.discord_attachment_id),
    discord_user_id = coalesce(EXCLUDED.discord_user_id, fixture_match_video_pending.discord_user_id),
    source = EXCLUDED.source,
    club_short_name = EXCLUDED.club_short_name,
    updated_at = now()
  RETURNING id INTO v_id;

  RETURN jsonb_build_object(
    'ok', true,
    'status', 'pending',
    'fixture_id', p_fixture_id,
    'side', p_side,
    'club', upper(btrim(p_club)),
    'url', p_url,
    'tag', p_parsed->>'tag',
    'credited', 0,
    'pending_id', v_id,
    'reason', 'Holding until GPSL result is confirmed — will match automatically'
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.match_video_store_pending(
  bigint, bigint, text, text, text, text, jsonb, text, text, text, text, text, text
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.match_video_store_pending(
  bigint, bigint, text, text, text, text, jsonb, text, text, text, text, text, text
) TO service_role;

CREATE OR REPLACE FUNCTION public.match_video_ingest_attachment(
  p_discord_message_id text,
  p_discord_channel_id text,
  p_discord_attachment_id text,
  p_discord_user_id text,
  p_uploader_club text,
  p_filename text,
  p_video_url text,
  p_channel_month text DEFAULT NULL,
  p_source text DEFAULT 'discord'
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season_id bigint;
  v_parsed jsonb;
  v_fixture public.competition_fixtures%ROWTYPE;
  v_fixture_id bigint;
  v_club text;
  v_side text;
  v_opp text;
  v_amount numeric := public.match_video_payout_amount();
  v_existing public.fixture_match_videos%ROWTYPE;
  v_pend public.fixture_match_video_pending%ROWTYPE;
  v_row_id bigint;
  v_ledger_id bigint;
  v_credited numeric := 0;
  v_already_credited boolean := false;
  v_url text := nullif(btrim(coalesce(p_video_url, '')), '');
  v_attach text := nullif(btrim(coalesce(p_discord_attachment_id, '')), '');
  v_msg text := nullif(btrim(coalesce(p_discord_message_id, '')), '');
  v_out jsonb;
  v_source text := coalesce(nullif(btrim(p_source), ''), 'discord');
  v_score_check jsonb;
  v_owner jsonb;
BEGIN
  IF coalesce(auth.role(), '') <> 'service_role' AND NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Not allowed';
  END IF;

  IF v_url IS NULL THEN
    v_out := jsonb_build_object('ok', false, 'reason', 'Missing video URL');
    INSERT INTO public.fixture_match_video_ingest_log (
      discord_message_id, discord_channel_id, discord_attachment_id,
      discord_user_id, filename, channel_month, ok, reason, result
    ) VALUES (
      v_msg, p_discord_channel_id, v_attach, p_discord_user_id,
      p_filename, p_channel_month, false, v_out->>'reason', v_out
    );
    RETURN v_out;
  END IF;

  IF NOT public.match_video_url_allowed(v_url) THEN
    v_out := jsonb_build_object(
      'ok', false,
      'reason',
      'URL not allowed — use an https YouTube link (youtu.be / youtube.com) or Discord video attachment'
    );
    INSERT INTO public.fixture_match_video_ingest_log (
      discord_message_id, discord_channel_id, discord_attachment_id,
      discord_user_id, filename, channel_month, ok, reason, result
    ) VALUES (
      v_msg, p_discord_channel_id, v_attach, p_discord_user_id,
      p_filename, p_channel_month, false, v_out->>'reason', v_out
    );
    RETURN v_out;
  END IF;

  IF v_attach IS NOT NULL THEN
    SELECT * INTO v_existing
    FROM public.fixture_match_videos v
    WHERE v.discord_attachment_id = v_attach
    LIMIT 1;
    IF FOUND THEN
      RETURN jsonb_build_object(
        'ok', true,
        'status', 'duplicate',
        'fixture_id', v_existing.fixture_id,
        'side', v_existing.side,
        'url', v_existing.video_url,
        'credited', 0,
        'reason', 'Already ingested this attachment'
      );
    END IF;

    SELECT * INTO v_pend
    FROM public.fixture_match_video_pending p
    WHERE p.discord_attachment_id = v_attach
    LIMIT 1;
    IF FOUND THEN
      RETURN jsonb_build_object(
        'ok', true,
        'status', 'pending',
        'fixture_id', v_pend.fixture_id,
        'side', v_pend.side,
        'club', v_pend.club_short_name,
        'url', v_pend.video_url,
        'credited', 0,
        'pending_id', v_pend.id,
        'reason', 'Already holding this upload until the GPSL result is confirmed'
      );
    END IF;
  END IF;

  SELECT id INTO v_season_id
  FROM public.competition_seasons
  WHERE is_current = true AND status = 'active'
  ORDER BY id DESC
  LIMIT 1;

  IF v_season_id IS NULL THEN
    v_out := jsonb_build_object('ok', false, 'reason', 'No active season');
    INSERT INTO public.fixture_match_video_ingest_log (
      discord_message_id, discord_channel_id, discord_attachment_id,
      discord_user_id, filename, channel_month, ok, reason, result
    ) VALUES (
      v_msg, p_discord_channel_id, v_attach, p_discord_user_id,
      p_filename, p_channel_month, false, v_out->>'reason', v_out
    );
    RETURN v_out;
  END IF;

  v_owner := public.match_video_resolve_uploader_club(
    p_discord_user_id,
    p_uploader_club
  );
  IF coalesce((v_owner->>'ok')::boolean, false) IS NOT TRUE THEN
    v_out := jsonb_build_object(
      'ok', false,
      'reason', coalesce(v_owner->>'reason', 'Could not map Discord user to a GPSL club')
    );
    INSERT INTO public.fixture_match_video_ingest_log (
      season_id, discord_message_id, discord_channel_id, discord_attachment_id,
      discord_user_id, filename, channel_month, ok, reason, result
    ) VALUES (
      v_season_id, v_msg, p_discord_channel_id, v_attach, p_discord_user_id,
      p_filename, p_channel_month, false, v_out->>'reason', v_out
    );
    RETURN v_out;
  END IF;
  v_club := upper(v_owner->>'club');

  v_parsed := public.match_video_parse_filename(p_filename);
  IF v_parsed IS NULL THEN
    v_out := jsonb_build_object(
      'ok', false,
      'reason',
      'Bad name — use: [ARS 2-0 CHE [SL-MD5]](youtube-url) (spaces around - optional)'
    );
    INSERT INTO public.fixture_match_video_ingest_log (
      season_id, discord_message_id, discord_channel_id, discord_attachment_id,
      discord_user_id, filename, channel_month, ok, reason, result
    ) VALUES (
      v_season_id, v_msg, p_discord_channel_id, v_attach, p_discord_user_id,
      p_filename, p_channel_month, false, v_out->>'reason', v_out
    );
    RETURN v_out;
  END IF;

  IF v_club NOT IN (
    upper(v_parsed->>'club_a'),
    upper(v_parsed->>'club_b')
  ) THEN
    v_out := jsonb_build_object(
      'ok', false,
      'reason', format(
        'Uploader club %s is not in filename (%s vs %s)',
        v_club, v_parsed->>'club_a', v_parsed->>'club_b'
      )
    );
    INSERT INTO public.fixture_match_video_ingest_log (
      season_id, discord_message_id, discord_channel_id, discord_attachment_id,
      discord_user_id, filename, channel_month, ok, reason, result
    ) VALUES (
      v_season_id, v_msg, p_discord_channel_id, v_attach, p_discord_user_id,
      p_filename, p_channel_month, false, v_out->>'reason', v_out
    );
    RETURN v_out;
  END IF;

  v_fixture_id := public.match_video_find_fixture(
    v_season_id, v_parsed, p_channel_month
  );
  IF v_fixture_id IS NULL THEN
    v_fixture_id := public.match_video_find_fixture(v_season_id, v_parsed, NULL);
  END IF;

  IF v_fixture_id IS NULL THEN
    v_out := jsonb_build_object(
      'ok', false,
      'reason', format(
        'No fixture matched for %s vs %s [%s]',
        v_parsed->>'club_a', v_parsed->>'club_b', v_parsed->>'tag'
      )
    );
    INSERT INTO public.fixture_match_video_ingest_log (
      season_id, discord_message_id, discord_channel_id, discord_attachment_id,
      discord_user_id, filename, channel_month, ok, reason, result
    ) VALUES (
      v_season_id, v_msg, p_discord_channel_id, v_attach, p_discord_user_id,
      p_filename, p_channel_month, false, v_out->>'reason', v_out
    );
    RETURN v_out;
  END IF;

  SELECT * INTO v_fixture
  FROM public.competition_fixtures f
  WHERE f.id = v_fixture_id;

  IF to_regprocedure('public.match_video_comp_matches_fixture(public.competition_fixtures,jsonb)') IS NOT NULL THEN
    v_score_check := public.match_video_comp_matches_fixture(v_fixture, v_parsed);
    IF coalesce((v_score_check->>'ok')::boolean, false) IS NOT TRUE THEN
      v_out := jsonb_build_object(
        'ok', false,
        'reason', coalesce(v_score_check->>'reason', 'COMP / division check failed'),
        'fixture_id', v_fixture_id
      );
      INSERT INTO public.fixture_match_video_ingest_log (
        season_id, discord_message_id, discord_channel_id, discord_attachment_id,
        discord_user_id, filename, channel_month, ok, reason, fixture_id, result
      ) VALUES (
        v_season_id, v_msg, p_discord_channel_id, v_attach, p_discord_user_id,
        p_filename, p_channel_month, false, v_out->>'reason', v_fixture_id, v_out
      );
      RETURN v_out;
    END IF;
  END IF;

  IF upper(v_fixture.home_club_short_name) = v_club THEN
    v_side := 'home';
    v_opp := v_fixture.away_club_short_name;
  ELSIF upper(v_fixture.away_club_short_name) = v_club THEN
    v_side := 'away';
    v_opp := v_fixture.home_club_short_name;
  ELSE
    v_out := jsonb_build_object(
      'ok', false,
      'reason', 'Uploader club is not home or away on matched fixture'
    );
    INSERT INTO public.fixture_match_video_ingest_log (
      season_id, discord_message_id, discord_channel_id, discord_attachment_id,
      discord_user_id, filename, channel_month, ok, reason, fixture_id, result
    ) VALUES (
      v_season_id, v_msg, p_discord_channel_id, v_attach, p_discord_user_id,
      p_filename, p_channel_month, false, v_out->>'reason', v_fixture_id, v_out
    );
    RETURN v_out;
  END IF;

  v_score_check := public.match_video_scores_match_fixture(v_fixture, v_parsed);
  IF coalesce((v_score_check->>'ok')::boolean, false) IS NOT TRUE THEN
    IF coalesce(v_score_check->>'code', '') = 'awaiting_result' THEN
      v_out := public.match_video_store_pending(
        v_season_id, v_fixture_id, v_side, v_club, v_url, p_filename, v_parsed,
        p_channel_month, v_msg, p_discord_channel_id, v_attach, p_discord_user_id, v_source
      );
      INSERT INTO public.fixture_match_video_ingest_log (
        season_id, discord_message_id, discord_channel_id, discord_attachment_id,
        discord_user_id, filename, channel_month, ok, reason, fixture_id, side, result
      ) VALUES (
        v_season_id, v_msg, p_discord_channel_id, v_attach, p_discord_user_id,
        p_filename, p_channel_month, true, v_out->>'reason', v_fixture_id, v_side, v_out
      );
      RETURN v_out;
    END IF;

    v_out := jsonb_build_object(
      'ok', false,
      'reason', coalesce(v_score_check->>'reason', 'Score check failed'),
      'fixture_id', v_fixture_id,
      'code', v_score_check->>'code'
    );
    INSERT INTO public.fixture_match_video_ingest_log (
      season_id, discord_message_id, discord_channel_id, discord_attachment_id,
      discord_user_id, filename, channel_month, ok, reason, fixture_id, result
    ) VALUES (
      v_season_id, v_msg, p_discord_channel_id, v_attach, p_discord_user_id,
      p_filename, p_channel_month, false, v_out->>'reason', v_fixture_id, v_out
    );
    RETURN v_out;
  END IF;

  SELECT * INTO v_existing
  FROM public.fixture_match_videos v
  WHERE v.fixture_id = v_fixture_id AND v.side = v_side;

  v_already_credited := FOUND AND coalesce(v_existing.credited_amount, 0) > 0;

  IF FOUND THEN
    UPDATE public.fixture_match_videos v
    SET video_url = v_url,
        filename = p_filename,
        tag = v_parsed->>'tag',
        gpsl_month = coalesce(v_fixture.gpsl_month, p_channel_month),
        discord_message_id = coalesce(v_msg, v.discord_message_id),
        discord_channel_id = coalesce(p_discord_channel_id, v.discord_channel_id),
        discord_attachment_id = coalesce(v_attach, v.discord_attachment_id),
        discord_user_id = coalesce(p_discord_user_id, v.discord_user_id),
        source = v_source,
        updated_at = now(),
        matched_at = now()
    WHERE v.id = v_existing.id
    RETURNING id INTO v_row_id;
  ELSE
    INSERT INTO public.fixture_match_videos (
      season_id, fixture_id, side, club_short_name, video_url,
      filename, tag, gpsl_month,
      discord_message_id, discord_channel_id, discord_attachment_id,
      discord_user_id, source
    ) VALUES (
      v_season_id, v_fixture_id, v_side, v_club, v_url,
      p_filename, v_parsed->>'tag', coalesce(v_fixture.gpsl_month, p_channel_month),
      v_msg, p_discord_channel_id, v_attach,
      p_discord_user_id, v_source
    )
    RETURNING id INTO v_row_id;
  END IF;

  -- Drop any pending hold for this side once matched
  DELETE FROM public.fixture_match_video_pending
  WHERE fixture_id = v_fixture_id AND side = v_side;

  IF NOT v_already_credited
     AND NOT EXISTS (
       SELECT 1
       FROM public.competition_finance_ledger l
       WHERE l.season_id = v_season_id
         AND l.fixture_id = v_fixture_id
         AND upper(l.club_short_name) = v_club
         AND l.entry_type = 'gate_match_video'
     )
  THEN
    PERFORM public.competition_credit_club_balance(v_club, v_amount);

    INSERT INTO public.competition_finance_ledger (
      season_id, fixture_id, club_short_name, entry_type, amount, description, metadata
    ) VALUES (
      v_season_id,
      v_fixture_id,
      v_club,
      'gate_match_video',
      v_amount,
      format(
        'Match video upload — vs %s [%s]',
        v_opp,
        coalesce(v_parsed->>'tag', '?')
      ),
      jsonb_build_object(
        'fixture_match_video_id', v_row_id,
        'side', v_side,
        'tag', v_parsed->>'tag',
        'filename', p_filename,
        'score_a', v_parsed->>'score_a',
        'score_b', v_parsed->>'score_b'
      )
    )
    RETURNING id INTO v_ledger_id;

    UPDATE public.fixture_match_videos
    SET credited_amount = v_amount,
        ledger_entry_id = v_ledger_id,
        updated_at = now()
    WHERE id = v_row_id;

    v_credited := v_amount;
  END IF;

  v_out := jsonb_build_object(
    'ok', true,
    'status', 'matched',
    'fixture_id', v_fixture_id,
    'side', v_side,
    'club', v_club,
    'url', v_url,
    'tag', v_parsed->>'tag',
    'credited', v_credited,
    'video_id', v_row_id
  );

  INSERT INTO public.fixture_match_video_ingest_log (
    season_id, discord_message_id, discord_channel_id, discord_attachment_id,
    discord_user_id, filename, channel_month, ok, reason, fixture_id, side,
    credited, result
  ) VALUES (
    v_season_id, v_msg, p_discord_channel_id, v_attach, p_discord_user_id,
    p_filename, p_channel_month, true, NULL, v_fixture_id, v_side,
    v_credited, v_out
  );

  RETURN v_out;
END;
$function$;

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
BEGIN
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
    ELSE
      v_fail := v_fail + 1;
    END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true,
    'fixture_id', p_fixture_id,
    'promoted', v_n,
    'failed', v_fail
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.match_video_promote_pending_for_fixture(bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.match_video_promote_pending_for_fixture(bigint)
  TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.trg_match_video_promote_on_played()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF NEW.status = 'played'
     AND OLD.status IS DISTINCT FROM 'played'
     AND NEW.home_goals IS NOT NULL
     AND NEW.away_goals IS NOT NULL
  THEN
    PERFORM public.match_video_promote_pending_for_fixture(NEW.id);
  END IF;
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS match_video_promote_on_played ON public.competition_fixtures;
CREATE TRIGGER match_video_promote_on_played
  AFTER UPDATE OF status, home_goals, away_goals ON public.competition_fixtures
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_match_video_promote_on_played();

CREATE OR REPLACE FUNCTION public.match_video_pending_sides(p_fixture_ids bigint[])
RETURNS TABLE (fixture_id bigint, side text, video_url text)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT p.fixture_id, p.side, p.video_url
  FROM public.fixture_match_video_pending p
  WHERE cardinality(coalesce(p_fixture_ids, '{}'::bigint[])) > 0
    AND p.fixture_id = ANY (p_fixture_ids);
$$;

REVOKE ALL ON FUNCTION public.match_video_pending_sides(bigint[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.match_video_pending_sides(bigint[]) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.match_video_promote_all_pending()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_id bigint;
  v_n int := 0;
  r jsonb;
BEGIN
  IF coalesce(auth.role(), '') <> 'service_role' AND NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  FOR v_id IN
    SELECT DISTINCT p.fixture_id
    FROM public.fixture_match_video_pending p
    JOIN public.competition_fixtures f ON f.id = p.fixture_id
    WHERE f.status = 'played'
  LOOP
    r := public.match_video_promote_pending_for_fixture(v_id);
    v_n := v_n + coalesce((r->>'promoted')::int, 0);
  END LOOP;

  RETURN jsonb_build_object('ok', true, 'promoted', v_n);
END;
$function$;

REVOKE ALL ON FUNCTION public.match_video_promote_all_pending() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.match_video_promote_all_pending() TO authenticated, service_role;

GRANT EXECUTE ON FUNCTION public.match_video_ingest_attachment(
  text, text, text, text, text, text, text, text, text
) TO service_role;

NOTIFY pgrst, 'reload schema';
