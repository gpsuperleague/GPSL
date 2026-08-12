-- =============================================================================
-- Fan Favourite designation (mutually exclusive with One of our own)
-- =============================================================================
-- Rules:
--   • Club whose nation GPDB pool has ≥1×79+ → may set OooO OR Fan Favourite (not both)
--   • Club whose nation has no 79+ in pool → Fan Favourite only
--   • Fan Favourite: contracted player rated 76–78, any nationality
--   • Edit window: UK June, July, January (admins anytime)
--   • Season wage bill: Central Bank pays 50% of FF contract wage (club charged
--     full squad wages, then credited 50% FF as wage_fan_favourite_subsidy)
-- =============================================================================

-- 1) Allow new designation value
ALTER TABLE public.club_squad_player_designations
  DROP CONSTRAINT IF EXISTS club_squad_player_designations_designation_check;

ALTER TABLE public.club_squad_player_designations
  ADD CONSTRAINT club_squad_player_designations_designation_check
  CHECK (designation IN ('star', 'one_of_our_own', 'fan_favourite'));

CREATE UNIQUE INDEX IF NOT EXISTS club_squad_player_designations_one_ff_per_club
  ON public.club_squad_player_designations (club_short_name)
  WHERE designation = 'fan_favourite';

-- 2) Ledger allow-list + central-bank routing for subsidy
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
      'wage_squad',
      'wage_renewal_34plus',
      'wage_star_tax',
      'wage_fan_favourite_subsidy'
    ])
  ) s;

  IF v_list IS NOT NULL THEN
    ALTER TABLE public.competition_finance_ledger
      DROP CONSTRAINT IF EXISTS competition_finance_ledger_entry_type_check;
    EXECUTE format(
      'ALTER TABLE public.competition_finance_ledger
         ADD CONSTRAINT competition_finance_ledger_entry_type_check
         CHECK (entry_type IN (%s))',
      v_list
    );
  END IF;
END;
$ledger_types$;

CREATE OR REPLACE FUNCTION public.finance_entry_via_central_bank(p_entry_type text)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT coalesce(p_entry_type, '') = ANY(ARRAY[
    'gov_hg_subsidy',
    'gov_youth_subsidy',
    'gov_bnb_subsidy',
    'gov_emergency_tax',
    'gov_income_tax',
    'gov_fine_compensation',
    'wage_star_tax',
    'wage_fan_favourite_subsidy',
    'eos_debt_interest',
    'eos_ffp_charge',
    'eos_balance_interest',
    'eos_injection',
    'prize',
    'prize_league',
    'prize_cup',
    'prize_challenge',
    'tv_revenue',
    'infra_purchase',
    'infra_expansion',
    'infra_expansion_refund',
    'infra_expansion_penalty',
    'loan_drawdown',
    'loan_repayment_principal',
    'loan_interest_payment',
    'admin_one_off_injection',
    'contract_release_comp_received',
    'special_auction_prize',
    'new_owner_release'
  ]);
$$;

-- 3) Helpers ------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.club_squad_designation_edit_window_open()
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
BEGIN
  IF to_regprocedure('public.competition_finances_current_season_id()') IS NOT NULL THEN
    v_season_id := public.competition_finances_current_season_id();
  ELSIF to_regprocedure('public.current_gpsl_season_id()') IS NOT NULL THEN
    v_season_id := public.current_gpsl_season_id();
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

  SELECT s.status INTO v_status
  FROM public.competition_seasons s
  WHERE s.id = v_season_id;

  IF v_status IN ('preseason', 'setup') THEN
    RETURN true;
  END IF;

  IF to_regprocedure('public.competition_active_gpsl_month(bigint, timestamptz)') IS NOT NULL THEN
    v_month := lower(btrim(coalesce(
      public.competition_active_gpsl_month(v_season_id, now()),
      ''
    )));
  END IF;

  RETURN v_month IN ('june', 'july', 'january');
END;
$function$;

COMMENT ON FUNCTION public.club_squad_designation_edit_window_open() IS
  'OooO / Fan Favourite editable in GPSL preseason/setup, or GPSL months june/july/january.';

CREATE OR REPLACE FUNCTION public.club_nation_has_gpdb_star(p_club_short_name text)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := btrim(p_club_short_name);
  v_nation text;
  v_code text;
  v_stars integer;
BEGIN
  IF v_club IS NULL OR v_club = '' THEN
    RETURN false;
  END IF;

  SELECT c."Nation"::text INTO v_nation
  FROM public."Clubs" c
  WHERE c."ShortName" = v_club;

  IF v_nation IS NULL OR btrim(v_nation) = '' THEN
    RETURN false;
  END IF;

  IF to_regclass('public.international_gpdb_label_map') IS NOT NULL
     AND to_regclass('public.international_nation_player_pool_cache') IS NOT NULL THEN
    SELECT m.nation_code INTO v_code
    FROM public.international_gpdb_label_map m
    WHERE m.norm_label = public.international_normalize_nation_label(v_nation)
    LIMIT 1;

    IF v_code IS NOT NULL THEN
      SELECT coalesce((cache.pool->'r79_plus'->>'total')::integer, 0)
      INTO v_stars
      FROM public.international_nation_player_pool_cache cache
      WHERE cache.nation_code = v_code;

      IF v_stars IS NOT NULL THEN
        RETURN v_stars > 0;
      END IF;
    END IF;
  END IF;

  -- Fallback: any GPDB player of this nation rated at/above star minimum
  SELECT count(*)::integer INTO v_stars
  FROM public."Players" p
  WHERE public.international_normalize_nation_label(p."Nation")
          = public.international_normalize_nation_label(v_nation)
    AND coalesce(public.club_squad_player_rating(p."Konami_ID"::text), 0)
          >= public.club_squad_star_min_rating();

  RETURN coalesce(v_stars, 0) > 0;
END;
$function$;

CREATE OR REPLACE FUNCTION public.club_squad_player_eligible_fan_favourite(
  p_player_id text,
  p_club_short_name text
)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_rating integer;
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public."Players" p
    WHERE p."Konami_ID"::text = btrim(p_player_id)
      AND p."Contracted_Team" = p_club_short_name
  ) THEN
    RETURN false;
  END IF;

  v_rating := public.club_squad_player_rating(p_player_id);
  RETURN v_rating IS NOT NULL AND v_rating BETWEEN 76 AND 78;
END;
$function$;

CREATE OR REPLACE FUNCTION public.club_squad_fan_favourite_wage_half(p_club_short_name text)
RETURNS TABLE (
  player_id text,
  player_name text,
  full_wage numeric,
  subsidy_half numeric
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_pid text;
  v_name text;
  v_wage numeric;
BEGIN
  SELECT d.player_id INTO v_pid
  FROM public.club_squad_player_designations d
  WHERE d.club_short_name = p_club_short_name
    AND d.designation = 'fan_favourite'
  LIMIT 1;

  IF v_pid IS NULL THEN
    RETURN;
  END IF;

  SELECT p."Name"::text,
         coalesce(
           nullif(p.contract_wage, 0),
           public.calculate_player_wage_for_club(v_pid, p_club_short_name)
         )
  INTO v_name, v_wage
  FROM public."Players" p
  WHERE p."Konami_ID"::text = v_pid
    AND p."Contracted_Team" = p_club_short_name;

  IF v_wage IS NULL OR v_wage <= 0 THEN
    RETURN;
  END IF;

  player_id := v_pid;
  player_name := v_name;
  full_wage := round(v_wage, 0);
  subsidy_half := round(v_wage / 2.0, 0);
  RETURN NEXT;
END;
$function$;

-- 4) State + set designation --------------------------------------------------

CREATE OR REPLACE FUNCTION public.club_squad_designations_state(p_club_short_name text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := coalesce(nullif(btrim(p_club_short_name), ''), public.my_club_shortname());
  v_cap smallint;
  v_star_count integer;
  v_ooo text;
  v_ff text;
  v_tier text;
  v_min smallint;
  v_ooo_allowed boolean;
  v_edit_open boolean;
BEGIN
  IF v_club IS NULL OR v_club = '' THEN
    RAISE EXCEPTION 'Club required';
  END IF;

  IF NOT public.club_squad_designations_is_privileged()
     AND public.my_club_shortname() IS DISTINCT FROM v_club THEN
    RAISE EXCEPTION 'Not allowed';
  END IF;

  v_cap := public.club_squad_star_cap(v_club);
  v_tier := public.competition_club_division_tier(v_club);
  v_min := public.club_squad_star_min_rating();
  v_ooo_allowed := public.club_nation_has_gpdb_star(v_club);
  v_edit_open := public.club_squad_designation_edit_window_open()
    OR public.is_gpsl_admin();

  SELECT d.player_id INTO v_ooo
  FROM public.club_squad_player_designations d
  WHERE d.club_short_name = v_club
    AND d.designation = 'one_of_our_own'
  LIMIT 1;

  SELECT d.player_id INTO v_ff
  FROM public.club_squad_player_designations d
  WHERE d.club_short_name = v_club
    AND d.designation = 'fan_favourite'
  LIMIT 1;

  SELECT count(*)::integer INTO v_star_count
  FROM public."Players" p
  WHERE p."Contracted_Team" = v_club
    AND nullif(regexp_replace(coalesce(btrim(p."Rating"::text), ''), '[^0-9]', '', 'g'), '')::integer >= v_min
    AND (v_ooo IS NULL OR p."Konami_ID"::text <> v_ooo);

  RETURN jsonb_build_object(
    'club_short_name', v_club,
    'division_tier', v_tier,
    'star_cap', v_cap,
    'star_count', coalesce(v_star_count, 0),
    'star_min_rating', v_min,
    'one_of_our_own_player_id', v_ooo,
    'fan_favourite_player_id', v_ff,
    'ooo_allowed', v_ooo_allowed,
    'fan_favourite_allowed', true,
    'designation_edit_open', v_edit_open,
    'designation_edit_months', jsonb_build_array(1, 6, 7),
    'designations', coalesce(
      (
        SELECT jsonb_object_agg(d.player_id, d.designation)
        FROM public.club_squad_player_designations d
        INNER JOIN public."Players" p
          ON p."Konami_ID"::text = d.player_id
          AND p."Contracted_Team" = d.club_short_name
        WHERE d.club_short_name = v_club
      ),
      '{}'::jsonb
    )
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.club_squad_set_designation(
  p_player_id text,
  p_designation text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := public.my_club_shortname();
  v_player text := btrim(p_player_id);
  v_desig text := nullif(lower(btrim(coalesce(p_designation, ''))), '');
  v_current text;
  v_admin boolean := public.is_gpsl_admin();
BEGIN
  IF v_club IS NULL OR v_club = '' THEN
    RAISE EXCEPTION 'No club linked to your account';
  END IF;

  IF v_player IS NULL OR v_player = '' THEN
    RAISE EXCEPTION 'Player required';
  END IF;

  IF v_desig = 'star' THEN
    RAISE EXCEPTION 'Star players are automatic (rating-based) — set One of our own or Fan Favourite only';
  END IF;

  IF v_desig IS NOT NULL
     AND v_desig NOT IN ('one_of_our_own', 'fan_favourite') THEN
    RAISE EXCEPTION 'Invalid designation';
  END IF;

  IF NOT v_admin AND NOT public.club_squad_designation_edit_window_open() THEN
    RAISE EXCEPTION
      'One of our own / Fan Favourite can only be changed in GPSL preseason (June/July) or January';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public."Players" p
    WHERE p."Konami_ID"::text = v_player
      AND p."Contracted_Team" = v_club
  ) THEN
    RAISE EXCEPTION 'Player is not on your squad';
  END IF;

  SELECT d.designation INTO v_current
  FROM public.club_squad_player_designations d
  WHERE d.club_short_name = v_club
    AND d.player_id = v_player;

  IF v_desig IS NULL THEN
    DELETE FROM public.club_squad_player_designations
    WHERE club_short_name = v_club AND player_id = v_player;
    RETURN public.club_squad_designations_state(v_club);
  END IF;

  IF v_desig = 'one_of_our_own' THEN
    IF NOT public.club_nation_has_gpdb_star(v_club) THEN
      RAISE EXCEPTION
        'Your nation has no 79+ stars in the GPDB pool — Fan Favourite only';
    END IF;
    IF NOT public.club_squad_player_eligible_one_of_our_own(v_player, v_club) THEN
      RAISE EXCEPTION
        'One of our own must be home-grown (Nation matches club) and rated % or higher',
        public.club_squad_star_min_rating();
    END IF;

    -- Mutual exclusion: clear Fan Favourite on this club
    DELETE FROM public.club_squad_player_designations
    WHERE club_short_name = v_club
      AND designation IN ('one_of_our_own', 'fan_favourite')
      AND player_id <> v_player;
  END IF;

  IF v_desig = 'fan_favourite' THEN
    IF NOT public.club_squad_player_eligible_fan_favourite(v_player, v_club) THEN
      RAISE EXCEPTION 'Fan Favourite must be a squad player rated 76, 77, or 78';
    END IF;

    -- Mutual exclusion: clear OooO on this club
    DELETE FROM public.club_squad_player_designations
    WHERE club_short_name = v_club
      AND designation IN ('one_of_our_own', 'fan_favourite')
      AND player_id <> v_player;
  END IF;

  INSERT INTO public.club_squad_player_designations (club_short_name, player_id, designation)
  VALUES (v_club, v_player, v_desig)
  ON CONFLICT (club_short_name, player_id) DO UPDATE
    SET designation = excluded.designation,
        assigned_at = now();

  RETURN public.club_squad_designations_state(v_club);
END;
$function$;

-- Random OooO assign: also clear Fan Favourite; respect nation star + window
CREATE OR REPLACE FUNCTION public.club_assign_random_one_of_our_own(p_club_short_name text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := btrim(p_club_short_name);
  v_player text;
BEGIN
  IF NOT public.club_squad_designations_is_privileged()
     AND public.my_club_shortname() IS DISTINCT FROM v_club THEN
    RAISE EXCEPTION 'Not allowed';
  END IF;

  IF NOT public.is_gpsl_admin()
     AND NOT public.club_squad_designation_edit_window_open() THEN
    RAISE EXCEPTION
      'One of our own / Fan Favourite can only be changed in GPSL preseason (June/July) or January';
  END IF;

  IF NOT public.club_nation_has_gpdb_star(v_club) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'nation_no_star_pool');
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.club_squad_player_designations d
    WHERE d.club_short_name = v_club AND d.designation = 'one_of_our_own'
  ) THEN
    RETURN public.club_squad_designations_state(v_club);
  END IF;

  SELECT p."Konami_ID"::text INTO v_player
  FROM public."Players" p
  WHERE p."Contracted_Team" = v_club
    AND public.club_squad_player_eligible_one_of_our_own(p."Konami_ID"::text, v_club)
  ORDER BY
    CASE
      WHEN public.club_squad_player_age(p."Konami_ID"::text) IS NOT NULL
           AND public.club_squad_player_age(p."Konami_ID"::text) <= 28 THEN 0
      ELSE 1
    END,
    public.club_squad_player_rating(p."Konami_ID"::text) DESC NULLS LAST,
    random()
  LIMIT 1;

  IF v_player IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_eligible_homegrown_star');
  END IF;

  DELETE FROM public.club_squad_player_designations
  WHERE club_short_name = v_club
    AND designation = 'fan_favourite';

  INSERT INTO public.club_squad_player_designations (club_short_name, player_id, designation)
  VALUES (v_club, v_player, 'one_of_our_own')
  ON CONFLICT (club_short_name, player_id) DO UPDATE
    SET designation = 'one_of_our_own',
        assigned_at = now();

  RETURN jsonb_build_object(
    'ok', true,
    'player_id', v_player,
    'state', public.club_squad_designations_state(v_club)
  );
END;
$function$;

-- 5) Wage bill: full charge + CB 50% FF subsidy --------------------------------

CREATE OR REPLACE FUNCTION public.competition_post_club_wage_bill(
  p_season_id bigint,
  p_club_short_name text
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_amount numeric;
  v_ff record;
  v_posted boolean;
BEGIN
  v_amount := public.competition_club_wage_bill_total(p_club_short_name, p_season_id);

  v_posted := public.competition_post_club_charge(
    p_season_id,
    p_club_short_name,
    'wage_squad',
    v_amount,
    format('Season squad wages — %s players', (
      SELECT count(*)::int FROM public."Players" WHERE "Contracted_Team" = p_club_short_name
    )),
    jsonb_build_object('wage_bill', v_amount)
  );

  -- If wages already posted this season, still try FF subsidy once
  IF NOT v_posted AND EXISTS (
    SELECT 1 FROM public.competition_season_charge_paid
    WHERE season_id = p_season_id
      AND club_short_name = p_club_short_name
      AND charge_type = 'wage_squad'
  ) THEN
    v_posted := true;
  END IF;

  IF NOT v_posted THEN
    RETURN false;
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.competition_season_charge_paid
    WHERE season_id = p_season_id
      AND club_short_name = p_club_short_name
      AND charge_type = 'wage_fan_favourite_subsidy'
  ) THEN
    RETURN true;
  END IF;

  SELECT * INTO v_ff
  FROM public.club_squad_fan_favourite_wage_half(p_club_short_name)
  LIMIT 1;

  IF v_ff.subsidy_half IS NULL OR v_ff.subsidy_half <= 0 THEN
    RETURN true;
  END IF;

  PERFORM public.post_club_ledger(
    p_club_short_name,
    'wage_fan_favourite_subsidy',
    v_ff.subsidy_half,
    format(
      'Fan Favourite wage subsidy (50%%) — %s',
      coalesce(v_ff.player_name, v_ff.player_id)
    ),
    jsonb_build_object(
      'player_id', v_ff.player_id,
      'full_wage', v_ff.full_wage,
      'subsidy_pct', 50,
      'subsidy_half', v_ff.subsidy_half
    ),
    p_season_id,
    NULL,
    true,
    true
  );

  INSERT INTO public.competition_season_charge_paid (
    season_id, club_short_name, charge_type, amount, metadata
  )
  VALUES (
    p_season_id,
    p_club_short_name,
    'wage_fan_favourite_subsidy',
    v_ff.subsidy_half,
    jsonb_build_object(
      'player_id', v_ff.player_id,
      'full_wage', v_ff.full_wage,
      'subsidy_pct', 50
    )
  );

  RETURN true;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.club_squad_designation_edit_window_open() TO authenticated;
GRANT EXECUTE ON FUNCTION public.club_nation_has_gpdb_star(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.club_squad_player_eligible_fan_favourite(text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.club_squad_fan_favourite_wage_half(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.club_squad_designations_state(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.club_squad_set_designation(text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.club_assign_random_one_of_our_own(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.competition_post_club_wage_bill(bigint, text) TO authenticated;

NOTIFY pgrst, 'reload schema';
