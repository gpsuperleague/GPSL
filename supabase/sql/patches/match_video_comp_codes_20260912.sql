-- =============================================================================
-- Match video COMP codes (authoritative)
--
-- League / division:
--   SL = SuperLeague
--   CA = Championship A
--   CB = Championship B
--
-- Cups:
--   LC = League Cup
--   S8 = Super8
--   PL = Plate
--   SH = Shield
--   BO = Bowl  (BW still accepted)
--
-- Later:
--   WC = World Cup (recognised, not matched in v1)
--
-- Division on the fixture MUST match the COMP tag (verified on ingest).
-- Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.match_video_map_comp(p_comp text)
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE
AS $function$
DECLARE
  v text := upper(btrim(coalesce(p_comp, '')));
BEGIN
  -- League divisions
  IF v IN ('SL', 'SUPERLEAGUE', 'SUPER') THEN
    RETURN jsonb_build_object(
      'kind', 'league',
      'division', 'superleague',
      'comp', 'SL'
    );
  END IF;
  IF v IN ('CA', 'CHA', 'CHAMPIONSHIP_A', 'CHAMPA') THEN
    RETURN jsonb_build_object(
      'kind', 'league',
      'division', 'championship_a',
      'comp', 'CA'
    );
  END IF;
  IF v IN ('CB', 'CHB', 'CHAMPIONSHIP_B', 'CHAMPB') THEN
    RETURN jsonb_build_object(
      'kind', 'league',
      'division', 'championship_b',
      'comp', 'CB'
    );
  END IF;
  -- Loose CH = either championship (resolved by clubs only)
  IF v IN ('CH', 'CHAMPIONSHIP', 'CHAMP') THEN
    RETURN jsonb_build_object(
      'kind', 'league',
      'division', NULL,
      'comp', 'CH'
    );
  END IF;

  -- Cups
  IF v IN ('S8', 'SUPER8') THEN
    RETURN jsonb_build_object('kind', 'cup', 'cup_code', 'super8', 'comp', 'S8');
  END IF;
  IF v IN ('PL', 'PLATE') THEN
    RETURN jsonb_build_object('kind', 'cup', 'cup_code', 'plate', 'comp', 'PL');
  END IF;
  IF v IN ('SH', 'SHIELD') THEN
    RETURN jsonb_build_object('kind', 'cup', 'cup_code', 'shield', 'comp', 'SH');
  END IF;
  IF v IN ('BO', 'BW', 'BOWL') THEN
    RETURN jsonb_build_object('kind', 'cup', 'cup_code', 'bowl', 'comp', 'BO');
  END IF;
  IF v IN ('LC', 'LEAGUECUP', 'LEAGUE_CUP', 'EFL') THEN
    RETURN jsonb_build_object('kind', 'cup', 'cup_code', 'league_cup', 'comp', 'LC');
  END IF;

  -- World Cup (recognised; matching not enabled yet)
  IF v IN ('WC', 'WORLDCUP', 'WORLD_CUP') THEN
    RETURN jsonb_build_object('kind', 'intl', 'comp', 'WC');
  END IF;

  RETURN NULL;
END;
$function$;

-- No more CA→SuperLeague rewrite; COMP is authoritative
CREATE OR REPLACE FUNCTION public.match_video_map_comp_for_ref(p_comp text, p_ref text)
RETURNS jsonb
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT public.match_video_map_comp(p_comp);
$$;

CREATE OR REPLACE FUNCTION public.match_video_find_fixture(
  p_season_id bigint,
  p_parsed jsonb,
  p_channel_month text DEFAULT NULL
)
RETURNS bigint
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club_a text := upper(p_parsed->>'club_a');
  v_club_b text := upper(p_parsed->>'club_b');
  v_comp_map jsonb;
  v_kind text;
  v_division text;
  v_cup_code text;
  v_md int;
  v_ref text := upper(p_parsed->>'ref');
  v_aliases text[];
  v_id bigint;
  v_month text := lower(nullif(btrim(coalesce(p_channel_month, '')), ''));
BEGIN
  v_comp_map := public.match_video_map_comp(p_parsed->>'comp');
  IF v_comp_map IS NULL THEN
    RETURN NULL;
  END IF;

  v_kind := v_comp_map->>'kind';
  v_division := nullif(v_comp_map->>'division', '');
  v_cup_code := nullif(v_comp_map->>'cup_code', '');

  IF v_kind = 'intl' THEN
    RETURN NULL; -- WC not wired yet
  END IF;

  IF v_kind = 'league' THEN
    v_md := public.match_video_ref_matchday(v_ref);
    IF v_md IS NULL THEN
      RETURN NULL;
    END IF;

    SELECT f.id INTO v_id
    FROM public.competition_fixtures f
    WHERE f.season_id = p_season_id
      AND f.competition_type = 'league'
      AND f.matchday = v_md
      AND (
        (upper(f.home_club_short_name) = v_club_a AND upper(f.away_club_short_name) = v_club_b)
        OR (upper(f.home_club_short_name) = v_club_b AND upper(f.away_club_short_name) = v_club_a)
      )
      AND (v_division IS NULL OR f.division = v_division)
      AND (
        v_month IS NULL
        OR lower(btrim(coalesce(f.gpsl_month, ''))) = v_month
      )
    ORDER BY
      CASE WHEN lower(btrim(coalesce(f.gpsl_month, ''))) = v_month THEN 0 ELSE 1 END,
      f.id
    LIMIT 1;

    RETURN v_id;
  END IF;

  -- Cups
  v_aliases := public.match_video_ref_cup_aliases(v_ref);

  SELECT f.id INTO v_id
  FROM public.competition_fixtures f
  WHERE f.season_id = p_season_id
    AND f.competition_type = 'cup'
    AND lower(coalesce(f.cup_code, '')) = lower(v_cup_code)
    AND (
      (upper(f.home_club_short_name) = v_club_a AND upper(f.away_club_short_name) = v_club_b)
      OR (upper(f.home_club_short_name) = v_club_b AND upper(f.away_club_short_name) = v_club_a)
    )
    AND (
      EXISTS (
        SELECT 1
        FROM public.competition_cup_round_schedule s
        WHERE s.cup_code = f.cup_code
          AND s.round_no = f.cup_round
          AND (
            lower(coalesce(s.stage, '')) = ANY (v_aliases)
            OR lower(regexp_replace(coalesce(s.round_label, ''), '[^a-z0-9]+', '', 'g'))
                 = ANY (
                   SELECT lower(regexp_replace(a, '[^a-z0-9]+', '', 'g'))
                   FROM unnest(v_aliases) a
                 )
          )
      )
      OR (
        v_ref ~ '^R0*[0-9]{1,2}$'
        AND f.cup_round = (regexp_match(v_ref, '^R0*([0-9]{1,2})$'))[1]::int
      )
      OR (
        lower(public.competition_cup_round_stage(
          f.cup_code,
          f.cup_round,
          (
            SELECT max(x.cup_round)::int
            FROM public.competition_fixtures x
            WHERE x.season_id = f.season_id AND x.cup_code = f.cup_code
          )
        )) = ANY (v_aliases)
      )
    )
    AND (
      v_month IS NULL
      OR lower(btrim(coalesce(f.gpsl_month, ''))) = v_month
    )
  ORDER BY
    CASE WHEN lower(btrim(coalesce(f.gpsl_month, ''))) = v_month THEN 0 ELSE 1 END,
    f.id
  LIMIT 1;

  RETURN v_id;
END;
$function$;

-- Explicit division / cup verify after fixture resolve
CREATE OR REPLACE FUNCTION public.match_video_comp_matches_fixture(
  p_fixture public.competition_fixtures,
  p_parsed jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE
AS $function$
DECLARE
  v_map jsonb := public.match_video_map_comp(p_parsed->>'comp');
  v_kind text;
  v_div text;
  v_cup text;
  v_comp text;
BEGIN
  IF v_map IS NULL THEN
    RETURN jsonb_build_object(
      'ok', false,
      'reason', format('Unknown COMP tag [%s] — use SL/CA/CB or S8/PL/SH/BO/LC', p_parsed->>'comp')
    );
  END IF;

  v_kind := v_map->>'kind';
  v_div := nullif(v_map->>'division', '');
  v_cup := nullif(v_map->>'cup_code', '');
  v_comp := coalesce(v_map->>'comp', upper(p_parsed->>'comp'));

  IF v_kind = 'intl' THEN
    RETURN jsonb_build_object(
      'ok', false,
      'reason', 'World Cup (WC) video matching is not enabled yet'
    );
  END IF;

  IF v_kind = 'league' THEN
    IF p_fixture.competition_type IS DISTINCT FROM 'league' THEN
      RETURN jsonb_build_object(
        'ok', false,
        'reason', format('COMP %s is league but fixture is not a league match', v_comp)
      );
    END IF;
    IF v_div IS NOT NULL AND p_fixture.division IS DISTINCT FROM v_div THEN
      RETURN jsonb_build_object(
        'ok', false,
        'reason', format(
          'Division mismatch — tag %s requires %s but fixture is %s',
          v_comp, v_div, coalesce(p_fixture.division, '?')
        )
      );
    END IF;
    RETURN jsonb_build_object('ok', true);
  END IF;

  IF v_kind = 'cup' THEN
    IF p_fixture.competition_type IS DISTINCT FROM 'cup' THEN
      RETURN jsonb_build_object(
        'ok', false,
        'reason', format('COMP %s is a cup but fixture is not a cup tie', v_comp)
      );
    END IF;
    IF v_cup IS NOT NULL
       AND lower(coalesce(p_fixture.cup_code, '')) IS DISTINCT FROM lower(v_cup)
    THEN
      RETURN jsonb_build_object(
        'ok', false,
        'reason', format(
          'Cup mismatch — tag %s requires %s but fixture is %s',
          v_comp, v_cup, coalesce(p_fixture.cup_code, '?')
        )
      );
    END IF;
    RETURN jsonb_build_object('ok', true);
  END IF;

  RETURN jsonb_build_object('ok', false, 'reason', 'Unhandled COMP kind');
END;
$function$;

NOTIFY pgrst, 'reload schema';
