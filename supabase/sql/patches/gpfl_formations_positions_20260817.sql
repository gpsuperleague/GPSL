-- =============================================================================
-- GPFL: GPSL formations + position-fit rules for XI
--
-- Flex (bidirectional):
--   LMF <-> LWF
--   RMF <-> RWF
--   CF  <-> SS
-- All other positions: exact match (after alias normalize LW/RW/LM/RM).
--
-- Safe re-run. Run after gpfl_fantasy_league_20260817.sql (+ club owner patch ok).
-- =============================================================================

ALTER TABLE public.gpfl_entries
  ADD COLUMN IF NOT EXISTS formation_id text;

ALTER TABLE public.gpfl_squad_players
  ADD COLUMN IF NOT EXISTS pitch_slot text;

CREATE TABLE IF NOT EXISTS public.gpfl_formation_slots (
  formation_id text NOT NULL,
  slot_id text NOT NULL,
  required_pos text NOT NULL,
  sort_order int NOT NULL DEFAULT 0,
  PRIMARY KEY (formation_id, slot_id)
);

ALTER TABLE public.gpfl_formation_slots ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS gpfl_formation_slots_read ON public.gpfl_formation_slots;
CREATE POLICY gpfl_formation_slots_read ON public.gpfl_formation_slots
  FOR SELECT TO authenticated, anon USING (true);

DELETE FROM public.gpfl_formation_slots;
INSERT INTO public.gpfl_formation_slots (formation_id, slot_id, required_pos, sort_order) VALUES
  ('4-4-2', 'GK', 'GK', 0),
  ('4-4-2', 'LB', 'LB', 1),
  ('4-4-2', 'CB1', 'CB', 2),
  ('4-4-2', 'CB2', 'CB', 3),
  ('4-4-2', 'RB', 'RB', 4),
  ('4-4-2', 'LMF', 'LMF', 5),
  ('4-4-2', 'CMF', 'CMF', 6),
  ('4-4-2', 'RMF', 'RMF', 7),
  ('4-4-2', 'RWF', 'RMF', 8),
  ('4-4-2', 'LWF', 'CF', 9),
  ('4-4-2', 'CF', 'CF', 10),
  ('4-3-3', 'GK', 'GK', 0),
  ('4-3-3', 'LB', 'LB', 1),
  ('4-3-3', 'CB1', 'CB', 2),
  ('4-3-3', 'CB2', 'CB', 3),
  ('4-3-3', 'RB', 'RB', 4),
  ('4-3-3', 'LMF', 'CMF', 5),
  ('4-3-3', 'CMF', 'CMF', 6),
  ('4-3-3', 'RMF', 'CMF', 7),
  ('4-3-3', 'LWF', 'LWF', 8),
  ('4-3-3', 'CF', 'CF', 9),
  ('4-3-3', 'RWF', 'RWF', 10),
  ('4-3-2-1', 'GK', 'GK', 0),
  ('4-3-2-1', 'LB', 'LB', 1),
  ('4-3-2-1', 'CB1', 'CB', 2),
  ('4-3-2-1', 'CB2', 'CB', 3),
  ('4-3-2-1', 'RB', 'RB', 4),
  ('4-3-2-1', 'LMF', 'CMF', 5),
  ('4-3-2-1', 'CMF', 'CMF', 6),
  ('4-3-2-1', 'RMF', 'CMF', 7),
  ('4-3-2-1', 'LWF', 'AMF', 8),
  ('4-3-2-1', 'RWF', 'AMF', 9),
  ('4-3-2-1', 'CF', 'CF', 10),
  ('4-3-1-2', 'GK', 'GK', 0),
  ('4-3-1-2', 'LB', 'LB', 1),
  ('4-3-1-2', 'CB1', 'CB', 2),
  ('4-3-1-2', 'CB2', 'CB', 3),
  ('4-3-1-2', 'RB', 'RB', 4),
  ('4-3-1-2', 'LMF', 'CMF', 5),
  ('4-3-1-2', 'CMF', 'CMF', 6),
  ('4-3-1-2', 'RMF', 'CMF', 7),
  ('4-3-1-2', 'LWF', 'AMF', 8),
  ('4-3-1-2', 'RWF', 'SS', 9),
  ('4-3-1-2', 'CF', 'CF', 10),
  ('4-2-3-1', 'GK', 'GK', 0),
  ('4-2-3-1', 'LB', 'LB', 1),
  ('4-2-3-1', 'CB1', 'CB', 2),
  ('4-2-3-1', 'CB2', 'CB', 3),
  ('4-2-3-1', 'RB', 'RB', 4),
  ('4-2-3-1', 'LMF', 'DMF', 5),
  ('4-2-3-1', 'RMF', 'DMF', 6),
  ('4-2-3-1', 'LWF', 'LWF', 7),
  ('4-2-3-1', 'CMF', 'AMF', 8),
  ('4-2-3-1', 'RWF', 'RWF', 9),
  ('4-2-3-1', 'CF', 'CF', 10),
  ('4-2-1-3', 'GK', 'GK', 0),
  ('4-2-1-3', 'LB', 'LB', 1),
  ('4-2-1-3', 'CB1', 'CB', 2),
  ('4-2-1-3', 'CB2', 'CB', 3),
  ('4-2-1-3', 'RB', 'RB', 4),
  ('4-2-1-3', 'LMF', 'DMF', 5),
  ('4-2-1-3', 'RMF', 'DMF', 6),
  ('4-2-1-3', 'CMF', 'AMF', 7),
  ('4-2-1-3', 'LWF', 'LWF', 8),
  ('4-2-1-3', 'CF', 'CF', 9),
  ('4-2-1-3', 'RWF', 'RWF', 10),
  ('4-1-4-1', 'GK', 'GK', 0),
  ('4-1-4-1', 'LB', 'LB', 1),
  ('4-1-4-1', 'CB1', 'CB', 2),
  ('4-1-4-1', 'CB2', 'CB', 3),
  ('4-1-4-1', 'RB', 'RB', 4),
  ('4-1-4-1', 'CMF', 'DMF', 5),
  ('4-1-4-1', 'LMF', 'LMF', 6),
  ('4-1-4-1', 'LWF', 'CMF', 7),
  ('4-1-4-1', 'RMF', 'CMF', 8),
  ('4-1-4-1', 'RWF', 'RMF', 9),
  ('4-1-4-1', 'CF', 'CF', 10),
  ('4-1-2-3', 'GK', 'GK', 0),
  ('4-1-2-3', 'LB', 'LB', 1),
  ('4-1-2-3', 'CB1', 'CB', 2),
  ('4-1-2-3', 'CB2', 'CB', 3),
  ('4-1-2-3', 'RB', 'RB', 4),
  ('4-1-2-3', 'CMF', 'DMF', 5),
  ('4-1-2-3', 'LMF', 'CMF', 6),
  ('4-1-2-3', 'RMF', 'CMF', 7),
  ('4-1-2-3', 'LWF', 'LWF', 8),
  ('4-1-2-3', 'CF', 'CF', 9),
  ('4-1-2-3', 'RWF', 'RWF', 10),
  ('3-4-3', 'GK', 'GK', 0),
  ('3-4-3', 'CB1', 'CB', 1),
  ('3-4-3', 'CB2', 'CB', 2),
  ('3-4-3', 'RB', 'CB', 3),
  ('3-4-3', 'LB', 'LMF', 4),
  ('3-4-3', 'LMF', 'CMF', 5),
  ('3-4-3', 'RMF', 'CMF', 6),
  ('3-4-3', 'RWF', 'RMF', 7),
  ('3-4-3', 'LWF', 'LWF', 8),
  ('3-4-3', 'CF', 'CF', 9),
  ('3-4-3', 'CMF', 'RWF', 10),
  ('3-2-4-1', 'GK', 'GK', 0),
  ('3-2-4-1', 'CB1', 'CB', 1),
  ('3-2-4-1', 'CB2', 'CB', 2),
  ('3-2-4-1', 'RB', 'CB', 3),
  ('3-2-4-1', 'LMF', 'DMF', 4),
  ('3-2-4-1', 'RMF', 'DMF', 5),
  ('3-2-4-1', 'LB', 'LMF', 6),
  ('3-2-4-1', 'LWF', 'CMF', 7),
  ('3-2-4-1', 'CMF', 'CMF', 8),
  ('3-2-4-1', 'RWF', 'RMF', 9),
  ('3-2-4-1', 'CF', 'CF', 10),
  ('3-2-3-2', 'GK', 'GK', 0),
  ('3-2-3-2', 'CB1', 'CB', 1),
  ('3-2-3-2', 'CB2', 'CB', 2),
  ('3-2-3-2', 'RB', 'CB', 3),
  ('3-2-3-2', 'LMF', 'CMF', 4),
  ('3-2-3-2', 'RMF', 'CMF', 5),
  ('3-2-3-2', 'LB', 'LWF', 6),
  ('3-2-3-2', 'CMF', 'AMF', 7),
  ('3-2-3-2', 'RWF', 'RWF', 8),
  ('3-2-3-2', 'LWF', 'CF', 9),
  ('3-2-3-2', 'CF', 'CF', 10),
  ('3-1-4-2', 'GK', 'GK', 0),
  ('3-1-4-2', 'CB1', 'CB', 1),
  ('3-1-4-2', 'CB2', 'CB', 2),
  ('3-1-4-2', 'RB', 'CB', 3),
  ('3-1-4-2', 'CMF', 'DMF', 4),
  ('3-1-4-2', 'LB', 'LMF', 5),
  ('3-1-4-2', 'LMF', 'CMF', 6),
  ('3-1-4-2', 'RMF', 'CMF', 7),
  ('3-1-4-2', 'RWF', 'RMF', 8),
  ('3-1-4-2', 'LWF', 'CF', 9),
  ('3-1-4-2', 'CF', 'CF', 10),
  ('5-3-2', 'GK', 'GK', 0),
  ('5-3-2', 'LB', 'LWB', 1),
  ('5-3-2', 'CB1', 'CB', 2),
  ('5-3-2', 'CB2', 'CB', 3),
  ('5-3-2', 'RB', 'CB', 4),
  ('5-3-2', 'RWF', 'RWB', 5),
  ('5-3-2', 'LMF', 'CMF', 6),
  ('5-3-2', 'CMF', 'CMF', 7),
  ('5-3-2', 'RMF', 'CMF', 8),
  ('5-3-2', 'LWF', 'CF', 9),
  ('5-3-2', 'CF', 'CF', 10),
  ('5-2-2-1', 'GK', 'GK', 0),
  ('5-2-2-1', 'LB', 'LWB', 1),
  ('5-2-2-1', 'CB1', 'CB', 2),
  ('5-2-2-1', 'CB2', 'CB', 3),
  ('5-2-2-1', 'RB', 'CB', 4),
  ('5-2-2-1', 'RWF', 'RWB', 5),
  ('5-2-2-1', 'LMF', 'CMF', 6),
  ('5-2-2-1', 'RMF', 'CMF', 7),
  ('5-2-2-1', 'LWF', 'AMF', 8),
  ('5-2-2-1', 'CMF', 'AMF', 9),
  ('5-2-2-1', 'CF', 'CF', 10),
  ('5-2-1-2', 'GK', 'GK', 0),
  ('5-2-1-2', 'LB', 'LWB', 1),
  ('5-2-1-2', 'CB1', 'CB', 2),
  ('5-2-1-2', 'CB2', 'CB', 3),
  ('5-2-1-2', 'RB', 'CB', 4),
  ('5-2-1-2', 'RWF', 'RWB', 5),
  ('5-2-1-2', 'LMF', 'CMF', 6),
  ('5-2-1-2', 'RMF', 'CMF', 7),
  ('5-2-1-2', 'CMF', 'AMF', 8),
  ('5-2-1-2', 'LWF', 'CF', 9),
  ('5-2-1-2', 'CF', 'CF', 10);

-- Aliases + GPFL flex rules (only LMF/LWF, RMF/RWF, CF/SS; all else exact)
CREATE OR REPLACE FUNCTION public.gpfl_normalize_pos(p_pos text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE upper(btrim(coalesce(p_pos, '')))
    WHEN 'LW' THEN 'LWF'
    WHEN 'RW' THEN 'RWF'
    WHEN 'LM' THEN 'LMF'
    WHEN 'RM' THEN 'RMF'
    WHEN 'WG' THEN 'LWF'
    ELSE upper(btrim(coalesce(p_pos, '')))
  END;
$$;

CREATE OR REPLACE FUNCTION public.gpfl_pos_fits_slot(p_player_pos text, p_slot_required text)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE
    WHEN v_p = '' OR v_s = '' THEN false
    WHEN v_p = v_s THEN true
    WHEN v_p IN ('LMF', 'LWF') AND v_s IN ('LMF', 'LWF') THEN true
    WHEN v_p IN ('RMF', 'RWF') AND v_s IN ('RMF', 'RWF') THEN true
    WHEN v_p IN ('CF', 'SS') AND v_s IN ('CF', 'SS') THEN true
    ELSE false
  END
  FROM (
    SELECT
      public.gpfl_normalize_pos(p_player_pos) AS v_p,
      public.gpfl_normalize_pos(p_slot_required) AS v_s
  ) x;
$$;

CREATE OR REPLACE FUNCTION public.gpfl_list_formations()
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY r.formation_id), '[]'::jsonb)
  FROM (
    SELECT
      fs.formation_id,
      jsonb_agg(
        jsonb_build_object(
          'slot_id', fs.slot_id,
          'required_pos', fs.required_pos,
          'sort_order', fs.sort_order
        )
        ORDER BY fs.sort_order, fs.slot_id
      ) AS slots
    FROM public.gpfl_formation_slots fs
    GROUP BY fs.formation_id
  ) r;
$$;

GRANT EXECUTE ON FUNCTION public.gpfl_normalize_pos(text) TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.gpfl_pos_fits_slot(text, text) TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.gpfl_list_formations() TO authenticated, anon;

-- Replace set XI: formation + slot map { "GK": "playerId", ... } + captain
DROP FUNCTION IF EXISTS public.gpfl_set_xi(text[], text);

CREATE OR REPLACE FUNCTION public.gpfl_set_xi(
  p_formation_id text,
  p_slot_map jsonb,
  p_captain_id text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_cfg public.gpfl_settings%rowtype;
  v_gs_id bigint;
  v_entry public.gpfl_entries%rowtype;
  v_slot record;
  v_pid text;
  v_player_pos text;
  v_seen text[] := ARRAY[]::text[];
  v_cap_ok boolean := false;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  SELECT * INTO v_cfg FROM public.gpfl_settings WHERE id = 1;
  v_gs_id := public.gpfl_current_season_id();

  SELECT * INTO v_entry
  FROM public.gpfl_entries
  WHERE gpfl_season_id = v_gs_id AND owner_id = v_uid AND status IN ('building', 'active');
  IF NOT FOUND THEN RAISE EXCEPTION 'Join GPFL first'; END IF;

  IF p_formation_id IS NULL OR NOT EXISTS (
    SELECT 1 FROM public.gpfl_formation_slots WHERE formation_id = p_formation_id
  ) THEN
    RAISE EXCEPTION 'Unknown formation %', p_formation_id;
  END IF;

  IF p_slot_map IS NULL OR jsonb_typeof(p_slot_map) <> 'object' THEN
    RAISE EXCEPTION 'p_slot_map must be a JSON object of slot_id → player_id';
  END IF;

  IF p_captain_id IS NULL OR btrim(p_captain_id) = '' THEN
    RAISE EXCEPTION 'Captain required';
  END IF;

  -- Clear pitch assignments
  UPDATE public.gpfl_squad_players
  SET is_starter = false, is_captain = false, pitch_slot = NULL
  WHERE entry_id = v_entry.id;

  FOR v_slot IN
    SELECT * FROM public.gpfl_formation_slots
    WHERE formation_id = p_formation_id
    ORDER BY sort_order
  LOOP
    v_pid := nullif(btrim(p_slot_map ->> v_slot.slot_id), '');
    IF v_pid IS NULL THEN
      RAISE EXCEPTION 'Fill every pitch slot (% needs a player)', v_slot.slot_id;
    END IF;
    IF v_pid = ANY (v_seen) THEN
      RAISE EXCEPTION 'Player % assigned twice', v_pid;
    END IF;
    v_seen := v_seen || v_pid;

    IF NOT EXISTS (
      SELECT 1 FROM public.gpfl_squad_players
      WHERE entry_id = v_entry.id AND player_id = v_pid AND slot_status = 'active'
    ) THEN
      RAISE EXCEPTION 'Player % is not in your active squad', v_pid;
    END IF;

    SELECT pp.position INTO v_player_pos
    FROM public.gpfl_player_prices pp
    WHERE pp.gpfl_season_id = v_gs_id AND pp.player_id = v_pid;

    IF v_player_pos IS NULL THEN
      SELECT p."Position"::text INTO v_player_pos
      FROM public."Players" p
      WHERE p."Konami_ID"::text = v_pid;
    END IF;

    IF NOT public.gpfl_pos_fits_slot(v_player_pos, v_slot.required_pos) THEN
      RAISE EXCEPTION '% (%) cannot play % slot (needs %)',
        v_pid, coalesce(v_player_pos, '?'), v_slot.slot_id, v_slot.required_pos;
    END IF;

    IF v_pid = p_captain_id THEN
      v_cap_ok := true;
    END IF;

    UPDATE public.gpfl_squad_players
    SET is_starter = true,
        pitch_slot = v_slot.slot_id,
        is_captain = (v_pid = p_captain_id)
    WHERE entry_id = v_entry.id AND player_id = v_pid;
  END LOOP;

  IF NOT v_cap_ok THEN
    RAISE EXCEPTION 'Captain must be one of the 11 starters';
  END IF;

  IF coalesce(array_length(v_seen, 1), 0) <> v_cfg.starters THEN
    RAISE EXCEPTION 'Expected % starters', v_cfg.starters;
  END IF;

  UPDATE public.gpfl_entries
  SET formation_id = p_formation_id
  WHERE id = v_entry.id;

  RETURN public.gpfl_my_entry();
END;
$function$;

GRANT EXECUTE ON FUNCTION public.gpfl_set_xi(text, jsonb, text) TO authenticated;

-- Confirm requires formation + full XI already saved
CREATE OR REPLACE FUNCTION public.gpfl_confirm_squad()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_cfg public.gpfl_settings%rowtype;
  v_gs_id bigint;
  v_entry public.gpfl_entries%rowtype;
  v_n int;
  v_starters int;
  v_caps int;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  SELECT * INTO v_cfg FROM public.gpfl_settings WHERE id = 1;
  v_gs_id := public.gpfl_current_season_id();
  PERFORM public.gpfl_sync_free_agents(v_gs_id);

  SELECT * INTO v_entry
  FROM public.gpfl_entries
  WHERE gpfl_season_id = v_gs_id AND owner_id = v_uid AND status IN ('building', 'active');
  IF NOT FOUND THEN RAISE EXCEPTION 'Join GPFL first'; END IF;

  IF v_entry.formation_id IS NULL OR NOT EXISTS (
    SELECT 1 FROM public.gpfl_formation_slots WHERE formation_id = v_entry.formation_id
  ) THEN
    RAISE EXCEPTION 'Set a GPSL formation and XI before confirming';
  END IF;

  SELECT count(*)::int INTO v_n
  FROM public.gpfl_squad_players
  WHERE entry_id = v_entry.id AND slot_status = 'active';
  IF v_n <> v_cfg.squad_size THEN
    RAISE EXCEPTION 'Need a full squad of % (have %)', v_cfg.squad_size, v_n;
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.gpfl_squad_players
    WHERE entry_id = v_entry.id AND slot_status = 'needs_replace'
  ) THEN
    RAISE EXCEPTION 'Replace free-agent slots before confirming';
  END IF;

  SELECT count(*) FILTER (WHERE is_starter)::int,
         count(*) FILTER (WHERE is_captain)::int
  INTO v_starters, v_caps
  FROM public.gpfl_squad_players
  WHERE entry_id = v_entry.id AND slot_status = 'active';

  IF v_starters <> v_cfg.starters OR v_caps <> 1 THEN
    RAISE EXCEPTION 'Save formation XI (%) and exactly 1 captain first', v_cfg.starters;
  END IF;

  -- Re-check position fit against current formation
  IF EXISTS (
    SELECT 1
    FROM public.gpfl_squad_players sp
    JOIN public.gpfl_formation_slots fs
      ON fs.formation_id = v_entry.formation_id AND fs.slot_id = sp.pitch_slot
    LEFT JOIN public.gpfl_player_prices pp
      ON pp.gpfl_season_id = v_gs_id AND pp.player_id = sp.player_id
    WHERE sp.entry_id = v_entry.id
      AND sp.is_starter
      AND NOT public.gpfl_pos_fits_slot(pp.position, fs.required_pos)
  ) THEN
    RAISE EXCEPTION 'One or more starters do not fit their formation slots';
  END IF;

  UPDATE public.gpfl_entries
  SET status = 'active',
      confirmed_at = coalesce(confirmed_at, now()),
      free_transfers_remaining = v_cfg.free_transfers_per_month
  WHERE id = v_entry.id;

  RETURN public.gpfl_my_entry();
END;
$function$;

GRANT EXECUTE ON FUNCTION public.gpfl_confirm_squad() TO authenticated;

-- my_entry: include pitch_slot + player position (keep club/owner from prior patch)
CREATE OR REPLACE FUNCTION public.gpfl_my_entry()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_gs_id bigint;
  v_entry public.gpfl_entries%rowtype;
  v_cfg jsonb;
  v_squad jsonb;
  v_season jsonb;
  v_formation jsonb;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  v_cfg := public.gpfl_settings_get();
  v_gs_id := public.gpfl_current_season_id();

  IF v_gs_id IS NULL THEN
    RETURN jsonb_build_object(
      'ok', true,
      'enabled', coalesce((v_cfg->>'enabled')::boolean, true),
      'joined', false,
      'gpfl_season_id', null,
      'settings', v_cfg
    );
  END IF;

  SELECT to_jsonb(gs.*) INTO v_season
  FROM public.gpfl_seasons gs WHERE gs.id = v_gs_id;

  SELECT * INTO v_entry
  FROM public.gpfl_entries
  WHERE gpfl_season_id = v_gs_id AND owner_id = v_uid;

  IF NOT FOUND OR v_entry.status = 'withdrawn' THEN
    RETURN jsonb_build_object(
      'ok', true,
      'enabled', coalesce((v_cfg->>'enabled')::boolean, true),
      'joined', false,
      'gpfl_season_id', v_gs_id,
      'season', v_season,
      'settings', v_cfg
    );
  END IF;

  PERFORM public.gpfl_sync_free_agents(v_gs_id);
  SELECT * INTO v_entry FROM public.gpfl_entries WHERE id = v_entry.id;

  IF v_entry.formation_id IS NOT NULL THEN
    SELECT jsonb_build_object(
      'formation_id', v_entry.formation_id,
      'slots', coalesce(jsonb_agg(
        jsonb_build_object(
          'slot_id', fs.slot_id,
          'required_pos', fs.required_pos,
          'sort_order', fs.sort_order
        ) ORDER BY fs.sort_order
      ), '[]'::jsonb)
    )
    INTO v_formation
    FROM public.gpfl_formation_slots fs
    WHERE fs.formation_id = v_entry.formation_id;
  END IF;

  SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY
    CASE WHEN x.pitch_slot IS NULL THEN 1 ELSE 0 END,
    CASE x.position_group WHEN 'gk' THEN 1 WHEN 'def' THEN 2 WHEN 'mid' THEN 3 ELSE 4 END,
    x.player_name
  ), '[]'::jsonb)
  INTO v_squad
  FROM (
    SELECT
      sp.id,
      sp.player_id,
      sp.position_group,
      sp.purchase_price,
      sp.is_starter,
      sp.is_captain,
      sp.slot_status,
      sp.pitch_slot,
      pp.player_name,
      pp.club_short_name,
      coalesce(nullif(btrim(c."Club"), ''), pp.club_short_name) AS club_name,
      CASE
        WHEN c.owner_id IS NULL AND coalesce(nullif(btrim(c.owner), ''), '') = '' THEN 'Vacant'
        ELSE coalesce(
          nullif(btrim(public.competition_owner_display_name(c.owner_id)), ''),
          nullif(btrim(c.owner), ''),
          'Vacant'
        )
      END AS owner_name,
      pp.division,
      pp.position,
      pp.price AS current_price,
      pp.eligible
    FROM public.gpfl_squad_players sp
    LEFT JOIN public.gpfl_player_prices pp
      ON pp.gpfl_season_id = v_gs_id AND pp.player_id = sp.player_id
    LEFT JOIN public."Clubs" c ON c."ShortName" = pp.club_short_name
    WHERE sp.entry_id = v_entry.id
  ) x;

  RETURN jsonb_build_object(
    'ok', true,
    'enabled', coalesce((v_cfg->>'enabled')::boolean, true),
    'joined', true,
    'gpfl_season_id', v_gs_id,
    'season', v_season,
    'settings', v_cfg,
    'entry', to_jsonb(v_entry),
    'formation', v_formation,
    'squad', v_squad
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.gpfl_my_entry() TO authenticated;
