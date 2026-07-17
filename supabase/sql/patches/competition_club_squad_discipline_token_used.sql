-- =============================================================================
-- Squad discipline: include medical token_used on active injuries
-- so squad Action menu can offer "Use medical token" only when eligible.
-- Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.competition_club_squad_discipline(
  p_club text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := nullif(btrim(p_club), '');
  v_season bigint;
  v_cards jsonb;
  v_injuries jsonb;
BEGIN
  IF v_club IS NULL THEN
    v_club := public.my_club_shortname();
  END IF;
  IF v_club IS NULL THEN
    RETURN jsonb_build_object('cards', '[]'::jsonb, 'injuries', '[]'::jsonb);
  END IF;

  SELECT s.id INTO v_season
  FROM public.competition_seasons s
  WHERE s.is_current = true
  ORDER BY s.id DESC
  LIMIT 1;

  SELECT coalesce(jsonb_agg(
    jsonb_build_object(
      'player_id', x.player_id,
      'yellows', x.yellows,
      'reds', x.reds
    )
    ORDER BY x.player_id
  ), '[]'::jsonb)
  INTO v_cards
  FROM (
    SELECT
      m.player_id,
      count(*) FILTER (WHERE m.yellow_card)::int AS yellows,
      count(*) FILTER (WHERE m.red_card)::int AS reds
    FROM public.competition_match_player_stats m
    WHERE m.season_id = v_season
      AND m.club_short_name = v_club
      AND (m.yellow_card OR m.red_card)
    GROUP BY m.player_id
  ) x;

  SELECT coalesce(jsonb_agg(
    jsonb_build_object(
      'injury_id', i.id,
      'player_id', i.player_id,
      'label', i.label,
      'severity', i.severity,
      'matches_out_remaining', coalesce(i.matches_out_remaining, 0),
      'recovery_remaining', coalesce(i.recovery_remaining, 0),
      'phase', CASE
        WHEN coalesce(i.matches_out_remaining, 0) > 0 THEN 'out'
        ELSE 'recovery'
      END,
      'token_used', EXISTS (
        SELECT 1 FROM public.club_medical_token_use u WHERE u.injury_id = i.id
      ),
      'pending_matches', coalesce((
        SELECT jsonb_agg(
          jsonb_build_object(
            'fixture_id', iff.fixture_id,
            'phase', iff.phase,
            'label', public.competition_fixture_discipline_label(f, i.club_short_name)
          )
          ORDER BY iff.id
        )
        FROM public.competition_player_injury_fixtures iff
        JOIN public.competition_fixtures f ON f.id = iff.fixture_id
        WHERE iff.injury_id = i.id
          AND iff.served = false
      ), '[]'::jsonb)
    )
    ORDER BY i.player_id
  ), '[]'::jsonb)
  INTO v_injuries
  FROM public.competition_player_injuries i
  WHERE i.club_short_name = v_club
    AND i.status = 'active'
    AND (
      coalesce(i.matches_out_remaining, 0) > 0
      OR coalesce(i.recovery_remaining, 0) > 0
    );

  RETURN jsonb_build_object(
    'season_id', v_season,
    'club_short_name', v_club,
    'cards', coalesce(v_cards, '[]'::jsonb),
    'injuries', coalesce(v_injuries, '[]'::jsonb)
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_club_squad_discipline(text) TO authenticated;

NOTIFY pgrst, 'reload schema';
