-- =============================================================================
-- Match videos — poster = GPSL owner + URL allowlist
--
-- Poster:
--   1) gpsl_owner_registry.discord_user_id → Clubs.owner_id (authoritative)
--   2) else Discord nick / owner tag match (fallback)
--   3) uploader must be home or away; score + COMP already verified elsewhere
--
-- URL:
--   https YouTube (youtube.com / youtu.be / youtube-nocookie) or Discord CDN only
--
-- Run AFTER match_video_score_verify_20260912.sql (re-run that patch too —
-- it now embeds the same helpers + ingest). Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.match_video_url_allowed(p_url text)
RETURNS boolean
LANGUAGE plpgsql
IMMUTABLE
AS $function$
DECLARE
  v text := btrim(coalesce(p_url, ''));
  v_host text;
BEGIN
  IF v = '' OR length(v) > 2000 THEN
    RETURN false;
  END IF;
  IF v !~* '^https://' THEN
    RETURN false;
  END IF;
  IF v ~ '[[:space:]]' OR position('@' in v) > 0 THEN
    RETURN false;
  END IF;

  v_host := lower(substring(v from '^https://([^/?:#]+)'));
  IF v_host IS NULL OR v_host = '' THEN
    RETURN false;
  END IF;
  IF left(v_host, 4) = 'www.' THEN
    v_host := substring(v_host from 5);
  END IF;

  IF v_host IN (
    'youtube.com',
    'm.youtube.com',
    'youtu.be',
    'youtube-nocookie.com'
  ) THEN
    RETURN true;
  END IF;

  IF v_host IN (
    'cdn.discordapp.com',
    'media.discordapp.net'
  ) THEN
    RETURN true;
  END IF;

  RETURN false;
END;
$function$;

CREATE OR REPLACE FUNCTION public.match_video_resolve_uploader_club(
  p_discord_user_id text,
  p_claimed_club text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_discord text := nullif(btrim(coalesce(p_discord_user_id, '')), '');
  v_claimed text := upper(nullif(btrim(coalesce(p_claimed_club, '')), ''));
  v_club text;
BEGIN
  IF v_discord IS NOT NULL
     AND to_regclass('public.gpsl_owner_registry') IS NOT NULL THEN
    SELECT upper(btrim(c."ShortName")) INTO v_club
    FROM public.gpsl_owner_registry r
    JOIN public."Clubs" c ON c.owner_id = r.owner_id
    WHERE r.discord_user_id = v_discord
      AND c.owner_id IS NOT NULL
      AND nullif(btrim(c."ShortName"), '') IS NOT NULL
    LIMIT 1;

    IF v_club IS NOT NULL THEN
      IF v_claimed IS NOT NULL AND v_claimed IS DISTINCT FROM v_club THEN
        RETURN jsonb_build_object(
          'ok', false,
          'reason', format(
            'Discord account is the GPSL owner of %s, not %s',
            v_club, v_claimed
          )
        );
      END IF;
      RETURN jsonb_build_object('ok', true, 'club', v_club, 'via', 'discord_id');
    END IF;
  END IF;

  IF v_claimed IS NOT NULL THEN
    RETURN jsonb_build_object('ok', true, 'club', v_claimed, 'via', 'owner_tag');
  END IF;

  RETURN jsonb_build_object(
    'ok', false,
    'reason',
    'Could not map Discord user to a GPSL club owner (link Discord ID or match owner tag)'
  );
END;
$function$;

-- Admin manual link: same URL allowlist
CREATE OR REPLACE FUNCTION public.match_video_admin_link(
  p_fixture_id bigint,
  p_side text,
  p_video_url text,
  p_credit boolean DEFAULT true
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_fixture public.competition_fixtures%ROWTYPE;
  v_side text := lower(btrim(coalesce(p_side, '')));
  v_club text;
  v_opp text;
  v_url text := nullif(btrim(coalesce(p_video_url, '')), '');
  v_amount numeric := public.match_video_payout_amount();
  v_existing public.fixture_match_videos%ROWTYPE;
  v_row_id bigint;
  v_ledger_id bigint;
  v_credited numeric := 0;
  v_filename text;
BEGIN
  IF NOT public.is_gpsl_admin()
     AND coalesce(auth.role(), '') <> 'service_role' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'admin_only');
  END IF;

  IF v_side NOT IN ('home', 'away') THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'side must be home or away');
  END IF;
  IF v_url IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'missing_url');
  END IF;
  IF NOT public.match_video_url_allowed(v_url) THEN
    RETURN jsonb_build_object(
      'ok', false,
      'reason',
      'URL not allowed — use https YouTube (youtu.be / youtube.com) or Discord CDN'
    );
  END IF;

  SELECT * INTO v_fixture
  FROM public.competition_fixtures f
  WHERE f.id = p_fixture_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'fixture_not_found');
  END IF;

  IF v_side = 'home' THEN
    v_club := upper(v_fixture.home_club_short_name);
    v_opp := v_fixture.away_club_short_name;
  ELSE
    v_club := upper(v_fixture.away_club_short_name);
    v_opp := v_fixture.home_club_short_name;
  END IF;

  v_filename := format(
    'admin-link %s vs %s',
    v_fixture.home_club_short_name,
    v_fixture.away_club_short_name
  );

  SELECT * INTO v_existing
  FROM public.fixture_match_videos v
  WHERE v.fixture_id = p_fixture_id AND v.side = v_side;

  IF FOUND THEN
    UPDATE public.fixture_match_videos
    SET video_url = v_url,
        filename = v_filename,
        source = 'admin',
        updated_at = now(),
        matched_at = now()
    WHERE id = v_existing.id
    RETURNING id INTO v_row_id;

    IF coalesce(v_existing.credited_amount, 0) > 0 THEN
      p_credit := false;
    END IF;
  ELSE
    INSERT INTO public.fixture_match_videos (
      season_id, fixture_id, side, club_short_name, video_url,
      filename, gpsl_month, source
    ) VALUES (
      v_fixture.season_id, p_fixture_id, v_side, v_club, v_url,
      v_filename, v_fixture.gpsl_month, 'admin'
    )
    RETURNING id INTO v_row_id;
  END IF;

  IF p_credit
     AND NOT EXISTS (
       SELECT 1
       FROM public.competition_finance_ledger l
       WHERE l.season_id = v_fixture.season_id
         AND l.fixture_id = p_fixture_id
         AND upper(l.club_short_name) = v_club
         AND l.entry_type = 'gate_match_video'
     )
  THEN
    PERFORM public.competition_credit_club_balance(v_club, v_amount);

    INSERT INTO public.competition_finance_ledger (
      season_id, fixture_id, club_short_name, entry_type, amount, description, metadata
    ) VALUES (
      v_fixture.season_id,
      p_fixture_id,
      v_club,
      'gate_match_video',
      v_amount,
      format('Match video upload — vs %s (admin link)', v_opp),
      jsonb_build_object(
        'fixture_match_video_id', v_row_id,
        'side', v_side,
        'source', 'admin'
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

  RETURN jsonb_build_object(
    'ok', true,
    'fixture_id', p_fixture_id,
    'side', v_side,
    'club', v_club,
    'url', v_url,
    'credited', v_credited,
    'video_id', v_row_id
  );
END;
$function$;

COMMENT ON FUNCTION public.match_video_url_allowed(text) IS
  'Match videos: only https YouTube or Discord CDN URLs.';
COMMENT ON FUNCTION public.match_video_resolve_uploader_club(text, text) IS
  'Match videos: Discord snowflake → owner club, else claimed owner-tag club.';

NOTIFY pgrst, 'reload schema';
