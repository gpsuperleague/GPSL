-- Eligible managers can be listed before the window, like players.
-- The row is Pending Window: visible, no bids, no auction clock.
-- It becomes Active only when the transfer window is open AND the GPSL
-- month is the window it was aimed at (June, July, or January — not August).
-- A played fixture still needs an active manager at the club entering the result.

BEGIN;

ALTER TABLE public."Manager_Transfer_Listings"
  ADD COLUMN IF NOT EXISTS metadata jsonb NOT NULL DEFAULT '{}'::jsonb;

DO $$
DECLARE
  r record;
BEGIN
  FOR r IN
    SELECT con.conname
    FROM pg_constraint con
    JOIN pg_class rel ON rel.oid = con.conrelid
    JOIN pg_namespace nsp ON nsp.oid = rel.relnamespace
    WHERE nsp.nspname = 'public'
      AND rel.relname = 'Manager_Transfer_Listings'
      AND con.contype = 'c'
      AND pg_get_constraintdef(con.oid) ILIKE '%status%'
  LOOP
    EXECUTE format(
      'ALTER TABLE public."Manager_Transfer_Listings" DROP CONSTRAINT %I',
      r.conname
    );
  END LOOP;
END $$;

ALTER TABLE public."Manager_Transfer_Listings"
  ADD CONSTRAINT manager_transfer_listings_status_check
  CHECK (
    status IN (
      'Active',
      'Review',
      'Seller Review',
      'Closed',
      'Cancelled',
      'Pending Window'
    )
  );

CREATE OR REPLACE FUNCTION public.club_assert_has_manager_for_matches(p_club_short text)
RETURNS void
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF NOT public.club_has_signed_manager(p_club_short) THEN
    RAISE EXCEPTION
      'Matches cannot be played without an active manager. % has none — sign one before check-in, kick-off, or entering a result.',
      coalesce(nullif(btrim(p_club_short), ''), '?');
  END IF;
END;
$function$;

CREATE OR REPLACE FUNCTION public.manager_preview_list_state(p_manager_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_mgr public."Managers"%rowtype;
  v_season bigint;
  v_month text;
  v_go text;
  v_label text;
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN jsonb_build_object('available', false, 'reason', 'Not signed in');
  END IF;

  SELECT * INTO v_mgr FROM public."Managers" WHERE id = p_manager_id;
  IF NOT FOUND OR v_mgr.contracted_club IS DISTINCT FROM public.my_club_shortname() THEN
    RETURN jsonb_build_object('available', false, 'reason', 'Manager not at your club');
  END IF;

  IF coalesce(v_mgr.archived, false) THEN
    RETURN jsonb_build_object('available', false, 'reason', 'This manager cannot be listed');
  END IF;

  SELECT id INTO v_season
  FROM public.competition_seasons
  WHERE is_current = true
  ORDER BY id DESC
  LIMIT 1;

  v_month := lower(coalesce(public.competition_active_gpsl_month(v_season, now()), ''));

  -- Pre-season and an open June / July / January window list live.
  -- Closed months (including August) stay on the preview path.
  IF public.manager_list_sack_window_open() THEN
    RETURN jsonb_build_object('available', false, 'live', true, 'reason', 'window_open');
  END IF;

  IF v_month IN ('june', 'july', 'january') THEN
    v_go := v_month || '_this_season';
    v_label := initcap(v_month);
  ELSIF v_month IN ('february', 'march', 'april', 'may') THEN
    v_go := 'june_next_season';
    v_label := 'June';
  ELSE
    v_go := 'january_this_season';
    v_label := 'January';
  END IF;

  IF NOT public.manager_sack_tenure_eligible(
    v_mgr.signed_season_id,
    v_mgr.signed_gpsl_month,
    CASE WHEN v_go = 'june_next_season' THEN coalesce(v_season, 0) + 1 ELSE v_season END,
    CASE
      WHEN v_go = 'june_next_season' THEN 'june'
      WHEN v_go = 'july_this_season' THEN 'july'
      WHEN v_go = 'june_this_season' THEN 'june'
      ELSE 'january'
    END
  ) THEN
    RETURN jsonb_build_object(
      'available', false,
      'reason',
      'Cannot list yet — managers must reach mid-season in their first spell (summer signings: January; January signings: next June–July)'
    );
  END IF;

  RETURN jsonb_build_object(
    'available', true,
    'live', false,
    'go_live', v_go,
    'label', v_label,
    'listed_season_id', v_season
  );
END;
$function$;

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
  v_now timestamptz := now();
  v_preview jsonb;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  v_club := public.my_club_shortname();
  IF v_club IS NULL THEN
    RAISE EXCEPTION 'No club linked to your account';
  END IF;

  SELECT * INTO v_mgr FROM public."Managers" WHERE id = p_manager_id FOR UPDATE;
  IF NOT FOUND OR v_mgr.contracted_club IS DISTINCT FROM v_club THEN
    RAISE EXCEPTION 'Manager not at your club';
  END IF;

  IF coalesce(v_mgr.archived, false) THEN
    RAISE EXCEPTION
      'This manager is no longer in the game catalog — they cannot be listed. You may only sack them; when the contract ends you receive full market value.';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public."Manager_Transfer_Listings"
    WHERE manager_id = p_manager_id
      AND status IN ('Active', 'Pending Window')
  ) THEN
    RAISE EXCEPTION 'Manager already listed';
  END IF;

  SELECT id INTO v_season_id
  FROM public.competition_seasons WHERE is_current = true ORDER BY id DESC LIMIT 1;

  v_month := lower(coalesce(public.competition_active_gpsl_month(v_season_id, v_now), ''));

  IF public.manager_list_sack_window_open() THEN
    IF NOT public.manager_sack_tenure_eligible(
      v_mgr.signed_season_id, v_mgr.signed_gpsl_month, v_season_id, v_month
    ) THEN
      RAISE EXCEPTION
        'Cannot list yet — managers must reach mid-season in their first spell (summer signings: January; January signings: next June–July)';
    END IF;

    IF to_regprocedure('public.compute_standard_listing_end_time(timestamptz)') IS NOT NULL THEN
      v_end := public.compute_standard_listing_end_time(v_now);
    ELSE
      v_end := coalesce(
        public.manager_gpsl_month_lock_at(v_season_id, v_month),
        v_now + interval '7 days'
      );
    END IF;

    INSERT INTO public."Manager_Transfer_Listings" (
      manager_id, seller_club_id, listing_type, status, end_time, market_value, metadata
    )
    VALUES (
      p_manager_id, v_club, 'standard', 'Active', v_end, v_mgr.market_value,
      jsonb_build_object(
        'gpsl_month', v_month,
        'season_id', v_season_id,
        'end_rule', 'standard_24h_7pm_uk'
      )
    )
    RETURNING id INTO v_listing_id;

    RETURN jsonb_build_object(
      'ok', true,
      'preview', false,
      'listing_id', v_listing_id,
      'end_time', v_end
    );
  END IF;

  v_preview := public.manager_preview_list_state(p_manager_id);
  IF coalesce((v_preview->>'available')::boolean, false) IS NOT TRUE THEN
    RAISE EXCEPTION '%', coalesce(v_preview->>'reason', 'Manager listing is not open');
  END IF;

  INSERT INTO public."Manager_Transfer_Listings" (
    manager_id, seller_club_id, listing_type, status, end_time, market_value, metadata
  )
  VALUES (
    p_manager_id, v_club, 'standard', 'Pending Window', NULL, v_mgr.market_value,
    jsonb_build_object(
      'preview', true,
      'go_live', v_preview->>'go_live',
      'label', v_preview->>'label',
      'listed_season_id', v_season_id
    )
  )
  RETURNING id INTO v_listing_id;

  RETURN jsonb_build_object(
    'ok', true,
    'preview', true,
    'listing_id', v_listing_id,
    'label', v_preview->>'label'
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.manager_cancel_preview_listing(p_manager_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text;
  v_id bigint;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  v_club := public.my_club_shortname();
  UPDATE public."Manager_Transfer_Listings"
  SET status = 'Cancelled'
  WHERE manager_id = p_manager_id
    AND seller_club_id = v_club
    AND status = 'Pending Window'
  RETURNING id INTO v_id;

  IF v_id IS NULL THEN
    RAISE EXCEPTION 'No preview listing to take off';
  END IF;

  RETURN jsonb_build_object('ok', true, 'listing_id', v_id);
END;
$function$;

CREATE OR REPLACE FUNCTION public.activate_pending_manager_listings(
  p_now timestamptz DEFAULT now()
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_now timestamptz := coalesce(p_now, now());
  v_season bigint;
  v_month text;
  v_end timestamptz;
  v_count int := 0;
BEGIN
  -- Same gate as a live list: June and July count even before the player
  -- window flag; January still needs that flag. August never starts these.
  IF NOT public.manager_list_sack_window_open() THEN
    RETURN jsonb_build_object('ok', true, 'activated', 0, 'reason', 'window_closed');
  END IF;

  SELECT id INTO v_season
  FROM public.competition_seasons
  WHERE is_current = true
  ORDER BY id DESC
  LIMIT 1;

  v_month := lower(coalesce(public.competition_active_gpsl_month(v_season, v_now), ''));
  IF v_month NOT IN ('june', 'july', 'january') THEN
    RETURN jsonb_build_object('ok', true, 'activated', 0, 'reason', 'not_a_manager_window');
  END IF;

  IF to_regprocedure('public.compute_standard_listing_end_time(timestamptz)') IS NOT NULL THEN
    v_end := public.compute_standard_listing_end_time(v_now);
  ELSE
    v_end := coalesce(
      public.manager_gpsl_month_lock_at(v_season, v_month),
      v_now + interval '7 days'
    );
  END IF;

  UPDATE public."Manager_Transfer_Listings" l
  SET status = 'Active',
      end_time = v_end,
      metadata = coalesce(l.metadata, '{}'::jsonb) || jsonb_build_object('went_live_at', v_now)
  FROM public."Managers" m
  WHERE l.manager_id = m.id
    AND l.status = 'Pending Window'
    AND l.listing_type = 'standard'
    AND coalesce(l.transfer_completed, false) = false
    AND coalesce(m.archived, false) = false
    AND public.manager_sack_tenure_eligible(
      m.signed_season_id, m.signed_gpsl_month, v_season, v_month
    )
    AND (
      (l.metadata->>'go_live' = 'january_this_season' AND v_month = 'january'
        AND (l.metadata->>'listed_season_id')::bigint = v_season)
      OR (l.metadata->>'go_live' = 'june_this_season' AND v_month = 'june'
        AND (l.metadata->>'listed_season_id')::bigint = v_season)
      OR (l.metadata->>'go_live' = 'july_this_season' AND v_month = 'july'
        AND (l.metadata->>'listed_season_id')::bigint = v_season)
      OR (l.metadata->>'go_live' = 'june_next_season' AND v_month = 'june'
        AND v_season > (l.metadata->>'listed_season_id')::bigint)
    );

  GET DIAGNOSTICS v_count = ROW_COUNT;

  RETURN jsonb_build_object('ok', true, 'activated', v_count, 'end_time', v_end);
END;
$function$;

CREATE OR REPLACE FUNCTION public.trg_activate_pending_listings_on_window_open()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF TG_OP = 'UPDATE'
     AND NEW.transfer_window_open IS TRUE
     AND OLD.transfer_window_open IS NOT TRUE THEN
    BEGIN
      PERFORM public.activate_pending_window_listings(now());
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'activate_pending_window_listings failed: %', SQLERRM;
    END;
    BEGIN
      PERFORM public.activate_pending_manager_listings(now());
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'activate_pending_manager_listings failed: %', SQLERRM;
    END;
  END IF;
  RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.trg_fixture_play_requires_manager()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text;
BEGIN
  IF NEW.status IS DISTINCT FROM 'played' OR OLD.status IS NOT DISTINCT FROM 'played' THEN
    RETURN NEW;
  END IF;
  IF auth.uid() IS NULL THEN
    RETURN NEW;
  END IF;
  v_club := public.my_club_shortname();
  IF v_club IS NULL OR v_club = '' THEN
    RETURN NEW;
  END IF;
  IF v_club IN (NEW.home_club_short_name, NEW.away_club_short_name)
     AND NOT public.club_has_signed_manager(v_club) THEN
    RAISE EXCEPTION
      'Matches cannot be played without an active manager. Sign one before this result can be entered.';
  END IF;
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_fixture_play_requires_manager ON public.competition_fixtures;
CREATE TRIGGER trg_fixture_play_requires_manager
  BEFORE UPDATE OF status ON public.competition_fixtures
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_fixture_play_requires_manager();

GRANT EXECUTE ON FUNCTION public.manager_preview_list_state(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.manager_list_for_transfer(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.manager_cancel_preview_listing(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.activate_pending_manager_listings(timestamptz) TO authenticated, service_role;

DO $cron$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    RETURN;
  END IF;
  IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'gpsl-manager-preview-activate') THEN
    PERFORM cron.unschedule('gpsl-manager-preview-activate');
  END IF;
  PERFORM cron.schedule(
    'gpsl-manager-preview-activate',
    '*/15 * * * *',
    $q$SELECT public.activate_pending_manager_listings(now());$q$
  );
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING 'Could not schedule manager preview activation: %', SQLERRM;
END
$cron$;

NOTIFY pgrst, 'reload schema';

COMMIT;
