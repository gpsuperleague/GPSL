-- Absences are the next matches still to play after the injury game.
-- Cups still jump ahead of league games in the same GPSL month, so a cup
-- that lands in that run takes a place. Matches already played are skipped.
-- Safe re-run. Does not walk already-played games or close a zero-length injury.

DO $patch$
DECLARE
  v_def text;
  v_old text;
  v_new text;
  v_season bigint;
  r record;
  v_expected jsonb;
  v_actual jsonb;
BEGIN
  PERFORM set_config('statement_timeout', '180s', true);

  v_def := replace(
    pg_get_functiondef('public.competition_injury_assign_fixtures(bigint)'::regprocedure),
    E'\r\n', E'\n'
  );

  IF position('Absences start after the injury match' IN v_def) = 0 THEN
    v_old := replace($old$      AND (v_inj.source_fixture_id IS NULL OR f.id IS DISTINCT FROM v_inj.source_fixture_id)
      AND NOT public.competition_injury_is_preseason_month(f.gpsl_month)
    ORDER BY$old$, E'\r\n', E'\n');
    v_new := replace($new$      AND (v_inj.source_fixture_id IS NULL OR f.id IS DISTINCT FROM v_inj.source_fixture_id)
      AND NOT public.competition_injury_is_preseason_month(f.gpsl_month)
      -- Absences start after the injury match.
      -- A cup in a later month still jumps ahead of that month's league games.
      AND (
        v_inj.source_fixture_id IS NULL
        OR NOT EXISTS (
          SELECT 1
          FROM public.competition_fixtures src
          WHERE src.id = v_inj.source_fixture_id
        )
        OR (
          coalesce(public.competition_gpsl_month_sort(f.gpsl_month), 99),
          CASE WHEN f.competition_type = 'cup' THEN 0 ELSE 1 END,
          coalesce(f.matchday, 9999),
          f.id
        ) > (
          SELECT
            coalesce(public.competition_gpsl_month_sort(src.gpsl_month), 99),
            CASE WHEN src.competition_type = 'cup' THEN 0 ELSE 1 END,
            coalesce(src.matchday, 9999),
            src.id
          FROM public.competition_fixtures src
          WHERE src.id = v_inj.source_fixture_id
        )
      )
    ORDER BY$new$, E'\r\n', E'\n');
    IF (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 THEN
      RAISE EXCEPTION 'injury assign needle not unique';
    END IF;
    EXECUTE replace(v_def, v_old, v_new);
  END IF;

  CREATE TEMP TABLE IF NOT EXISTS _injury_repin (
    injury_id bigint PRIMARY KEY
  );
  TRUNCATE _injury_repin;

  SELECT s.id INTO v_season
  FROM public.competition_seasons s
  WHERE s.is_current
  ORDER BY s.id DESC
  LIMIT 1;

  FOR r IN
    SELECT i.id
    FROM public.competition_player_injuries i
    WHERE i.status = 'active'
      AND i.source_fixture_id IS NOT NULL
      AND (
        coalesce(i.matches_out_remaining, 0) > 0
        OR coalesce(i.recovery_remaining, 0) > 0
      )
  LOOP
    SELECT coalesce(jsonb_agg(
      jsonb_build_object('id', z.fixture_id, 'phase', z.phase) ORDER BY z.rn
    ), '[]'::jsonb)
    INTO v_expected
    FROM (
      SELECT
        f.id AS fixture_id,
        CASE
          WHEN row_number() OVER (
            ORDER BY
              coalesce(public.competition_gpsl_month_sort(f.gpsl_month), 99),
              CASE WHEN f.competition_type = 'cup' THEN 0 ELSE 1 END,
              coalesce(f.matchday, 9999),
              f.id
          ) <= greatest(coalesce(i.matches_out_remaining, 0), 0)
          THEN 'out'
          ELSE 'recovery'
        END AS phase,
        row_number() OVER (
          ORDER BY
            coalesce(public.competition_gpsl_month_sort(f.gpsl_month), 99),
            CASE WHEN f.competition_type = 'cup' THEN 0 ELSE 1 END,
            coalesce(f.matchday, 9999),
            f.id
        ) AS rn
      FROM public.competition_player_injuries i
      JOIN public.competition_fixtures src ON src.id = i.source_fixture_id
      JOIN public.competition_fixtures f
        ON f.season_id = coalesce(v_season, i.season_id, i.incurred_season_id)
       AND f.status = 'scheduled'
       AND (
         f.home_club_short_name = i.club_short_name
         OR f.away_club_short_name = i.club_short_name
       )
       AND f.id IS DISTINCT FROM src.id
       AND NOT public.competition_injury_is_preseason_month(f.gpsl_month)
       AND (
         coalesce(public.competition_gpsl_month_sort(f.gpsl_month), 99),
         CASE WHEN f.competition_type = 'cup' THEN 0 ELSE 1 END,
         coalesce(f.matchday, 9999),
         f.id
       ) > (
         coalesce(public.competition_gpsl_month_sort(src.gpsl_month), 99),
         CASE WHEN src.competition_type = 'cup' THEN 0 ELSE 1 END,
         coalesce(src.matchday, 9999),
         src.id
       )
      WHERE i.id = r.id
    ) z
    WHERE z.rn <= (
      SELECT greatest(coalesce(matches_out_remaining, 0), 0)
           + greatest(coalesce(recovery_remaining, 0), 0)
      FROM public.competition_player_injuries
      WHERE id = r.id
    );

    SELECT coalesce(jsonb_agg(
      jsonb_build_object('id', iff.fixture_id, 'phase', iff.phase)
      ORDER BY
        coalesce(public.competition_gpsl_month_sort(f.gpsl_month), 99),
        CASE WHEN f.competition_type = 'cup' THEN 0 ELSE 1 END,
        coalesce(f.matchday, 9999),
        f.id
    ), '[]'::jsonb)
    INTO v_actual
    FROM public.competition_player_injury_fixtures iff
    JOIN public.competition_fixtures f ON f.id = iff.fixture_id
    WHERE iff.injury_id = r.id
      AND iff.served = false;

    IF v_expected IS DISTINCT FROM v_actual THEN
      PERFORM public.competition_injury_assign_fixtures(r.id);
      INSERT INTO _injury_repin (injury_id) VALUES (r.id);
    END IF;
  END LOOP;
END
$patch$;

SELECT
  i.id,
  i.club_short_name AS club,
  p."Name" AS player,
  i.label,
  i.matches_out_remaining AS out_left,
  i.recovery_remaining AS rec_left,
  (rp.injury_id IS NOT NULL) AS moved,
  src.gpsl_month AS injured_month,
  src.matchday AS injured_md,
  src.home_club_short_name || ' vs ' || src.away_club_short_name AS injured_in,
  (
    SELECT coalesce(string_agg(
      CASE WHEN iff.phase = 'recovery' THEN 'recovery ' ELSE '' END
        || f.gpsl_month || ' '
        || CASE
             WHEN f.competition_type = 'cup' THEN coalesce(f.cup_code, 'cup') || ' R' || coalesce(f.cup_round::text, '?')
             ELSE 'MD' || coalesce(f.matchday::text, '?')
           END
        || ' ' || f.home_club_short_name || ' vs ' || f.away_club_short_name,
      ' | ' ORDER BY
        coalesce(public.competition_gpsl_month_sort(f.gpsl_month), 99),
        CASE WHEN f.competition_type = 'cup' THEN 0 ELSE 1 END,
        coalesce(f.matchday, 9999),
        f.id
    ), '')
    FROM public.competition_player_injury_fixtures iff
    JOIN public.competition_fixtures f ON f.id = iff.fixture_id
    WHERE iff.injury_id = i.id
      AND iff.served = false
  ) AS still_out
FROM public.competition_player_injuries i
LEFT JOIN public."Players" p ON p."Konami_ID"::text = i.player_id
LEFT JOIN public.competition_fixtures src ON src.id = i.source_fixture_id
LEFT JOIN pg_temp._injury_repin rp ON rp.injury_id = i.id
WHERE i.status = 'active'
ORDER BY i.club_short_name, p."Name";
