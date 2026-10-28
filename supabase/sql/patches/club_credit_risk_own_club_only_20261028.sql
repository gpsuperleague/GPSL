-- =============================================================================
-- Credit rating: own club only (admins may query any)
-- Hardens club_credit_risk_status so clubs cannot read each other's risk.
-- Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.club_credit_risk_status(p_club text)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := upper(btrim(coalesce(p_club, '')));
  v_mine text := upper(btrim(coalesce(public.my_club_shortname(), '')));
  v_limit int := public.club_credit_overdrawn_months_limit();
  v_lookback int := public.club_credit_ffp_lookback_seasons();
  v_streak int := 0;
  v_checked int := 0;
  v_ffp_seasons jsonb;
  v_negative_seasons int := 0;
  r record;
BEGIN
  IF v_club = '' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_club');
  END IF;

  -- Owners: own club only. Admins / service may query any.
  IF auth.uid() IS NOT NULL
     AND v_club IS DISTINCT FROM v_mine
     AND NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Not your club';
  END IF;

  FOR r IN
    SELECT b.balance
    FROM public.club_month_end_balances b
    WHERE b.club_short_name = v_club
    ORDER BY b.checkpoint_at DESC
    LIMIT v_limit
  LOOP
    v_checked := v_checked + 1;
    EXIT WHEN r.balance >= 0;
    v_streak := v_streak + 1;
  END LOOP;

  SELECT coalesce(jsonb_agg(
           jsonb_build_object('season_id', s.id, 'season_label', s.label)
           ORDER BY s.id DESC
         ), '[]'::jsonb)
  INTO v_ffp_seasons
  FROM (
    SELECT id, label FROM public.competition_seasons ORDER BY id DESC LIMIT v_lookback
  ) s
  WHERE EXISTS (
    SELECT 1 FROM public.competition_season_charge_paid cp
    WHERE cp.season_id = s.id
      AND cp.club_short_name = v_club
      AND cp.charge_type = 'eos_ffp_charge'
  );

  IF to_regprocedure('public.club_loan_negative_season_count(text)') IS NOT NULL THEN
    v_negative_seasons := public.club_loan_negative_season_count(v_club);
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'club', v_club,
    'overdrawn_month_ends', v_streak,
    'overdrawn_month_ends_limit', v_limit,
    'overdrawn_risk', v_streak >= v_limit,
    'ffp_seasons', v_ffp_seasons,
    'ffp_lookback_seasons', v_lookback,
    'ffp_risk', jsonb_array_length(v_ffp_seasons) > 0,
    'negative_seasons', v_negative_seasons,
    'negative_seasons_risk', v_negative_seasons >= 2
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.club_credit_risk_status(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.club_credit_risk_status(text) TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';

SELECT to_regprocedure('public.club_credit_risk_status(text)') IS NOT NULL AS status_fn;
