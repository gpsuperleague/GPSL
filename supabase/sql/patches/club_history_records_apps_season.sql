-- =============================================================================
-- Club history records: season labels, apps context, all-time appearances
-- Safe re-run after competition_history.sql
-- =============================================================================

CREATE OR REPLACE FUNCTION public.transfer_history_season_label(p_transfer_time timestamptz)
RETURNS text
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT coalesce(
    (
      SELECT CASE
        WHEN nullif(btrim(s.label), '') ~ '^[0-9]+$' THEN 'Season ' || btrim(s.label)
        WHEN nullif(btrim(s.label), '') ~* '^season\s*[0-9]+' THEN
          'Season ' || (regexp_match(btrim(s.label), '[0-9]+'))[1]
        ELSE nullif(btrim(s.label), '')
      END
      FROM public.competition_seasons s
      WHERE p_transfer_time IS NOT NULL
        AND s.started_at IS NOT NULL
        AND p_transfer_time >= s.started_at
        AND (s.ended_at IS NULL OR p_transfer_time < s.ended_at)
      ORDER BY s.started_at DESC
      LIMIT 1
    ),
    (
      SELECT CASE
        WHEN nullif(btrim(s.label), '') ~ '^[0-9]+$' THEN 'Season ' || btrim(s.label)
        WHEN nullif(btrim(s.label), '') ~* '^season\s*[0-9]+' THEN
          'Season ' || (regexp_match(btrim(s.label), '[0-9]+'))[1]
        ELSE nullif(btrim(s.label), '')
      END
      FROM public.competition_seasons s
      WHERE s.is_current
      ORDER BY s.id DESC
      LIMIT 1
    ),
    CASE
      WHEN p_transfer_time IS NULL THEN NULL
      ELSE to_char(p_transfer_time AT TIME ZONE 'UTC', 'YYYY')
    END
  );
$$;

CREATE OR REPLACE FUNCTION public.competition_format_season_label(p_label text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE
    WHEN nullif(btrim(p_label), '') IS NULL THEN NULL
    WHEN btrim(p_label) ~ '^[0-9]+$' THEN 'Season ' || btrim(p_label)
    WHEN btrim(p_label) ~* '^season\s*[0-9]+' THEN
      'Season ' || (regexp_match(btrim(p_label), '[0-9]+'))[1]
    ELSE btrim(p_label)
  END;
$$;

CREATE OR REPLACE FUNCTION public.competition_club_history_bundle(p_club_short_name text)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := upper(btrim(p_club_short_name));
  v_honours jsonb;
  v_seasons jsonb;
  v_awards jsonb;
  v_records jsonb;
BEGIN
  IF v_club IS NULL OR v_club = '' THEN
    RETURN '{}'::jsonb;
  END IF;

  SELECT coalesce(jsonb_agg(row_to_json(h) ORDER BY h.honoured_at DESC), '[]'::jsonb)
  INTO v_honours
  FROM public.competition_club_honours_public h
  WHERE h.club_short_name = v_club;

  SELECT coalesce(jsonb_agg(row_to_json(s) ORDER BY s.season_label DESC), '[]'::jsonb)
  INTO v_seasons
  FROM public.competition_club_season_history_public s
  WHERE s.club_short_name = v_club;

  SELECT coalesce(jsonb_agg(row_to_json(a) ORDER BY a.season_label DESC), '[]'::jsonb)
  INTO v_awards
  FROM public.competition_season_awards_public a
  WHERE a.club_short_name = v_club
    AND a.award_type = 'ballon_dor';

  WITH career AS (
    SELECT *
    FROM public.competition_player_career_public
    WHERE upper(btrim(club_short_name)) = v_club
  ),
  totals AS (
    SELECT
      player_id,
      max(player_name) AS player_name,
      sum(goals)::int AS total_goals,
      sum(assists)::int AS total_assists,
      sum(potm_awards)::int AS total_potm,
      sum(appearances)::int AS total_apps
    FROM career
    GROUP BY player_id
  ),
  season_totals AS (
    SELECT
      player_id,
      max(player_name) AS player_name,
      public.competition_format_season_label(season_label) AS season_label,
      season_label AS season_label_raw,
      sum(goals)::int AS goals,
      sum(assists)::int AS assists,
      sum(potm_awards)::int AS potm_awards,
      sum(appearances)::int AS appearances
    FROM career
    GROUP BY player_id, season_label
  )
  SELECT jsonb_build_object(
    'all_time_top_scorer',
      (SELECT row_to_json(t) FROM totals t ORDER BY total_goals DESC, total_apps DESC, total_assists DESC LIMIT 1),
    'all_time_top_assists',
      (SELECT row_to_json(t) FROM totals t ORDER BY total_assists DESC, total_apps DESC, total_goals DESC LIMIT 1),
    'all_time_top_potm',
      (SELECT row_to_json(t) FROM totals t ORDER BY total_potm DESC, total_apps DESC, total_goals DESC LIMIT 1),
    'all_time_top_apps',
      (SELECT row_to_json(t) FROM totals t ORDER BY total_apps DESC, total_goals DESC, total_assists DESC LIMIT 1),
    'season_top_goals',
      (
        SELECT row_to_json(s)
        FROM season_totals s
        ORDER BY goals DESC, appearances DESC, assists DESC
        LIMIT 1
      ),
    'season_top_assists',
      (
        SELECT row_to_json(s)
        FROM season_totals s
        ORDER BY assists DESC, appearances DESC, goals DESC
        LIMIT 1
      ),
    'season_top_potm',
      (
        SELECT row_to_json(s)
        FROM season_totals s
        ORDER BY potm_awards DESC, appearances DESC, goals DESC
        LIMIT 1
      ),
    'record_signing',
      (
        SELECT row_to_json(x)
        FROM (
          SELECT
            h.player_id::text AS player_id,
            p."Name" AS player_name,
            h.fee::numeric AS fee,
            coalesce(h.agent_fee, 0)::numeric AS agent_fee,
            (coalesce(h.fee, 0) + coalesce(h.agent_fee, 0))::numeric AS total_cost,
            public.transfer_history_season_label(h.transfer_time) AS season_label,
            h.seller_club_id,
            h.buyer_club_id,
            h.foreign_buyer_name,
            h.transfer_sale_note,
            h.transfer_time
          FROM public."Transfer_History" h
          LEFT JOIN public."Players" p ON p."Konami_ID"::text = h.player_id::text
          WHERE upper(btrim(h.buyer_club_id)) = v_club
            AND coalesce(h.fee, 0) > 0
          ORDER BY
            (coalesce(h.fee, 0) + coalesce(h.agent_fee, 0)) DESC,
            h.fee DESC,
            h.transfer_time DESC
          LIMIT 1
        ) x
      ),
    'record_sale',
      (
        SELECT row_to_json(x)
        FROM (
          SELECT
            h.player_id::text AS player_id,
            p."Name" AS player_name,
            h.fee::numeric AS fee,
            public.transfer_history_season_label(h.transfer_time) AS season_label,
            h.seller_club_id,
            h.buyer_club_id,
            h.foreign_buyer_name,
            h.transfer_sale_note,
            h.transfer_time
          FROM public."Transfer_History" h
          LEFT JOIN public."Players" p ON p."Konami_ID"::text = h.player_id::text
          WHERE upper(btrim(h.seller_club_id)) = v_club
            AND coalesce(h.fee, 0) > 0
          ORDER BY h.fee DESC, h.transfer_time DESC
          LIMIT 1
        ) x
      )
  )
  INTO v_records;

  RETURN jsonb_build_object(
    'club_short_name', v_club,
    'honours', coalesce(v_honours, '[]'::jsonb),
    'seasons', coalesce(v_seasons, '[]'::jsonb),
    'ballon_winners', coalesce(v_awards, '[]'::jsonb),
    'records', coalesce(v_records, '{}'::jsonb)
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.transfer_history_season_label(timestamptz) TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.competition_format_season_label(text) TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.competition_club_history_bundle(text) TO authenticated, anon;

NOTIFY pgrst, 'reload schema';
