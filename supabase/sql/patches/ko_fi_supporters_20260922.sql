-- =============================================================================
-- Ko-fi Supporters (manual admin flag)
--
-- • Admin sets is_supporter on gpsl_owner_registry (owners + waiting list)
-- • Unset mid-month → perks until last day of that month (supporter_grace_until)
-- • 1st of month (Europe/London): ₿1,000 Building Society if still flagged;
--   lapsed owners lose theme (enabled=false); badge file kept but hidden
-- • Perks while active: badge visible/editable, colour scheme, free club swap
--   once per season into an empty club; otherwise ₿150m club-bank fee
-- • Club swap moves squad/manager/medical/cash; history stays on ShortName;
--   vacated club gets empty squad, no manager, ₿650m cash
--
-- Apply in Supabase SQL Editor. Safe re-run.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Columns
-- ---------------------------------------------------------------------------
ALTER TABLE public.gpsl_owner_registry
  ADD COLUMN IF NOT EXISTS is_supporter boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS supporter_since timestamptz,
  ADD COLUMN IF NOT EXISTS supporter_unset_at timestamptz,
  ADD COLUMN IF NOT EXISTS supporter_grace_until date,
  ADD COLUMN IF NOT EXISTS supporter_credit_ym text,
  ADD COLUMN IF NOT EXISTS supporter_note text,
  ADD COLUMN IF NOT EXISTS supporter_free_swap_season_id bigint;

COMMENT ON COLUMN public.gpsl_owner_registry.is_supporter IS
  'Admin Ko-fi flag. When true on the 1st (London), owner gets ₿1,000 Building Society.';
COMMENT ON COLUMN public.gpsl_owner_registry.supporter_grace_until IS
  'After unset: keep perks through this date (last day of unset month).';
COMMENT ON COLUMN public.gpsl_owner_registry.supporter_credit_ym IS
  'Last YYYY-MM (Europe/London) monthly credit was posted.';
COMMENT ON COLUMN public.gpsl_owner_registry.supporter_free_swap_season_id IS
  'Competition season id when free supporter club swap was used.';

CREATE TABLE IF NOT EXISTS public.owner_club_swap_log (
  id bigserial PRIMARY KEY,
  owner_id uuid NOT NULL,
  from_club_short_name text NOT NULL,
  to_club_short_name text NOT NULL,
  season_id bigint,
  was_supporter boolean NOT NULL DEFAULT false,
  fee_amount numeric(14, 2) NOT NULL DEFAULT 0,
  value_delta numeric(14, 2) NOT NULL DEFAULT 0,
  balance_moved numeric(14, 2),
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS owner_club_swap_log_owner_idx
  ON public.owner_club_swap_log (owner_id, created_at DESC);

ALTER TABLE public.owner_club_swap_log ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS owner_club_swap_log_select_self_or_admin ON public.owner_club_swap_log;
CREATE POLICY owner_club_swap_log_select_self_or_admin ON public.owner_club_swap_log
  FOR SELECT TO authenticated
  USING (owner_id = auth.uid() OR public.is_gpsl_admin());

GRANT SELECT ON public.owner_club_swap_log TO authenticated;

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.supporter_london_today()
RETURNS date
LANGUAGE sql
STABLE
AS $$
  SELECT (timezone('Europe/London', now()))::date;
$$;

CREATE OR REPLACE FUNCTION public.supporter_london_ym(p_day date DEFAULT NULL)
RETURNS text
LANGUAGE sql
STABLE
AS $$
  SELECT to_char(coalesce(p_day, public.supporter_london_today()), 'YYYY-MM');
$$;

CREATE OR REPLACE FUNCTION public.supporter_month_end(p_day date DEFAULT NULL)
RETURNS date
LANGUAGE sql
STABLE
AS $$
  SELECT (
    date_trunc('month', coalesce(p_day, public.supporter_london_today())::timestamp)
    + interval '1 month'
    - interval '1 day'
  )::date;
$$;

CREATE OR REPLACE FUNCTION public.owner_is_supporter_active(p_owner_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT coalesce(
    (
      SELECT
        r.is_supporter
        OR (
          r.supporter_grace_until IS NOT NULL
          AND public.supporter_london_today() <= r.supporter_grace_until
        )
      FROM public.gpsl_owner_registry r
      WHERE r.owner_id = p_owner_id
    ),
    false
  );
$$;

CREATE OR REPLACE FUNCTION public.club_stadium_value(p_club_short text)
RETURNS numeric
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT round(greatest(coalesce(c."Capacity", 0), 0)::numeric * 1500)
  FROM public."Clubs" c
  WHERE c."ShortName" = upper(btrim(coalesce(p_club_short, '')))
  LIMIT 1;
$$;

CREATE OR REPLACE FUNCTION public.supporter_disable_club_theme(p_owner_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text;
BEGIN
  SELECT c."ShortName" INTO v_club
  FROM public."Clubs" c
  WHERE c.owner_id = p_owner_id
  LIMIT 1;

  IF v_club IS NULL THEN
    RETURN;
  END IF;

  UPDATE public.club_dashboard_theme
  SET enabled = false,
      updated_at = now()
  WHERE club_short_name = v_club
    AND enabled = true;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.owner_is_supporter_active(uuid) TO authenticated;

-- ---------------------------------------------------------------------------
-- Admin: set / unset supporter
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
  v_today date := public.supporter_london_today();
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
        supporter_unset_at = NULL,
        supporter_grace_until = NULL,
        supporter_note = coalesce(
          nullif(btrim(p_note), ''),
          supporter_note
        )
    WHERE owner_id = v_uid;
  ELSE
    -- Admin unset = immediate revoke (no grace). Month-end grace is for
    -- automated Ko-fi lapse later; manual admin toggle must cut perks now.
    UPDATE public.gpsl_owner_registry
    SET is_supporter = false,
        supporter_unset_at = now(),
        supporter_grace_until = NULL,
        supporter_note = coalesce(
          nullif(btrim(p_note), ''),
          supporter_note
        )
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
    'supporter_grace_until', (
      SELECT supporter_grace_until FROM public.gpsl_owner_registry WHERE owner_id = v_uid
    ),
    'was_supporter', coalesce(v_was, false)
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_owner_supporter_map()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  RETURN coalesce(
    (
      SELECT jsonb_object_agg(
        r.owner_id::text,
        jsonb_build_object(
          'is_supporter', r.is_supporter,
          'supporter_active', public.owner_is_supporter_active(r.owner_id),
          'supporter_grace_until', r.supporter_grace_until,
          'supporter_since', r.supporter_since,
          'supporter_note', r.supporter_note
        )
      )
      FROM public.gpsl_owner_registry r
      WHERE r.is_supporter
         OR r.supporter_grace_until IS NOT NULL
         OR r.supporter_since IS NOT NULL
    ),
    '{}'::jsonb
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.admin_owner_set_supporter(uuid, boolean, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_owner_supporter_map() TO authenticated;

-- ---------------------------------------------------------------------------
-- Monthly tick: credit + lapse cleanup
-- ---------------------------------------------------------------------------
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

  FOR v_row IN
    SELECT r.owner_id
    FROM public.gpsl_owner_registry r
    WHERE r.is_supporter = false
      AND r.supporter_grace_until IS NOT NULL
      AND r.supporter_grace_until < v_today
  LOOP
    PERFORM public.supporter_disable_club_theme(v_row.owner_id);
    UPDATE public.gpsl_owner_registry
    SET supporter_grace_until = NULL
    WHERE owner_id = v_row.owner_id;
    v_lapsed := v_lapsed + 1;
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true,
    'london_date', v_today,
    'credit_ym', v_ym,
    'credited', v_credited,
    'credit_errors', v_skipped,
    'lapsed', v_lapsed
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_supporter_month_tick_now()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;
  RETURN public.supporter_month_tick();
END;
$function$;

GRANT EXECUTE ON FUNCTION public.supporter_month_tick() TO service_role;
GRANT EXECUTE ON FUNCTION public.admin_supporter_month_tick_now() TO authenticated;

DO $cron$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    BEGIN
      PERFORM cron.unschedule('gpsl-supporter-month-tick');
    EXCEPTION WHEN OTHERS THEN
      NULL;
    END;
    PERFORM cron.schedule(
      'gpsl-supporter-month-tick',
      '10 0 * * *',
      $$SELECT public.supporter_month_tick();$$
    );
  END IF;
EXCEPTION WHEN OTHERS THEN
  RAISE NOTICE 'pg_cron supporter schedule skipped: %', SQLERRM;
END;
$cron$;

-- ---------------------------------------------------------------------------
-- Gate: profile badge upload
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.owner_registry_set_badge_path(p_path text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_path text := nullif(btrim(p_path), '');
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not signed in';
  END IF;

  PERFORM public.owner_registry_ensure_self();

  IF v_path IS NOT NULL AND NOT public.owner_is_supporter_active(v_uid) THEN
    RAISE EXCEPTION 'Profile image is a Supporter perk — become a Ko-fi Supporter to set a badge';
  END IF;

  IF v_path IS NOT NULL AND split_part(v_path, '/', 1) <> v_uid::text THEN
    RAISE EXCEPTION 'Badge path must be under your owner folder';
  END IF;

  UPDATE public.gpsl_owner_registry
  SET badge_path = v_path,
      badge_updated_at = CASE WHEN v_path IS NULL THEN NULL ELSE now() END
  WHERE owner_id = v_uid;

  RETURN jsonb_build_object('ok', true, 'badge_path', v_path);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.owner_registry_set_badge_path(text) TO authenticated;

-- ---------------------------------------------------------------------------
-- Gate: club colour scheme (same signature as club_theme_common.js)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.club_owner_dashboard_theme_save(
  p_enabled boolean,
  p_color_primary text,
  p_color_secondary text,
  p_color_border text,
  p_color_text text,
  p_theme_scope text DEFAULT 'dashboard',
  p_source_kit text DEFAULT 'manual'
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_short text;
  v_primary text;
  v_secondary text;
  v_border text;
  v_text text;
  v_scope text := lower(btrim(coalesce(p_theme_scope, 'dashboard')));
  v_source text := lower(btrim(coalesce(p_source_kit, 'manual')));
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not signed in';
  END IF;

  IF NOT public.owner_is_supporter_active(v_uid) THEN
    RAISE EXCEPTION 'Colour scheme is a Supporter perk — become a Ko-fi Supporter to customise colours';
  END IF;

  SELECT c."ShortName" INTO v_short
  FROM public."Clubs" c
  WHERE c.owner_id = v_uid
  LIMIT 1;

  IF v_short IS NULL THEN
    RAISE EXCEPTION 'No club linked to this account';
  END IF;

  IF v_scope NOT IN ('dashboard', 'club_pages') THEN
    RAISE EXCEPTION 'Invalid theme_scope (use dashboard or club_pages)';
  END IF;

  IF v_source NOT IN ('home', 'away', 'third', 'manual') THEN
    RAISE EXCEPTION 'Invalid source_kit';
  END IF;

  IF coalesce(p_enabled, false) THEN
    v_primary := public._normalize_theme_hex(p_color_primary);
    v_secondary := public._normalize_theme_hex(p_color_secondary);
    v_border := public._normalize_theme_hex(p_color_border);
    v_text := public._normalize_theme_hex(p_color_text);
    IF v_primary IS NULL OR v_secondary IS NULL OR v_border IS NULL OR v_text IS NULL THEN
      RAISE EXCEPTION 'All four colours are required when theme is enabled';
    END IF;
  ELSE
    v_primary := public._normalize_theme_hex(p_color_primary);
    v_secondary := public._normalize_theme_hex(p_color_secondary);
    v_border := public._normalize_theme_hex(p_color_border);
    v_text := public._normalize_theme_hex(p_color_text);
  END IF;

  INSERT INTO public.club_dashboard_theme (
    club_short_name,
    enabled,
    color_primary,
    color_secondary,
    color_border,
    color_text,
    theme_scope,
    source_kit,
    updated_at
  )
  VALUES (
    v_short,
    coalesce(p_enabled, false),
    v_primary,
    v_secondary,
    v_border,
    v_text,
    v_scope,
    v_source,
    now()
  )
  ON CONFLICT (club_short_name) DO UPDATE
  SET enabled = excluded.enabled,
      color_primary = excluded.color_primary,
      color_secondary = excluded.color_secondary,
      color_border = excluded.color_border,
      color_text = excluded.color_text,
      theme_scope = excluded.theme_scope,
      source_kit = excluded.source_kit,
      updated_at = now();

  RETURN jsonb_build_object(
    'ok', true,
    'club_short_name', v_short,
    'enabled', coalesce(p_enabled, false),
    'color_primary', v_primary,
    'color_secondary', v_secondary,
    'color_border', v_border,
    'color_text', v_text,
    'theme_scope', v_scope,
    'source_kit', v_source
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.club_owner_dashboard_theme_save(boolean, text, text, text, text, text, text)
  TO authenticated;

-- ---------------------------------------------------------------------------
-- Public profile: hide badge unless supporter active
-- ---------------------------------------------------------------------------
DROP VIEW IF EXISTS public.gpsl_owner_profile_public;
CREATE VIEW public.gpsl_owner_profile_public
WITH (security_invoker = false)
AS
SELECT
  r.owner_id,
  public.owner_registry_resolve_tag(r.owner_id) AS owner_tag,
  public.competition_owner_display_name(r.owner_id) AS owner_name,
  r.status,
  r.last_club_short_name,
  c."Club" AS current_club_name,
  c."ShortName" AS current_club_short_name,
  r.last_nation_code,
  n.name AS nation_name,
  n.flag_emoji,
  CASE
    WHEN public.owner_is_supporter_active(r.owner_id)
      AND r.badge_path IS NOT NULL AND btrim(r.badge_path) <> ''
    THEN r.badge_path
    ELSE NULL
  END AS badge_path,
  CASE
    WHEN public.owner_is_supporter_active(r.owner_id)
      AND r.badge_path IS NOT NULL AND btrim(r.badge_path) <> ''
    THEN 'owner-badges/' || btrim(r.badge_path)
    ELSE NULL
  END AS badge_storage_path,
  CASE
    WHEN public.owner_is_supporter_active(r.owner_id) THEN r.badge_updated_at
    ELSE NULL
  END AS badge_updated_at,
  public.owner_is_supporter_active(r.owner_id) AS is_supporter
FROM public.gpsl_owner_registry r
LEFT JOIN public."Clubs" c ON c.owner_id = r.owner_id
LEFT JOIN public.international_nations n ON n.code = r.last_nation_code;

GRANT SELECT ON public.gpsl_owner_profile_public TO authenticated;
GRANT SELECT ON public.gpsl_owner_profile_public TO anon;

-- ---------------------------------------------------------------------------
-- Club swap window: GPSL June only (~one UK week each season)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.owner_club_swap_window_open(
  p_at timestamptz DEFAULT now()
)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season_id bigint;
  v_month text;
BEGIN
  IF to_regprocedure('public.competition_finances_current_season_id()') IS NOT NULL THEN
    BEGIN
      v_season_id := public.competition_finances_current_season_id();
    EXCEPTION WHEN OTHERS THEN
      v_season_id := NULL;
    END;
  ELSIF to_regprocedure('public.current_gpsl_season_id()') IS NOT NULL THEN
    BEGIN
      v_season_id := public.current_gpsl_season_id();
    EXCEPTION WHEN OTHERS THEN
      v_season_id := NULL;
    END;
  ELSE
    SELECT s.id INTO v_season_id
    FROM public.competition_seasons s
    WHERE s.is_current = true
    ORDER BY s.id DESC
    LIMIT 1;
  END IF;

  IF v_season_id IS NULL THEN
    RETURN false;
  END IF;

  IF to_regprocedure('public.competition_active_gpsl_month(bigint, timestamptz)') IS NULL THEN
    RETURN false;
  END IF;

  v_month := lower(btrim(coalesce(
    public.competition_active_gpsl_month(v_season_id, coalesce(p_at, now())),
    ''
  )));

  RETURN v_month = 'june';
END;
$function$;

COMMENT ON FUNCTION public.owner_club_swap_window_open(timestamptz) IS
  'Club swap allowed only during the active GPSL June calendar window (~one week per season).';

GRANT EXECUTE ON FUNCTION public.owner_club_swap_window_open(timestamptz) TO authenticated;

-- ---------------------------------------------------------------------------
-- owner_registry_get_self — keep onboarding fields + supporter perks
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.owner_registry_get_self()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_has_club boolean;
  v_caretaker boolean;
  v_row public.gpsl_owner_registry%ROWTYPE;
  v_tag text;
  v_tz text;
  v_slot_count int;
  v_pos int;
  v_total int;
  v_awaiting boolean;
  v_member boolean;
  v_preclub boolean;
  v_has_interest boolean;
  v_has_backup boolean;
  v_supporter_active boolean;
  v_season_id bigint;
  v_free_swap_used boolean := false;
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN jsonb_build_object('authenticated', false);
  END IF;

  SELECT EXISTS (
    SELECT 1 FROM public."Clubs" c WHERE c.owner_id = auth.uid()
  ) INTO v_has_club;

  SELECT EXISTS (
    SELECT 1 FROM public.gpsl_club_caretaker ct
    WHERE ct.caretaker_owner_id = auth.uid() AND ct.ended_at IS NULL
  ) INTO v_caretaker;

  SELECT * INTO v_row
  FROM public.gpsl_owner_registry
  WHERE owner_id = auth.uid();

  v_tag := public.owner_registry_resolve_tag(auth.uid());
  v_tz := nullif(btrim(coalesce(v_row.owner_timezone, '')), '');
  v_supporter_active := public.owner_is_supporter_active(auth.uid());

  SELECT count(*)::int INTO v_slot_count
  FROM public.gpsl_owner_registry_availability_slot s
  WHERE s.owner_id = auth.uid();

  SELECT w.list_position INTO v_pos
  FROM public.waiting_list_ordered_rows(false) w
  WHERE w.owner_id = auth.uid();

  SELECT count(*)::int INTO v_total
  FROM public.waiting_list_ordered_rows(false);

  v_awaiting := NOT v_has_club
    AND coalesce(v_row.status, '') = 'awaiting_club_auction';

  v_member := NOT v_has_club
    AND public.waiting_list_on_list_status(coalesce(v_row.status, ''));

  v_preclub := v_awaiting OR v_member;

  SELECT EXISTS (
    SELECT 1 FROM public.club_auction_interests i
    WHERE i.owner_id = auth.uid() AND i.mark_kind = 'interest'
  ) INTO v_has_interest;

  SELECT EXISTS (
    SELECT 1 FROM public.club_auction_interests i
    WHERE i.owner_id = auth.uid() AND i.mark_kind = 'backup'
  ) INTO v_has_backup;

  BEGIN
    v_season_id := public.competition_finances_current_season_id();
  EXCEPTION WHEN OTHERS THEN
    v_season_id := NULL;
  END;

  v_free_swap_used :=
    v_season_id IS NOT NULL
    AND v_row.supporter_free_swap_season_id IS NOT NULL
    AND v_row.supporter_free_swap_season_id = v_season_id;

  RETURN jsonb_build_object(
    'authenticated', true,
    'has_club', v_has_club,
    'status', v_row.status,
    'owner_tag', v_tag,
    'owner_timezone', v_tz,
    'availability_slot_count', coalesce(v_slot_count, 0),
    'pending_starting_balance', coalesce(v_row.pending_starting_balance, 0),
    'needs_club_auction', v_awaiting,
    'needs_owner_tag', v_preclub AND v_tag IS NULL,
    'needs_onboarding_timezone', v_preclub AND v_tz IS NULL,
    'needs_onboarding_availability', v_preclub AND coalesce(v_slot_count, 0) < 1,
    'has_club_interest', v_has_interest,
    'has_club_backup', v_has_backup,
    'needs_club_interest', v_preclub AND NOT v_has_interest,
    'needs_club_backup', v_preclub AND NOT v_has_backup,
    'auction_onboarding_ready',
      v_awaiting
      AND v_tag IS NOT NULL
      AND v_tz IS NOT NULL
      AND coalesce(v_slot_count, 0) > 0
      AND v_has_interest
      AND v_has_backup,
    'is_member', v_member,
    'is_archived', coalesce(v_row.status, '') = 'archived',
    'is_caretaker', v_caretaker,
    'waiting_list_position', v_pos,
    'waiting_list_total', coalesce(v_total, 0),
    'is_supporter', coalesce(v_row.is_supporter, false),
    'supporter_active', v_supporter_active,
    'supporter_grace_until', v_row.supporter_grace_until,
    'badge_path', CASE WHEN v_supporter_active THEN v_row.badge_path ELSE NULL END,
    'badge_path_stored', v_row.badge_path,
    'can_set_profile_image', v_supporter_active,
    'can_set_colour_scheme', v_supporter_active AND v_has_club,
    'can_free_club_swap', v_supporter_active AND v_has_club AND NOT v_free_swap_used,
    'free_club_swap_used', v_free_swap_used,
    'club_swap_fee', 150000000,
    'club_swap_window_open', public.owner_club_swap_window_open()
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.owner_registry_get_self() TO authenticated;

-- ---------------------------------------------------------------------------
-- Vacant clubs for swap UI
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.owner_club_swap_vacant_list()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_from text;
  v_from_value numeric;
  v_supporter boolean;
  v_free_used boolean := false;
  v_season_id bigint;
  v_rows jsonb;
  v_window_open boolean := false;
  v_month text;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not signed in';
  END IF;

  SELECT c."ShortName" INTO v_from
  FROM public."Clubs" c
  WHERE c.owner_id = v_uid
  LIMIT 1;

  IF v_from IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_club');
  END IF;

  v_from_value := coalesce(public.club_stadium_value(v_from), 0);
  v_supporter := public.owner_is_supporter_active(v_uid);
  v_window_open := public.owner_club_swap_window_open();

  BEGIN
    v_season_id := public.competition_finances_current_season_id();
  EXCEPTION WHEN OTHERS THEN
    v_season_id := NULL;
  END;

  IF v_season_id IS NOT NULL
     AND to_regprocedure('public.competition_active_gpsl_month(bigint, timestamptz)') IS NOT NULL THEN
    v_month := lower(btrim(coalesce(
      public.competition_active_gpsl_month(v_season_id, now()),
      ''
    )));
  END IF;

  SELECT
    r.supporter_free_swap_season_id IS NOT NULL
    AND v_season_id IS NOT NULL
    AND r.supporter_free_swap_season_id = v_season_id
  INTO v_free_used
  FROM public.gpsl_owner_registry r
  WHERE r.owner_id = v_uid;

  v_free_used := coalesce(v_free_used, false);

  IF NOT v_window_open THEN
    RETURN jsonb_build_object(
      'ok', true,
      'from_club', v_from,
      'from_stadium_value', v_from_value,
      'supporter_active', v_supporter,
      'can_free_swap', v_supporter AND NOT v_free_used,
      'free_swap_used', v_free_used,
      'paid_fee', 150000000,
      'window_open', false,
      'active_gpsl_month', nullif(v_month, ''),
      'vacant', '[]'::jsonb,
      'reason', 'window_closed'
    );
  END IF;

  SELECT coalesce(jsonb_agg(row_data ORDER BY club_name), '[]'::jsonb)
  INTO v_rows
  FROM (
    SELECT jsonb_build_object(
      'short_name', c."ShortName",
      'club_name', c."Club",
      'capacity', coalesce(c."Capacity", 0),
      'stadium_value', coalesce(public.club_stadium_value(c."ShortName"), 0),
      'value_delta', coalesce(public.club_stadium_value(c."ShortName"), 0) - v_from_value
    ) AS row_data,
    c."Club" AS club_name
    FROM public."Clubs" c
    WHERE c.owner_id IS NULL
      AND coalesce(c.is_archived, false) = false
      AND c."ShortName" <> 'FOREIGN'
      AND c."ShortName" IS DISTINCT FROM v_from
    ORDER BY c."Club"
  ) x;

  RETURN jsonb_build_object(
    'ok', true,
    'from_club', v_from,
    'from_stadium_value', v_from_value,
    'supporter_active', v_supporter,
    'can_free_swap', v_supporter AND NOT v_free_used,
    'free_swap_used', v_free_used,
    'paid_fee', 150000000,
    'window_open', true,
    'active_gpsl_month', 'june',
    'vacant', coalesce(v_rows, '[]'::jsonb)
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.owner_club_swap_vacant_list() TO authenticated;

-- ---------------------------------------------------------------------------
-- Club swap (empty target only)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.owner_club_swap_execute(p_to_club_short text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_from text;
  v_to text := upper(btrim(coalesce(p_to_club_short, '')));
  v_from_name text;
  v_to_name text;
  v_tag text;
  v_supporter boolean;
  v_season_id bigint;
  v_free_used boolean := false;
  v_use_free boolean := false;
  v_fee numeric := 0;
  v_from_value numeric;
  v_to_value numeric;
  v_delta numeric;
  v_old_balance numeric := 0;
  v_new_balance numeric := 0;
  v_start numeric := 650000000;
  v_players int := 0;
  v_managers int := 0;
  v_medical int := 0;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not signed in';
  END IF;

  IF v_to = '' THEN
    RAISE EXCEPTION 'Target club required';
  END IF;

  SELECT c."ShortName", c."Club", nullif(btrim(c.owner), '')
  INTO v_from, v_from_name, v_tag
  FROM public."Clubs" c
  WHERE c.owner_id = v_uid
  LIMIT 1;

  IF v_from IS NULL THEN
    RAISE EXCEPTION 'You do not own a club';
  END IF;

  IF v_from = v_to THEN
    RAISE EXCEPTION 'Already at %', v_to;
  END IF;

  IF NOT public.owner_club_swap_window_open() THEN
    RAISE EXCEPTION 'Club swap is only open during GPSL June (one week each season)';
  END IF;

  PERFORM 1 FROM public."Clubs" c WHERE c."ShortName" = v_from FOR UPDATE;
  PERFORM 1 FROM public."Clubs" c WHERE c."ShortName" = v_to FOR UPDATE;

  SELECT c."Club" INTO v_to_name
  FROM public."Clubs" c
  WHERE c."ShortName" = v_to
    AND coalesce(c.is_archived, false) = false;

  IF v_to_name IS NULL THEN
    RAISE EXCEPTION 'Club % not found', v_to;
  END IF;

  IF EXISTS (
    SELECT 1 FROM public."Clubs" c
    WHERE c."ShortName" = v_to AND c.owner_id IS NOT NULL
  ) THEN
    RAISE EXCEPTION 'Target club % is not empty', v_to;
  END IF;

  v_supporter := public.owner_is_supporter_active(v_uid);

  BEGIN
    v_season_id := public.competition_finances_current_season_id();
  EXCEPTION WHEN OTHERS THEN
    v_season_id := NULL;
  END;

  SELECT
    r.supporter_free_swap_season_id IS NOT NULL
    AND v_season_id IS NOT NULL
    AND r.supporter_free_swap_season_id = v_season_id
  INTO v_free_used
  FROM public.gpsl_owner_registry r
  WHERE r.owner_id = v_uid;

  v_free_used := coalesce(v_free_used, false);
  v_use_free := v_supporter AND NOT v_free_used;
  v_fee := CASE WHEN v_use_free THEN 0 ELSE 150000000 END;

  BEGIN
    v_start := greatest(coalesce(public.club_auction_default_starting_balance(), 650000000), 0);
  EXCEPTION WHEN OTHERS THEN
    v_start := 650000000;
  END;

  v_from_value := coalesce(public.club_stadium_value(v_from), 0);
  v_to_value := coalesce(public.club_stadium_value(v_to), 0);
  v_delta := v_to_value - v_from_value;

  IF NOT EXISTS (SELECT 1 FROM public."Club_Finances" f WHERE f.club_name = v_from) THEN
    INSERT INTO public."Club_Finances" (club_name, balance) VALUES (v_from, 0);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public."Club_Finances" f WHERE f.club_name = v_to) THEN
    INSERT INTO public."Club_Finances" (club_name, balance) VALUES (v_to, 0);
  END IF;

  SELECT f.balance INTO v_old_balance
  FROM public."Club_Finances" f
  WHERE f.club_name = v_from
  FOR UPDATE;

  PERFORM 1 FROM public."Club_Finances" f WHERE f.club_name = v_to FOR UPDATE;

  v_new_balance := coalesce(v_old_balance, 0) - v_delta - v_fee;

  IF v_fee > 0 AND coalesce(v_old_balance, 0) < v_fee THEN
    RAISE EXCEPTION 'Club bank needs enough cash for the ₿150m swap fee';
  END IF;

  -- Squad
  IF to_regprocedure('public.player_contracted_club_key(text)') IS NOT NULL THEN
    UPDATE public."Players" p
    SET "Contracted_Team" = v_to
    WHERE public.player_contracted_club_key(p."Contracted_Team") = v_from;
  ELSE
    UPDATE public."Players" p
    SET "Contracted_Team" = v_to
    WHERE upper(btrim(coalesce(p."Contracted_Team", ''))) = v_from;
  END IF;
  GET DIAGNOSTICS v_players = ROW_COUNT;

  UPDATE public."Managers" m
  SET contracted_club = v_to
  WHERE upper(btrim(coalesce(m.contracted_club, ''))) = v_from;
  GET DIAGNOSTICS v_managers = ROW_COUNT;

  BEGIN
    UPDATE public.club_medical_staff
    SET club_short_name = v_to
    WHERE club_short_name = v_from;
    GET DIAGNOSTICS v_medical = ROW_COUNT;
  EXCEPTION WHEN undefined_table THEN
    v_medical := 0;
  END;

  BEGIN
    UPDATE public.international_owner_nations
    SET club_short_name = v_to
    WHERE club_short_name = v_from
      AND is_active = true;
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;

  UPDATE public."Club_Finances"
  SET balance = v_new_balance
  WHERE club_name = v_to;

  UPDATE public."Club_Finances"
  SET balance = v_start
  WHERE club_name = v_from;

  UPDATE public."Clubs"
  SET owner_id = NULL,
      owner = NULL
  WHERE "ShortName" = v_from;

  UPDATE public."Clubs"
  SET owner_id = v_uid,
      owner = coalesce(v_tag, owner)
  WHERE "ShortName" = v_to;

  INSERT INTO public.gpsl_owner_registry (
    owner_id, status, owner_tag, last_club_short_name, status_changed_at,
    supporter_free_swap_season_id
  )
  VALUES (
    v_uid, 'active', v_tag, v_to, now(),
    CASE WHEN v_use_free THEN v_season_id ELSE NULL END
  )
  ON CONFLICT (owner_id) DO UPDATE
  SET status = 'active',
      owner_tag = coalesce(excluded.owner_tag, gpsl_owner_registry.owner_tag),
      last_club_short_name = v_to,
      status_note = NULL,
      status_changed_at = now(),
      supporter_free_swap_season_id = CASE
        WHEN v_use_free THEN v_season_id
        ELSE gpsl_owner_registry.supporter_free_swap_season_id
      END;

  INSERT INTO public.owner_club_swap_log (
    owner_id, from_club_short_name, to_club_short_name, season_id,
    was_supporter, fee_amount, value_delta, balance_moved
  )
  VALUES (
    v_uid, v_from, v_to, v_season_id,
    v_supporter, v_fee, v_delta, v_new_balance
  );

  RETURN jsonb_build_object(
    'ok', true,
    'from_club', v_from,
    'from_club_name', v_from_name,
    'to_club', v_to,
    'to_club_name', v_to_name,
    'supporter_active', v_supporter,
    'used_free_swap', v_use_free,
    'fee', v_fee,
    'value_delta', v_delta,
    'balance_moved', v_new_balance,
    'vacated_starting_balance', v_start,
    'players_moved', v_players,
    'managers_moved', v_managers,
    'medical_moved', v_medical
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.owner_club_swap_execute(text) TO authenticated;

NOTIFY pgrst, 'reload schema';
