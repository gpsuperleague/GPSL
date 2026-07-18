-- =============================================================================
-- Clearer playoff tie / fixture labels
-- Safe re-run. Updates existing ties + future generate_playoffs inserts.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.competition_playoff_label_for(
  p_bracket text,
  p_round_no smallint,
  p_match_no smallint
)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE lower(btrim(coalesce(p_bracket, '')))
    WHEN 'sl_1617' THEN
      'Super League Relegation Playoff Final — 16th vs 17th'
    WHEN 'ch_sb_a' THEN
      'Championship A Shield Playoff Final — 16th vs 17th'
    WHEN 'ch_sb_b' THEN
      'Championship B Shield Playoff Final — 16th vs 17th'
    WHEN 'ch_promo_a' THEN
      CASE
        WHEN p_round_no = 1 AND p_match_no = 1 THEN
          'Championship A Semi Final — 3rd vs 6th'
        WHEN p_round_no = 1 AND p_match_no = 2 THEN
          'Championship A Semi Final — 4th vs 5th'
        WHEN p_round_no = 2 THEN
          'Championship A Final — semi-final winners'
        ELSE 'Championship A promotion playoff'
      END
    WHEN 'ch_promo_b' THEN
      CASE
        WHEN p_round_no = 1 AND p_match_no = 1 THEN
          'Championship B Semi Final — 3rd vs 6th'
        WHEN p_round_no = 1 AND p_match_no = 2 THEN
          'Championship B Semi Final — 4th vs 5th'
        WHEN p_round_no = 2 THEN
          'Championship B Final — semi-final winners'
        ELSE 'Championship B promotion playoff'
      END
    WHEN 'ch_final' THEN
      'Championship Playoff Final — Championship A final winner vs Championship B final winner'
    WHEN 'sl_final' THEN
      'Super League Playoff Final — relegation playoff winner vs Championship Playoff Final winner'
    ELSE coalesce(nullif(btrim(p_bracket), ''), 'Playoff')
  END;
$$;

GRANT EXECUTE ON FUNCTION public.competition_playoff_label_for(text, smallint, smallint)
  TO authenticated, anon, service_role;

-- Keep labels consistent on insert / bracket changes (future generate_playoffs)
CREATE OR REPLACE FUNCTION public.competition_playoff_ties_set_label()
RETURNS trigger
LANGUAGE plpgsql
AS $function$
BEGIN
  NEW.label := public.competition_playoff_label_for(NEW.bracket, NEW.round_no, NEW.match_no);
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_competition_playoff_ties_set_label ON public.competition_playoff_ties;
CREATE TRIGGER trg_competition_playoff_ties_set_label
  BEFORE INSERT OR UPDATE OF bracket, round_no, match_no
  ON public.competition_playoff_ties
  FOR EACH ROW
  EXECUTE FUNCTION public.competition_playoff_ties_set_label();

-- Refresh labels on existing ties (current + past seasons)
UPDATE public.competition_playoff_ties t
SET label = public.competition_playoff_label_for(t.bracket, t.round_no, t.match_no);

-- Cup / matchday / deploy display: prefer the tie label
CREATE OR REPLACE FUNCTION public.competition_cup_fixture_label(p_fixture public.competition_fixtures)
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_code text := lower(coalesce(p_fixture.cup_code, ''));
  v_tie_label text;
BEGIN
  IF v_code LIKE 'po_%' THEN
    SELECT t.label INTO v_tie_label
    FROM public.competition_playoff_ties t
    WHERE t.fixture_id = p_fixture.id
    LIMIT 1;

    IF v_tie_label IS NOT NULL AND btrim(v_tie_label) <> '' THEN
      RETURN v_tie_label;
    END IF;

    RETURN CASE v_code
      WHEN 'po_sl_1617' THEN
        'Super League Relegation Playoff Final — 16th vs 17th'
      WHEN 'po_ch_sb_a' THEN
        'Championship A Shield Playoff Final — 16th vs 17th'
      WHEN 'po_ch_sb_b' THEN
        'Championship B Shield Playoff Final — 16th vs 17th'
      WHEN 'po_ch_a' THEN
        CASE coalesce(p_fixture.cup_round, 0)
          WHEN 1 THEN
            CASE coalesce(p_fixture.cup_match, 0)
              WHEN 1 THEN 'Championship A Semi Final — 3rd vs 6th'
              WHEN 2 THEN 'Championship A Semi Final — 4th vs 5th'
              ELSE 'Championship A Semi Final'
            END
          WHEN 2 THEN 'Championship A Final — semi-final winners'
          ELSE 'Championship A promotion playoff'
        END
      WHEN 'po_ch_b' THEN
        CASE coalesce(p_fixture.cup_round, 0)
          WHEN 1 THEN
            CASE coalesce(p_fixture.cup_match, 0)
              WHEN 1 THEN 'Championship B Semi Final — 3rd vs 6th'
              WHEN 2 THEN 'Championship B Semi Final — 4th vs 5th'
              ELSE 'Championship B Semi Final'
            END
          WHEN 2 THEN 'Championship B Final — semi-final winners'
          ELSE 'Championship B promotion playoff'
        END
      WHEN 'po_ch_final' THEN
        'Championship Playoff Final — Championship A final winner vs Championship B final winner'
      WHEN 'po_sl_final' THEN
        'Super League Playoff Final — relegation playoff winner vs Championship Playoff Final winner'
      ELSE 'Playoff'
    END;
  END IF;

  RETURN coalesce(
    nullif(btrim(
      CASE v_code
        WHEN 'super8' THEN 'Super8'
        WHEN 'plate' THEN 'Plate'
        WHEN 'shield' THEN 'Shield'
        WHEN 'bowl' THEN 'Bowl'
        WHEN 'league_cup' THEN 'League Cup'
        ELSE initcap(replace(v_code, '_', ' '))
      END
      || CASE WHEN p_fixture.cup_round IS NOT NULL THEN ' R' || p_fixture.cup_round::text ELSE '' END
      || CASE WHEN p_fixture.cup_match IS NOT NULL THEN ' M' || p_fixture.cup_match::text ELSE '' END
    ), ''),
    'Cup'
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_cup_fixture_label(public.competition_fixtures)
  TO authenticated, anon, service_role;

-- Admin deploy pickers: show clear playoff names
CREATE OR REPLACE FUNCTION public.admin_testing_list_club_month_fixtures(
  p_gpsl_month text,
  p_club_short_name text,
  p_season_id bigint DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_month text := lower(nullif(btrim(coalesce(p_gpsl_month, '')), ''));
  v_club text := btrim(coalesce(p_club_short_name, ''));
  v_season_id bigint;
  v_rows jsonb;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF v_month IS NULL OR v_club = '' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'month_and_club_required');
  END IF;

  IF p_season_id IS NULL THEN
    SELECT id INTO v_season_id
    FROM public.competition_seasons
    WHERE is_current = true
    ORDER BY id DESC
    LIMIT 1;
  ELSE
    v_season_id := p_season_id;
  END IF;

  IF v_season_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_season');
  END IF;

  SELECT coalesce(jsonb_agg(row_data ORDER BY sort_key, fixture_id), '[]'::jsonb)
  INTO v_rows
  FROM (
    SELECT
      f.id AS fixture_id,
      CASE f.competition_type WHEN 'league' THEN 0 ELSE 1 END AS sort_key,
      jsonb_build_object(
        'fixture_id', f.id,
        'competition_type', f.competition_type,
        'division', f.division,
        'cup_code', f.cup_code,
        'cup_round', f.cup_round,
        'cup_match', f.cup_match,
        'matchday', f.matchday,
        'gpsl_month', f.gpsl_month,
        'status', f.status,
        'home_club_short_name', f.home_club_short_name,
        'away_club_short_name', f.away_club_short_name,
        'home_club_name', coalesce(ch."Club", f.home_club_short_name),
        'away_club_name', coalesce(ca."Club", f.away_club_short_name),
        'home_goals', f.home_goals,
        'away_goals', f.away_goals,
        'is_home', f.home_club_short_name = v_club,
        'opponent_short_name', CASE
          WHEN f.home_club_short_name = v_club THEN f.away_club_short_name
          ELSE f.home_club_short_name
        END,
        'opponent_name', CASE
          WHEN f.home_club_short_name = v_club THEN coalesce(ca."Club", f.away_club_short_name)
          ELSE coalesce(ch."Club", f.home_club_short_name)
        END,
        'competition_label', CASE
          WHEN f.competition_type = 'cup' THEN public.competition_cup_fixture_label(f)
          WHEN f.division = 'superleague' THEN 'Super League'
          WHEN f.division = 'championship_a' THEN 'Championship A'
          WHEN f.division = 'championship_b' THEN 'Championship B'
          ELSE coalesce(f.division, 'league')
        END,
        'squads_ready', public.admin_testing_fixture_squads_ready(
          f.home_club_short_name,
          f.away_club_short_name,
          f.id
        ),
        'home_available', public.admin_testing_club_available_count(f.home_club_short_name, f.id),
        'away_available', public.admin_testing_club_available_count(f.away_club_short_name, f.id)
      ) AS row_data
    FROM public.competition_fixtures f
    LEFT JOIN public."Clubs" ch ON ch."ShortName" = f.home_club_short_name
    LEFT JOIN public."Clubs" ca ON ca."ShortName" = f.away_club_short_name
    WHERE f.season_id = v_season_id
      AND lower(f.gpsl_month) = v_month
      AND f.competition_type IN ('league', 'cup')
      AND (
        f.home_club_short_name = v_club
        OR f.away_club_short_name = v_club
      )
  ) q;

  RETURN jsonb_build_object(
    'ok', true,
    'season_id', v_season_id,
    'gpsl_month', v_month,
    'club_short_name', v_club,
    'fixtures', coalesce(v_rows, '[]'::jsonb)
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.admin_testing_list_club_month_fixtures(text, text, bigint)
  TO authenticated;

NOTIFY pgrst, 'reload schema';
