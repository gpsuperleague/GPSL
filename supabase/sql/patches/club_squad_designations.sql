-- =============================================================================
-- Club squad designations: Star player (79+) and One of our own (home-grown)
-- Star caps: Super League 3, Championship 2. OOO does not count toward star cap.
-- Star tax (wage_star_tax) counts designated stars only — not all high-rated players.
-- Run after squad_composition_rules.sql + player_wage_settings.sql + competition_wages_taxes.sql
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.club_squad_player_designations (
  club_short_name text NOT NULL,
  player_id text NOT NULL,
  designation text NOT NULL,
  assigned_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT club_squad_player_designations_designation_check
    CHECK (designation IN ('star', 'one_of_our_own')),
  CONSTRAINT club_squad_player_designations_pkey
    PRIMARY KEY (club_short_name, player_id)
);

CREATE INDEX IF NOT EXISTS club_squad_player_designations_club_idx
  ON public.club_squad_player_designations (club_short_name);

CREATE UNIQUE INDEX IF NOT EXISTS club_squad_player_designations_one_ooo_per_club
  ON public.club_squad_player_designations (club_short_name)
  WHERE designation = 'one_of_our_own';

CREATE OR REPLACE FUNCTION public.club_squad_star_cap(p_club_short_name text)
RETURNS smallint
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_tier text;
BEGIN
  v_tier := public.competition_club_division_tier(p_club_short_name);
  IF v_tier = 'superleague' THEN
    RETURN 3;
  END IF;
  RETURN 2;
END;
$function$;

CREATE OR REPLACE FUNCTION public.club_squad_star_min_rating()
RETURNS smallint
LANGUAGE sql
STABLE
SET search_path = public
AS $$
  SELECT coalesce(
    (SELECT star_tax_min_rating FROM public.global_settings WHERE id = 1),
    79
  )::smallint;
$$;

CREATE OR REPLACE FUNCTION public.club_squad_player_rating(p_player_id text)
RETURNS integer
LANGUAGE sql
STABLE
SET search_path = public
AS $$
  SELECT nullif(
    regexp_replace(coalesce(btrim(p."Rating"::text), ''), '[^0-9]', '', 'g'),
    ''
  )::integer
  FROM public."Players" p
  WHERE p."Konami_ID"::text = btrim(p_player_id);
$$;

CREATE OR REPLACE FUNCTION public.club_squad_player_age(p_player_id text)
RETURNS integer
LANGUAGE sql
STABLE
SET search_path = public
AS $$
  SELECT nullif(btrim(p."Age"::text), '')::integer
  FROM public."Players" p
  WHERE p."Konami_ID"::text = btrim(p_player_id);
$$;

CREATE OR REPLACE FUNCTION public.club_squad_player_eligible_star(
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
  v_min smallint;
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public."Players" p
    WHERE p."Konami_ID"::text = btrim(p_player_id)
      AND p."Contracted_Team" = p_club_short_name
  ) THEN
    RETURN false;
  END IF;

  v_min := public.club_squad_star_min_rating();
  v_rating := public.club_squad_player_rating(p_player_id);
  RETURN v_rating IS NOT NULL AND v_rating >= v_min;
END;
$function$;

CREATE OR REPLACE FUNCTION public.club_squad_player_eligible_one_of_our_own(
  p_player_id text,
  p_club_short_name text
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT public.is_player_homegrown(btrim(p_player_id), p_club_short_name)
    AND EXISTS (
      SELECT 1 FROM public."Players" p
      WHERE p."Konami_ID"::text = btrim(p_player_id)
        AND p."Contracted_Team" = p_club_short_name
    );
$$;

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
  v_tier text;
  v_min smallint;
BEGIN
  IF v_club IS NULL OR v_club = '' THEN
    RAISE EXCEPTION 'Club required';
  END IF;

  IF NOT public.is_gpsl_admin()
     AND public.my_club_shortname() IS DISTINCT FROM v_club THEN
    RAISE EXCEPTION 'Not allowed';
  END IF;

  v_cap := public.club_squad_star_cap(v_club);
  v_tier := public.competition_club_division_tier(v_club);
  v_min := public.club_squad_star_min_rating();

  SELECT count(*)::integer INTO v_star_count
  FROM public.club_squad_player_designations d
  WHERE d.club_short_name = v_club
    AND d.designation = 'star';

  SELECT d.player_id INTO v_ooo
  FROM public.club_squad_player_designations d
  WHERE d.club_short_name = v_club
    AND d.designation = 'one_of_our_own'
  LIMIT 1;

  RETURN jsonb_build_object(
    'club_short_name', v_club,
    'division_tier', v_tier,
    'star_cap', v_cap,
    'star_count', coalesce(v_star_count, 0),
    'star_min_rating', v_min,
    'one_of_our_own_player_id', v_ooo,
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
  v_cap smallint;
  v_star_count integer;
  v_current text;
BEGIN
  IF v_club IS NULL OR v_club = '' THEN
    RAISE EXCEPTION 'No club linked to your account';
  END IF;

  IF v_player IS NULL OR v_player = '' THEN
    RAISE EXCEPTION 'Player required';
  END IF;

  IF v_desig IS NOT NULL AND v_desig NOT IN ('star', 'one_of_our_own') THEN
    RAISE EXCEPTION 'Invalid designation';
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

  IF v_desig = 'star' THEN
    IF NOT public.club_squad_player_eligible_star(v_player, v_club) THEN
      RAISE EXCEPTION 'Star players must be rated % or higher', public.club_squad_star_min_rating();
    END IF;

    v_cap := public.club_squad_star_cap(v_club);
    SELECT count(*)::integer INTO v_star_count
    FROM public.club_squad_player_designations d
    WHERE d.club_short_name = v_club
      AND d.designation = 'star'
      AND d.player_id <> v_player;

    IF coalesce(v_star_count, 0) >= v_cap THEN
      RAISE EXCEPTION 'Star player limit reached (% for %)', v_cap, public.competition_club_division_tier(v_club);
    END IF;
  ELSIF v_desig = 'one_of_our_own' THEN
    IF NOT public.club_squad_player_eligible_one_of_our_own(v_player, v_club) THEN
      RAISE EXCEPTION 'One of our own must be home-grown (player Nation matches club Nation)';
    END IF;

    DELETE FROM public.club_squad_player_designations
    WHERE club_short_name = v_club
      AND designation = 'one_of_our_own'
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
  IF NOT public.is_gpsl_admin()
     AND public.my_club_shortname() IS DISTINCT FROM v_club THEN
    RAISE EXCEPTION 'Not allowed';
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
    AND public.is_player_homegrown(p."Konami_ID"::text, v_club)
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
    RETURN jsonb_build_object('ok', false, 'reason', 'no_eligible_homegrown');
  END IF;

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

CREATE OR REPLACE FUNCTION public.club_squad_designations_purge_player()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF TG_OP = 'UPDATE'
     AND coalesce(NEW."Contracted_Team", '') IS DISTINCT FROM coalesce(OLD."Contracted_Team", '') THEN
    DELETE FROM public.club_squad_player_designations
    WHERE player_id = OLD."Konami_ID"::text
      AND club_short_name = coalesce(OLD."Contracted_Team", '');
  END IF;
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS club_squad_designations_purge_player_trg ON public."Players";
CREATE TRIGGER club_squad_designations_purge_player_trg
  AFTER UPDATE OF "Contracted_Team" ON public."Players"
  FOR EACH ROW
  EXECUTE FUNCTION public.club_squad_designations_purge_player();

-- Star tax: designated stars only (OOO never counted — separate designation)
CREATE OR REPLACE FUNCTION public.competition_club_star_tax_count(p_club_short_name text)
RETURNS int
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  RETURN (
    SELECT count(*)::int
    FROM public.club_squad_player_designations d
    INNER JOIN public."Players" p
      ON p."Konami_ID"::text = d.player_id
      AND p."Contracted_Team" = d.club_short_name
    WHERE d.club_short_name = p_club_short_name
      AND d.designation = 'star'
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.competition_post_club_star_tax(
  p_season_id bigint,
  p_club_short_name text
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_count int;
  v_rate numeric;
  v_min int;
  v_amount numeric;
BEGIN
  v_count := public.competition_club_star_tax_count(p_club_short_name);
  IF v_count = 0 THEN
    RETURN false;
  END IF;

  SELECT star_tax_per_player, star_tax_min_rating
  INTO v_rate, v_min
  FROM public.global_settings WHERE id = 1;

  v_amount := round(v_count * coalesce(v_rate, 0), 0);

  RETURN public.competition_post_club_charge(
    p_season_id,
    p_club_short_name,
    'wage_star_tax',
    v_amount,
    format('Star maintenance — %s designated star player(s)', v_count),
    jsonb_build_object('player_count', v_count, 'min_rating', v_min)
  );
END;
$function$;

GRANT SELECT ON public.club_squad_player_designations TO authenticated;
GRANT EXECUTE ON FUNCTION public.club_squad_star_cap(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.club_squad_designations_state(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.club_squad_set_designation(text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.club_assign_random_one_of_our_own(text) TO authenticated;

NOTIFY pgrst, 'reload schema';
