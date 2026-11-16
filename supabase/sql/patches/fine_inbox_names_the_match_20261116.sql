-- Fine inbox rows named the charge and the amount, and left out the match.
-- Put the fixture on the first line, and fill that in on rows already sent.
-- Safe re-run.

DO $fine_inbox$
DECLARE
  v_def text;
  v_old text;
  v_new text;
BEGIN
  v_def := replace(
    pg_get_functiondef('public.owner_inbox_notify_fine_applied(bigint)'::regprocedure),
    E'\r\n', E'\n'
  );
  IF position('fine inbox names the match' IN v_def) > 0 THEN
    RETURN;
  END IF;

  v_old := replace($old$  v_body := concat_ws(
    E'\n',
    v_row.description,$old$, E'\r\n', E'\n');
  v_new := replace($new$  -- fine inbox names the match
  v_body := concat_ws(
    E'\n',
    (
      SELECT CASE
        WHEN f.id IS NULL THEN NULL
        WHEN lower(coalesce(f.competition_type, 'league')) = 'cup' THEN format(
          '%s R%s — %s vs %s',
          coalesce(nullif(btrim(f.cup_code), ''), 'Cup'),
          coalesce(f.cup_round, 0),
          coalesce(public.club_display_name(f.home_club_short_name), f.home_club_short_name),
          coalesce(public.club_display_name(f.away_club_short_name), f.away_club_short_name)
        )
        ELSE format(
          '%s MD%s — %s vs %s',
          public.competition_gpsl_month_label(f.gpsl_month),
          f.matchday,
          coalesce(public.club_display_name(f.home_club_short_name), f.home_club_short_name),
          coalesce(public.club_display_name(f.away_club_short_name), f.away_club_short_name)
        )
      END
      FROM public.competition_fixtures f
      WHERE f.id = v_row.fixture_id
    ),
    v_row.description,$new$, E'\r\n', E'\n');
  IF position(v_old IN v_def) = 0 THEN
    RAISE EXCEPTION 'fine inbox body needle not found';
  END IF;
  v_def := replace(v_def, v_old, v_new);

  v_old := replace($old$  v_title := CASE
    WHEN v_row.direction = 'fine' THEN 'Fine applied'
    ELSE 'Compensation credited'
  END;$old$, E'\r\n', E'\n');
  v_new := replace($new$  v_title := coalesce(
    nullif(btrim(v_row.description), ''),
    CASE
      WHEN v_row.direction = 'fine' THEN 'Fine applied'
      ELSE 'Compensation credited'
    END
  );$new$, E'\r\n', E'\n');
  IF position(v_old IN v_def) = 0 THEN
    RAISE EXCEPTION 'fine inbox title needle not found';
  END IF;
  EXECUTE replace(v_def, v_old, v_new);
END;
$fine_inbox$;

UPDATE public.competition_inbox i
SET
  title = coalesce(nullif(btrim(a.description), ''), i.title),
  body = CASE
    WHEN i.body ILIKE '% vs %' THEN i.body
    ELSE concat_ws(
      E'\n',
      CASE
        WHEN lower(coalesce(f.competition_type, 'league')) = 'cup' THEN format(
          '%s R%s — %s vs %s',
          coalesce(nullif(btrim(f.cup_code), ''), 'Cup'),
          coalesce(f.cup_round, 0),
          coalesce(public.club_display_name(f.home_club_short_name), f.home_club_short_name),
          coalesce(public.club_display_name(f.away_club_short_name), f.away_club_short_name)
        )
        ELSE format(
          '%s MD%s — %s vs %s',
          public.competition_gpsl_month_label(f.gpsl_month),
          f.matchday,
          coalesce(public.club_display_name(f.home_club_short_name), f.home_club_short_name),
          coalesce(public.club_display_name(f.away_club_short_name), f.away_club_short_name)
        )
      END,
      i.body
    )
  END
FROM public.competition_fine_applied a
JOIN public.competition_fixtures f ON f.id = a.fixture_id
WHERE i.message_type = 'fine_applied'
  AND i.dedupe_key = 'fine:' || a.id::text
  AND a.fixture_id IS NOT NULL
  AND i.body NOT ILIKE '% vs %';

SELECT jsonb_build_object(
  'names_match', position(
    'fine inbox names the match'
    IN pg_get_functiondef('public.owner_inbox_notify_fine_applied(bigint)'::regprocedure)
  ) > 0,
  'vague_left', (
    SELECT count(*)
    FROM public.competition_inbox i
    JOIN public.competition_fine_applied a
      ON i.dedupe_key = 'fine:' || a.id::text
    WHERE i.message_type = 'fine_applied'
      AND a.fixture_id IS NOT NULL
      AND i.body NOT ILIKE '% vs %'
  ),
  'sample', (
    SELECT left(i.body, 180)
    FROM public.competition_inbox i
    WHERE i.id = 2445642
  )
);
