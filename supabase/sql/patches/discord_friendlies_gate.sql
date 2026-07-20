-- =============================================================================
-- Discord friendlies → GPSL gate receipts (small incentive)
--
-- Format (exact):  club score - score club
-- Example:         JUB 2 - 2 BEN
--
-- Flow:
--   1) Owner posts scoreline in #gpsl-friendlies
--   2) Opponent posts the matching result (same clubs + scores; order may flip)
--   3) Edge function discord-friendlies-ingest → this RPC
--   4) Both clubs get ₿5,000 (if under monthly/season caps)
--
-- Caps (per club):
--   • ₿5,000 per confirmed friendly
--   • Max 10 paid friendlies per GPSL month
--   • Max ₿500,000 season total from friendlies
--
-- Setup:
--   1) Run this patch in Supabase SQL Editor
--   2) Edge secrets: DISCORD_BOT_TOKEN, DISCORD_GUILD_ID,
--      DISCORD_FRIENDLIES_CHANNEL_ID, DISCORD_FRIENDLIES_INVOKE_KEY (optional)
--   3) Deploy: supabase functions deploy discord-friendlies-ingest
--   4) Cron (every 1–2 min) OR Admin → Discord Friendlies → Poll now
--
-- Safe re-run.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Ledger entry type: gate_friendlies
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
CREATE TABLE IF NOT EXISTS public.gpsl_friendly_reports (
  id bigserial PRIMARY KEY,
  season_id bigint NOT NULL REFERENCES public.competition_seasons(id),
  gpsl_month text NOT NULL,
  discord_message_id text NOT NULL,
  discord_user_id text,
  reporter_club_short_name text NOT NULL,
  club_left text NOT NULL,
  score_left int NOT NULL CHECK (score_left >= 0 AND score_left <= 99),
  club_right text NOT NULL,
  score_right int NOT NULL CHECK (score_right >= 0 AND score_right <= 99),
  canon_club_a text NOT NULL,
  canon_score_a int NOT NULL,
  canon_club_b text NOT NULL,
  canon_score_b int NOT NULL,
  status text NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending', 'matched', 'ignored', 'expired')),
  matched_friendly_id bigint,
  note text,
  posted_at timestamptz NOT NULL DEFAULT now(),
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT gpsl_friendly_reports_clubs_diff CHECK (
    upper(btrim(club_left)) <> upper(btrim(club_right))
  )
);

CREATE UNIQUE INDEX IF NOT EXISTS gpsl_friendly_reports_discord_msg_uidx
  ON public.gpsl_friendly_reports (discord_message_id);

CREATE INDEX IF NOT EXISTS gpsl_friendly_reports_pending_match_idx
  ON public.gpsl_friendly_reports (
    season_id, gpsl_month, canon_club_a, canon_club_b,
    canon_score_a, canon_score_b, status
  )
  WHERE status = 'pending';

CREATE TABLE IF NOT EXISTS public.gpsl_friendlies (
  id bigserial PRIMARY KEY,
  season_id bigint NOT NULL REFERENCES public.competition_seasons(id),
  gpsl_month text NOT NULL,
  club_left text NOT NULL,
  score_left int NOT NULL,
  club_right text NOT NULL,
  score_right int NOT NULL,
  report_1_id bigint NOT NULL REFERENCES public.gpsl_friendly_reports(id),
  report_2_id bigint NOT NULL REFERENCES public.gpsl_friendly_reports(id),
  paid_left numeric NOT NULL DEFAULT 0,
  paid_right numeric NOT NULL DEFAULT 0,
  left_skipped_reason text,
  right_skipped_reason text,
  confirmed_at timestamptz NOT NULL DEFAULT now(),
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS gpsl_friendlies_season_month_idx
  ON public.gpsl_friendlies (season_id, gpsl_month, confirmed_at DESC);

ALTER TABLE public.gpsl_friendly_reports
  DROP CONSTRAINT IF EXISTS gpsl_friendly_reports_matched_fk;
ALTER TABLE public.gpsl_friendly_reports
  ADD CONSTRAINT gpsl_friendly_reports_matched_fk
  FOREIGN KEY (matched_friendly_id) REFERENCES public.gpsl_friendlies(id);

ALTER TABLE public.gpsl_friendly_reports ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.gpsl_friendlies ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS gpsl_friendly_reports_admin_select ON public.gpsl_friendly_reports;
CREATE POLICY gpsl_friendly_reports_admin_select
  ON public.gpsl_friendly_reports
  FOR SELECT TO authenticated
  USING (public.is_gpsl_admin());

DROP POLICY IF EXISTS gpsl_friendlies_admin_select ON public.gpsl_friendlies;
CREATE POLICY gpsl_friendlies_admin_select
  ON public.gpsl_friendlies
  FOR SELECT TO authenticated
  USING (public.is_gpsl_admin());

DROP POLICY IF EXISTS gpsl_friendlies_owner_select ON public.gpsl_friendlies;
CREATE POLICY gpsl_friendlies_owner_select
  ON public.gpsl_friendlies
  FOR SELECT TO authenticated
  USING (
    upper(club_left) = upper(coalesce(public.my_club_shortname(), ''))
    OR upper(club_right) = upper(coalesce(public.my_club_shortname(), ''))
  );

GRANT SELECT ON public.gpsl_friendly_reports TO authenticated;
GRANT SELECT ON public.gpsl_friendlies TO authenticated;
GRANT ALL ON public.gpsl_friendly_reports TO service_role;
GRANT ALL ON public.gpsl_friendlies TO service_role;
GRANT USAGE, SELECT ON SEQUENCE public.gpsl_friendly_reports_id_seq TO service_role;
GRANT USAGE, SELECT ON SEQUENCE public.gpsl_friendlies_id_seq TO service_role;

-- ---------------------------------------------------------------------------
-- Constants / helpers
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.gpsl_friendlies_payout_amount()
RETURNS numeric
LANGUAGE sql
IMMUTABLE
AS $$ SELECT 5000::numeric; $$;

CREATE OR REPLACE FUNCTION public.gpsl_friendlies_month_cap()
RETURNS int
LANGUAGE sql
IMMUTABLE
AS $$ SELECT 10; $$;

CREATE OR REPLACE FUNCTION public.gpsl_friendlies_season_cap()
RETURNS numeric
LANGUAGE sql
IMMUTABLE
AS $$ SELECT 500000::numeric; $$;

CREATE OR REPLACE FUNCTION public.gpsl_friendlies_pending_hours()
RETURNS int
LANGUAGE sql
IMMUTABLE
AS $$ SELECT 48; $$;

CREATE OR REPLACE FUNCTION public.gpsl_friendlies_parse_scoreline(p_content text)
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE
AS $function$
DECLARE
  v_raw text := btrim(coalesce(p_content, ''));
  v_club_l text;
  v_club_r text;
  v_score_l int;
  v_score_r int;
BEGIN
  -- Allow optional surrounding whitespace; reject extra text.
  IF v_raw !~* '^[A-Z0-9]{2,8}\s+\d{1,2}\s*-\s*\d{1,2}\s+[A-Z0-9]{2,8}$' THEN
    RETURN NULL;
  END IF;

  v_club_l := upper(btrim((regexp_match(v_raw, '^([A-Za-z0-9]{2,8})'))[1]));
  v_score_l := ((regexp_match(v_raw, '^[A-Za-z0-9]{2,8}\s+(\d{1,2})'))[1])::int;
  v_score_r := ((regexp_match(v_raw, '-\s*(\d{1,2})\s+[A-Za-z0-9]{2,8}$'))[1])::int;
  v_club_r := upper(btrim((regexp_match(v_raw, '([A-Za-z0-9]{2,8})$'))[1]));

  IF v_club_l IS NULL OR v_club_r IS NULL OR v_club_l = v_club_r THEN
    RETURN NULL;
  END IF;

  RETURN jsonb_build_object(
    'club_left', v_club_l,
    'score_left', v_score_l,
    'club_right', v_club_r,
    'score_right', v_score_r
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.gpsl_friendlies_canonical(
  p_club_left text,
  p_score_left int,
  p_club_right text,
  p_score_right int
)
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE
AS $function$
DECLARE
  v_l text := upper(btrim(coalesce(p_club_left, '')));
  v_r text := upper(btrim(coalesce(p_club_right, '')));
BEGIN
  IF v_l < v_r THEN
    RETURN jsonb_build_object(
      'canon_club_a', v_l,
      'canon_score_a', p_score_left,
      'canon_club_b', v_r,
      'canon_score_b', p_score_right
    );
  END IF;
  RETURN jsonb_build_object(
    'canon_club_a', v_r,
    'canon_score_a', p_score_right,
    'canon_club_b', v_l,
    'canon_score_b', p_score_left
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.gpsl_friendlies_live_season_id()
RETURNS bigint
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT id
  FROM public.competition_seasons
  WHERE is_current = true
    AND status = 'active'
  ORDER BY id DESC
  LIMIT 1;
$$;

CREATE OR REPLACE FUNCTION public.gpsl_friendlies_month_paid_count(
  p_season_id bigint,
  p_gpsl_month text,
  p_club text
)
RETURNS int
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT count(*)::int
  FROM public.gpsl_friendlies f
  WHERE f.season_id = p_season_id
    AND f.gpsl_month = p_gpsl_month
    AND (
      (upper(f.club_left) = upper(p_club) AND f.paid_left > 0)
      OR (upper(f.club_right) = upper(p_club) AND f.paid_right > 0)
    );
$$;

CREATE OR REPLACE FUNCTION public.gpsl_friendlies_season_paid_total(
  p_season_id bigint,
  p_club text
)
RETURNS numeric
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT coalesce(sum(l.amount), 0)::numeric
  FROM public.competition_finance_ledger l
  WHERE l.season_id = p_season_id
    AND upper(l.club_short_name) = upper(p_club)
    AND l.entry_type = 'gate_friendlies';
$$;

CREATE OR REPLACE FUNCTION public.gpsl_friendlies_pay_club(
  p_season_id bigint,
  p_gpsl_month text,
  p_club text,
  p_friendly_id bigint,
  p_scoreline text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_amount numeric := public.gpsl_friendlies_payout_amount();
  v_month_cap int := public.gpsl_friendlies_month_cap();
  v_season_cap numeric := public.gpsl_friendlies_season_cap();
  v_month_count int;
  v_season_total numeric;
  v_desc text;
BEGIN
  v_month_count := public.gpsl_friendlies_month_paid_count(
    p_season_id, p_gpsl_month, p_club
  );
  IF v_month_count >= v_month_cap THEN
    RETURN jsonb_build_object(
      'paid', 0,
      'skipped', format('Month cap reached (%s friendlies)', v_month_cap)
    );
  END IF;

  v_season_total := public.gpsl_friendlies_season_paid_total(p_season_id, p_club);
  IF v_season_total + v_amount > v_season_cap THEN
    RETURN jsonb_build_object(
      'paid', 0,
      'skipped', format('Season cap reached (₿%s)', to_char(v_season_cap, 'FM999,999,999'))
    );
  END IF;

  v_desc := format(
    'Friendly gate — %s · %s',
    p_scoreline,
    public.competition_gpsl_month_label(p_gpsl_month)
  );

  PERFORM public.competition_credit_club_balance(p_club, v_amount);

  INSERT INTO public.competition_finance_ledger (
    season_id, club_short_name, entry_type, amount, description, metadata
  )
  VALUES (
    p_season_id,
    p_club,
    'gate_friendlies',
    v_amount,
    v_desc,
    jsonb_build_object(
      'friendly_id', p_friendly_id,
      'gpsl_month', p_gpsl_month,
      'scoreline', p_scoreline
    )
  );

  RETURN jsonb_build_object('paid', v_amount, 'skipped', NULL);
END;
$function$;

-- ---------------------------------------------------------------------------
-- Ingest one Discord post (service_role / admin)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.gpsl_friendlies_ingest_post(
  p_discord_message_id text,
  p_discord_user_id text,
  p_reporter_club text,
  p_content text,
  p_posted_at timestamptz DEFAULT now()
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_msg_id text := nullif(btrim(coalesce(p_discord_message_id, '')), '');
  v_club text := upper(nullif(btrim(coalesce(p_reporter_club, '')), ''));
  v_parsed jsonb;
  v_canon jsonb;
  v_season_id bigint;
  v_month text;
  v_club_l text;
  v_club_r text;
  v_score_l int;
  v_score_r int;
  v_canon_a text;
  v_canon_b text;
  v_score_a int;
  v_score_b int;
  v_report public.gpsl_friendly_reports%ROWTYPE;
  v_match public.gpsl_friendly_reports%ROWTYPE;
  v_friendly_id bigint;
  v_scoreline text;
  v_pay_l jsonb;
  v_pay_r jsonb;
  v_exists boolean;
BEGIN
  IF coalesce(auth.role(), '') <> 'service_role' AND NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Not allowed';
  END IF;

  IF v_msg_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'status', 'ignored', 'reason', 'Missing Discord message id');
  END IF;

  SELECT EXISTS (
    SELECT 1 FROM public.gpsl_friendly_reports r WHERE r.discord_message_id = v_msg_id
  ) INTO v_exists;
  IF v_exists THEN
    RETURN jsonb_build_object('ok', true, 'status', 'duplicate', 'reason', 'Already ingested');
  END IF;

  IF v_club IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'status', 'ignored', 'reason', 'Could not map Discord user to a GPSL club');
  END IF;

  v_parsed := public.gpsl_friendlies_parse_scoreline(p_content);
  IF v_parsed IS NULL THEN
    RETURN jsonb_build_object(
      'ok', false,
      'status', 'ignored',
      'reason', 'Bad format — use: CLUB score - score CLUB (e.g. JUB 2 - 2 BEN)'
    );
  END IF;

  v_club_l := v_parsed ->> 'club_left';
  v_club_r := v_parsed ->> 'club_right';
  v_score_l := (v_parsed ->> 'score_left')::int;
  v_score_r := (v_parsed ->> 'score_right')::int;

  IF NOT EXISTS (SELECT 1 FROM public."Clubs" c WHERE upper(c."ShortName") = v_club_l) THEN
    RETURN jsonb_build_object('ok', false, 'status', 'ignored', 'reason', format('Unknown club %s', v_club_l));
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public."Clubs" c WHERE upper(c."ShortName") = v_club_r) THEN
    RETURN jsonb_build_object('ok', false, 'status', 'ignored', 'reason', format('Unknown club %s', v_club_r));
  END IF;

  IF v_club <> v_club_l AND v_club <> v_club_r THEN
    RETURN jsonb_build_object(
      'ok', false,
      'status', 'ignored',
      'reason', format('Your club (%s) is not in this scoreline', v_club)
    );
  END IF;

  v_season_id := public.gpsl_friendlies_live_season_id();
  IF v_season_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'status', 'ignored', 'reason', 'No live season');
  END IF;

  v_month := public.competition_active_gpsl_month(v_season_id, coalesce(p_posted_at, now()));
  IF v_month IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'status', 'ignored', 'reason', 'No active GPSL month');
  END IF;

  v_canon := public.gpsl_friendlies_canonical(v_club_l, v_score_l, v_club_r, v_score_r);
  v_canon_a := v_canon ->> 'canon_club_a';
  v_canon_b := v_canon ->> 'canon_club_b';
  v_score_a := (v_canon ->> 'canon_score_a')::int;
  v_score_b := (v_canon ->> 'canon_score_b')::int;

  -- Expire old pending for this season (best-effort)
  UPDATE public.gpsl_friendly_reports
  SET status = 'expired',
      note = 'Expired — no matching opponent post'
  WHERE status = 'pending'
    AND season_id = v_season_id
    AND posted_at < now() - make_interval(hours => public.gpsl_friendlies_pending_hours());

  -- Same club re-posting the same pending scoreline — keep the original, record msg
  IF EXISTS (
    SELECT 1
    FROM public.gpsl_friendly_reports r
    WHERE r.status = 'pending'
      AND r.season_id = v_season_id
      AND r.gpsl_month = v_month
      AND r.canon_club_a = v_canon_a
      AND r.canon_club_b = v_canon_b
      AND r.canon_score_a = v_score_a
      AND r.canon_score_b = v_score_b
      AND upper(r.reporter_club_short_name) = v_club
      AND r.posted_at >= now() - make_interval(hours => public.gpsl_friendlies_pending_hours())
  ) THEN
    INSERT INTO public.gpsl_friendly_reports (
      season_id, gpsl_month, discord_message_id, discord_user_id,
      reporter_club_short_name,
      club_left, score_left, club_right, score_right,
      canon_club_a, canon_score_a, canon_club_b, canon_score_b,
      status, note, posted_at
    )
    VALUES (
      v_season_id, v_month, v_msg_id, nullif(btrim(coalesce(p_discord_user_id, '')), ''),
      v_club,
      v_club_l, v_score_l, v_club_r, v_score_r,
      v_canon_a, v_score_a, v_canon_b, v_score_b,
      'ignored',
      'Duplicate pending post from same club',
      coalesce(p_posted_at, now())
    );
    RETURN jsonb_build_object(
      'ok', true,
      'status', 'duplicate',
      'reason', 'You already have a pending post for this scoreline'
    );
  END IF;

  -- Find opponent pending report with same canonical scoreline
  SELECT r.* INTO v_match
  FROM public.gpsl_friendly_reports r
  WHERE r.status = 'pending'
    AND r.season_id = v_season_id
    AND r.gpsl_month = v_month
    AND r.canon_club_a = v_canon_a
    AND r.canon_club_b = v_canon_b
    AND r.canon_score_a = v_score_a
    AND r.canon_score_b = v_score_b
    AND upper(r.reporter_club_short_name) <> v_club
    AND (
      upper(r.reporter_club_short_name) = v_club_l
      OR upper(r.reporter_club_short_name) = v_club_r
    )
    AND r.posted_at >= now() - make_interval(hours => public.gpsl_friendlies_pending_hours())
  ORDER BY r.posted_at ASC
  LIMIT 1
  FOR UPDATE SKIP LOCKED;

  INSERT INTO public.gpsl_friendly_reports (
    season_id, gpsl_month, discord_message_id, discord_user_id,
    reporter_club_short_name,
    club_left, score_left, club_right, score_right,
    canon_club_a, canon_score_a, canon_club_b, canon_score_b,
    status, posted_at
  )
  VALUES (
    v_season_id, v_month, v_msg_id, nullif(btrim(coalesce(p_discord_user_id, '')), ''),
    v_club,
    v_club_l, v_score_l, v_club_r, v_score_r,
    v_canon_a, v_score_a, v_canon_b, v_score_b,
    CASE WHEN v_match.id IS NULL THEN 'pending' ELSE 'matched' END,
    coalesce(p_posted_at, now())
  )
  RETURNING * INTO v_report;

  IF v_match.id IS NULL THEN
    RETURN jsonb_build_object(
      'ok', true,
      'status', 'pending',
      'report_id', v_report.id,
      'scoreline', format('%s %s - %s %s', v_club_l, v_score_l, v_score_r, v_club_r),
      'reason', 'Waiting for opponent to post the matching result'
    );
  END IF;

  -- Confirm friendly + pay
  v_scoreline := format('%s %s - %s %s', v_match.club_left, v_match.score_left, v_match.score_right, v_match.club_right);

  INSERT INTO public.gpsl_friendlies (
    season_id, gpsl_month,
    club_left, score_left, club_right, score_right,
    report_1_id, report_2_id
  )
  VALUES (
    v_season_id, v_month,
    v_match.club_left, v_match.score_left, v_match.club_right, v_match.score_right,
    v_match.id, v_report.id
  )
  RETURNING id INTO v_friendly_id;

  v_pay_l := public.gpsl_friendlies_pay_club(
    v_season_id, v_month, v_match.club_left, v_friendly_id, v_scoreline
  );
  v_pay_r := public.gpsl_friendlies_pay_club(
    v_season_id, v_month, v_match.club_right, v_friendly_id, v_scoreline
  );

  UPDATE public.gpsl_friendlies
  SET paid_left = coalesce((v_pay_l ->> 'paid')::numeric, 0),
      paid_right = coalesce((v_pay_r ->> 'paid')::numeric, 0),
      left_skipped_reason = v_pay_l ->> 'skipped',
      right_skipped_reason = v_pay_r ->> 'skipped'
  WHERE id = v_friendly_id;

  UPDATE public.gpsl_friendly_reports
  SET status = 'matched',
      matched_friendly_id = v_friendly_id
  WHERE id IN (v_match.id, v_report.id);

  RETURN jsonb_build_object(
    'ok', true,
    'status', 'matched',
    'friendly_id', v_friendly_id,
    'scoreline', v_scoreline,
    'paid_left', coalesce((v_pay_l ->> 'paid')::numeric, 0),
    'paid_right', coalesce((v_pay_r ->> 'paid')::numeric, 0),
    'left_skipped', v_pay_l ->> 'skipped',
    'right_skipped', v_pay_r ->> 'skipped',
    'report_id', v_report.id,
    'matched_report_id', v_match.id,
    'discord_message_ids', jsonb_build_array(
      v_match.discord_message_id,
      v_report.discord_message_id
    )
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.gpsl_friendlies_ingest_post(text, text, text, text, timestamptz)
  TO service_role, authenticated;

-- Admin overview
CREATE OR REPLACE FUNCTION public.admin_gpsl_friendlies_overview(p_limit int DEFAULT 50)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_limit int := greatest(1, least(coalesce(p_limit, 50), 200));
  v_season_id bigint := public.gpsl_friendlies_live_season_id();
  v_month text;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF v_season_id IS NOT NULL THEN
    v_month := public.competition_active_gpsl_month(v_season_id, now());
  END IF;

  RETURN jsonb_build_object(
    'season_id', v_season_id,
    'gpsl_month', v_month,
    'gpsl_month_label', CASE
      WHEN v_month IS NULL THEN NULL
      ELSE public.competition_gpsl_month_label(v_month)
    END,
    'payout', public.gpsl_friendlies_payout_amount(),
    'month_cap', public.gpsl_friendlies_month_cap(),
    'season_cap', public.gpsl_friendlies_season_cap(),
    'format', 'CLUB score - score CLUB',
    'example', 'JUB 2 - 2 BEN',
    'pending', coalesce((
      SELECT jsonb_agg(to_jsonb(r) ORDER BY r.posted_at DESC)
      FROM (
        SELECT
          id, gpsl_month, reporter_club_short_name,
          club_left, score_left, club_right, score_right,
          status, posted_at, discord_message_id
        FROM public.gpsl_friendly_reports
        WHERE status = 'pending'
        ORDER BY posted_at DESC
        LIMIT v_limit
      ) r
    ), '[]'::jsonb),
    'confirmed', coalesce((
      SELECT jsonb_agg(to_jsonb(f) ORDER BY f.confirmed_at DESC)
      FROM (
        SELECT
          id, gpsl_month, club_left, score_left, club_right, score_right,
          paid_left, paid_right, left_skipped_reason, right_skipped_reason,
          confirmed_at
        FROM public.gpsl_friendlies
        ORDER BY confirmed_at DESC
        LIMIT v_limit
      ) f
    ), '[]'::jsonb)
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.admin_gpsl_friendlies_overview(int) TO authenticated;

COMMENT ON FUNCTION public.gpsl_friendlies_ingest_post(text, text, text, text, timestamptz) IS
  'Discord friendlies ingest: parse JUB 2 - 2 BEN, match opponent post, pay gate_friendlies under caps.';
