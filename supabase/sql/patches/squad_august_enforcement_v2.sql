-- =============================================================================
-- August squad enforcement v2
--
-- Extends squad_minimum_august.sql:
--   * Fines / loan fees: ₿2.5m (was ₿5m)
--   * Size ≥24, HG ≥8, U21 ≥5, stars ≤ SL3 / Champ2
--   * Loan picks: prefer positional gaps (2 GK / 8 DEF / 8 MID / 6 ATT) —
--     loan-picking only, not an everyday registration rule
--   * Loan pool: HG ≤72 first, else any nation ≤72
--   * At 28: release lowest eligible (OooO never) to make room for loans
--   * Stars: release lowest-rated stars @ 125% MV + ₿2.5m fine; loan first
--     if release would drop under 24; OooO protected always
--
-- Run after squad_minimum_august.sql (+ club_squad_designations.sql,
-- international_nation_player_pool.sql for position groups, overflow paid-up lock).
-- Safe re-run.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Amounts + tariffs
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.squad_minimum_fine_amount()
RETURNS numeric
LANGUAGE sql
IMMUTABLE
AS $$ SELECT 2500000::numeric; $$;

CREATE OR REPLACE FUNCTION public.squad_minimum_loan_fee_amount()
RETURNS numeric
LANGUAGE sql
IMMUTABLE
AS $$ SELECT 2500000::numeric; $$;

ALTER TABLE public.club_squad_minimum_enforcement
  ALTER COLUMN fine_per_player SET DEFAULT 2500000,
  ALTER COLUMN loan_fee_per_player SET DEFAULT 2500000;

ALTER TABLE public.club_season_loans
  ALTER COLUMN loan_fee SET DEFAULT 2500000,
  ALTER COLUMN fine_amount SET DEFAULT 2500000;

INSERT INTO public.competition_fine_tariff (code, label, category, direction, amount, amount_mode, sort_order)
VALUES
  ('breach_squad_24_min', 'Breach of 24 Squad Minimum', 'squad', 'fine', 2500000, 'fixed', 81),
  ('breach_squad_hg_min', 'Breach of Home-Grown Minimum', 'squad', 'fine', 2500000, 'fixed', 83),
  ('breach_squad_u21_min', 'Breach of Under-21 Minimum', 'squad', 'fine', 2500000, 'fixed', 84),
  ('breach_squad_star_cap', 'Breach of Star Player Cap', 'squad', 'fine', 2500000, 'fixed', 85)
ON CONFLICT (code) DO UPDATE
SET
  label = excluded.label,
  category = excluded.category,
  direction = excluded.direction,
  amount = excluded.amount,
  amount_mode = excluded.amount_mode,
  sort_order = excluded.sort_order,
  is_active = true;

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.club_ooo_player_id(p_club_short_name text)
RETURNS text
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT d.player_id
  FROM public.club_squad_player_designations d
  WHERE d.club_short_name = btrim(p_club_short_name)
    AND d.designation = 'one_of_our_own'
  LIMIT 1;
$$;

CREATE OR REPLACE FUNCTION public.club_player_is_hg(p_player_id text, p_club_short_name text)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public."Players" p
    JOIN public."Clubs" c ON c."ShortName" = btrim(p_club_short_name)
    WHERE p."Konami_ID"::text = btrim(p_player_id)
      AND public.normalize_nation_key(p."Nation") = public.normalize_nation_key(c."Nation")
      AND public.normalize_nation_key(p."Nation") <> ''
  );
$$;

CREATE OR REPLACE FUNCTION public.club_player_is_u21(p_player_id text)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public."Players" p
    WHERE p."Konami_ID"::text = btrim(p_player_id)
      AND p."Age" IS NOT NULL
      AND btrim(p."Age"::text) <> ''
      AND btrim(p."Age"::text)::numeric <= 21
  );
$$;

CREATE OR REPLACE FUNCTION public.club_hg_count(p_club_short_name text)
RETURNS int
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT count(*)::int
  FROM public."Players" p
  JOIN public."Clubs" c ON c."ShortName" = btrim(p_club_short_name)
  WHERE p."Contracted_Team" = c."ShortName"
    AND public.normalize_nation_key(p."Nation") = public.normalize_nation_key(c."Nation")
    AND public.normalize_nation_key(p."Nation") <> '';
$$;

CREATE OR REPLACE FUNCTION public.club_u21_count(p_club_short_name text)
RETURNS int
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT count(*)::int
  FROM public."Players" p
  WHERE p."Contracted_Team" = btrim(p_club_short_name)
    AND p."Age" IS NOT NULL
    AND btrim(p."Age"::text) <> ''
    AND btrim(p."Age"::text)::numeric <= 21;
$$;

CREATE OR REPLACE FUNCTION public.club_star_count_for_cap(p_club_short_name text)
RETURNS int
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := btrim(p_club_short_name);
  v_min smallint := 79;
  v_ooo text;
BEGIN
  IF to_regprocedure('public.club_squad_star_min_rating()') IS NOT NULL THEN
    v_min := public.club_squad_star_min_rating();
  END IF;
  v_ooo := public.club_ooo_player_id(v_club);

  RETURN (
    SELECT count(*)::int
    FROM public."Players" p
    WHERE p."Contracted_Team" = v_club
      AND nullif(
        regexp_replace(coalesce(btrim(p."Rating"::text), ''), '[^0-9]', '', 'g'),
        ''
      )::integer >= v_min
      AND (v_ooo IS NULL OR p."Konami_ID"::text <> v_ooo)
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.club_position_group_counts(p_club_short_name text)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT jsonb_build_object(
    'gk', count(*) FILTER (WHERE g = 'gk'),
    'def', count(*) FILTER (WHERE g = 'def'),
    'mid', count(*) FILTER (WHERE g = 'mid'),
    'fwd', count(*) FILTER (WHERE g = 'fwd')
  )
  FROM (
    SELECT public.international_player_pool_position_group(p."Position") AS g
    FROM public."Players" p
    WHERE p."Contracted_Team" = btrim(p_club_short_name)
  ) x;
$$;

-- Soft targets used only when choosing which loan to draw.
CREATE OR REPLACE FUNCTION public.club_worst_loan_position_gap(p_club_short_name text)
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_counts jsonb := public.club_position_group_counts(p_club_short_name);
  v_best text := NULL;
  v_best_short int := 0;
  v_short int;
BEGIN
  v_short := greatest(2 - coalesce((v_counts ->> 'gk')::int, 0), 0);
  IF v_short > v_best_short THEN
    v_best_short := v_short;
    v_best := 'gk';
  END IF;

  v_short := greatest(8 - coalesce((v_counts ->> 'def')::int, 0), 0);
  IF v_short > v_best_short THEN
    v_best_short := v_short;
    v_best := 'def';
  END IF;

  v_short := greatest(8 - coalesce((v_counts ->> 'mid')::int, 0), 0);
  IF v_short > v_best_short THEN
    v_best_short := v_short;
    v_best := 'mid';
  END IF;

  v_short := greatest(6 - coalesce((v_counts ->> 'fwd')::int, 0), 0);
  IF v_short > v_best_short THEN
    v_best_short := v_short;
    v_best := 'fwd';
  END IF;

  IF v_best_short <= 0 THEN
    RETURN NULL;
  END IF;
  RETURN v_best;
END;
$function$;

-- ---------------------------------------------------------------------------
-- Loan draw: position gap → HG ≤72 → any nation ≤72
-- ---------------------------------------------------------------------------

DROP FUNCTION IF EXISTS public.draw_season_loan_player(text, bigint, text[]);

CREATE OR REPLACE FUNCTION public.draw_season_loan_player(
  p_club_short_name text,
  p_season_id bigint,
  p_exclude_player_ids text[] DEFAULT ARRAY[]::text[],
  p_require_u21 boolean DEFAULT false,
  p_require_hg boolean DEFAULT false
)
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := btrim(p_club_short_name);
  v_club_nation text;
  v_prefer_grp text := public.club_worst_loan_position_gap(v_club);
  v_player_id text;
  v_exclude text[] := coalesce(p_exclude_player_ids, ARRAY[]::text[]);
BEGIN
  SELECT c."Nation" INTO v_club_nation
  FROM public."Clubs" c
  WHERE c."ShortName" = v_club;

  -- 1) Preferred position + HG
  IF v_prefer_grp IS NOT NULL THEN
    SELECT p."Konami_ID"::text INTO v_player_id
    FROM public."Players" p
    WHERE (p."Contracted_Team" IS NULL OR btrim(p."Contracted_Team") = '')
      AND public.normalize_nation_key(p."Nation") = public.normalize_nation_key(v_club_nation)
      AND public.normalize_nation_key(p."Nation") <> ''
      AND btrim(coalesce(p."Rating"::text, '')) <> ''
      AND btrim(p."Rating"::text)::numeric <= 72
      AND public.international_player_pool_position_group(p."Position") = v_prefer_grp
      AND (NOT p_require_u21 OR (
        p."Age" IS NOT NULL AND btrim(p."Age"::text) <> '' AND btrim(p."Age"::text)::numeric <= 21
      ))
      AND NOT (p."Konami_ID"::text = ANY (v_exclude))
      AND NOT EXISTS (
        SELECT 1 FROM public.club_season_loans l
        WHERE l.season_id = p_season_id AND l.player_id = p."Konami_ID"::text AND l.status = 'active'
      )
      AND NOT public.player_foreign_contract_locked(p."Konami_ID"::text)
    ORDER BY random()
    LIMIT 1;
    IF v_player_id IS NOT NULL THEN RETURN v_player_id; END IF;
  END IF;

  -- 2) Any position + HG
  SELECT p."Konami_ID"::text INTO v_player_id
  FROM public."Players" p
  WHERE (p."Contracted_Team" IS NULL OR btrim(p."Contracted_Team") = '')
    AND public.normalize_nation_key(p."Nation") = public.normalize_nation_key(v_club_nation)
    AND public.normalize_nation_key(p."Nation") <> ''
    AND btrim(coalesce(p."Rating"::text, '')) <> ''
    AND btrim(p."Rating"::text)::numeric <= 72
    AND (NOT p_require_u21 OR (
      p."Age" IS NOT NULL AND btrim(p."Age"::text) <> '' AND btrim(p."Age"::text)::numeric <= 21
    ))
    AND NOT (p."Konami_ID"::text = ANY (v_exclude))
    AND NOT EXISTS (
      SELECT 1 FROM public.club_season_loans l
      WHERE l.season_id = p_season_id AND l.player_id = p."Konami_ID"::text AND l.status = 'active'
    )
    AND NOT public.player_foreign_contract_locked(p."Konami_ID"::text)
  ORDER BY random()
  LIMIT 1;
  IF v_player_id IS NOT NULL THEN RETURN v_player_id; END IF;

  IF p_require_hg THEN
    RETURN NULL;
  END IF;

  -- 3) Preferred position + any nation
  IF v_prefer_grp IS NOT NULL THEN
    SELECT p."Konami_ID"::text INTO v_player_id
    FROM public."Players" p
    WHERE (p."Contracted_Team" IS NULL OR btrim(p."Contracted_Team") = '')
      AND btrim(coalesce(p."Rating"::text, '')) <> ''
      AND btrim(p."Rating"::text)::numeric <= 72
      AND public.international_player_pool_position_group(p."Position") = v_prefer_grp
      AND (NOT p_require_u21 OR (
        p."Age" IS NOT NULL AND btrim(p."Age"::text) <> '' AND btrim(p."Age"::text)::numeric <= 21
      ))
      AND NOT (p."Konami_ID"::text = ANY (v_exclude))
      AND NOT EXISTS (
        SELECT 1 FROM public.club_season_loans l
        WHERE l.season_id = p_season_id AND l.player_id = p."Konami_ID"::text AND l.status = 'active'
      )
      AND NOT public.player_foreign_contract_locked(p."Konami_ID"::text)
    ORDER BY random()
    LIMIT 1;
    IF v_player_id IS NOT NULL THEN RETURN v_player_id; END IF;
  END IF;

  -- 4) Any nation / any position
  SELECT p."Konami_ID"::text INTO v_player_id
  FROM public."Players" p
  WHERE (p."Contracted_Team" IS NULL OR btrim(p."Contracted_Team") = '')
    AND btrim(coalesce(p."Rating"::text, '')) <> ''
    AND btrim(p."Rating"::text)::numeric <= 72
    AND (NOT p_require_u21 OR (
      p."Age" IS NOT NULL AND btrim(p."Age"::text) <> '' AND btrim(p."Age"::text)::numeric <= 21
    ))
    AND NOT (p."Konami_ID"::text = ANY (v_exclude))
    AND NOT EXISTS (
      SELECT 1 FROM public.club_season_loans l
      WHERE l.season_id = p_season_id AND l.player_id = p."Konami_ID"::text AND l.status = 'active'
    )
    AND NOT public.player_foreign_contract_locked(p."Konami_ID"::text)
  ORDER BY random()
  LIMIT 1;

  RETURN v_player_id;
END;
$function$;

-- Allow non-HG season loans (fallback pool). Still ≤72 free agents only.
CREATE OR REPLACE FUNCTION public.assign_player_season_loan(
  p_player_id text,
  p_club_short_name text,
  p_season_id bigint,
  p_loan_fee numeric DEFAULT NULL,
  p_fine_amount numeric DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := btrim(p_club_short_name);
  v_pid text := btrim(p_player_id);
  v_player public."Players"%rowtype;
  v_loan_fee numeric := coalesce(p_loan_fee, public.squad_minimum_loan_fee_amount());
  v_fine_amount numeric := coalesce(p_fine_amount, public.squad_minimum_fine_amount());
  v_season_label text;
  v_wage numeric;
  v_loan_id bigint;
  v_ledger_id bigint;
  v_balance numeric;
BEGIN
  IF v_pid = '' OR v_club = '' THEN
    RAISE EXCEPTION 'Player and club are required';
  END IF;

  SELECT * INTO v_player
  FROM public."Players"
  WHERE "Konami_ID"::text = v_pid
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Player not found';
  END IF;

  IF v_player."Contracted_Team" IS NOT NULL AND btrim(v_player."Contracted_Team") <> '' THEN
    RAISE EXCEPTION 'Player is not a free agent';
  END IF;

  IF btrim(coalesce(v_player."Rating"::text, '')) = ''
     OR btrim(v_player."Rating"::text)::numeric > 72 THEN
    RAISE EXCEPTION 'Season loan draw must be rating 72 or lower';
  END IF;

  SELECT balance INTO v_balance
  FROM public."Club_Finances"
  WHERE club_name = v_club
  FOR UPDATE;

  IF v_balance IS NULL THEN
    RAISE EXCEPTION 'Club finances not found for %', v_club;
  END IF;
  IF v_balance < v_loan_fee THEN
    RAISE EXCEPTION 'Insufficient balance for season loan fee (need %, have %)', v_loan_fee, v_balance;
  END IF;

  v_season_label := public.current_gpsl_season_label();
  v_wage := public.calculate_player_wage_for_club(v_pid, v_club);

  UPDATE public."Players"
  SET
    "Contracted_Team" = v_club,
    "Season_Signed" = v_season_label,
    contract_seasons_remaining = 1,
    contract_wage = round(coalesce(v_wage, 0), 0),
    foreign_contract_club = NULL,
    foreign_contract_sold_season_id = NULL,
    foreign_contract_unlock_season_label = NULL,
    foreign_contract_lock_kind = NULL
  WHERE "Konami_ID"::text = v_pid;

  v_ledger_id := public.post_club_ledger(
    v_club,
    'season_loan_fee',
    -abs(v_loan_fee),
    format('Season loan fee — %s', coalesce(v_player."Name", v_pid)),
    jsonb_build_object(
      'player_id', v_pid,
      'season_id', p_season_id,
      'kind', 'season_loan',
      'home_grown', public.club_player_is_hg(v_pid, v_club)
    ),
    p_season_id,
    NULL,
    true,
    true
  );

  INSERT INTO public.club_season_loans (
    season_id, club_short_name, player_id, loan_fee, fine_amount, status, loan_ledger_id
  )
  VALUES (
    p_season_id, v_club, v_pid, v_loan_fee, v_fine_amount, 'active', v_ledger_id
  )
  RETURNING id INTO v_loan_id;

  RETURN jsonb_build_object(
    'ok', true,
    'loan_id', v_loan_id,
    'player_id', v_pid,
    'player_name', v_player."Name",
    'loan_fee', v_loan_fee,
    'home_grown', public.club_player_is_hg(v_pid, v_club)
  );
END;
$function$;

-- ---------------------------------------------------------------------------
-- Release helpers (OooO never eligible)
-- mode: any | non_hg | non_u21 | star
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.club_pick_august_release_player(
  p_club_short_name text,
  p_mode text
)
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := btrim(p_club_short_name);
  v_mode text := lower(btrim(coalesce(p_mode, 'any')));
  v_ooo text := public.club_ooo_player_id(v_club);
  v_min smallint := 79;
  v_pid text;
BEGIN
  IF to_regprocedure('public.club_squad_star_min_rating()') IS NOT NULL THEN
    v_min := public.club_squad_star_min_rating();
  END IF;

  SELECT p."Konami_ID"::text INTO v_pid
  FROM public."Players" p
  WHERE p."Contracted_Team" = v_club
    AND (v_ooo IS NULL OR p."Konami_ID"::text <> v_ooo)
    AND (
      v_mode = 'any'
      OR (v_mode = 'non_hg' AND NOT public.club_player_is_hg(p."Konami_ID"::text, v_club))
      OR (v_mode = 'non_u21' AND NOT public.club_player_is_u21(p."Konami_ID"::text))
      OR (
        v_mode = 'star'
        AND nullif(
          regexp_replace(coalesce(btrim(p."Rating"::text), ''), '[^0-9]', '', 'g'),
          ''
        )::integer >= v_min
      )
    )
  ORDER BY public.player_rating_as_numeric(p."Rating"::text) ASC,
           coalesce(p."Name", p."Konami_ID"::text)
  LIMIT 1;

  RETURN v_pid;
END;
$function$;

CREATE OR REPLACE FUNCTION public.club_august_release_player(
  p_club_short_name text,
  p_player_id text,
  p_mv_rate numeric DEFAULT 1.0,
  p_sale_note text DEFAULT 'august_enforcement',
  p_buyer_label text DEFAULT 'Market value (August enforcement)'
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := btrim(p_club_short_name);
  v_pid text := btrim(p_player_id);
  v_ooo text := public.club_ooo_player_id(v_club);
  v_player public."Players"%rowtype;
  v_fee numeric;
  v_bal numeric;
  v_rate numeric := greatest(coalesce(p_mv_rate, 1.0), 0);
BEGIN
  IF v_ooo IS NOT NULL AND v_pid = v_ooo THEN
    RAISE EXCEPTION 'One of Our Own cannot be released';
  END IF;

  SELECT * INTO v_player
  FROM public."Players"
  WHERE "Konami_ID"::text = v_pid
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Player not found';
  END IF;

  IF public.player_contracted_club_key(v_player."Contracted_Team") IS DISTINCT FROM v_club THEN
    RAISE EXCEPTION 'Player is not at club %', v_club;
  END IF;

  v_fee := round(greatest(coalesce(v_player.market_value::numeric, 0), 0) * v_rate);

  UPDATE public."Player_Transfer_Listings" l
  SET status = 'Closed', transfer_completed = false, winning_bid = null, winning_club = null
  WHERE l.player_id::text = v_pid
    AND l.seller_club_id = v_club
    AND l.status IN ('Active', 'Review');

  UPDATE public."Player_Transfer_Bids" b
  SET status = 'rejected'
  WHERE b.is_direct = true
    AND b.listing_id IS NULL
    AND lower(coalesce(b.status::text, '')) = 'active'
    AND (
      (b.player_id IS NOT NULL AND btrim(b.player_id::text) = v_pid)
      OR (b.direct_bid_id IS NOT NULL AND btrim(b.direct_bid_id::text) = v_pid)
    );

  SELECT balance INTO v_bal
  FROM public."Club_Finances"
  WHERE club_name = v_club
  FOR UPDATE;

  IF v_bal IS NULL THEN
    RAISE EXCEPTION 'Club finances not found for %', v_club;
  END IF;

  PERFORM public.ensure_foreign_buyer_club();
  PERFORM public.player_release_from_club(v_pid);

  UPDATE public."Club_Finances"
  SET balance = v_bal + v_fee
  WHERE club_name = v_club;

  INSERT INTO public."Transfer_History" (
    player_id, seller_club_id, buyer_club_id, fee, agent_fee,
    transfer_time, listing_id, foreign_buyer_name, transfer_sale_note
  )
  VALUES (
    v_player."Konami_ID", v_club, 'FOREIGN', v_fee, 0,
    now(), NULL, p_buyer_label, p_sale_note
  );

  -- Unavailable for auctions until next season (same as overflow paid-up)
  IF to_regprocedure('public.player_apply_overflow_paid_up_lock(text, text)') IS NOT NULL THEN
    PERFORM public.player_apply_overflow_paid_up_lock(v_pid, v_club);
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'player_id', v_pid,
    'player_name', v_player."Name",
    'rating', v_player."Rating",
    'fee', v_fee,
    'mv_rate', v_rate,
    'sale_note', p_sale_note
  );
END;
$function$;

-- ---------------------------------------------------------------------------
-- Core: one loan attempt (optional release-to-make-room first)
-- Returns { ok, loan?, released?, exclude[], error? }
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.club_august_issue_loan(
  p_club_short_name text,
  p_season_id bigint,
  p_exclude text[] DEFAULT ARRAY[]::text[],
  p_require_u21 boolean DEFAULT false,
  p_require_hg boolean DEFAULT false,
  p_release_mode text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := btrim(p_club_short_name);
  v_count int;
  v_release_id text;
  v_player_id text;
  v_loan jsonb;
  v_rel jsonb;
  v_exclude text[] := coalesce(p_exclude, ARRAY[]::text[]);
  v_err text;
BEGIN
  v_count := public.club_registered_squad_count(v_club);

  IF v_count >= public.squad_max_size() AND p_release_mode IS NOT NULL THEN
    v_release_id := public.club_pick_august_release_player(v_club, p_release_mode);
    IF v_release_id IS NULL THEN
      v_err := format('At max squad — no releasable player (mode %s)', p_release_mode);
      RETURN jsonb_build_object('ok', false, 'reason', 'no_release_candidate', 'error', v_err, 'exclude', to_jsonb(v_exclude));
    END IF;
    BEGIN
      v_rel := public.club_august_release_player(
        v_club, v_release_id, 1.0, 'august_make_room',
        'Market value (August — room for loan)'
      );
    EXCEPTION WHEN OTHERS THEN
      v_err := format('Release failed %s: %s', v_release_id, SQLERRM);
      RETURN jsonb_build_object('ok', false, 'reason', 'release_failed', 'error', v_err, 'exclude', to_jsonb(v_exclude));
    END;
  ELSIF v_count >= public.squad_max_size() THEN
    v_err := 'At max squad — cannot loan without a release mode';
    RETURN jsonb_build_object('ok', false, 'reason', 'squad_full', 'error', v_err, 'exclude', to_jsonb(v_exclude));
  END IF;

  v_player_id := public.draw_season_loan_player(
    v_club, p_season_id, v_exclude, p_require_u21, p_require_hg
  );

  IF v_player_id IS NULL THEN
    v_err := format(
      'No eligible loan (≤72%s%s)',
      CASE WHEN p_require_hg THEN ', HG' ELSE '' END,
      CASE WHEN p_require_u21 THEN ', U21' ELSE '' END
    );
    RETURN jsonb_build_object('ok', false, 'reason', 'no_loan_candidate', 'error', v_err, 'exclude', to_jsonb(v_exclude), 'released', v_rel);
  END IF;

  BEGIN
    v_loan := public.assign_player_season_loan(
      v_player_id, v_club, p_season_id,
      public.squad_minimum_loan_fee_amount(),
      public.squad_minimum_fine_amount()
    );
    v_exclude := array_append(v_exclude, v_player_id);
    RETURN jsonb_build_object(
      'ok', true,
      'loan', v_loan,
      'released', v_rel,
      'exclude', to_jsonb(v_exclude)
    );
  EXCEPTION WHEN OTHERS THEN
    v_err := format('Loan failed %s: %s', v_player_id, SQLERRM);
    RETURN jsonb_build_object('ok', false, 'reason', 'loan_failed', 'error', v_err, 'exclude', to_jsonb(v_exclude), 'released', v_rel);
  END;
END;
$function$;

-- ---------------------------------------------------------------------------
-- Per-club August enforcement (size → HG → U21 → stars)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.club_enforce_squad_minimum(
  p_club_short_name text,
  p_season_id bigint DEFAULT NULL,
  p_force boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := btrim(p_club_short_name);
  v_season_id bigint := p_season_id;
  v_count int;
  v_hg int;
  v_u21 int;
  v_stars int;
  v_star_cap int;
  v_short int;
  v_i int;
  v_exclude text[] := ARRAY[]::text[];
  v_errors text[] := ARRAY[]::text[];
  v_actions jsonb := '[]'::jsonb;
  v_action jsonb;
  v_fine_total numeric := 0;
  v_loan_total numeric := 0;
  v_loans int := 0;
  v_releases int := 0;
  v_size_short int := 0;
  v_hg_short int := 0;
  v_u21_short int := 0;
  v_star_over int := 0;
  v_fee numeric := public.squad_minimum_fine_amount();
  v_loan_fee numeric := public.squad_minimum_loan_fee_amount();
  v_pid text;
  v_rel jsonb;
  v_min_hg constant int := 8;
  v_min_u21 constant int := 5;
BEGIN
  IF v_club IS NULL OR v_club = '' THEN
    RAISE EXCEPTION 'Club required';
  END IF;

  IF v_season_id IS NULL THEN
    SELECT id INTO v_season_id
    FROM public.competition_seasons
    WHERE is_current = true
    ORDER BY id DESC
    LIMIT 1;
  END IF;

  IF v_season_id IS NULL THEN
    RAISE EXCEPTION 'No current season';
  END IF;

  IF NOT p_force AND NOT public.squad_minimum_punishments_active(v_season_id) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'before_august', 'club', v_club);
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.club_squad_minimum_enforcement e
    WHERE e.season_id = v_season_id AND e.club_short_name = v_club
  ) THEN
    RETURN jsonb_build_object('ok', true, 'already_enforced', true, 'club', v_club);
  END IF;

  -- ===== 1) Size ≥ 24 =====
  v_count := public.club_registered_squad_count(v_club);
  v_short := greatest(public.squad_minimum_size() - v_count, 0);
  v_size_short := v_short;

  FOR v_i IN 1..v_short LOOP
    PERFORM public.competition_apply_club_fine_tariff(
      v_club, 'breach_squad_24_min', v_fee,
      format('Below minimum squad at August (%s of %s missing)', v_i, v_short),
      NULL, v_season_id
    );
    v_fine_total := v_fine_total + v_fee;

    v_action := public.club_august_issue_loan(
      v_club, v_season_id, v_exclude, false, false, 'any'
    );
    IF jsonb_typeof(v_action -> 'exclude') = 'array'
       AND jsonb_array_length(v_action -> 'exclude') > 0 THEN
      SELECT array_agg(x ORDER BY ord)
      INTO v_exclude
      FROM jsonb_array_elements_text(v_action -> 'exclude') WITH ORDINALITY AS t(x, ord);
    END IF;
    IF v_action ->> 'error' IS NOT NULL THEN
      v_errors := array_append(v_errors, v_action ->> 'error');
    END IF;
    IF coalesce((v_action ->> 'ok')::boolean, false) THEN
      v_loans := v_loans + 1;
      v_loan_total := v_loan_total + v_loan_fee;
      IF v_action -> 'released' IS NOT NULL AND jsonb_typeof(v_action -> 'released') = 'object' THEN
        v_releases := v_releases + 1;
      END IF;
    END IF;
    v_actions := v_actions || jsonb_build_array(jsonb_build_object('step', 'size', 'result', v_action));
  END LOOP;

  -- ===== 2) HG ≥ 8 =====
  v_hg := public.club_hg_count(v_club);
  v_short := greatest(v_min_hg - v_hg, 0);
  v_hg_short := v_short;

  FOR v_i IN 1..v_short LOOP
    PERFORM public.competition_apply_club_fine_tariff(
      v_club, 'breach_squad_hg_min', v_fee,
      format('Below home-grown minimum at August (%s of %s missing)', v_i, v_short),
      NULL, v_season_id
    );
    v_fine_total := v_fine_total + v_fee;

    v_action := public.club_august_issue_loan(
      v_club, v_season_id, v_exclude, false, true, 'non_hg'
    );
    IF jsonb_typeof(v_action -> 'exclude') = 'array'
       AND jsonb_array_length(v_action -> 'exclude') > 0 THEN
      SELECT array_agg(x ORDER BY ord)
      INTO v_exclude
      FROM jsonb_array_elements_text(v_action -> 'exclude') WITH ORDINALITY AS t(x, ord);
    END IF;
    IF v_action ->> 'error' IS NOT NULL THEN
      v_errors := array_append(v_errors, v_action ->> 'error');
    END IF;
    IF coalesce((v_action ->> 'ok')::boolean, false) THEN
      v_loans := v_loans + 1;
      v_loan_total := v_loan_total + v_loan_fee;
      IF v_action -> 'released' IS NOT NULL AND jsonb_typeof(v_action -> 'released') = 'object' THEN
        v_releases := v_releases + 1;
      END IF;
    END IF;
    v_actions := v_actions || jsonb_build_array(jsonb_build_object('step', 'hg', 'result', v_action));
  END LOOP;

  -- ===== 3) U21 ≥ 5 =====
  v_u21 := public.club_u21_count(v_club);
  v_short := greatest(v_min_u21 - v_u21, 0);
  v_u21_short := v_short;

  FOR v_i IN 1..v_short LOOP
    PERFORM public.competition_apply_club_fine_tariff(
      v_club, 'breach_squad_u21_min', v_fee,
      format('Below under-21 minimum at August (%s of %s missing)', v_i, v_short),
      NULL, v_season_id
    );
    v_fine_total := v_fine_total + v_fee;

    v_action := public.club_august_issue_loan(
      v_club, v_season_id, v_exclude, true, false, 'non_u21'
    );
    IF jsonb_typeof(v_action -> 'exclude') = 'array'
       AND jsonb_array_length(v_action -> 'exclude') > 0 THEN
      SELECT array_agg(x ORDER BY ord)
      INTO v_exclude
      FROM jsonb_array_elements_text(v_action -> 'exclude') WITH ORDINALITY AS t(x, ord);
    END IF;
    IF v_action ->> 'error' IS NOT NULL THEN
      v_errors := array_append(v_errors, v_action ->> 'error');
    END IF;
    IF coalesce((v_action ->> 'ok')::boolean, false) THEN
      v_loans := v_loans + 1;
      v_loan_total := v_loan_total + v_loan_fee;
      IF v_action -> 'released' IS NOT NULL AND jsonb_typeof(v_action -> 'released') = 'object' THEN
        v_releases := v_releases + 1;
      END IF;
    END IF;
    v_actions := v_actions || jsonb_build_array(jsonb_build_object('step', 'u21', 'result', v_action));
  END LOOP;

  -- ===== 4) Stars ≤ cap =====
  IF to_regprocedure('public.club_squad_star_cap(text)') IS NOT NULL THEN
    v_star_cap := public.club_squad_star_cap(v_club)::int;
  ELSE
    v_star_cap := CASE
      WHEN public.competition_club_division_tier(v_club) = 'superleague' THEN 3
      ELSE 2
    END;
  END IF;

  v_stars := public.club_star_count_for_cap(v_club);
  v_star_over := greatest(v_stars - v_star_cap, 0);

  FOR v_i IN 1..v_star_over LOOP
    v_count := public.club_registered_squad_count(v_club);

    IF v_count <= public.squad_minimum_size() THEN
      v_action := public.club_august_issue_loan(
        v_club, v_season_id, v_exclude, false, false, 'any'
      );
      IF jsonb_typeof(v_action -> 'exclude') = 'array'
         AND jsonb_array_length(v_action -> 'exclude') > 0 THEN
        SELECT array_agg(x ORDER BY ord)
        INTO v_exclude
        FROM jsonb_array_elements_text(v_action -> 'exclude') WITH ORDINALITY AS t(x, ord);
      END IF;
      IF v_action ->> 'error' IS NOT NULL THEN
        v_errors := array_append(v_errors, v_action ->> 'error');
      END IF;
      IF coalesce((v_action ->> 'ok')::boolean, false) THEN
        v_loans := v_loans + 1;
        v_loan_total := v_loan_total + v_loan_fee;
        v_actions := v_actions || jsonb_build_array(jsonb_build_object('step', 'star_preloan', 'result', v_action));
      ELSE
        v_errors := array_append(v_errors, 'Cannot release star — squad at minimum and loan unavailable');
        v_actions := v_actions || jsonb_build_array(jsonb_build_object('step', 'star_preloan', 'result', v_action));
        EXIT;
      END IF;
    END IF;

    v_pid := public.club_pick_august_release_player(v_club, 'star');
    IF v_pid IS NULL THEN
      v_errors := array_append(v_errors, 'No releasable star remaining');
      EXIT;
    END IF;

    BEGIN
      v_rel := public.club_august_release_player(
        v_club, v_pid, 1.25, 'august_star_compliance',
        'Market value 125% (August star cap)'
      );
      v_releases := v_releases + 1;

      PERFORM public.competition_apply_club_fine_tariff(
        v_club, 'breach_squad_star_cap', v_fee,
        format('Star cap breach — released %s (%s of %s)', coalesce(v_rel ->> 'player_name', v_pid), v_i, v_star_over),
        NULL, v_season_id
      );
      v_fine_total := v_fine_total + v_fee;

      v_actions := v_actions || jsonb_build_array(jsonb_build_object(
        'step', 'star_release',
        'result', v_rel
      ));
    EXCEPTION WHEN OTHERS THEN
      v_errors := array_append(v_errors, format('Star release failed %s: %s', v_pid, SQLERRM));
      EXIT;
    END;
  END LOOP;

  v_count := public.club_registered_squad_count(v_club);
  v_short := greatest(v_size_short + v_hg_short + v_u21_short + v_star_over, 0);

  IF v_short > 0 OR v_loans > 0 OR v_releases > 0 OR v_fine_total > 0 THEN
    INSERT INTO public.club_squad_minimum_enforcement (
      season_id, club_short_name, squad_count, shortfall,
      fine_per_player, loan_fee_per_player, total_fine, total_loan_fee,
      loans_granted, metadata
    )
    VALUES (
      v_season_id, v_club, v_count,
      greatest(v_short, 1),
      v_fee, v_loan_fee, v_fine_total, v_loan_total, v_loans,
      jsonb_build_object(
        'version', 2,
        'size_shortfall', v_size_short,
        'hg_shortfall', v_hg_short,
        'u21_shortfall', v_u21_short,
        'stars_over', v_star_over,
        'star_cap', v_star_cap,
        'releases', v_releases,
        'errors', to_jsonb(v_errors),
        'actions', v_actions
      )
    )
    ON CONFLICT (season_id, club_short_name) DO UPDATE
    SET
      squad_count = excluded.squad_count,
      shortfall = excluded.shortfall,
      fine_per_player = excluded.fine_per_player,
      loan_fee_per_player = excluded.loan_fee_per_player,
      total_fine = excluded.total_fine,
      total_loan_fee = excluded.total_loan_fee,
      loans_granted = excluded.loans_granted,
      metadata = excluded.metadata,
      enforced_at = now();
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'club', v_club,
    'squad_count', v_count,
    'size_shortfall', v_size_short,
    'hg_shortfall', v_hg_short,
    'u21_shortfall', v_u21_short,
    'stars_over', v_star_over,
    'star_cap', v_star_cap,
    'fines_total', v_fine_total,
    'loans_granted', v_loans,
    'loan_fees_total', v_loan_total,
    'releases', v_releases,
    'errors', to_jsonb(v_errors),
    'enforced', v_short > 0
  );
END;
$function$;

-- competition_enforce_squad_minimum_august stays; it already loops clubs.

GRANT EXECUTE ON FUNCTION public.draw_season_loan_player(text, bigint, text[], boolean, boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.club_enforce_squad_minimum(text, bigint, boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.club_august_release_player(text, text, numeric, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.club_august_issue_loan(text, bigint, text[], boolean, boolean, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.club_pick_august_release_player(text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.club_worst_loan_position_gap(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.club_star_count_for_cap(text) TO authenticated;

NOTIFY pgrst, 'reload schema';
