-- =============================================================================
-- Stadium maintenance % — admin-adjustable (2026-10-02)
--
-- Was hardcoded at 12.5% of stadium value (capacity × ₿1,500) in the
-- Close Finances posting, the cost helper and several views.
-- Now: global_settings.stadium_maintenance_pct (default 12.5), edited on
-- Admin → Stadium costs. Applies to the next Close Finances.
--
-- Safe to re-run.
-- =============================================================================

ALTER TABLE public.global_settings
  ADD COLUMN IF NOT EXISTS stadium_maintenance_pct numeric(6, 3) NOT NULL DEFAULT 12.5;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'public.global_settings'::regclass
      AND conname = 'global_settings_stadium_maintenance_pct_check'
  ) THEN
    ALTER TABLE public.global_settings
      ADD CONSTRAINT global_settings_stadium_maintenance_pct_check
      CHECK (stadium_maintenance_pct >= 0 AND stadium_maintenance_pct <= 100);
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.stadium_maintenance_rate_pct()
RETURNS numeric
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT coalesce(
    (SELECT g.stadium_maintenance_pct FROM public.global_settings g WHERE g.id = 1),
    12.5
  );
$$;

GRANT EXECUTE ON FUNCTION public.stadium_maintenance_rate_pct() TO anon, authenticated;

CREATE OR REPLACE FUNCTION public.admin_set_stadium_maintenance_pct(p_pct numeric)
RETURNS numeric
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;
  IF p_pct IS NULL OR p_pct < 0 OR p_pct > 100 THEN
    RAISE EXCEPTION 'Maintenance %% must be between 0 and 100';
  END IF;

  UPDATE public.global_settings
  SET stadium_maintenance_pct = round(p_pct, 3)
  WHERE id = 1;

  RETURN public.stadium_maintenance_rate_pct();
END;
$function$;

GRANT EXECUTE ON FUNCTION public.admin_set_stadium_maintenance_pct(numeric) TO authenticated;

-- ---------------------------------------------------------------------------
-- Cost helper + Close Finances posting
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.club_stadium_maintenance_cost(p_club_short_name text)
RETURNS numeric
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT round(
    greatest(coalesce(c."Capacity", 0), 0)::numeric * 1500
      * (public.stadium_maintenance_rate_pct() / 100.0)
  )
  FROM public."Clubs" c
  WHERE c."ShortName" = p_club_short_name;
$$;

COMMENT ON FUNCTION public.club_stadium_maintenance_cost(text) IS
  'Season stadium maintenance: global_settings.stadium_maintenance_pct of stadium value (capacity × ₿1,500).';

GRANT EXECUTE ON FUNCTION public.club_stadium_maintenance_cost(text) TO authenticated;

CREATE OR REPLACE FUNCTION public.competition_post_infra_maintenance(p_season_id bigint)
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club record;
  v_cost numeric;
  v_paid int := 0;
  v_pct numeric := public.stadium_maintenance_rate_pct();
BEGIN
  IF p_season_id IS NULL THEN
    RETURN 0;
  END IF;

  FOR v_club IN
    SELECT
      ccs.club_short_name,
      greatest(coalesce(c."Capacity", 0), 0)::int AS capacity
    FROM public.competition_club_seasons ccs
    JOIN public."Clubs" c ON c."ShortName" = ccs.club_short_name
    WHERE ccs.season_id = p_season_id
      AND ccs.division IN ('superleague', 'championship_a', 'championship_b')
      AND ccs.club_short_name <> 'FOREIGN'
    ORDER BY ccs.club_short_name
  LOOP
    v_cost := round(v_club.capacity::numeric * 1500 * v_pct / 100.0);
    IF v_cost <= 0 THEN
      CONTINUE;
    END IF;

    IF public.competition_post_club_charge(
      p_season_id,
      v_club.club_short_name,
      'infra_maintenance',
      v_cost,
      format(
        'Stadium maintenance — %s seats × ₿1,500 × %s%%',
        to_char(v_club.capacity, 'FM999,999,999'),
        trim(trailing '.' FROM trim(trailing '0' FROM v_pct::text))
      ),
      jsonb_build_object(
        'capacity', v_club.capacity,
        'value_per_seat', 1500,
        'rate_pct', v_pct,
        'stadium_value', v_club.capacity * 1500
      )
    ) THEN
      v_paid := v_paid + 1;
    END IF;
  END LOOP;

  RETURN v_paid;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_post_infra_maintenance(bigint) TO authenticated;

-- ---------------------------------------------------------------------------
-- Views that show maintenance (club database, club auction, GPDB):
-- swap the hardcoded "* 0.125" for the setting, keeping view options.
-- ---------------------------------------------------------------------------
DO $views$
DECLARE
  r record;
  v_def text;
  v_new text;
  v_opts text;
BEGIN
  FOR r IN
    SELECT c.oid, c.relname, c.reloptions
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public'
      AND c.relkind = 'v'
  LOOP
    v_def := pg_get_viewdef(r.oid);
    IF v_def NOT ILIKE '%capacity%' OR position('* 0.125' IN v_def) = 0 THEN
      CONTINUE;
    END IF;

    v_new := replace(v_def, '* 0.125', '* (public.stadium_maintenance_rate_pct() / 100.0)');
    v_opts := CASE WHEN r.reloptions IS NOT NULL
                   THEN format(' WITH (%s)', array_to_string(r.reloptions, ', '))
                   ELSE '' END;

    BEGIN
      EXECUTE format('CREATE OR REPLACE VIEW public.%I%s AS %s', r.relname, v_opts, v_new);
      RAISE NOTICE 'Maintenance %% now from setting in view %', r.relname;
    EXCEPTION WHEN OTHERS THEN
      RAISE NOTICE 'View % left unchanged (%)', r.relname, SQLERRM;
    END;
  END LOOP;
END;
$views$;

NOTIFY pgrst, 'reload schema';
