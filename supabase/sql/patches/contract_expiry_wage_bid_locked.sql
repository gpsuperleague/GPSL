-- Expiring wage bids are one-shot: once placed, cannot be changed.
-- Safe re-run.

CREATE OR REPLACE FUNCTION public.contract_submit_expiry_wage_bid(
  p_player_id text,
  p_wage_offer numeric
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club      text;
  v_pid       text := btrim(p_player_id);
  v_wage      numeric;
  v_season    text;
  v_holder    text;
  v_current   numeric;
  v_min_offer numeric;
  v_pct       numeric := public.contract_expiry_min_wage_uplift_pct();
  v_existing  numeric;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  v_club := public.my_club_shortname();
  IF v_club IS NULL OR btrim(v_club) = '' THEN
    RAISE EXCEPTION 'No club linked to this account';
  END IF;

  IF NOT public.player_expiry_auction_applies(v_pid) THEN
    RAISE EXCEPTION
      'This player is not on the expiring-contract market';
  END IF;

  v_wage := round(coalesce(p_wage_offer, 0), 0);
  IF v_wage <= 0 THEN
    RAISE EXCEPTION 'Wage bid must be greater than zero';
  END IF;

  SELECT public.player_contracted_club_key(p."Contracted_Team"),
         p.contract_wage
  INTO v_holder, v_current
  FROM public."Players" p
  WHERE p."Konami_ID"::text = v_pid;

  v_min_offer := public.contract_expiry_min_wage_offer(v_current);

  IF v_wage < v_min_offer THEN
    RAISE EXCEPTION
      'Wage offer must be at least ₿% (% %% above current wage ₿%)',
      to_char(v_min_offer, 'FM999,999,999'),
      to_char(v_pct, 'FM999'),
      to_char(coalesce(v_current, 0), 'FM999,999,999');
  END IF;

  v_season := coalesce(public.current_gpsl_season_label(), 'unknown');

  SELECT b.wage_offer
  INTO v_existing
  FROM public.contract_expiry_wage_bids b
  WHERE b.player_id = v_pid
    AND b.bidder_club_short_name = v_club
    AND b.season_label = v_season;

  IF FOUND THEN
    RAISE EXCEPTION
      'Your wage bid is locked in at ₿% and cannot be changed',
      to_char(v_existing, 'FM999,999,999');
  END IF;

  INSERT INTO public.contract_expiry_wage_bids (
    player_id,
    bidder_club_short_name,
    wage_offer,
    season_label,
    updated_at
  )
  VALUES (v_pid, v_club, v_wage, v_season, now());

  RETURN jsonb_build_object(
    'ok', true,
    'player_id', v_pid,
    'bidder_club_short_name', v_club,
    'wage_offer', v_wage,
    'min_wage_offer', v_min_offer,
    'min_uplift_pct', v_pct,
    'wage_step', 1,
    'season_label', v_season,
    'locked', true
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.contract_submit_expiry_wage_bid(text, numeric) TO authenticated;

NOTIFY pgrst, 'reload schema';
