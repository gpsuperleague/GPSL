-- =============================================================================
-- Match video uploads (Discord → fixtures → ₿200k Matchday revenue)
--
-- Filename:  HomeShort H-A AwayShort [COMP-REF].ext
-- Examples:  ARS 2-0 CHE [SL-MD5].mp4
--            LEE 1-1 NOR [CH-MD12].mkv
--            LIV 3-1 MCI [S8-QF].mp4
--
-- COMP: SL | CA | CB (league) · S8 | PL | SH | BO | LC (cups) · WC (later)
-- REF:  MD{n} (league) | R{n} | R16 | QF | SF | F / FINAL (cups)
--
-- Flow:
--   Discord bot MESSAGE_CREATE → edge discord-match-videos-ingest
--   → match_video_ingest_attachment → fixture_match_videos + gate_match_video
--
-- Credit: ₿200,000 once per club per fixture when THAT club's video matches.
-- Safe re-run.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Ledger entry type: gate_match_video
-- ---------------------------------------------------------------------------
DO $ledger_types$
DECLARE
  v_list text;
BEGIN
  SELECT string_agg(quote_literal(t), ', ' ORDER BY t)
  INTO v_list
  FROM (
    SELECT DISTINCT entry_type AS t
    FROM public.competition_finance_ledger
    WHERE entry_type IS NOT NULL
    UNION
    SELECT unnest(ARRAY[
      'gate_league_home',
      'gate_cup_share',
      'gate_friendlies',
      'gate_match_video',
      'eos_debt_interest',
      'eos_ffp_charge',
      'eos_balance_interest',
      'eos_injection'
    ])
  ) s;

  ALTER TABLE public.competition_finance_ledger
    DROP CONSTRAINT IF EXISTS competition_finance_ledger_entry_type_check;

  EXECUTE format(
    'ALTER TABLE public.competition_finance_ledger
       ADD CONSTRAINT competition_finance_ledger_entry_type_check
       CHECK (entry_type IN (%s))',
    v_list
  );
END;
$ledger_types$;

-- ---------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.fixture_match_videos (
  id bigserial PRIMARY KEY,
  season_id bigint NOT NULL REFERENCES public.competition_seasons(id),
  fixture_id bigint NOT NULL REFERENCES public.competition_fixtures(id) ON DELETE CASCADE,
  side text NOT NULL CHECK (side IN ('home', 'away')),
  club_short_name text NOT NULL,
  video_url text NOT NULL,
  filename text,
  tag text,
  gpsl_month text,
  discord_message_id text,
  discord_channel_id text,
  discord_attachment_id text,
  discord_user_id text,
  credited_amount numeric NOT NULL DEFAULT 0,
  ledger_entry_id bigint,
  source text NOT NULL DEFAULT 'discord'
    CHECK (source IN ('discord', 'admin', 'manual')),
  matched_at timestamptz NOT NULL DEFAULT now(),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT fixture_match_videos_fixture_side_uidx UNIQUE (fixture_id, side)
);

CREATE UNIQUE INDEX IF NOT EXISTS fixture_match_videos_attachment_uidx
  ON public.fixture_match_videos (discord_attachment_id)
  WHERE discord_attachment_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS fixture_match_videos_fixture_idx
  ON public.fixture_match_videos (fixture_id);

CREATE INDEX IF NOT EXISTS fixture_match_videos_season_matched_idx
  ON public.fixture_match_videos (season_id, matched_at DESC);

CREATE TABLE IF NOT EXISTS public.fixture_match_video_ingest_log (
  id bigserial PRIMARY KEY,
  season_id bigint,
  discord_message_id text,
  discord_channel_id text,
  discord_attachment_id text,
  discord_user_id text,
  filename text,
  channel_month text,
  ok boolean NOT NULL DEFAULT false,
  reason text,
  fixture_id bigint,
  side text,
  credited numeric,
  result jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS fixture_match_video_ingest_log_created_idx
  ON public.fixture_match_video_ingest_log (created_at DESC);

ALTER TABLE public.fixture_match_videos ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.fixture_match_video_ingest_log ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS fixture_match_videos_select ON public.fixture_match_videos;
CREATE POLICY fixture_match_videos_select
  ON public.fixture_match_videos
  FOR SELECT TO authenticated
  USING (true);

DROP POLICY IF EXISTS fixture_match_videos_admin_all ON public.fixture_match_videos;
CREATE POLICY fixture_match_videos_admin_all
  ON public.fixture_match_videos
  FOR ALL TO authenticated
  USING (public.is_gpsl_admin())
  WITH CHECK (public.is_gpsl_admin());

DROP POLICY IF EXISTS fixture_match_video_ingest_log_admin_select
  ON public.fixture_match_video_ingest_log;
CREATE POLICY fixture_match_video_ingest_log_admin_select
  ON public.fixture_match_video_ingest_log
  FOR SELECT TO authenticated
  USING (public.is_gpsl_admin());

GRANT SELECT ON public.fixture_match_videos TO authenticated;
GRANT SELECT ON public.fixture_match_video_ingest_log TO authenticated;
GRANT ALL ON public.fixture_match_videos TO service_role;
GRANT ALL ON public.fixture_match_video_ingest_log TO service_role;
GRANT USAGE, SELECT ON SEQUENCE public.fixture_match_videos_id_seq TO service_role;
GRANT USAGE, SELECT ON SEQUENCE public.fixture_match_video_ingest_log_id_seq TO service_role;

-- ---------------------------------------------------------------------------
-- Constants / helpers
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.match_video_payout_amount()
RETURNS numeric
LANGUAGE sql
IMMUTABLE
AS $$ SELECT 200000::numeric; $$;

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
  v_score_h int;
  v_score_a int;
BEGIN
  -- Strip path / URL query noise; keep basename without extension
  v_raw := regexp_replace(v_raw, '[?#].*$', '');
  v_raw := regexp_replace(v_raw, '^.*[\\/]', '');
  v_base := regexp_replace(v_raw, '\.[A-Za-z0-9]{1,8}$', '');
  v_base := replace(v_base, '_', ' ');
  v_base := regexp_replace(v_base, '[\u2013\u2014\u2212\u2010\u2011]', '-', 'g');
  v_base := regexp_replace(v_base, '\s+', ' ', 'g');
  v_base := btrim(v_base);

  -- Prefer: CLUB score - score CLUB [COMP-REF]
  v_m := regexp_match(
    v_base,
    '^([A-Za-z0-9]{2,8})\s+(\d{1,2})\s*-\s*(\d{1,2})\s+([A-Za-z0-9]{2,8})\s*\[([A-Za-z0-9]+)\s*-\s*([A-Za-z0-9]+)\]$'
  );
  IF v_m IS NOT NULL THEN
    v_club_a := upper(v_m[1]);
    v_score_h := v_m[2]::int;
    v_score_a := v_m[3]::int;
    v_club_b := upper(v_m[4]);
    v_comp := upper(v_m[5]);
    v_ref := upper(v_m[6]);
  ELSE
    -- Score optional: CLUB CLUB [COMP-REF] or CLUB vs CLUB [COMP-REF]
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

  IF v_club_a IS NULL OR v_club_b IS NULL OR v_club_a = v_club_b THEN
    RETURN NULL;
  END IF;
  IF v_comp IS NULL OR v_ref IS NULL THEN
    RETURN NULL;
  END IF;

  RETURN jsonb_build_object(
    'club_a', v_club_a,
    'club_b', v_club_b,
    'score_home', v_score_h,
    'score_away', v_score_a,
    'comp', v_comp,
    'ref', v_ref,
    'tag', v_comp || '-' || v_ref
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.match_video_map_comp(p_comp text)
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE
AS $function$
DECLARE
  v text := upper(btrim(coalesce(p_comp, '')));
BEGIN
  IF v IN ('SL', 'SUPERLEAGUE', 'SUPER') THEN
    RETURN jsonb_build_object('kind', 'league', 'division', 'superleague', 'comp', 'SL');
  END IF;
  IF v IN ('CA', 'CHA', 'CHAMPIONSHIP_A', 'CHAMPA') THEN
    RETURN jsonb_build_object('kind', 'league', 'division', 'championship_a', 'comp', 'CA');
  END IF;
  IF v IN ('CB', 'CHB', 'CHAMPIONSHIP_B', 'CHAMPB') THEN
    RETURN jsonb_build_object('kind', 'league', 'division', 'championship_b', 'comp', 'CB');
  END IF;
  IF v IN ('CH', 'CHAMPIONSHIP', 'CHAMP') THEN
    RETURN jsonb_build_object('kind', 'league', 'division', NULL, 'comp', 'CH');
  END IF;
  IF v IN ('S8', 'SUPER8') THEN
    RETURN jsonb_build_object('kind', 'cup', 'cup_code', 'super8', 'comp', 'S8');
  END IF;
  IF v IN ('PL', 'PLATE') THEN
    RETURN jsonb_build_object('kind', 'cup', 'cup_code', 'plate', 'comp', 'PL');
  END IF;
  IF v IN ('SH', 'SHIELD') THEN
    RETURN jsonb_build_object('kind', 'cup', 'cup_code', 'shield', 'comp', 'SH');
  END IF;
  IF v IN ('BO', 'BW', 'BOWL') THEN
    RETURN jsonb_build_object('kind', 'cup', 'cup_code', 'bowl', 'comp', 'BO');
  END IF;
  IF v IN ('LC', 'LEAGUECUP', 'LEAGUE_CUP', 'EFL') THEN
    RETURN jsonb_build_object('kind', 'cup', 'cup_code', 'league_cup', 'comp', 'LC');
  END IF;
  IF v IN ('WC', 'WORLDCUP', 'WORLD_CUP') THEN
    RETURN jsonb_build_object('kind', 'intl', 'comp', 'WC');
  END IF;
  RETURN NULL;
END;
$function$;

CREATE OR REPLACE FUNCTION public.match_video_ref_matchday(p_ref text)
RETURNS int
LANGUAGE plpgsql
IMMUTABLE
AS $function$
DECLARE
  v text := upper(btrim(coalesce(p_ref, '')));
  v_m text[];
BEGIN
  v_m := regexp_match(v, '^MD0*([0-9]{1,2})$');
  IF v_m IS NOT NULL THEN
    RETURN v_m[1]::int;
  END IF;
  v_m := regexp_match(v, '^M0*([0-9]{1,2})$');
  IF v_m IS NOT NULL THEN
    RETURN v_m[1]::int;
  END IF;
  RETURN NULL;
END;
$function$;

CREATE OR REPLACE FUNCTION public.match_video_ref_cup_aliases(p_ref text)
RETURNS text[]
LANGUAGE plpgsql
IMMUTABLE
AS $function$
DECLARE
  v text := upper(btrim(coalesce(p_ref, '')));
BEGIN
  IF v IN ('F', 'FINAL', 'FINALS') THEN
    RETURN ARRAY['final', 'f'];
  END IF;
  IF v IN ('SF', 'SEMI', 'SEMIS', 'SEMIFINAL') THEN
    RETURN ARRAY['sf', 'semi'];
  END IF;
  IF v IN ('QF', 'QUARTER', 'QUARTERS', 'QUARTERFINAL') THEN
    RETURN ARRAY['qf', 'quarter'];
  END IF;
  IF v IN ('R16', 'R016', 'LAST16', 'L16') THEN
    RETURN ARRAY['r16', 'last16', 'r2'];
  END IF;
  IF v IN ('R32', 'R032', 'LAST32', 'L32') THEN
    RETURN ARRAY['r32', 'last32', 'r1'];
  END IF;
  IF v ~ '^R0*[0-9]{1,2}$' THEN
    RETURN ARRAY[lower(regexp_replace(v, '^R0*', 'r'))];
  END IF;
  RETURN ARRAY[lower(v)];
END;
$function$;

CREATE OR REPLACE FUNCTION public.match_video_find_fixture(
  p_season_id bigint,
  p_parsed jsonb,
  p_channel_month text DEFAULT NULL
)
RETURNS bigint
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club_a text := upper(p_parsed->>'club_a');
  v_club_b text := upper(p_parsed->>'club_b');
  v_comp_map jsonb;
  v_kind text;
  v_division text;
  v_cup_code text;
  v_md int;
  v_ref text := upper(p_parsed->>'ref');
  v_aliases text[];
  v_id bigint;
  v_month text := lower(nullif(btrim(coalesce(p_channel_month, '')), ''));
BEGIN
  v_comp_map := public.match_video_map_comp(p_parsed->>'comp');
  IF v_comp_map IS NULL THEN
    RETURN NULL;
  END IF;

  v_kind := v_comp_map->>'kind';
  v_division := nullif(v_comp_map->>'division', '');
  v_cup_code := nullif(v_comp_map->>'cup_code', '');

  IF v_kind = 'league' THEN
    v_md := public.match_video_ref_matchday(v_ref);
    IF v_md IS NULL THEN
      RETURN NULL;
    END IF;

    SELECT f.id INTO v_id
    FROM public.competition_fixtures f
    WHERE f.season_id = p_season_id
      AND f.competition_type = 'league'
      AND f.matchday = v_md
      AND (
        (upper(f.home_club_short_name) = v_club_a AND upper(f.away_club_short_name) = v_club_b)
        OR (upper(f.home_club_short_name) = v_club_b AND upper(f.away_club_short_name) = v_club_a)
      )
      AND (v_division IS NULL OR f.division = v_division)
      AND (
        v_month IS NULL
        OR lower(btrim(coalesce(f.gpsl_month, ''))) = v_month
      )
    ORDER BY
      CASE WHEN lower(btrim(coalesce(f.gpsl_month, ''))) = v_month THEN 0 ELSE 1 END,
      f.id
    LIMIT 1;

    RETURN v_id;
  END IF;

  -- Cups
  v_aliases := public.match_video_ref_cup_aliases(v_ref);
  v_md := public.match_video_ref_matchday(v_ref); -- unlikely, but allow R{n} via aliases

  SELECT f.id INTO v_id
  FROM public.competition_fixtures f
  WHERE f.season_id = p_season_id
    AND f.competition_type = 'cup'
    AND lower(coalesce(f.cup_code, '')) = lower(v_cup_code)
    AND (
      (upper(f.home_club_short_name) = v_club_a AND upper(f.away_club_short_name) = v_club_b)
      OR (upper(f.home_club_short_name) = v_club_b AND upper(f.away_club_short_name) = v_club_a)
    )
    AND (
      -- Match by stage alias from schedule
      EXISTS (
        SELECT 1
        FROM public.competition_cup_round_schedule s
        WHERE s.cup_code = f.cup_code
          AND s.round_no = f.cup_round
          AND (
            lower(coalesce(s.stage, '')) = ANY (v_aliases)
            OR lower(regexp_replace(coalesce(s.round_label, ''), '[^a-z0-9]+', '', 'g'))
                 = ANY (
                   SELECT lower(regexp_replace(a, '[^a-z0-9]+', '', 'g'))
                   FROM unnest(v_aliases) a
                 )
          )
      )
      OR (
        v_ref ~ '^R0*[0-9]{1,2}$'
        AND f.cup_round = (regexp_match(v_ref, '^R0*([0-9]{1,2})$'))[1]::int
      )
      OR (
        -- Fallback: stage from competition_cup_round_stage
        lower(public.competition_cup_round_stage(
          f.cup_code,
          f.cup_round,
          (
            SELECT max(x.cup_round)::int
            FROM public.competition_fixtures x
            WHERE x.season_id = f.season_id AND x.cup_code = f.cup_code
          )
        )) = ANY (v_aliases)
      )
    )
    AND (
      v_month IS NULL
      OR lower(btrim(coalesce(f.gpsl_month, ''))) = v_month
    )
  ORDER BY
    CASE WHEN lower(btrim(coalesce(f.gpsl_month, ''))) = v_month THEN 0 ELSE 1 END,
    f.id
  LIMIT 1;

  RETURN v_id;
END;
$function$;

-- ---------------------------------------------------------------------------
-- Ingest one Discord attachment (service_role / admin)
-- ---------------------------------------------------------------------------
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

  -- Idempotent on attachment id
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
      'Bad filename — use: Home 2-0 Away [SL-MD5].mp4 (or [S8-QF] for cups)'
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
    -- Retry without month filter (catch-up posted in later channel)
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
        'Match video upload — vs %s [%s]',
        v_opp,
        coalesce(v_parsed->>'tag', '?')
      ),
      jsonb_build_object(
        'fixture_match_video_id', v_row_id,
        'side', v_side,
        'tag', v_parsed->>'tag',
        'filename', p_filename
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

REVOKE ALL ON FUNCTION public.match_video_ingest_attachment(
  text, text, text, text, text, text, text, text, text
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.match_video_ingest_attachment(
  text, text, text, text, text, text, text, text, text
) TO service_role;
GRANT EXECUTE ON FUNCTION public.match_video_ingest_attachment(
  text, text, text, text, text, text, text, text, text
) TO authenticated;

-- ---------------------------------------------------------------------------
-- Admin manual link (mistyped Discord names)
-- ---------------------------------------------------------------------------
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

REVOKE ALL ON FUNCTION public.match_video_admin_link(bigint, text, text, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.match_video_admin_link(bigint, text, text, boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.match_video_admin_link(bigint, text, text, boolean) TO service_role;

-- Recent ingest for admin UI
CREATE OR REPLACE FUNCTION public.match_video_admin_recent(p_limit int DEFAULT 50)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_rows jsonb;
BEGIN
  IF NOT public.is_gpsl_admin()
     AND coalesce(auth.role(), '') <> 'service_role' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'admin_only');
  END IF;

  SELECT coalesce(jsonb_agg(to_jsonb(q) ORDER BY q.created_at DESC), '[]'::jsonb)
  INTO v_rows
  FROM (
    SELECT
      l.id,
      l.created_at,
      l.ok,
      l.reason,
      l.filename,
      l.channel_month,
      l.fixture_id,
      l.side,
      l.credited,
      l.discord_message_id,
      l.discord_user_id
    FROM public.fixture_match_video_ingest_log l
    ORDER BY l.created_at DESC
    LIMIT greatest(1, least(coalesce(p_limit, 50), 200))
  ) q;

  RETURN jsonb_build_object('ok', true, 'rows', v_rows);
END;
$function$;

REVOKE ALL ON FUNCTION public.match_video_admin_recent(int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.match_video_admin_recent(int) TO authenticated;
GRANT EXECUTE ON FUNCTION public.match_video_admin_recent(int) TO service_role;

NOTIFY pgrst, 'reload schema';
