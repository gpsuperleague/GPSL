-- =============================================================================
-- Match videos 窶・flexible score parsing + verify vs confirmed fixture result
--
-- Accepts labels like:
--   ARS 3-4 CHE [SL-MD5]
--   ARS 3 - 4 CHE [SL-MD5]
--   ARS 3 CHE 4 [SL-MD5]
--   ARS3-4CHE [SL-MD5]   (tight spacing)
--
-- Score is required and must match the played fixture (order-aware).
-- Run after match_video_uploads_20260912.sql. Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.match_video_parse_filename(p_filename text)
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE
AS $function$
DECLARE
  v_raw text := btrim(coalesce(p_filename, ''));
  v_base text;
  v_m text[];
  v_club_a text;
  v_club_b text;
  v_comp text;
  v_ref text;
  v_score_a int;
  v_score_b int;
BEGIN
  -- Strip path / URL / extension; normalise dashes & spaces
  v_raw := regexp_replace(v_raw, '[?#].*$', '');
  v_raw := regexp_replace(v_raw, '^.*[\\/]', '');
  v_base := regexp_replace(v_raw, '\.[A-Za-z0-9]{1,8}$', '');
  v_base := replace(v_base, '_', ' ');
  v_base := regexp_replace(v_base, '[\u2013\u2014\u2212\u2010\u2011]', '-', 'g');
  v_base := regexp_replace(v_base, '\s+', ' ', 'g');
  v_base := btrim(v_base);

  -- A) CLUB score - score CLUB [COMP-REF]  (spaces optional around - and clubs)
  v_m := regexp_match(
    v_base,
    '^([A-Za-z0-9]{2,8})\s*(\d{1,2})\s*-\s*(\d{1,2})\s*([A-Za-z0-9]{2,8})\s*\[([A-Za-z0-9]+)\s*-\s*([A-Za-z0-9]+)\]$'
  );
  IF v_m IS NOT NULL THEN
    v_club_a := upper(v_m[1]);
    v_score_a := v_m[2]::int;
    v_score_b := v_m[3]::int;
    v_club_b := upper(v_m[4]);
    v_comp := upper(v_m[5]);
    v_ref := upper(v_m[6]);
  ELSE
    -- B) CLUB score CLUB score [COMP-REF]  e.g. ARS 3 CHE 4 [SL-MD5]
    v_m := regexp_match(
      v_base,
      '^([A-Za-z0-9]{2,8})\s+(\d{1,2})\s+([A-Za-z0-9]{2,8})\s+(\d{1,2})\s*\[([A-Za-z0-9]+)\s*-\s*([A-Za-z0-9]+)\]$'
    );
    IF v_m IS NOT NULL THEN
      v_club_a := upper(v_m[1]);
      v_score_a := v_m[2]::int;
      v_club_b := upper(v_m[3]);
      v_score_b := v_m[4]::int;
      v_comp := upper(v_m[5]);
      v_ref := upper(v_m[6]);
    ELSE
      -- C) Score optional (rejected later by verify): CLUB CLUB [TAG] / CLUB vs CLUB [TAG]
      v_m := regexp_match(
        v_base,
        '^([A-Za-z0-9]{2,8})\s+(?:vs\.?\s+)?([A-Za-z0-9]{2,8})\s*\[([A-Za-z0-9]+)\s*-\s*([A-Za-z0-9]+)\]$'
      );
      IF v_m IS NULL THEN
        RETURN NULL;
      END IF;
      v_club_a := upper(v_m[1]);
      v_club_b := upper(v_m[2]);
      v_comp := upper(v_m[3]);
      v_ref := upper(v_m[4]);
    END IF;
  END IF;

  IF v_club_a IS NULL OR v_club_b IS NULL OR v_club_a = v_club_b THEN
    RETURN NULL;
  END IF;
  IF v_comp IS NULL OR v_ref IS NULL THEN
    RETURN NULL;
  END IF;

  RETURN jsonb_build_object(
    'club_a', v_club_a,
    'club_b', v_club_b,
    'score_a', v_score_a,
    'score_b', v_score_b,
    -- legacy aliases (score for first/second club in the label)
    'score_home', v_score_a,
    'score_away', v_score_b,
    'comp', v_comp,
    'ref', v_ref,
    'tag', v_comp || '-' || v_ref
  );
END;
$function$;

-- True when label scores match fixture result (club-order aware)
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
      'reason', 'Score missing 窶・include it in the name, e.g. ARS 2-0 CHE [SL-MD5]'
    );
  END IF;

  v_sa := coalesce((p_parsed->>'score_a')::int, (p_parsed->>'score_home')::int);
  v_sb := coalesce((p_parsed->>'score_b')::int, (p_parsed->>'score_away')::int);

  IF v_sa IS NULL OR v_sb IS NULL THEN
    RETURN jsonb_build_object(
      'ok', false,
      'reason', 'Score missing 窶・include it in the name, e.g. ARS 2-0 CHE [SL-MD5]'
    );
  END IF;

  IF p_fixture.status IS DISTINCT FROM 'played'
     OR v_hg IS NULL
     OR v_ag IS NULL
  THEN
    RETURN jsonb_build_object(
      'ok', false,
      'reason', 'Fixture result not confirmed yet 窶・post the video after the result is in'
    );
  END IF;

  IF v_club_a = v_home AND v_club_b = v_away THEN
    IF v_sa = v_hg AND v_sb = v_ag THEN
      RETURN jsonb_build_object('ok', true);
    END IF;
    RETURN jsonb_build_object(
      'ok', false,
      'reason', format(
        'Score mismatch 窶・label %s-%s but result is %s-%s',
        v_sa, v_sb, v_hg, v_ag
      )
    );
  END IF;

  IF v_club_a = v_away AND v_club_b = v_home THEN
    -- Label wrote away club first: their goals are score_a
    IF v_sa = v_ag AND v_sb = v_hg THEN
      RETURN jsonb_build_object('ok', true);
    END IF;
    RETURN jsonb_build_object(
      'ok', false,
      'reason', format(
        'Score mismatch 窶・label %s-%s (away listed first) but result is %s-%s',
        v_sa, v_sb, v_hg, v_ag
      )
    );
  END IF;

  RETURN jsonb_build_object(
    'ok', false,
    'reason', 'Clubs in label do not match fixture home/away'
  );
END;
$function$;

-- Patch ingest: after loading fixture, verify score before writing video row
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
  v_club text := upper(nullif(btrim(coalesce(p_uploader_club, '')), ''));
  v_side text;
  v_opp text;
  v_amount numeric := public.match_video_payout_amount();
  v_existing public.fixture_match_videos%ROWTYPE;
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

  IF v_club IS NULL THEN
    v_out := jsonb_build_object(
      'ok', false,
      'reason', 'Could not map Discord user to a GPSL club'
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

  -- Division / cup COMP must match the fixture
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

  v_score_check := public.match_video_scores_match_fixture(v_fixture, v_parsed);
  IF coalesce((v_score_check->>'ok')::boolean, false) IS NOT TRUE THEN
    v_out := jsonb_build_object(
      'ok', false,
      'reason', coalesce(v_score_check->>'reason', 'Score check failed'),
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

NOTIFY pgrst, 'reload schema';
