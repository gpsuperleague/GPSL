-- =============================================================================
-- Admin Testing: set default matchday squad (4-3-3 best XI + bench)
-- UI: admin_test_set_default_squad.html
-- Mirrors Matchday "auto-fill best XI" + Save default squad.
-- =============================================================================

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

CREATE OR REPLACE FUNCTION public.admin_test_matchday_squad_snapshot(p_club_short_name text)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := btrim(p_club_short_name);
  v_club_name text;
  v_contracted int := 0;
  v_pitch int := 0;
  v_bench int := 0;
  v_total int := 0;
  v_formation text;
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF v_club IS NULL OR v_club = '' OR v_club = 'FOREIGN' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_club');
  END IF;

  SELECT c."Club" INTO v_club_name
  FROM public."Clubs" c
  WHERE c."ShortName" = v_club;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'club_not_found');
  END IF;

  SELECT count(*)::int INTO v_contracted
  FROM public."Players" p
  WHERE p."Contracted_Team" = v_club;

  SELECT
    count(*) FILTER (WHERE sp.slot_kind = 'pitch')::int,
    count(*) FILTER (WHERE sp.slot_kind = 'bench')::int,
    count(*)::int
  INTO v_pitch, v_bench, v_total
  FROM public.club_matchday_squad_player sp
  WHERE sp.club_short_name = v_club;

  SELECT nullif(btrim(s.pitch_layout->>'formation_id'), '')
  INTO v_formation
  FROM public.club_matchday_squad s
  WHERE s.club_short_name = v_club;

  RETURN jsonb_build_object(
    'ok', true,
    'club', v_club,
    'club_name', v_club_name,
    'contracted', v_contracted,
    'matchday_total', v_total,
    'matchday_pitch', v_pitch,
    'matchday_bench', v_bench,
    'formation_id', v_formation,
    'has_saved_squad', v_total > 0,
    'can_set_default', v_contracted >= 11
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.admin_test_matchday_squad_snapshot(text) TO authenticated;

DROP FUNCTION IF EXISTS public.admin_test_set_default_matchday_squad(text, boolean);

CREATE OR REPLACE FUNCTION public.admin_test_set_default_matchday_squad(
  p_club_short_name text,
  p_dry_run boolean DEFAULT true
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
SET statement_timeout = '60s'
AS $function$
DECLARE
  v_club text := btrim(p_club_short_name);
  v_layout jsonb;
  v_slots jsonb := '[]'::jsonb;
  v_xi jsonb := '[]'::jsonb;
  v_bench jsonb := '[]'::jsonb;
  v_slot text;
  v_prefs text[];
  v_player record;
  v_used text[] := ARRAY[]::text[];
  v_sort smallint := 0;
  v_contracted int := 0;
  v_pitch_n int := 0;
  v_bench_n int := 0;
  v_slot_list text[] := ARRAY[
    'GK', 'LB', 'CB1', 'CB2', 'RB', 'LMF', 'CMF', 'RMF', 'LWF', 'CF', 'RWF'
  ];
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF v_club IS NULL OR v_club = '' OR v_club = 'FOREIGN' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_club');
  END IF;

  IF NOT EXISTS (SELECT 1 FROM public."Clubs" c WHERE c."ShortName" = v_club) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'club_not_found');
  END IF;

  SELECT count(*)::int INTO v_contracted
  FROM public."Players" p
  WHERE p."Contracted_Team" = v_club;

  IF v_contracted < 11 THEN
    RETURN jsonb_build_object(
      'ok', false,
      'reason', 'need_11_contracted',
      'club', v_club,
      'contracted', v_contracted
    );
  END IF;

  -- Default 4-3-3 pitch layout (matches matchday_formations.js)
  v_layout := jsonb_build_object(
    'formation_id', '4-3-3',
    'GK',  jsonb_build_object('x', 50, 'y', 86, 'label', 'GK'),
    'LB',  jsonb_build_object('x', 12, 'y', 68, 'label', 'LB'),
    'CB1', jsonb_build_object('x', 36, 'y', 72, 'label', 'CB'),
    'CB2', jsonb_build_object('x', 64, 'y', 72, 'label', 'CB'),
    'RB',  jsonb_build_object('x', 88, 'y', 68, 'label', 'RB'),
    'LMF', jsonb_build_object('x', 16, 'y', 48, 'label', 'CMF'),
    'CMF', jsonb_build_object('x', 50, 'y', 52, 'label', 'CMF'),
    'RMF', jsonb_build_object('x', 84, 'y', 48, 'label', 'CMF'),
    'LWF', jsonb_build_object('x', 22, 'y', 22, 'label', 'LWF'),
    'CF',  jsonb_build_object('x', 50, 'y', 12, 'label', 'CF'),
    'RWF', jsonb_build_object('x', 78, 'y', 22, 'label', 'RWF')
  );

  FOREACH v_slot IN ARRAY v_slot_list LOOP
    v_prefs := CASE v_slot
      WHEN 'GK'  THEN ARRAY['GK']
      WHEN 'LB'  THEN ARRAY['LB', 'LWB']
      WHEN 'CB1' THEN ARRAY['CB']
      WHEN 'CB2' THEN ARRAY['CB']
      WHEN 'RB'  THEN ARRAY['RB', 'RWB']
      WHEN 'LMF' THEN ARRAY['LMF', 'CMF', 'DMF', 'AMF']
      WHEN 'CMF' THEN ARRAY['CMF', 'DMF', 'AMF', 'LMF', 'RMF']
      WHEN 'RMF' THEN ARRAY['RMF', 'CMF', 'DMF', 'AMF']
      WHEN 'LWF' THEN ARRAY['LWF', 'LW', 'SS', 'CF']
      WHEN 'CF'  THEN ARRAY['CF', 'SS']
      WHEN 'RWF' THEN ARRAY['RWF', 'RW', 'SS', 'CF']
      ELSE ARRAY[]::text[]
    END;

    SELECT
      p."Konami_ID"::text AS player_id,
      p."Name" AS player_name,
      upper(btrim(p."Position"::text)) AS player_position,
      public.match_sim_player_rating_num(p."Rating"::text, 0) AS rating
    INTO v_player
    FROM public."Players" p
    WHERE p."Contracted_Team" = v_club
      AND NOT (p."Konami_ID"::text = ANY (v_used))
      AND upper(btrim(p."Position"::text)) = ANY (v_prefs)
    ORDER BY
      array_position(v_prefs, upper(btrim(p."Position"::text))) NULLS LAST,
      public.match_sim_player_rating_num(p."Rating"::text, 0) DESC,
      p."Name"
    LIMIT 1;

    IF NOT FOUND THEN
      SELECT
        p."Konami_ID"::text AS player_id,
        p."Name" AS player_name,
        upper(btrim(p."Position"::text)) AS player_position,
        public.match_sim_player_rating_num(p."Rating"::text, 0) AS rating
      INTO v_player
      FROM public."Players" p
      WHERE p."Contracted_Team" = v_club
        AND NOT (p."Konami_ID"::text = ANY (v_used))
      ORDER BY
        public.match_sim_player_rating_num(p."Rating"::text, 0) DESC,
        p."Name"
      LIMIT 1;
    END IF;

    IF NOT FOUND THEN
      EXIT;
    END IF;

    v_used := array_append(v_used, v_player.player_id);
    v_pitch_n := v_pitch_n + 1;
    v_slots := v_slots || jsonb_build_array(
      jsonb_build_object(
        'player_id', v_player.player_id,
        'slot_kind', 'pitch',
        'pitch_slot', v_slot,
        'sort_order', v_pitch_n
      )
    );
    v_xi := v_xi || jsonb_build_array(
      jsonb_build_object(
        'player_id', v_player.player_id,
        'player_name', v_player.player_name,
        'position', v_player.player_position,
        'pitch_slot', v_slot,
        'rating', v_player.rating
      )
    );
  END LOOP;

  IF v_pitch_n < 11 THEN
    RETURN jsonb_build_object(
      'ok', false,
      'reason', 'could_not_fill_xi',
      'club', v_club,
      'pitch', v_pitch_n,
      'contracted', v_contracted
    );
  END IF;

  -- Bench: next best remaining (up to 12), total matchday squad ≤ 23
  FOR v_player IN
    SELECT
      p."Konami_ID"::text AS player_id,
      p."Name" AS player_name,
      upper(btrim(p."Position"::text)) AS player_position,
      public.match_sim_player_rating_num(p."Rating"::text, 0) AS rating
    FROM public."Players" p
    WHERE p."Contracted_Team" = v_club
      AND NOT (p."Konami_ID"::text = ANY (v_used))
    ORDER BY
      public.match_sim_player_rating_num(p."Rating"::text, 0) DESC,
      p."Name"
    LIMIT 12
  LOOP
    v_bench_n := v_bench_n + 1;
    v_used := array_append(v_used, v_player.player_id);
    v_slots := v_slots || jsonb_build_array(
      jsonb_build_object(
        'player_id', v_player.player_id,
        'slot_kind', 'bench',
        'pitch_slot', NULL,
        'sort_order', v_bench_n
      )
    );
    v_bench := v_bench || jsonb_build_array(
      jsonb_build_object(
        'player_id', v_player.player_id,
        'player_name', v_player.player_name,
        'position', v_player.player_position,
        'rating', v_player.rating,
        'sort_order', v_bench_n
      )
    );
  END LOOP;

  IF NOT p_dry_run THEN
    INSERT INTO public.club_matchday_squad (club_short_name, pitch_layout, updated_at)
    VALUES (v_club, v_layout, now())
    ON CONFLICT (club_short_name) DO UPDATE
    SET pitch_layout = EXCLUDED.pitch_layout,
        updated_at = now();

    DELETE FROM public.club_matchday_squad_player
    WHERE club_short_name = v_club;

    INSERT INTO public.club_matchday_squad_player (
      club_short_name, player_id, slot_kind, pitch_slot, sort_order
    )
    SELECT
      v_club,
      btrim(s->>'player_id'),
      btrim(s->>'slot_kind'),
      nullif(btrim(s->>'pitch_slot'), ''),
      coalesce((s->>'sort_order')::smallint, 0)
    FROM jsonb_array_elements(v_slots) s;
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'dry_run', p_dry_run,
    'club', v_club,
    'formation_id', '4-3-3',
    'contracted', v_contracted,
    'pitch', v_pitch_n,
    'bench', v_bench_n,
    'total', v_pitch_n + v_bench_n,
    'xi', v_xi,
    'bench_players', v_bench
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.admin_test_set_default_matchday_squad(text, boolean)
  TO authenticated;
