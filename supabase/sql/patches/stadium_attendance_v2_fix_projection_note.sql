-- Fix: coalesce(smallint, '?') tried to cast '?' to smallint
-- Run if overview_list / overview view fails with invalid input syntax for type smallint: "?"

CREATE OR REPLACE FUNCTION public.competition_stadium_projection_note(
  p_club_short_name text,
  p_display_fill numeric,
  p_prestige_rank smallint,
  p_tier text,
  p_band text
)
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_cfg public.global_settings;
  v_seasons_to_full numeric;
  v_gap numeric;
BEGIN
  SELECT * INTO v_cfg FROM public.global_settings WHERE id = 1;

  v_gap := greatest(0, v_cfg.stadium_target_fill_pct - coalesce(p_display_fill, v_cfg.stadium_min_fill_pct));

  IF v_gap <= 0 THEN
    IF coalesce(p_display_fill, 0) > v_cfg.stadium_target_fill_pct THEN
      RETURN format(
        'Cushion %s%% above full gate — absorbs %s%% of a bad season before gate revenue drops.',
        round(p_display_fill - v_cfg.stadium_target_fill_pct, 1),
        round(least(p_display_fill - v_cfg.stadium_target_fill_pct, v_cfg.stadium_under_bad_penalty_pct), 1)
      );
    END IF;
    RETURN 'At full gate — maintain on-target seasons to keep cushion.';
  END IF;

  v_seasons_to_full := ceil(v_gap / greatest(v_cfg.stadium_season_gain_on_target_pct, 0.01));

  IF p_tier = 'low' OR p_tier = 'medium' THEN
    RETURN format(
      'Rank %s %s club: ~%s on-target season(s) to reach %s%% gate from %s%%. Strong manager + overperformance speeds this.',
      coalesce(p_prestige_rank::text, '?'),
      coalesce(p_tier, 'club'),
      v_seasons_to_full::int,
      v_cfg.stadium_target_fill_pct::int,
      round(coalesce(p_display_fill, v_cfg.stadium_min_fill_pct), 1)
    );
  END IF;

  RETURN format(
    'Big club held to high standards — band %s. ~%s strong season(s) to restore %s%% gate.',
    coalesce(p_band, 'on_target'),
    v_seasons_to_full::int,
    v_cfg.stadium_target_fill_pct::int
  );
END;
$function$;

NOTIFY pgrst, 'reload schema';
