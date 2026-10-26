CREATE OR REPLACE FUNCTION public.match_video_ingest_attachment(p_discord_message_id text, p_discord_channel_id text, p_discord_attachment_id text, p_discord_user_id text, p_uploader_club text, p_filename text, p_video_url text, p_channel_month text DEFAULT NULL::text, p_source text DEFAULT 'discord'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
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
  IF coalesce(nullif(current_setting('gpsl.match_video_internal', true), ''), '') NOT IN ('1', 'true', 'on')
     AND coalesce(auth.role(), '') <> 'service_role'
     AND NOT public.is_gpsl_admin()
  THEN
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
      'URL not allowed 窶・use https YouTube, MEGA (mega.nz), or a Discord video attachment'
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
      -- If the GPSL result is already confirmed, clear the hold and continue
      -- matching below (promote used to bounce here forever).
      SELECT * INTO v_fixture
      FROM public.competition_fixtures f
      WHERE f.id = v_pend.fixture_id;
      IF FOUND
         AND v_fixture.status = 'played'
         AND v_fixture.home_goals IS NOT NULL
         AND v_fixture.away_goals IS NOT NULL
      THEN
        DELETE FROM public.fixture_match_video_pending WHERE id = v_pend.id;
      ELSE
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
      'Bad name 窶・use: [ARS 2-0 CHE [SL-MD5]](youtube-url) (spaces around - optional)'
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
        'Match video upload 窶・vs %s [%s]',
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

-- Promote holds that were stuck after result confirm
SELECT public.match_video_promote_all_pending() AS promote_all;

