-- =============================================================================
-- 34+ fee is AGE-based, not rating-based
--
-- Bug: competition_club_34plus_count filtered Players."Rating" >= threshold.
-- Correct rule: squad players aged >= admin threshold (default 34).
--
-- Column wage_34plus_min_rating keeps its name for compatibility but means
-- minimum AGE. UI/admin copy should say "age".
--
-- Run once in Supabase SQL Editor. Safe re-run.
-- If Close Finances already posted wage_renewal_34plus this season with the
-- wrong count, re-post / repair wage bills after applying this patch.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.competition_club_34plus_count(p_club_short_name text)
RETURNS int
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_min int;
BEGIN
  -- Column name is historical; value is the minimum AGE threshold.
  v_min := (SELECT wage_34plus_min_rating FROM public.global_settings WHERE id = 1);

  RETURN (
    SELECT count(*)::int
    FROM public."Players" p
    WHERE p."Contracted_Team" = p_club_short_name
      AND nullif(btrim(p."Age"::text), '') ~ '^[0-9]+$'
      AND nullif(btrim(p."Age"::text), '')::int >= coalesce(v_min, 34)
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.competition_post_club_34plus_tax(
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
  v_count := public.competition_club_34plus_count(p_club_short_name);
  IF v_count = 0 THEN
    RETURN false;
  END IF;

  SELECT wage_34plus_per_player, wage_34plus_min_rating
  INTO v_rate, v_min
  FROM public.global_settings WHERE id = 1;

  v_amount := round(v_count * coalesce(v_rate, 0), 0);

  RETURN public.competition_post_club_charge(
    p_season_id,
    p_club_short_name,
    'wage_renewal_34plus',
    v_amount,
    format('%s+ age fee — %s player(s)', coalesce(v_min, 34), v_count),
    jsonb_build_object(
      'player_count', v_count,
      'min_age', v_min,
      -- legacy key kept for older finance UIs
      'min_rating', v_min
    )
  );
END;
$function$;

COMMENT ON FUNCTION public.competition_club_34plus_count(text) IS
  'Count contracted squad players aged >= global_settings.wage_34plus_min_rating (min age threshold; column name is historical).';

NOTIFY pgrst, 'reload schema';
