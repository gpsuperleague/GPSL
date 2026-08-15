-- =============================================================================
-- Manager sack/list: mid-spell tenure + calendar window
--
-- Rules:
--   • List/sack calendar: June, July, January (not August) / pre-season
--   • Mid-spell tenure for BOTH list and sack: summer signing → January;
--     January signing → next June–July/January
--   • Archived managers may be sacked without mid-spell wait (cannot list)
--
-- Also exposes sack_tenure_eligible on manager_club_status_public for UI
-- (used for both List and Sack buttons).
-- Also run manager_list_tenure_fix_20260815.sql for list RPC tenure.
-- Safe re-run.
-- =============================================================================

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

  IF v_month IN ('june', 'july') THEN
    RETURN true;
  END IF;

  IF v_month = 'january' AND coalesce(v_tw, false) THEN
    RETURN true;
  END IF;

  RETURN false;
END;
$function$;

CREATE OR REPLACE FUNCTION public.manager_sack_window_open()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT public.manager_list_sack_window_open();
$$;

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
    RETURN (v_season > p_signed_season_id)
        OR (v_season = p_signed_season_id AND v_month = 'january');
  END IF;

  -- January cohort → first chance next season's June/July/January
  RETURN v_season > p_signed_season_id
    AND (
      v_month IN ('june', 'july', 'january')
      OR v_season > p_signed_season_id + 1
    );
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
      'Manager sack is only available in June, July, or the January transfer window';
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

  -- Archived: allow sack without mid-spell (cannot list them)
  IF NOT coalesce(v_mgr.archived, false)
     AND NOT public.manager_sack_tenure_eligible(
       v_mgr.signed_season_id, v_mgr.signed_gpsl_month, v_season_id, v_month
     ) THEN
    RAISE EXCEPTION
      'Cannot sack yet — managers must reach mid-season in their first spell (summer signings: January; January signings: next June–July)';
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

DROP VIEW IF EXISTS public.manager_club_status_public;

CREATE VIEW public.manager_club_status_public
WITH (security_invoker = true)
AS
SELECT
  c."ShortName" AS club_short_name,
  m.id AS manager_id,
  m.name AS manager_name,
  m.rating AS manager_rating,
  m.market_value,
  m.contract_seasons_remaining,
  m.weekly_wage,
  m.pending_owner_renewal,
  m.deal_start_season_id,
  m.signed_season_id,
  m.signed_gpsl_month,
  coalesce(m.archived, false) AS manager_archived,
  c.manager_sacks_remaining,
  coalesce(pos.division, ccs.division) AS division,
  pos.season_position,
  t.target_kind,
  t.target_value,
  t.label AS target_label,
  public.manager_target_met(
    t,
    pos.season_position,
    coalesce(pos.division, ccs.division)
  ) AS target_met,
  public.manager_boost_band_label(1, e.boost1_min, e.boost1_max) AS boost1_label,
  public.manager_boost_band_label(2, e.boost2_min, e.boost2_max) AS boost2_label,
  public.manager_boost_band_label(3, e.boost3_min, e.boost3_max) AS boost3_label,
  (
    SELECT count(*)::int
    FROM public.manager_deal_season_results r
    WHERE r.manager_id = m.id
      AND r.club_short_name = c."ShortName"
      AND r.deal_start_season_id = coalesce(m.deal_start_season_id, m.signed_season_id)
      AND r.target_met IS TRUE
  ) AS deal_target_hits,
  (
    SELECT count(*)::int
    FROM public.manager_deal_season_results r
    WHERE r.manager_id = m.id
      AND r.club_short_name = c."ShortName"
      AND r.deal_start_season_id = coalesce(m.deal_start_season_id, m.signed_season_id)
      AND r.target_met IS FALSE
  ) AS deal_target_misses,
  CASE
    WHEN m.id IS NULL THEN false
    WHEN coalesce(m.archived, false) THEN true
    ELSE public.manager_sack_tenure_eligible(
      m.signed_season_id,
      m.signed_gpsl_month,
      s.id,
      public.competition_active_gpsl_month(s.id, now())
    )
  END AS sack_tenure_eligible
FROM public."Clubs" c
LEFT JOIN public."Managers" m ON m.id = c.manager_id
LEFT JOIN public.competition_seasons s ON s.is_current = true
LEFT JOIN public.competition_club_seasons ccs
  ON ccs.club_short_name = c."ShortName" AND ccs.season_id = s.id
LEFT JOIN LATERAL public.manager_club_season_position(s.id, c."ShortName") pos ON s.id IS NOT NULL
LEFT JOIN public.manager_rating_targets t
  ON m.id IS NOT NULL
  AND coalesce(pos.division, ccs.division) IS NOT NULL
  AND m.rating BETWEEN t.min_rating AND t.max_rating
  AND t.division = coalesce(pos.division, ccs.division)
  AND t.id = (
    SELECT t2.id
    FROM public.manager_rating_targets t2
    WHERE t2.division = coalesce(pos.division, ccs.division)
      AND m.rating BETWEEN t2.min_rating AND t2.max_rating
    ORDER BY t2.sort_order, t2.id
    LIMIT 1
  )
LEFT JOIN public.manager_proficiency_expectancy e
  ON m.id IS NOT NULL
  AND e.proficiency = public.manager_proficiency_clamp(m.rating);

GRANT SELECT ON public.manager_club_status_public TO authenticated;
GRANT SELECT ON public.manager_club_status_public TO anon;

GRANT EXECUTE ON FUNCTION public.manager_list_sack_window_open() TO authenticated;
GRANT EXECUTE ON FUNCTION public.manager_sack_window_open() TO authenticated;
GRANT EXECUTE ON FUNCTION public.manager_sack_tenure_eligible(bigint, text, bigint, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.manager_sack() TO authenticated;

NOTIFY pgrst, 'reload schema';
