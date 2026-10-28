-- =============================================================================
-- Friendlies supporter gate boost — ensure live pay + retro top-up (2026-10-28)
--
-- Rule (supporters): first 10 paid friendlies / GPSL month → ₿15,000;
--                     11–20 → ₿5,000. Standard always ₿5,000.
--
-- Issue: August friendlies for supporters still paid ₿5,000 (8th should be
-- ₿15,000). June / July pre-dated the perk and need the same uplift on the
-- first 10 paid per club per month.
--
-- This patch:
--   1) Re-applies gpsl_friendlies_pay_club (and amount helpers) so new pays
--      use the boost.
--   2) Tops up underpaid supporter friendlies in june / july / august:
--      credit ₿10,000 delta, bump paid_left/paid_right, ledger top-up row.
--
-- Eligibility: club's *current* owner is supporter-active (incl. grace).
-- Idempotent: skips when paid side already ≥ ₿15,000 or a retro top-up
-- ledger row already exists for that friendly + club.
-- Safe re-run.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1) Amount helpers + pay_club (same as supporter_perks_mid_friendlies_anniv)
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

REVOKE ALL ON FUNCTION public.gpsl_friendlies_pay_club(bigint, text, text, bigint, text)
  FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.gpsl_friendlies_pay_club(bigint, text, text, bigint, text)
  TO service_role, authenticated;

-- ---------------------------------------------------------------------------
-- 2) Retro top-up: first N paid / month for supporter clubs → ₿15k
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_gpsl_friendlies_supporter_boost_retro(
  p_months text[] DEFAULT ARRAY['june', 'july', 'august'],
  p_season_id bigint DEFAULT NULL,
  p_dry_run boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season bigint := p_season_id;
  v_boost_n int := public.gpsl_friendlies_supporter_boost_count();
  v_target numeric := public.gpsl_friendlies_supporter_payout_amount();
  v_standard numeric := public.gpsl_friendlies_payout_amount();
  v_season_cap numeric := public.gpsl_friendlies_supporter_season_cap();
  v_months text[] := coalesce(p_months, ARRAY['june', 'july', 'august']);
  v_month text;
  v_row record;
  v_club text;
  v_owner uuid;
  v_side text;
  v_paid numeric;
  v_delta numeric;
  v_season_total numeric;
  v_scoreline text;
  v_topped int := 0;
  v_skipped int := 0;
  v_capped int := 0;
  v_amount_total numeric := 0;
  v_details jsonb := '[]'::jsonb;
BEGIN
  -- SQL Editor / service_role: auth.uid() is null. Browser: admin only.
  IF auth.uid() IS NOT NULL AND NOT public.is_gpsl_admin() THEN
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
    RETURN jsonb_build_object('ok', false, 'error', 'No current season');
  END IF;

  FOREACH v_month IN ARRAY v_months
  LOOP
    v_month := lower(btrim(v_month));
    IF v_month = '' THEN
      CONTINUE;
    END IF;

    FOR v_row IN
      WITH ranked AS (
        SELECT
          f.id AS friendly_id,
          f.gpsl_month,
          f.club_left,
          f.club_right,
          f.paid_left,
          f.paid_right,
          f.score_left,
          f.score_right,
          f.created_at,
          side.club_short,
          side.paid_amt,
          side.side_key,
          row_number() OVER (
            PARTITION BY side.club_short
            ORDER BY f.id
          ) AS pay_ord
        FROM public.gpsl_friendlies f
        CROSS JOIN LATERAL (
          VALUES
            (upper(btrim(f.club_left)), f.paid_left, 'left'),
            (upper(btrim(f.club_right)), f.paid_right, 'right')
        ) AS side(club_short, paid_amt, side_key)
        WHERE f.season_id = v_season
          AND lower(btrim(f.gpsl_month)) = v_month
          AND side.paid_amt > 0
      )
      SELECT *
      FROM ranked
      WHERE pay_ord <= v_boost_n
      ORDER BY club_short, pay_ord
    LOOP
      v_club := v_row.club_short;
      v_side := v_row.side_key;
      v_paid := coalesce(v_row.paid_amt, 0);

      SELECT c.owner_id INTO v_owner
      FROM public."Clubs" c
      WHERE upper(btrim(c."ShortName")) = v_club
      LIMIT 1;

      IF v_owner IS NULL
         OR NOT public.owner_is_supporter_active(v_owner) THEN
        v_skipped := v_skipped + 1;
        CONTINUE;
      END IF;

      IF v_paid >= v_target THEN
        v_skipped := v_skipped + 1;
        CONTINUE;
      END IF;

      -- Already retro'd for this friendly + club
      IF EXISTS (
        SELECT 1
        FROM public.competition_finance_ledger l
        WHERE l.season_id = v_season
          AND upper(btrim(l.club_short_name)) = v_club
          AND l.entry_type = 'gate_friendlies'
          AND coalesce(l.metadata->>'supporter_boost_retro', '') = 'true'
          AND (l.metadata->>'friendly_id')::bigint = v_row.friendly_id
      ) THEN
        v_skipped := v_skipped + 1;
        CONTINUE;
      END IF;

      v_delta := v_target - v_paid;
      IF v_delta <= 0 THEN
        v_skipped := v_skipped + 1;
        CONTINUE;
      END IF;

      -- Only top up rows that look like the old standard rate (or partial)
      IF v_paid > v_target THEN
        v_skipped := v_skipped + 1;
        CONTINUE;
      END IF;

      v_season_total := public.gpsl_friendlies_season_paid_total(v_season, v_club);
      IF v_season_total + v_delta > v_season_cap THEN
        v_capped := v_capped + 1;
        v_details := v_details || jsonb_build_array(jsonb_build_object(
          'club', v_club,
          'month', v_month,
          'friendly_id', v_row.friendly_id,
          'skipped', 'season_cap',
          'season_paid', v_season_total,
          'delta', v_delta
        ));
        CONTINUE;
      END IF;

      v_scoreline := format(
        '%s %s - %s %s',
        v_row.club_left, v_row.score_left, v_row.score_right, v_row.club_right
      );

      IF NOT p_dry_run THEN
        PERFORM public.competition_credit_club_balance(v_club, v_delta);

        INSERT INTO public.competition_finance_ledger (
          season_id, club_short_name, entry_type, amount, description, metadata
        )
        VALUES (
          v_season,
          v_club,
          'gate_friendlies',
          v_delta,
          format(
            'Friendly gate — supporter boost top-up · %s · %s (#%s)',
            v_scoreline,
            public.competition_gpsl_month_label(v_month),
            v_row.pay_ord
          ),
          jsonb_build_object(
            'friendly_id', v_row.friendly_id,
            'gpsl_month', v_month,
            'scoreline', v_scoreline,
            'supporter_boost', true,
            'supporter_boost_retro', true,
            'pay_ord', v_row.pay_ord,
            'prior_paid', v_paid,
            'target_paid', v_target,
            'owner_id', v_owner
          )
        );

        IF v_side = 'left' THEN
          UPDATE public.gpsl_friendlies
          SET paid_left = v_target
          WHERE id = v_row.friendly_id;
        ELSE
          UPDATE public.gpsl_friendlies
          SET paid_right = v_target
          WHERE id = v_row.friendly_id;
        END IF;
      END IF;

      v_topped := v_topped + 1;
      v_amount_total := v_amount_total + v_delta;
      v_details := v_details || jsonb_build_array(jsonb_build_object(
        'club', v_club,
        'month', v_month,
        'friendly_id', v_row.friendly_id,
        'pay_ord', v_row.pay_ord,
        'prior_paid', v_paid,
        'delta', v_delta,
        'side', v_side
      ));
    END LOOP;
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true,
    'dry_run', p_dry_run,
    'season_id', v_season,
    'months', to_jsonb(v_months),
    'boost_count', v_boost_n,
    'target_amount', v_target,
    'standard_amount', v_standard,
    'topped_up', v_topped,
    'skipped', v_skipped,
    'season_cap_blocked', v_capped,
    'total_credited', v_amount_total,
    'details', v_details
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.admin_gpsl_friendlies_supporter_boost_retro(text[], bigint, boolean)
  FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_gpsl_friendlies_supporter_boost_retro(text[], bigint, boolean)
  TO service_role, authenticated;

COMMENT ON FUNCTION public.admin_gpsl_friendlies_supporter_boost_retro(text[], bigint, boolean) IS
  'Top up underpaid supporter friendlies (first 10/month) to ₿15,000 for june/july/august. Idempotent.';

-- ---------------------------------------------------------------------------
-- 3) DIAGNOSE (preview) then APPLY
-- ---------------------------------------------------------------------------
-- Preview:
SELECT public.admin_gpsl_friendlies_supporter_boost_retro(
  ARRAY['june', 'july', 'august'],
  NULL,
  true
) AS dry_run;

-- Apply:
SELECT public.admin_gpsl_friendlies_supporter_boost_retro(
  ARRAY['june', 'july', 'august'],
  NULL,
  false
) AS applied;

-- Spot-check: any remaining first-10 underpays for active supporters
WITH season AS (
  SELECT id FROM public.competition_seasons WHERE is_current = true ORDER BY id DESC LIMIT 1
),
ranked AS (
  SELECT
    f.id,
    f.gpsl_month,
    side.club_short,
    side.paid_amt,
    row_number() OVER (
      PARTITION BY lower(f.gpsl_month), side.club_short
      ORDER BY f.id
    ) AS pay_ord,
    c.owner_id
  FROM public.gpsl_friendlies f
  CROSS JOIN LATERAL (
    VALUES
      (upper(btrim(f.club_left)), f.paid_left),
      (upper(btrim(f.club_right)), f.paid_right)
  ) AS side(club_short, paid_amt)
  JOIN public."Clubs" c ON upper(btrim(c."ShortName")) = side.club_short
  WHERE f.season_id = (SELECT id FROM season)
    AND lower(btrim(f.gpsl_month)) IN ('june', 'july', 'august')
    AND side.paid_amt > 0
)
SELECT
  gpsl_month,
  club_short,
  id AS friendly_id,
  pay_ord,
  paid_amt,
  public.owner_is_supporter_active(owner_id) AS supporter
FROM ranked
WHERE pay_ord <= public.gpsl_friendlies_supporter_boost_count()
  AND paid_amt < public.gpsl_friendlies_supporter_payout_amount()
  AND public.owner_is_supporter_active(owner_id)
ORDER BY gpsl_month, club_short, pay_ord;
