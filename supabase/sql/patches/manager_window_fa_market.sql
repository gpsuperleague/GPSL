-- =============================================================================
-- Manager window FA market + list/sack in all TW months + mid-season sack lock
--
-- 1) At start of June / July / August / January: put 10 random free-agent
--    managers on Manager Market (listing_type=window_fa, seller NULL).
--    Fresh batch each month — prior unsold window_fa rows are closed.
--    Listings run until signed or the GPSL month locks; short auctions renew
--    while the month is still active.
-- 2) Settlement: fee → buyer only (league FA), vacant club only — same idea
--    as draft FA. Wired into transferengine_run_report.
-- 3) List + sack allowed in June / July / August / January (TW open for
--    August & January; June/July always during those months).
-- 4) Cannot sack immediately: summer signings first eligible in January;
--    January signings first eligible in the next season's June–August.
--
-- Run after managers_system.sql + new_owner_release_window_june_july.sql
--       + manager_sack_rehire_block.sql (+ calendar / transferengine).
-- Safe re-run.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Schema
-- ---------------------------------------------------------------------------

ALTER TABLE public."Managers"
  ADD COLUMN IF NOT EXISTS signed_gpsl_month text;

COMMENT ON COLUMN public."Managers".signed_gpsl_month IS
  'GPSL month when current club spell started (june/july/august/january/…). Used for mid-season sack lock.';

ALTER TABLE public."Manager_Transfer_Listings"
  ADD COLUMN IF NOT EXISTS metadata jsonb NOT NULL DEFAULT '{}'::jsonb;

DO $$
BEGIN
  ALTER TABLE public."Manager_Transfer_Listings"
    DROP CONSTRAINT IF EXISTS "Manager_Transfer_Listings_listing_type_check";
EXCEPTION WHEN undefined_object THEN
  NULL;
END $$;

ALTER TABLE public."Manager_Transfer_Listings"
  DROP CONSTRAINT IF EXISTS manager_transfer_listings_listing_type_check;

ALTER TABLE public."Manager_Transfer_Listings"
  ADD CONSTRAINT manager_transfer_listings_listing_type_check
  CHECK (listing_type IN ('standard', 'direct', 'draft', 'window_fa'));

-- ---------------------------------------------------------------------------
-- Helpers: transfer months + month lock time
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.manager_transfer_window_months()
RETURNS text[]
LANGUAGE sql
IMMUTABLE
AS $$ SELECT ARRAY['june', 'july', 'august', 'january']; $$;

CREATE OR REPLACE FUNCTION public.manager_is_transfer_window_month(p_month text)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT lower(btrim(coalesce(p_month, ''))) = ANY (public.manager_transfer_window_months());
$$;

CREATE OR REPLACE FUNCTION public.manager_gpsl_month_lock_at(
  p_season_id bigint,
  p_month text
)
RETURNS timestamptz
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT m.lock_at
  FROM public.competition_season_calendar m
  WHERE m.season_id = p_season_id
    AND lower(m.gpsl_month) = lower(btrim(p_month))
  LIMIT 1;
$$;

CREATE OR REPLACE FUNCTION public.manager_list_sack_window_open()
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season_id bigint;
  v_status text;
  v_month text;
  v_tw boolean;
BEGIN
  SELECT s.id, s.status
  INTO v_season_id, v_status
  FROM public.competition_seasons s
  WHERE s.is_current = true
  ORDER BY s.id DESC
  LIMIT 1;

  IF v_season_id IS NULL THEN
    RETURN false;
  END IF;

  IF lower(coalesce(v_status, '')) = 'preseason' THEN
    RETURN true;
  END IF;

  SELECT transfer_window_open INTO v_tw
  FROM public.global_settings WHERE id = 1;

  v_month := lower(coalesce(public.competition_active_gpsl_month(v_season_id, now()), ''));

  IF v_month = '' AND coalesce(v_tw, false) THEN
    RETURN true;
  END IF;

  -- Summer TW months (always while that GPSL month is live)
  IF v_month IN ('june', 'july', 'august') THEN
    RETURN true;
  END IF;

  -- January requires transfer window flag
  IF v_month = 'january' AND coalesce(v_tw, false) THEN
    RETURN true;
  END IF;

  RETURN false;
END;
$function$;

-- Alias used by squad / older callers
CREATE OR REPLACE FUNCTION public.manager_sack_window_open()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT public.manager_list_sack_window_open();
$$;

CREATE OR REPLACE FUNCTION public.manager_signed_cohort(p_month text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE
    WHEN lower(btrim(coalesce(p_month, ''))) = 'january' THEN 'january'
    ELSE 'summer' -- june/july/august/preseason/unknown
  END;
$$;

-- Mid-season lock: first sack only from the far half of the first season in charge.
CREATE OR REPLACE FUNCTION public.manager_sack_tenure_eligible(
  p_signed_season_id bigint,
  p_signed_gpsl_month text,
  p_current_season_id bigint DEFAULT NULL,
  p_current_month text DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season bigint := p_current_season_id;
  v_month text := lower(btrim(coalesce(p_current_month, '')));
  v_cohort text := public.manager_signed_cohort(p_signed_gpsl_month);
BEGIN
  IF p_signed_season_id IS NULL THEN
    RETURN true; -- legacy spells with no stamp
  END IF;

  IF v_season IS NULL THEN
    SELECT id INTO v_season
    FROM public.competition_seasons
    WHERE is_current = true
    ORDER BY id DESC
    LIMIT 1;
  END IF;

  IF v_month = '' THEN
    v_month := lower(coalesce(public.competition_active_gpsl_month(v_season, now()), ''));
  END IF;

  IF v_cohort = 'summer' THEN
    -- Signed June/July/August → first chance January same season, then any later season
    RETURN (v_season > p_signed_season_id)
        OR (v_season = p_signed_season_id AND v_month = 'january');
  END IF;

  -- Signed January → first chance next season's June/July/August (or later)
  RETURN v_season > p_signed_season_id
    AND (
      v_month IN ('june', 'july', 'august', 'january')
      OR v_season > p_signed_season_id + 1
    );
END;
$function$;

-- ---------------------------------------------------------------------------
-- Stamp signed_gpsl_month on assign (wrap via replace of assign)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.manager_assign_to_club(
  p_manager_id bigint,
  p_club_short text,
  p_seasons smallint DEFAULT 2,
  p_fee numeric DEFAULT NULL,
  p_buyer_pays boolean DEFAULT true,
  p_ledger_metadata jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_mgr public."Managers"%rowtype;
  v_existing bigint;
  v_balance numeric;
  v_fee numeric;
  v_season_id bigint;
  v_wage bigint;
  v_meta jsonb;
  v_month text;
  v_kind text := 'assign';
BEGIN
  SELECT * INTO v_mgr FROM public."Managers" WHERE id = p_manager_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Manager not found';
  END IF;

  IF v_mgr.contracted_club IS NOT NULL AND btrim(v_mgr.contracted_club) <> '' THEN
    RAISE EXCEPTION 'Manager already contracted to %', v_mgr.contracted_club;
  END IF;

  IF NOT coalesce((p_ledger_metadata->>'skip_sack_block')::boolean, false)
    AND NOT (
      auth.uid() IS NOT NULL
      AND public.is_gpsl_admin()
    ) THEN
    IF to_regprocedure('public.manager_assert_not_sack_blocked(text, bigint)') IS NOT NULL THEN
      PERFORM public.manager_assert_not_sack_blocked(p_club_short, p_manager_id);
    END IF;
  END IF;

  SELECT m.id INTO v_existing
  FROM public."Managers" m
  WHERE m.contracted_club = p_club_short
  LIMIT 1;

  IF v_existing IS NOT NULL THEN
    RAISE EXCEPTION 'Club already has a manager signed';
  END IF;

  v_fee := coalesce(p_fee, v_mgr.market_value::numeric);

  SELECT id INTO v_season_id
  FROM public.competition_seasons
  WHERE is_current = true
  ORDER BY id DESC
  LIMIT 1;

  v_month := lower(coalesce(public.competition_active_gpsl_month(v_season_id, now()), ''));
  IF v_month = '' THEN
    v_month := 'june';
  END IF;

  IF p_buyer_pays AND v_fee > 0 THEN
    SELECT balance INTO v_balance
    FROM public."Club_Finances"
    WHERE club_name = p_club_short
    FOR UPDATE;

    IF v_balance IS NULL THEN
      RAISE EXCEPTION 'Club finances not found for %', p_club_short;
    END IF;
    -- Debt allowed (manager_signing_allow_debt)

    v_meta := coalesce(p_ledger_metadata, '{}'::jsonb)
      || jsonb_build_object('manager_id', p_manager_id, 'kind', 'manager');

    PERFORM public.post_club_ledger(
      p_club_short,
      'contract_signing_offer',
      -abs(v_fee),
      format('Manager signing — %s', v_mgr.name),
      v_meta,
      v_season_id,
      NULL,
      true,
      true
    );
  END IF;

  v_wage := public.manager_weekly_wage_for(v_mgr.market_value);

  UPDATE public."Managers"
  SET contracted_club = p_club_short,
      contract_seasons_remaining = greatest(coalesce(p_seasons, 2), 1),
      weekly_wage = v_wage,
      signed_season_id = v_season_id,
      signed_gpsl_month = v_month,
      updated_at = now()
  WHERE id = p_manager_id;

  BEGIN
    UPDATE public."Managers"
    SET deal_start_season_id = coalesce(deal_start_season_id, v_season_id)
    WHERE id = p_manager_id;
  EXCEPTION WHEN undefined_column THEN
    NULL;
  END;

  PERFORM public.manager_sync_club_rating(p_club_short);

  UPDATE public."Manager_Transfer_Listings"
  SET status = 'Closed',
      transfer_completed = true,
      updated_at = now()
  WHERE manager_id = p_manager_id
    AND listing_type IN ('draft', 'window_fa')
    AND status = 'Active';

  IF coalesce((p_ledger_metadata->>'manager_draft')::boolean, false)
    OR coalesce(p_ledger_metadata->>'manager_draft', '') IN ('true', 't', '1') THEN
    v_kind := 'draft';
  ELSIF coalesce(p_ledger_metadata->>'source', '') = 'market' THEN
    v_kind := 'market';
  ELSIF coalesce(p_ledger_metadata->>'source', '') = 'admin' THEN
    v_kind := 'admin';
  ELSE
    v_kind := 'market';
  END IF;

  IF to_regprocedure(
    'public.manager_stint_open(bigint, text, numeric, text, bigint, timestamp with time zone)'
  ) IS NOT NULL THEN
    PERFORM public.manager_stint_open(
      p_manager_id,
      p_club_short,
      v_fee,
      v_kind,
      v_season_id,
      now()
    );
  END IF;

  IF to_regprocedure('public.owner_inbox_notify_season_expectations(text)') IS NOT NULL THEN
    PERFORM public.owner_inbox_notify_season_expectations(p_club_short);
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'manager_id', p_manager_id,
    'club', p_club_short,
    'fee', CASE WHEN p_buyer_pays THEN v_fee ELSE 0 END,
    'seasons', greatest(coalesce(p_seasons, 2), 1),
    'weekly_wage', v_wage,
    'signed_gpsl_month', v_month
  );
END;
$function$;

-- ---------------------------------------------------------------------------
-- List / sack (windows + tenure)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.manager_list_for_transfer(p_manager_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text;
  v_mgr public."Managers"%rowtype;
  v_end timestamptz;
  v_listing_id bigint;
  v_season_id bigint;
  v_month text;
  v_lock timestamptz;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  IF NOT public.manager_list_sack_window_open() THEN
    RAISE EXCEPTION
      'Manager listing is only available in June, July, August, or the January transfer window';
  END IF;

  v_club := public.my_club_shortname();
  IF v_club IS NULL THEN
    RAISE EXCEPTION 'No club linked to your account';
  END IF;

  SELECT * INTO v_mgr FROM public."Managers" WHERE id = p_manager_id FOR UPDATE;
  IF NOT FOUND OR v_mgr.contracted_club IS DISTINCT FROM v_club THEN
    RAISE EXCEPTION 'Manager not at your club';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public."Manager_Transfer_Listings"
    WHERE manager_id = p_manager_id AND status = 'Active'
  ) THEN
    RAISE EXCEPTION 'Manager already listed';
  END IF;

  SELECT id INTO v_season_id
  FROM public.competition_seasons WHERE is_current = true ORDER BY id DESC LIMIT 1;

  v_month := lower(coalesce(public.competition_active_gpsl_month(v_season_id, now()), ''));
  v_lock := public.manager_gpsl_month_lock_at(v_season_id, v_month);
  v_end := coalesce(v_lock, now() + interval '7 days');

  INSERT INTO public."Manager_Transfer_Listings" (
    manager_id, seller_club_id, listing_type, status, end_time, market_value, metadata
  )
  VALUES (
    p_manager_id, v_club, 'standard', 'Active', v_end, v_mgr.market_value,
    jsonb_build_object('gpsl_month', v_month, 'season_id', v_season_id)
  )
  RETURNING id INTO v_listing_id;

  RETURN jsonb_build_object('ok', true, 'listing_id', v_listing_id, 'end_time', v_end);
END;
$function$;

CREATE OR REPLACE FUNCTION public.manager_sack()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text;
  v_mgr public."Managers"%rowtype;
  v_payout numeric;
  v_sacks smallint;
  v_season_id bigint;
  v_result jsonb;
  v_month text;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  IF NOT public.manager_list_sack_window_open() THEN
    RAISE EXCEPTION
      'Manager sack is only available in June, July, August, or the January transfer window';
  END IF;

  v_club := public.my_club_shortname();
  IF v_club IS NULL THEN
    RAISE EXCEPTION 'No club linked to your account';
  END IF;

  SELECT manager_sacks_remaining INTO v_sacks
  FROM public."Clubs"
  WHERE "ShortName" = v_club
  FOR UPDATE;

  IF coalesce(v_sacks, 0) < 1 THEN
    RAISE EXCEPTION 'Manager sack already used this season';
  END IF;

  SELECT * INTO v_mgr
  FROM public."Managers"
  WHERE contracted_club = v_club
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'No manager signed at your club';
  END IF;

  SELECT id INTO v_season_id
  FROM public.competition_seasons
  WHERE is_current = true
  ORDER BY id DESC
  LIMIT 1;

  v_month := lower(coalesce(public.competition_active_gpsl_month(v_season_id, now()), ''));

  IF NOT public.manager_sack_tenure_eligible(
    v_mgr.signed_season_id, v_mgr.signed_gpsl_month, v_season_id, v_month
  ) THEN
    RAISE EXCEPTION
      'Cannot sack yet — managers must reach mid-season in their first spell (summer signings: January; January signings: next June–August)';
  END IF;

  v_payout := round(greatest(v_mgr.market_value, 0)::numeric / 2.0, 0);

  UPDATE public."Clubs"
  SET manager_sacks_remaining = 0
  WHERE "ShortName" = v_club;

  v_result := public.manager_release_from_club(
    v_mgr.id,
    v_club,
    v_payout,
    'contract_release_comp',
    format('Manager sack — %s (half MV)', v_mgr.name),
    jsonb_build_object(
      'manager_sack', true,
      'gpsl_month', nullif(v_month, '')
    )
  );

  IF to_regprocedure('public.manager_club_sack_block_record(text, bigint, bigint)') IS NOT NULL THEN
    PERFORM public.manager_club_sack_block_record(v_club, v_mgr.id, v_season_id);
  END IF;

  RETURN v_result;
END;
$function$;

-- ---------------------------------------------------------------------------
-- Window FA market: expire / spawn / renew / settle
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.manager_window_fa_close_batch(
  p_season_id bigint,
  p_keep_month text DEFAULT NULL
)
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_n int;
BEGIN
  UPDATE public."Manager_Transfer_Listings" l
  SET status = 'Closed',
      transfer_completed = false,
      updated_at = now()
  WHERE l.listing_type = 'window_fa'
    AND l.status = 'Active'
    AND (
      p_keep_month IS NULL
      OR coalesce(l.metadata->>'gpsl_month', '') IS DISTINCT FROM lower(btrim(p_keep_month))
      OR coalesce((l.metadata->>'season_id')::bigint, 0) IS DISTINCT FROM p_season_id
    );

  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END;
$function$;

CREATE OR REPLACE FUNCTION public.manager_window_fa_pick_ids(
  p_season_id bigint,
  p_limit int DEFAULT 10
)
RETURNS bigint[]
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_ids bigint[] := ARRAY[]::bigint[];
  v_id bigint;
  v_band text;
  v_need int;
  v_bands text[] := ARRAY['low', 'mid', 'upper', 'elite'];
  v_quotas int[] := ARRAY[2, 3, 3, 2]; -- 10 total; refill from any if short
  v_i int;
BEGIN
  FOR v_i IN 1..4 LOOP
    v_band := v_bands[v_i];
    v_need := v_quotas[v_i];

    FOR v_id IN
      SELECT m.id
      FROM public."Managers" m
      WHERE (m.contracted_club IS NULL OR btrim(m.contracted_club) = '')
        AND NOT EXISTS (
          SELECT 1 FROM public."Manager_Transfer_Listings" l
          WHERE l.manager_id = m.id AND l.status = 'Active'
        )
        AND NOT (m.id = ANY (v_ids))
        AND (
          (v_band = 'low' AND coalesce(m.rating, 0) <= 65)
          OR (v_band = 'mid' AND coalesce(m.rating, 0) BETWEEN 66 AND 72)
          OR (v_band = 'upper' AND coalesce(m.rating, 0) BETWEEN 73 AND 78)
          OR (v_band = 'elite' AND coalesce(m.rating, 0) >= 79)
        )
      ORDER BY random()
      LIMIT v_need
    LOOP
      v_ids := array_append(v_ids, v_id);
    END LOOP;
  END LOOP;

  -- Fill remainder from any eligible FA
  WHILE coalesce(array_length(v_ids, 1), 0) < p_limit LOOP
    SELECT m.id INTO v_id
    FROM public."Managers" m
    WHERE (m.contracted_club IS NULL OR btrim(m.contracted_club) = '')
      AND NOT EXISTS (
        SELECT 1 FROM public."Manager_Transfer_Listings" l
        WHERE l.manager_id = m.id AND l.status = 'Active'
      )
      AND NOT (m.id = ANY (v_ids))
    ORDER BY random()
    LIMIT 1;

    EXIT WHEN v_id IS NULL;
    v_ids := array_append(v_ids, v_id);
  END LOOP;

  RETURN v_ids;
END;
$function$;

CREATE OR REPLACE FUNCTION public.manager_window_fa_spawn(
  p_season_id bigint DEFAULT NULL,
  p_month text DEFAULT NULL,
  p_force boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season_id bigint := p_season_id;
  v_month text := lower(btrim(coalesce(p_month, '')));
  v_job text;
  v_job_id bigint;
  v_ids bigint[];
  v_id bigint;
  v_mv bigint;
  v_end timestamptz;
  v_lock timestamptz;
  v_created int := 0;
  v_closed int := 0;
BEGIN
  IF v_season_id IS NULL THEN
    SELECT id INTO v_season_id
    FROM public.competition_seasons
    WHERE is_current = true AND status = 'active'
    ORDER BY id DESC LIMIT 1;
  END IF;

  IF v_season_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_season');
  END IF;

  IF v_month = '' THEN
    v_month := lower(coalesce(public.competition_active_gpsl_month(v_season_id, now()), ''));
  END IF;

  IF NOT public.manager_is_transfer_window_month(v_month) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_tw_month', 'month', v_month);
  END IF;

  v_job := format('manager_window_fa:%s', v_month);

  IF NOT p_force THEN
    INSERT INTO public.competition_season_calendar_jobs (
      season_id, job_key, gpsl_month, result
    )
    VALUES (v_season_id, v_job, v_month, jsonb_build_object('status', 'running'))
    ON CONFLICT (season_id, job_key) DO NOTHING
    RETURNING id INTO v_job_id;

    IF v_job_id IS NULL THEN
      RETURN jsonb_build_object('ok', true, 'skipped', true, 'reason', 'already_spawned', 'month', v_month);
    END IF;
  ELSE
    DELETE FROM public.competition_season_calendar_jobs
    WHERE season_id = v_season_id AND job_key = v_job;
    INSERT INTO public.competition_season_calendar_jobs (
      season_id, job_key, gpsl_month, result
    )
    VALUES (v_season_id, v_job, v_month, jsonb_build_object('status', 'running'))
    RETURNING id INTO v_job_id;
  END IF;

  v_closed := public.manager_window_fa_close_batch(v_season_id, NULL);

  v_lock := public.manager_gpsl_month_lock_at(v_season_id, v_month);
  v_end := coalesce(v_lock, now() + interval '7 days');
  -- First auction slice: up to 48h, never past month lock
  v_end := least(v_end, now() + interval '48 hours');

  v_ids := public.manager_window_fa_pick_ids(v_season_id, 10);

  FOREACH v_id IN ARRAY coalesce(v_ids, ARRAY[]::bigint[]) LOOP
    SELECT coalesce(m.market_value, 0) INTO v_mv
    FROM public."Managers" m WHERE m.id = v_id;

    INSERT INTO public."Manager_Transfer_Listings" (
      manager_id, seller_club_id, listing_type, status, end_time, market_value, metadata
    )
    VALUES (
      v_id, NULL, 'window_fa', 'Active', v_end, v_mv,
      jsonb_build_object(
        'gpsl_month', v_month,
        'season_id', v_season_id,
        'window_fa', true,
        'batch_job', v_job
      )
    );
    v_created := v_created + 1;
  END LOOP;

  UPDATE public.competition_season_calendar_jobs
  SET result = jsonb_build_object(
        'ok', true,
        'month', v_month,
        'closed_prior', v_closed,
        'created', v_created,
        'manager_ids', to_jsonb(v_ids)
      ),
      ran_at = now()
  WHERE id = v_job_id;

  RETURN jsonb_build_object(
    'ok', true,
    'month', v_month,
    'closed_prior', v_closed,
    'created', v_created,
    'end_time', v_end
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.manager_window_fa_renew_active()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season_id bigint;
  v_month text;
  v_lock timestamptz;
  v_n int := 0;
BEGIN
  SELECT id INTO v_season_id
  FROM public.competition_seasons
  WHERE is_current = true AND status = 'active'
  ORDER BY id DESC LIMIT 1;

  IF v_season_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'renewed', 0);
  END IF;

  v_month := lower(coalesce(public.competition_active_gpsl_month(v_season_id, now()), ''));
  IF NOT public.manager_is_transfer_window_month(v_month) THEN
    -- Outside TW months: close any leftover window_fa
    PERFORM public.manager_window_fa_close_batch(v_season_id, NULL);
    RETURN jsonb_build_object('ok', true, 'renewed', 0, 'closed_off_month', true);
  END IF;

  v_lock := public.manager_gpsl_month_lock_at(v_season_id, v_month);

  UPDATE public."Manager_Transfer_Listings" l
  SET end_time = least(coalesce(v_lock, now() + interval '48 hours'), now() + interval '48 hours'),
      updated_at = now()
  WHERE l.listing_type = 'window_fa'
    AND l.status = 'Active'
    AND l.end_time IS NOT NULL
    AND l.end_time <= now()
    AND l.current_highest_bidder IS NULL
    AND coalesce(l.metadata->>'gpsl_month', '') = v_month
    AND coalesce((l.metadata->>'season_id')::bigint, 0) = v_season_id;

  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN jsonb_build_object('ok', true, 'renewed', v_n, 'month', v_month);
END;
$function$;

CREATE OR REPLACE FUNCTION public.manager_process_window_fa_listings()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_id bigint;
  v_sold int := 0;
  v_closed int := 0;
  v_row jsonb;
  v_renew jsonb;
BEGIN
  v_renew := public.manager_window_fa_renew_active();

  -- Settle expired listings that have a high bidder
  FOR v_id IN
    SELECT l.id
    FROM public."Manager_Transfer_Listings" l
    WHERE l.listing_type = 'window_fa'
      AND l.status = 'Active'
      AND l.end_time IS NOT NULL
      AND l.end_time <= now()
      AND l.current_highest_bidder IS NOT NULL
    ORDER BY l.end_time
  LOOP
    v_row := public.manager_settle_listing(v_id);
    IF coalesce((v_row ->> 'sold')::boolean, false) THEN
      v_sold := v_sold + 1;
    ELSE
      v_closed := v_closed + 1;
    END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true,
    'sold', v_sold,
    'closed_unsold', v_closed,
    'renew', v_renew
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.manager_window_fa_month_tick()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_spawn jsonb;
  v_process jsonb;
BEGIN
  v_spawn := public.manager_window_fa_spawn(NULL, NULL, false);
  v_process := public.manager_process_window_fa_listings();
  RETURN jsonb_build_object('spawn', v_spawn, 'process', v_process);
END;
$function$;

-- ---------------------------------------------------------------------------
-- Wire into transferengine_run_report (append manager FA tick)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.transferengine_run_report()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_settings record;
  v_stuck int;
  v_draft_before int;
  v_draft_after int;
  v_mgr_draft_before int;
  v_mgr_draft_after int;
  v_club_before int;
  v_club_after int;
  v_blocked boolean;
  v_finish_passed boolean;
  v_calendar jsonb;
  v_mgr_fa jsonb;
BEGIN
  SELECT
    draft_auction_enabled,
    manager_draft_auction_enabled,
    club_auction_enabled,
    draft_random_finish_time
  INTO v_settings
  FROM global_settings
  WHERE id = 1;

  v_finish_passed :=
    v_settings.draft_random_finish_time IS NOT NULL
    AND now() >= v_settings.draft_random_finish_time;

  v_blocked := public.transferengine_standard_listings_block_draft_settlement(
    now(),
    v_settings.draft_random_finish_time
  );

  SELECT count(*)::int INTO v_stuck
  FROM public."Player_Transfer_Listings" l
  WHERE l.status = 'Active'
    AND l.listing_type IS DISTINCT FROM 'draft'
    AND l.end_time IS NOT NULL
    AND l.end_time <= now();

  SELECT count(*)::int INTO v_draft_before
  FROM public."Player_Transfer_Listings" l
  WHERE l.listing_type = 'draft' AND l.status = 'Active';

  SELECT count(*)::int INTO v_mgr_draft_before
  FROM public."Manager_Transfer_Listings" l
  WHERE l.listing_type = 'draft' AND l.status = 'Active';

  SELECT count(*)::int INTO v_club_before
  FROM public."Club_Auction_Listings" l
  WHERE l.status = 'Active';

  PERFORM public.transferengine_run();

  SELECT count(*)::int INTO v_draft_after
  FROM public."Player_Transfer_Listings" l
  WHERE l.listing_type = 'draft' AND l.status = 'Active';

  SELECT count(*)::int INTO v_mgr_draft_after
  FROM public."Manager_Transfer_Listings" l
  WHERE l.listing_type = 'draft' AND l.status = 'Active';

  SELECT count(*)::int INTO v_club_after
  FROM public."Club_Auction_Listings" l
  WHERE l.status = 'Active';

  IF to_regprocedure('public.competition_calendar_month_tick()') IS NOT NULL THEN
    v_calendar := public.competition_calendar_month_tick();
  ELSE
    v_calendar := jsonb_build_object('skipped', true);
  END IF;

  v_mgr_fa := public.manager_window_fa_month_tick();

  RETURN jsonb_build_object(
    'ok', true,
    'note', 'transferengine_run() returns void — blank in SQL Editor is normal',
    'ran_at', now(),
    'draft_auction_enabled', COALESCE(v_settings.draft_auction_enabled, false),
    'manager_draft_auction_enabled', COALESCE(v_settings.manager_draft_auction_enabled, false),
    'club_auction_enabled', COALESCE(v_settings.club_auction_enabled, false),
    'draft_random_finish_time', v_settings.draft_random_finish_time,
    'secret_finish_passed', v_finish_passed,
    'blocked_by_7pm_transfer_list', v_blocked,
    'stuck_standard_before', v_stuck,
    'active_draft_before', v_draft_before,
    'active_draft_after', v_draft_after,
    'draft_settled_count', v_draft_before - v_draft_after,
    'active_manager_draft_before', v_mgr_draft_before,
    'active_manager_draft_after', v_mgr_draft_after,
    'manager_draft_settled_count', v_mgr_draft_before - v_mgr_draft_after,
    'active_club_auction_before', v_club_before,
    'active_club_auction_after', v_club_after,
    'club_auction_settled_count', v_club_before - v_club_after,
    'calendar_month_tick', v_calendar,
    'manager_window_fa', v_mgr_fa
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.manager_list_sack_window_open() TO authenticated;
GRANT EXECUTE ON FUNCTION public.manager_sack_window_open() TO authenticated;
GRANT EXECUTE ON FUNCTION public.manager_sack_tenure_eligible(bigint, text, bigint, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.manager_list_for_transfer(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.manager_sack() TO authenticated;
GRANT EXECUTE ON FUNCTION public.manager_window_fa_spawn(bigint, text, boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.manager_window_fa_month_tick() TO service_role;
GRANT EXECUTE ON FUNCTION public.manager_process_window_fa_listings() TO service_role;
GRANT EXECUTE ON FUNCTION public.transferengine_run_report() TO service_role;

NOTIFY pgrst, 'reload schema';
