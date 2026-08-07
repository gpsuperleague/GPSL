-- =============================================================================
-- HOTFIX ONLY: Rating text/int COALESCE in match sim load
-- Prefer this over re-running the full match_result_simulation.sql
-- (avoids ALTER TABLE locks that can deadlock against live traffic).
--
-- Close any Simulate tabs, then run this once in Supabase SQL Editor.
-- If it deadlocks, wait 10s and retry — do not click Simulate while it runs.
-- =============================================================================

SET lock_timeout = '15s';
SET statement_timeout = '60s';

CREATE OR REPLACE FUNCTION public.match_sim_player_rating_num(
  p_rating text,
  p_default numeric DEFAULT 70
)
RETURNS numeric
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT coalesce(
    nullif(
      regexp_replace(coalesce(btrim(p_rating), ''), '[^0-9.]', '', 'g'),
      ''
    )::numeric,
    p_default
  );
$$;

CREATE OR REPLACE FUNCTION public.match_sim_load_club_side(p_club text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := btrim(p_club);
  v_rows jsonb;
  v_n int;
BEGIN
  SELECT coalesce(
    jsonb_agg(
      jsonb_build_object(
        'player_id', sp.player_id,
        'name', p."Name",
        'rating', public.match_sim_player_rating_num(p."Rating"::text, 70),
        'role', public.match_sim_role_from_slot(sp.pitch_slot, p."Position"),
        'pitch_slot', sp.pitch_slot,
        'started', true,
        'subbed_on', false,
        'is_star', public.match_sim_is_star(
          public.match_sim_player_rating_num(p."Rating"::text, 70)
        )
      )
      ORDER BY sp.sort_order NULLS LAST, sp.pitch_slot, p."Name"
    ),
    '[]'::jsonb
  )
  INTO v_rows
  FROM public.club_matchday_squad_player sp
  JOIN public."Players" p ON p."Konami_ID"::text = sp.player_id
  WHERE sp.club_short_name = v_club
    AND sp.slot_kind = 'pitch'
    AND p."Contracted_Team" = v_club;

  v_n := jsonb_array_length(v_rows);

  IF v_n < 11 THEN
    SELECT coalesce(
      jsonb_agg(x.obj ORDER BY x.ord),
      '[]'::jsonb
    )
    INTO v_rows
    FROM (
      SELECT
        jsonb_build_object(
          'player_id', p."Konami_ID"::text,
          'name', p."Name",
          'rating', public.match_sim_player_rating_num(p."Rating"::text, 70),
          'role', public.match_sim_role_from_slot(NULL, p."Position"),
          'pitch_slot', NULL,
          'started', true,
          'subbed_on', false,
          'is_star', public.match_sim_is_star(
            public.match_sim_player_rating_num(p."Rating"::text, 70)
          )
        ) AS obj,
        row_number() OVER (
          ORDER BY public.match_sim_player_rating_num(p."Rating"::text, 0) DESC, p."Name"
        ) AS ord
      FROM public."Players" p
      WHERE p."Contracted_Team" = v_club
      LIMIT 11
    ) x;
    v_n := jsonb_array_length(v_rows);
  END IF;

  IF v_n < 11 THEN
    RAISE EXCEPTION 'Club % needs at least 11 contracted players to simulate (have %)', v_club, v_n;
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.club_matchday_squad_player sp
    WHERE sp.club_short_name = v_club AND sp.slot_kind = 'bench'
  ) THEN
    SELECT v_rows || coalesce(
      (
        SELECT jsonb_agg(
          jsonb_build_object(
            'player_id', sp.player_id,
            'name', p."Name",
            'rating', public.match_sim_player_rating_num(p."Rating"::text, 70),
            'role', public.match_sim_role_from_slot(NULL, p."Position"),
            'pitch_slot', NULL,
            'started', false,
            'subbed_on', true,
            'is_star', public.match_sim_is_star(
              public.match_sim_player_rating_num(p."Rating"::text, 70)
            )
          )
          ORDER BY sp.sort_order NULLS LAST, p."Name"
        )
        FROM public.club_matchday_squad_player sp
        JOIN public."Players" p ON p."Konami_ID"::text = sp.player_id
        WHERE sp.club_short_name = v_club
          AND sp.slot_kind = 'bench'
          AND p."Contracted_Team" = v_club
        LIMIT 5
      ),
      '[]'::jsonb
    )
    INTO v_rows;
  ELSE
    SELECT v_rows || coalesce(
      (
        SELECT jsonb_agg(y.obj ORDER BY y.ord)
        FROM (
          SELECT
            jsonb_build_object(
              'player_id', p."Konami_ID"::text,
              'name', p."Name",
              'rating', public.match_sim_player_rating_num(p."Rating"::text, 70),
              'role', public.match_sim_role_from_slot(NULL, p."Position"),
              'pitch_slot', NULL,
              'started', false,
              'subbed_on', true,
              'is_star', public.match_sim_is_star(
                public.match_sim_player_rating_num(p."Rating"::text, 70)
              )
            ) AS obj,
            row_number() OVER (
              ORDER BY public.match_sim_player_rating_num(p."Rating"::text, 0) DESC, p."Name"
            ) AS ord
          FROM public."Players" p
          WHERE p."Contracted_Team" = v_club
            AND NOT EXISTS (
              SELECT 1
              FROM jsonb_array_elements(v_rows) e
              WHERE e->>'player_id' = p."Konami_ID"::text
            )
          LIMIT 5
        ) y
      ),
      '[]'::jsonb
    )
    INTO v_rows;
  END IF;

  RETURN v_rows;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.match_sim_player_rating_num(text, numeric) TO authenticated;
GRANT EXECUTE ON FUNCTION public.match_sim_load_club_side(text) TO authenticated;

NOTIFY pgrst, 'reload schema';
