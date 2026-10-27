-- =============================================================================
-- Ko-fi Supporter perks (2026-10-27)
--
-- 1) Continuous streak (supporter_continuous_since) — resets on unset / lapse
-- 2) Anniversary: ₿2,500 Building Society every 6 months continuous
-- 3) Friendlies: first 10 paid / month → ₿15,000 if supporter-active on confirm;
--    11–20 → ₿5,000; season cap ₿2,000,000 (others ₿1,200,000)
-- 4) Mid-season pack (on November GPSL month lock): 2× consult −2 + one 5% fee
--    discount — requires ≥60 continuous calendar days + is_supporter flag
-- 5) Free club swap also requires ≥60 continuous days
-- 6) Supporter-sourced tokens only usable while supporter-active
--
-- Safe re-run. Apply in Supabase SQL Editor after prior Ko-fi / friendlies patches.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Columns
-- ---------------------------------------------------------------------------
ALTER TABLE public.gpsl_owner_registry
  ADD COLUMN IF NOT EXISTS supporter_continuous_since timestamptz,
  ADD COLUMN IF NOT EXISTS supporter_anniv_milestones_paid int NOT NULL DEFAULT 0;

COMMENT ON COLUMN public.gpsl_owner_registry.supporter_continuous_since IS
  'Start of current continuous Ko-fi streak (Europe/London membership). Cleared on unset/lapse.';
COMMENT ON COLUMN public.gpsl_owner_registry.supporter_anniv_milestones_paid IS
  'How many 6-month anniversary credits paid in the current continuous streak.';

-- Backfill continuous_since for current flagged supporters
UPDATE public.gpsl_owner_registry
SET supporter_continuous_since = coalesce(supporter_continuous_since, supporter_since, now())
WHERE is_supporter = true
  AND supporter_continuous_since IS NULL;

CREATE TABLE IF NOT EXISTS public.supporter_season_perk_grants (
  owner_id uuid NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  season_id bigint NOT NULL,
  perk_kind text NOT NULL,
  club_short_name text,
  granted_at timestamptz NOT NULL DEFAULT now(),
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  PRIMARY KEY (owner_id, season_id, perk_kind)
);

CREATE INDEX IF NOT EXISTS supporter_season_perk_grants_season_idx
  ON public.supporter_season_perk_grants (season_id, perk_kind);

ALTER TABLE public.supporter_season_perk_grants ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.supporter_season_perk_grants FROM anon, authenticated;
GRANT SELECT ON public.supporter_season_perk_grants TO authenticated;

DROP POLICY IF EXISTS supporter_season_perk_grants_select_self ON public.supporter_season_perk_grants;
CREATE POLICY supporter_season_perk_grants_select_self
  ON public.supporter_season_perk_grants FOR SELECT TO authenticated
  USING (owner_id = auth.uid() OR public.is_gpsl_admin());

-- ---------------------------------------------------------------------------
-- Continuous streak helpers
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.owner_supporter_continuous_days(p_owner_id uuid)
RETURNS int
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_since timestamptz;
  v_flag boolean;
BEGIN
  IF p_owner_id IS NULL THEN
    RETURN 0;
  END IF;

  SELECT r.is_supporter, r.supporter_continuous_since
  INTO v_flag, v_since
  FROM public.gpsl_owner_registry r
  WHERE r.owner_id = p_owner_id;

  IF NOT coalesce(v_flag, false) OR v_since IS NULL THEN
    RETURN 0;
  END IF;

  RETURN greatest(
    0,
    (public.supporter_london_today() - (v_since AT TIME ZONE 'Europe/London')::date)
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.owner_supporter_meets_tenure(
  p_owner_id uuid,
  p_min_days int DEFAULT 60
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT public.owner_supporter_continuous_days(p_owner_id) >= greatest(coalesce(p_min_days, 60), 0);
$$;

CREATE OR REPLACE FUNCTION public.club_owner_id_for_short(p_club text)
RETURNS uuid
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT c.owner_id
  FROM public."Clubs" c
  WHERE upper(btrim(c."ShortName")) = upper(btrim(coalesce(p_club, '')))
  LIMIT 1;
$$;

GRANT EXECUTE ON FUNCTION public.owner_supporter_continuous_days(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.owner_supporter_meets_tenure(uuid, int) TO authenticated;
GRANT EXECUTE ON FUNCTION public.club_owner_id_for_short(text) TO authenticated;

-- ---------------------------------------------------------------------------
-- Admin set / unset — reset continuous streak on lapse
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_owner_set_supporter(
  p_owner_id uuid,
  p_is_supporter boolean,
  p_note text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_uid uuid := p_owner_id;
  v_was boolean;
  v_active boolean;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'owner_id required';
  END IF;

  INSERT INTO public.gpsl_owner_registry (owner_id, status, status_changed_at)
  VALUES (v_uid, 'on_break', now())
  ON CONFLICT (owner_id) DO NOTHING;

  SELECT r.is_supporter INTO v_was
  FROM public.gpsl_owner_registry r
  WHERE r.owner_id = v_uid;

  IF coalesce(p_is_supporter, false) THEN
    UPDATE public.gpsl_owner_registry
    SET is_supporter = true,
        supporter_since = coalesce(supporter_since, now()),
        supporter_continuous_since = CASE
          WHEN coalesce(v_was, false) THEN coalesce(supporter_continuous_since, now())
          ELSE now()
        END,
        supporter_anniv_milestones_paid = CASE
          WHEN coalesce(v_was, false) THEN supporter_anniv_milestones_paid
          ELSE 0
        END,
        supporter_unset_at = NULL,
        supporter_grace_until = NULL,
        supporter_note = coalesce(nullif(btrim(p_note), ''), supporter_note)
    WHERE owner_id = v_uid;
  ELSE
    UPDATE public.gpsl_owner_registry
    SET is_supporter = false,
        supporter_unset_at = now(),
        supporter_grace_until = NULL,
        supporter_continuous_since = NULL,
        supporter_anniv_milestones_paid = 0,
        supporter_note = coalesce(nullif(btrim(p_note), ''), supporter_note)
    WHERE owner_id = v_uid;
  END IF;

  v_active := public.owner_is_supporter_active(v_uid);

  IF NOT v_active THEN
    PERFORM public.supporter_disable_club_theme(v_uid);
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'owner_id', v_uid,
    'is_supporter', coalesce(p_is_supporter, false),
    'supporter_active', v_active,
    'continuous_days', public.owner_supporter_continuous_days(v_uid),
    'supporter_grace_until', (
      SELECT supporter_grace_until FROM public.gpsl_owner_registry WHERE owner_id = v_uid
    )
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.admin_owner_set_supporter(uuid, boolean, text) TO authenticated;

-- ---------------------------------------------------------------------------
-- Anniversary credits (every 6 continuous months → ₿2,500)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.supporter_credit_anniversary_milestones(p_owner_id uuid DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_today date := public.supporter_london_today();
  v_row record;
  v_days int;
  v_due int;
  v_pay int;
  v_i int;
  v_credited int := 0;
  v_amount numeric := 2500;
  v_ledger bigint;
BEGIN
  FOR v_row IN
    SELECT r.owner_id, r.supporter_continuous_since, r.supporter_anniv_milestones_paid
    FROM public.gpsl_owner_registry r
    WHERE r.is_supporter = true
      AND r.supporter_continuous_since IS NOT NULL
      AND (p_owner_id IS NULL OR r.owner_id = p_owner_id)
  LOOP
    v_days := public.owner_supporter_continuous_days(v_row.owner_id);
    -- ~182.5 days ≈ 6 months; use 183 calendar days per milestone
    v_due := greatest(0, floor(v_days / 183.0)::int);
    v_pay := greatest(0, v_due - coalesce(v_row.supporter_anniv_milestones_paid, 0));
    -- Cap catch-up to 2 milestones at a time (6m + 12m)
    v_pay := least(v_pay, 2);

    FOR v_i IN 1..v_pay LOOP
      BEGIN
        PERFORM public.owner_wallet_ensure(v_row.owner_id);
        v_ledger := public._post_owner_ledger_internal(
          v_row.owner_id,
          'supporter_anniversary_credit',
          v_amount,
          format(
            'Ko-fi Supporter — %s-month continuous membership gift',
            (coalesce(v_row.supporter_anniv_milestones_paid, 0) + v_i) * 6
          ),
          jsonb_build_object(
            'source', 'ko_fi_supporter_anniversary',
            'milestone_index', coalesce(v_row.supporter_anniv_milestones_paid, 0) + v_i,
            'continuous_days', v_days,
            'london_date', v_today
          ),
          NULL,
          true
        );
        UPDATE public.gpsl_owner_registry
        SET supporter_anniv_milestones_paid = coalesce(supporter_anniv_milestones_paid, 0) + 1
        WHERE owner_id = v_row.owner_id;
        v_credited := v_credited + 1;
      EXCEPTION WHEN OTHERS THEN
        NULL;
      END;
    END LOOP;
  END LOOP;

  RETURN jsonb_build_object('ok', true, 'credited', v_credited, 'london_date', v_today);
END;
$function$;

REVOKE ALL ON FUNCTION public.supporter_credit_anniversary_milestones(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.supporter_credit_anniversary_milestones(uuid) TO authenticated;

-- Hook into monthly tick (1st credits + lapse + anniversary)
CREATE OR REPLACE FUNCTION public.supporter_month_tick()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_today date := public.supporter_london_today();
  v_ym text := public.supporter_london_ym(v_today);
  v_credited int := 0;
  v_skipped int := 0;
  v_lapsed int := 0;
  v_row record;
  v_ledger bigint;
  v_anniv jsonb;
BEGIN
  IF extract(day from v_today) = 1 THEN
    FOR v_row IN
      SELECT r.owner_id
      FROM public.gpsl_owner_registry r
      WHERE r.is_supporter = true
        AND coalesce(r.supporter_credit_ym, '') IS DISTINCT FROM v_ym
    LOOP
      BEGIN
        PERFORM public.owner_wallet_ensure(v_row.owner_id);
        v_ledger := public._post_owner_ledger_internal(
          v_row.owner_id,
          'supporter_monthly_credit',
          1000,
          'Ko-fi Supporter — monthly Building Society credit',
          jsonb_build_object(
            'source', 'ko_fi_supporter',
            'credit_ym', v_ym
          ),
          NULL,
          true
        );
        UPDATE public.gpsl_owner_registry
        SET supporter_credit_ym = v_ym
        WHERE owner_id = v_row.owner_id;
        v_credited := v_credited + 1;
      EXCEPTION WHEN OTHERS THEN
        v_skipped := v_skipped + 1;
      END;
    END LOOP;
  END IF;

  -- Anniversary gifts (any day the tick runs — cron / admin)
  BEGIN
    v_anniv := public.supporter_credit_anniversary_milestones(NULL);
  EXCEPTION WHEN OTHERS THEN
    v_anniv := jsonb_build_object('ok', false, 'error', SQLERRM);
  END;

  FOR v_row IN
    SELECT r.owner_id
    FROM public.gpsl_owner_registry r
    WHERE r.is_supporter = false
      AND r.supporter_grace_until IS NOT NULL
      AND r.supporter_grace_until < v_today
  LOOP
    PERFORM public.supporter_disable_club_theme(v_row.owner_id);
    UPDATE public.gpsl_owner_registry
    SET supporter_grace_until = NULL,
        supporter_continuous_since = NULL,
        supporter_anniv_milestones_paid = 0
    WHERE owner_id = v_row.owner_id;
    v_lapsed := v_lapsed + 1;
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true,
    'london_date', v_today,
    'credit_ym', v_ym,
    'credited', v_credited,
    'credit_errors', v_skipped,
    'lapsed', v_lapsed,
    'anniversary', v_anniv
  );
END;
$function$;

-- ---------------------------------------------------------------------------
-- Friendlies gate: supporter uplift + season cap
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.gpsl_friendlies_payout_amount()
RETURNS numeric
LANGUAGE sql
IMMUTABLE
AS $$ SELECT 5000::numeric; $$;

CREATE OR REPLACE FUNCTION public.gpsl_friendlies_supporter_payout_amount()
RETURNS numeric
LANGUAGE sql
IMMUTABLE
AS $$ SELECT 15000::numeric; $$;

CREATE OR REPLACE FUNCTION public.gpsl_friendlies_supporter_boost_count()
RETURNS int
LANGUAGE sql
IMMUTABLE
AS $$ SELECT 10; $$;

CREATE OR REPLACE FUNCTION public.gpsl_friendlies_season_cap()
RETURNS numeric
LANGUAGE sql
IMMUTABLE
AS $$ SELECT 1200000::numeric; $$;

CREATE OR REPLACE FUNCTION public.gpsl_friendlies_supporter_season_cap()
RETURNS numeric
LANGUAGE sql
IMMUTABLE
AS $$ SELECT 2000000::numeric; $$;

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
  v_owner uuid;
  v_supporter boolean := false;
  v_amount numeric;
  v_month_cap int := public.gpsl_friendlies_month_cap();
  v_boost_n int := public.gpsl_friendlies_supporter_boost_count();
  v_season_cap numeric;
  v_month_count int;
  v_season_total numeric;
  v_desc text;
BEGIN
  v_owner := public.club_owner_id_for_short(p_club);
  IF v_owner IS NOT NULL THEN
    v_supporter := public.owner_is_supporter_active(v_owner);
  END IF;

  v_month_count := public.gpsl_friendlies_month_paid_count(
    p_season_id, p_gpsl_month, p_club
  );
  IF v_month_count >= v_month_cap THEN
    RETURN jsonb_build_object(
      'paid', 0,
      'skipped', format('Month cap reached (%s friendlies)', v_month_cap)
    );
  END IF;

  IF v_supporter AND v_month_count < v_boost_n THEN
    v_amount := public.gpsl_friendlies_supporter_payout_amount();
  ELSE
    v_amount := public.gpsl_friendlies_payout_amount();
  END IF;

  v_season_cap := CASE
    WHEN v_supporter THEN public.gpsl_friendlies_supporter_season_cap()
    ELSE public.gpsl_friendlies_season_cap()
  END;

  v_season_total := public.gpsl_friendlies_season_paid_total(p_season_id, p_club);
  IF v_season_total + v_amount > v_season_cap THEN
    RETURN jsonb_build_object(
      'paid', 0,
      'skipped', format('Season cap reached (₿%s)', to_char(v_season_cap, 'FM999,999,999'))
    );
  END IF;

  v_desc := format(
    'Friendly gate — %s · %s%s',
    p_scoreline,
    public.competition_gpsl_month_label(p_gpsl_month),
    CASE WHEN v_supporter AND v_month_count < v_boost_n THEN ' · Supporter' ELSE '' END
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
      'scoreline', p_scoreline,
      'supporter_boost', (v_supporter AND v_month_count < v_boost_n),
      'owner_id', v_owner
    )
  );

  RETURN jsonb_build_object(
    'paid', v_amount,
    'skipped', NULL,
    'supporter_boost', (v_supporter AND v_month_count < v_boost_n)
  );
END;
$function$;

-- Club friendlies page: expose supporter rates / cap for the viewing owner
CREATE OR REPLACE FUNCTION public.club_friendlies_my_club()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := upper(nullif(btrim(coalesce(public.my_club_shortname(), '')), ''));
  v_uid uuid := auth.uid();
  v_season_id bigint;
  v_active_month text;
  v_season_paid numeric := 0;
  v_supporter boolean := false;
BEGIN
  IF v_club IS NULL THEN
    RETURN jsonb_build_object(
      'ok', false,
      'reason', 'No club linked to this login',
      'club', NULL,
      'months', '[]'::jsonb
    );
  END IF;

  IF v_uid IS NOT NULL THEN
    v_supporter := public.owner_is_supporter_active(v_uid);
  END IF;

  v_season_id := public.gpsl_friendlies_live_season_id();
  IF v_season_id IS NULL THEN
    SELECT id INTO v_season_id
    FROM public.competition_seasons
    WHERE is_current = true
    ORDER BY id DESC
    LIMIT 1;
  END IF;

  IF v_season_id IS NOT NULL THEN
    v_active_month := public.competition_active_gpsl_month(v_season_id, now());
    v_season_paid := public.gpsl_friendlies_season_paid_total(v_season_id, v_club);
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'club', v_club,
    'season_id', v_season_id,
    'active_gpsl_month', v_active_month,
    'active_gpsl_month_label', CASE
      WHEN v_active_month IS NULL THEN NULL
      ELSE public.competition_gpsl_month_label(v_active_month)
    END,
    'supporter_active', v_supporter,
    'payout_amount', public.gpsl_friendlies_payout_amount(),
    'supporter_payout_amount', public.gpsl_friendlies_supporter_payout_amount(),
    'supporter_boost_count', public.gpsl_friendlies_supporter_boost_count(),
    'month_cap', public.gpsl_friendlies_month_cap(),
    'season_cap', CASE
      WHEN v_supporter THEN public.gpsl_friendlies_supporter_season_cap()
      ELSE public.gpsl_friendlies_season_cap()
    END,
    'season_cap_standard', public.gpsl_friendlies_season_cap(),
    'season_cap_supporter', public.gpsl_friendlies_supporter_season_cap(),
    'season_paid_total', v_season_paid,
    'months', coalesce((
      SELECT jsonb_agg(m.month_obj ORDER BY m.sort_order)
      FROM (
        SELECT
          x.gpsl_month,
          public.competition_gpsl_month_sort(x.gpsl_month) AS sort_order,
          jsonb_build_object(
            'gpsl_month', x.gpsl_month,
            'gpsl_month_label', public.competition_gpsl_month_label(x.gpsl_month),
            'paid_count', (
              SELECT count(*)::int
              FROM public.gpsl_friendlies f2
              WHERE f2.season_id = v_season_id
                AND f2.gpsl_month = x.gpsl_month
                AND (
                  (upper(f2.club_left) = v_club AND f2.paid_left > 0)
                  OR (upper(f2.club_right) = v_club AND f2.paid_right > 0)
                )
            ),
            'month_cap', public.gpsl_friendlies_month_cap(),
            'friendlies', coalesce((
              SELECT jsonb_agg(row_to_json(t)::jsonb ORDER BY t.confirmed_at DESC)
              FROM (
                SELECT
                  f.id,
                  'confirmed'::text AS status,
                  f.gpsl_month,
                  f.club_left,
                  lc."Club" AS club_left_name,
                  f.score_left,
                  f.club_right,
                  rc."Club" AS club_right_name,
                  f.score_right,
                  coalesce(nullif(btrim(lc."Stadium"), ''), lc."Club", f.club_left) AS stadium,
                  f.confirmed_at,
                  (upper(f.club_left) = v_club) AS is_home,
                  CASE
                    WHEN upper(f.club_left) = v_club THEN f.paid_left
                    ELSE f.paid_right
                  END AS my_payout,
                  CASE
                    WHEN upper(f.club_left) = v_club THEN f.left_skipped_reason
                    ELSE f.right_skipped_reason
                  END AS my_payout_skipped
                FROM public.gpsl_friendlies f
                LEFT JOIN public."Clubs" lc ON upper(lc."ShortName") = upper(f.club_left)
                LEFT JOIN public."Clubs" rc ON upper(rc."ShortName") = upper(f.club_right)
                WHERE f.season_id = v_season_id
                  AND f.gpsl_month = x.gpsl_month
                  AND (
                    upper(f.club_left) = v_club
                    OR upper(f.club_right) = v_club
                  )
              ) t
            ), '[]'::jsonb),
            'pending', coalesce((
              SELECT jsonb_agg(row_to_json(p)::jsonb ORDER BY p.posted_at DESC)
              FROM (
                SELECT
                  r.id,
                  'pending'::text AS status,
                  r.gpsl_month,
                  r.reporter_club_short_name,
                  r.club_left,
                  lc."Club" AS club_left_name,
                  r.score_left,
                  r.club_right,
                  rc."Club" AS club_right_name,
                  r.score_right,
                  coalesce(nullif(btrim(lc."Stadium"), ''), lc."Club", r.club_left) AS stadium,
                  r.posted_at,
                  (upper(r.club_left) = v_club) AS is_home,
                  (upper(r.reporter_club_short_name) = v_club) AS i_reported
                FROM public.gpsl_friendly_reports r
                LEFT JOIN public."Clubs" lc ON upper(lc."ShortName") = upper(r.club_left)
                LEFT JOIN public."Clubs" rc ON upper(rc."ShortName") = upper(r.club_right)
                WHERE r.season_id = v_season_id
                  AND r.gpsl_month = x.gpsl_month
                  AND r.status = 'pending'
                  AND (
                    upper(r.club_left) = v_club
                    OR upper(r.club_right) = v_club
                  )
              ) p
            ), '[]'::jsonb)
          ) AS month_obj
        FROM (
          SELECT DISTINCT f.gpsl_month
          FROM public.gpsl_friendlies f
          WHERE f.season_id = v_season_id
            AND (upper(f.club_left) = v_club OR upper(f.club_right) = v_club)
          UNION
          SELECT DISTINCT r.gpsl_month
          FROM public.gpsl_friendly_reports r
          WHERE r.season_id = v_season_id
            AND r.status = 'pending'
            AND (upper(r.club_left) = v_club OR upper(r.club_right) = v_club)
        ) x
      ) m
    ), '[]'::jsonb)
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.club_friendlies_my_club() TO authenticated;

-- ---------------------------------------------------------------------------
-- Mid-season pack (November lock): 2× −2 consult + 5% fee discount
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.supporter_grant_mid_season_pack(
  p_season_id bigint,
  p_owner_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season bigint := p_season_id;
  v_row record;
  v_club text;
  v_granted int := 0;
  v_skipped int := 0;
  v_ids jsonb := '[]'::jsonb;
  v_id bigint;
  v_i int;
  v_meta jsonb;
BEGIN
  IF v_season IS NULL THEN
    RAISE EXCEPTION 'season_id required';
  END IF;

  FOR v_row IN
    SELECT r.owner_id
    FROM public.gpsl_owner_registry r
    WHERE r.is_supporter = true
      AND public.owner_supporter_meets_tenure(r.owner_id, 60)
      AND (p_owner_id IS NULL OR r.owner_id = p_owner_id)
  LOOP
    IF EXISTS (
      SELECT 1 FROM public.supporter_season_perk_grants g
      WHERE g.owner_id = v_row.owner_id
        AND g.season_id = v_season
        AND g.perk_kind = 'mid_season_pack'
    ) THEN
      v_skipped := v_skipped + 1;
      CONTINUE;
    END IF;

    SELECT upper(c."ShortName") INTO v_club
    FROM public."Clubs" c
    WHERE c.owner_id = v_row.owner_id
      AND coalesce(c.is_archived, false) = false
    ORDER BY c."ShortName"
    LIMIT 1;

    IF v_club IS NULL THEN
      v_skipped := v_skipped + 1;
      CONTINUE;
    END IF;

    v_meta := jsonb_build_object(
      'source', 'supporter_mid_season',
      'requires_supporter_active', true,
      'season_id', v_season
    );

    -- Two −2 specialist consults (prize inventory → named consults)
    FOR v_i IN 1..2 LOOP
      IF to_regprocedure(
        'public.prize_grant_inventory_item(text,text,int,text,bigint,text,jsonb)'
      ) IS NOT NULL THEN
        v_id := public.prize_grant_inventory_item(
          v_club, 'medical_token', 2,
          'supporter_mid_season', v_season, 'mid', v_meta
        );
        v_ids := v_ids || jsonb_build_array(jsonb_build_object(
          'type', 'medical_token', 'param', 2, 'id', v_id, 'club', v_club
        ));
      END IF;
    END LOOP;

    -- One 5% fee discount
    IF to_regprocedure(
      'public.prize_grant_inventory_item(text,text,int,text,bigint,text,jsonb)'
    ) IS NOT NULL THEN
      v_id := public.prize_grant_inventory_item(
        v_club, 'fee_discount', 5,
        'supporter_mid_season', v_season, 'mid', v_meta
      );
      v_ids := v_ids || jsonb_build_array(jsonb_build_object(
        'type', 'fee_discount', 'param', 5, 'id', v_id, 'club', v_club
      ));
    END IF;

    INSERT INTO public.supporter_season_perk_grants (
      owner_id, season_id, perk_kind, club_short_name, metadata
    ) VALUES (
      v_row.owner_id, v_season, 'mid_season_pack', v_club,
      jsonb_build_object('items', v_ids)
    )
    ON CONFLICT DO NOTHING;

    v_granted := v_granted + 1;
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true,
    'season_id', v_season,
    'granted', v_granted,
    'skipped', v_skipped
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.supporter_on_gpsl_month_lock(
  p_season_id bigint,
  p_gpsl_month text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_month text := lower(btrim(coalesce(p_gpsl_month, '')));
BEGIN
  -- Mid-season = after first half (June–November) locks
  IF v_month <> 'november' THEN
    RETURN jsonb_build_object(
      'ok', true,
      'skipped', true,
      'reason', 'not_mid_season_month',
      'gpsl_month', v_month
    );
  END IF;

  RETURN public.supporter_grant_mid_season_pack(p_season_id, NULL)
    || jsonb_build_object('gpsl_month', v_month);
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_supporter_grant_mid_season_pack_now(
  p_season_id bigint DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season bigint := p_season_id;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;
  IF v_season IS NULL THEN
    SELECT id INTO v_season
    FROM public.competition_seasons
    WHERE is_current = true
    ORDER BY id DESC
    LIMIT 1;
  END IF;
  IF v_season IS NULL THEN
    RAISE EXCEPTION 'No current season';
  END IF;
  RETURN public.supporter_grant_mid_season_pack(v_season, NULL);
END;
$function$;

REVOKE ALL ON FUNCTION public.supporter_grant_mid_season_pack(bigint, uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.supporter_on_gpsl_month_lock(bigint, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_supporter_grant_mid_season_pack_now(bigint) TO authenticated;

-- Wire into month lock (safe re-run)
DO $wire$
DECLARE
  v_oid oid;
  v_def text;
  v_marker text := 'supporter_on_gpsl_month_lock';
  v_insert text;
  v_new text;
BEGIN
  v_oid := to_regprocedure('public.competition_run_month_lock_jobs(bigint,boolean,text,text)');
  IF v_oid IS NULL THEN
    RAISE NOTICE 'competition_run_month_lock_jobs missing — mid-season wire skipped';
    RETURN;
  END IF;

  v_def := pg_get_functiondef(v_oid);
  v_def := replace(replace(v_def, E'\r\n', E'\n'), E'\r', E'\n');

  IF position(v_marker IN v_def) > 0 THEN
    RAISE NOTICE 'Supporter mid-season pack already wired into month-lock jobs';
    RETURN;
  END IF;

  v_insert :=
    E'  -- Ko-fi mid-season supporter pack (November lock)\n'
    || E'  IF coalesce(v_month, '''') = ''november''\n'
    || E'     AND coalesce(nullif(v_stage, ''''), ''all'') IN (''all'', ''tables'', ''league_tables'', ''awards'', ''friendlies'')\n'
    || E'  THEN\n'
    || E'    BEGIN\n'
    || E'      IF to_regprocedure(''public.supporter_on_gpsl_month_lock(bigint,text)'') IS NOT NULL THEN\n'
    || E'        v_out := v_out || jsonb_build_object(\n'
    || E'          ''supporter_mid_season'',\n'
    || E'          public.supporter_on_gpsl_month_lock(p_season_id, v_month)\n'
    || E'        );\n'
    || E'      END IF;\n'
    || E'    EXCEPTION WHEN OTHERS THEN\n'
    || E'      v_out := v_out || jsonb_build_object(\n'
    || E'        ''supporter_mid_season'', jsonb_build_object(''ok'', false, ''error'', SQLERRM)\n'
    || E'      );\n'
    || E'    END;\n'
    || E'  END IF;\n\n';

  IF v_def !~ E'RETURN v_out;[[:space:]]*END;[[:space:]]*\\$function\\$[[:space:]]*$' THEN
    RAISE NOTICE 'Could not wire supporter mid-season — RETURN v_out ending not found';
    RETURN;
  END IF;

  v_new := regexp_replace(
    v_def,
    E'RETURN v_out;[[:space:]]*END;[[:space:]]*\\$function\\$[[:space:]]*$',
    v_insert || E'  RETURN v_out;\n\nEND;\n$function$\n'
  );

  IF v_new IS NOT DISTINCT FROM v_def OR position(v_marker IN v_new) = 0 THEN
    RAISE NOTICE 'Supporter mid-season wire replace failed';
    RETURN;
  END IF;

  EXECUTE v_new;
  RAISE NOTICE 'Wired supporter mid-season pack into competition_run_month_lock_jobs';
END;
$wire$;

-- ---------------------------------------------------------------------------
-- Free club swap: require 60 continuous days (patch live function in place)
-- ---------------------------------------------------------------------------
DO $swap_tenure$
DECLARE
  v_oid oid;
  v_def text;
  v_old text := 'v_supporter := public.owner_is_supporter_active(v_uid);';
  v_new text :=
    'v_supporter := public.owner_is_supporter_active(v_uid)'
    || E'\n    AND public.owner_supporter_meets_tenure(v_uid, 60);';
BEGIN
  v_oid := to_regprocedure('public.owner_club_swap_execute(text)');
  IF v_oid IS NULL THEN
    RAISE NOTICE 'owner_club_swap_execute missing — tenure gate skipped';
    RETURN;
  END IF;
  v_def := pg_get_functiondef(v_oid);
  IF position('owner_supporter_meets_tenure' IN v_def) > 0 THEN
    RAISE NOTICE 'Free club swap tenure gate already present';
    RETURN;
  END IF;
  IF position(v_old IN v_def) = 0 THEN
    RAISE NOTICE 'Could not locate supporter assignment in owner_club_swap_execute';
    RETURN;
  END IF;
  EXECUTE replace(v_def, v_old, v_new);
  RAISE NOTICE 'Free club swap now requires 60 continuous supporter days';
END;
$swap_tenure$;

-- ---------------------------------------------------------------------------
-- Supporter-sourced tokens: usable only while supporter-active
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.prize_item_requires_supporter(p_source text, p_metadata jsonb)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT coalesce(p_source, '') LIKE 'supporter_%'
      OR coalesce(p_metadata->>'requires_supporter_active', '') IN ('true', 't', '1');
$$;

-- Wrap fee-discount lock with supporter gate (replace body; keep signature)
CREATE OR REPLACE FUNCTION public.prize_lock_fee_discount(
  p_inventory_id bigint,
  p_context_kind text,
  p_context_id bigint
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := public.my_club_shortname();
  v_uid uuid := auth.uid();
  v_row public.club_prize_inventory%rowtype;
BEGIN
  IF v_club IS NULL THEN RAISE EXCEPTION 'No club linked'; END IF;
  IF p_context_kind NOT IN ('listing', 'special_auction', 'draft_listing') THEN
    RAISE EXCEPTION 'Invalid context kind';
  END IF;
  IF p_context_id IS NULL THEN
    RAISE EXCEPTION 'Context id required';
  END IF;

  UPDATE public.club_prize_inventory
  SET status = 'available',
      locked_context = NULL,
      updated_at = now()
  WHERE club_short_name = v_club
    AND prize_type = 'fee_discount'
    AND status = 'locked';

  SELECT * INTO v_row
  FROM public.club_prize_inventory
  WHERE id = p_inventory_id
  FOR UPDATE;

  IF NOT FOUND OR v_row.club_short_name IS DISTINCT FROM v_club THEN
    RAISE EXCEPTION 'Discount token not found';
  END IF;
  IF v_row.prize_type <> 'fee_discount' OR v_row.status <> 'available' THEN
    RAISE EXCEPTION 'Token not available';
  END IF;

  IF public.prize_item_requires_supporter(v_row.source, v_row.metadata)
     AND NOT public.owner_is_supporter_active(v_uid) THEN
    RAISE EXCEPTION 'This fee discount is a Ko-fi Supporter perk — resubscribe to use it';
  END IF;

  UPDATE public.club_prize_inventory
  SET status = 'locked',
      locked_context = jsonb_build_object(
        'kind', p_context_kind,
        'id', p_context_id
      ),
      updated_at = now()
  WHERE id = p_inventory_id;

  RETURN jsonb_build_object(
    'ok', true,
    'inventory_id', p_inventory_id,
    'discount_pct', v_row.param_int,
    'context_kind', p_context_kind,
    'context_id', p_context_id
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.prize_lock_fee_discount(bigint, text, bigint) TO authenticated;

-- Self status: free swap needs 60 continuous days
DO $self_tenure$
DECLARE
  v_oid oid;
  v_def text;
  v_old text :=
    '''can_free_club_swap'', v_supporter_active AND v_has_club AND NOT v_free_swap_used,';
  v_new text :=
    '''can_free_club_swap'', v_supporter_active AND v_has_club AND NOT v_free_swap_used'
    || E'\n      AND public.owner_supporter_meets_tenure(auth.uid(), 60),';
BEGIN
  v_oid := to_regprocedure('public.owner_registry_get_self()');
  IF v_oid IS NULL THEN
    RETURN;
  END IF;
  v_def := pg_get_functiondef(v_oid);
  IF position('owner_supporter_meets_tenure(auth.uid()' IN v_def) > 0 THEN
    RETURN;
  END IF;
  IF position(v_old IN v_def) = 0 THEN
    RAISE NOTICE 'owner_registry_get_self can_free_club_swap line not found';
    RETURN;
  END IF;
  EXECUTE replace(v_def, v_old, v_new);
END;
$self_tenure$;

-- Medical apply: block supporter-sourced consults when lapsed
DO $med_gate$
DECLARE
  v_oid oid;
  v_def text;
BEGIN
  v_oid := to_regprocedure(
    'public.medical_apply_specialist_token(bigint,bigint,boolean,bigint)'
  );
  IF v_oid IS NULL THEN
    RAISE NOTICE 'medical_apply_specialist_token missing — supporter use gate skipped';
    RETURN;
  END IF;
  v_def := pg_get_functiondef(v_oid);
  IF position('supporter_mid_season_use_gate' IN v_def) > 0 THEN
    RETURN;
  END IF;
  IF position(
    'IF NOT FOUND OR v_consult.club_short_name IS DISTINCT FROM v_club THEN'
    IN v_def
  ) = 0 THEN
    RAISE NOTICE 'Could not inject medical supporter use gate';
    RETURN;
  END IF;
  v_def := replace(
    v_def,
    'IF NOT FOUND OR v_consult.club_short_name IS DISTINCT FROM v_club THEN',
    E'-- supporter_mid_season_use_gate\n'
    || E'  IF FOUND AND public.prize_item_requires_supporter(v_consult.source, NULL)\n'
    || E'     AND NOT public.owner_is_supporter_active(auth.uid()) THEN\n'
    || E'    RAISE EXCEPTION ''This specialist consult is a Ko-fi Supporter perk — resubscribe to use it'';\n'
    || E'  END IF;\n'
    || E'  IF NOT FOUND OR v_consult.club_short_name IS DISTINCT FROM v_club THEN'
  );
  EXECUTE v_def;
  RAISE NOTICE 'Medical apply gated for supporter-sourced consults';
EXCEPTION WHEN OTHERS THEN
  RAISE NOTICE 'Medical supporter use gate skipped: %', SQLERRM;
END;
$med_gate$;

NOTIFY pgrst, 'reload schema';
