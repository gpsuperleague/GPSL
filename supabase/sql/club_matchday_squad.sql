-- =============================================================================
-- GPSL Matchday squad — default 23-man squad with pitch/bench/reserve slots
-- Run after competition_phase0.sql (Clubs, Players, my_club_shortname)
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.club_matchday_squad (
  club_short_name text NOT NULL PRIMARY KEY
    REFERENCES public."Clubs" ("ShortName") ON DELETE CASCADE,
  pitch_layout jsonb NOT NULL DEFAULT '{}'::jsonb,
  updated_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.club_matchday_squad
  ADD COLUMN IF NOT EXISTS pitch_layout jsonb NOT NULL DEFAULT '{}'::jsonb;

CREATE TABLE IF NOT EXISTS public.club_matchday_squad_player (
  club_short_name text NOT NULL
    REFERENCES public.club_matchday_squad (club_short_name) ON DELETE CASCADE,
  player_id text NOT NULL,
  slot_kind text NOT NULL,
  pitch_slot text,
  sort_order smallint NOT NULL DEFAULT 0,
  CONSTRAINT club_matchday_squad_player_kind_chk
    CHECK (slot_kind IN ('pitch', 'bench', 'reserve')),
  CONSTRAINT club_matchday_squad_player_pitch_chk
    CHECK (
      (slot_kind = 'pitch' AND pitch_slot IS NOT NULL)
      OR (slot_kind <> 'pitch' AND pitch_slot IS NULL)
    ),
  CONSTRAINT club_matchday_squad_player_unique UNIQUE (club_short_name, player_id),
  CONSTRAINT club_matchday_squad_pitch_slot_unique UNIQUE (club_short_name, pitch_slot)
);

CREATE INDEX IF NOT EXISTS club_matchday_squad_player_club_idx
  ON public.club_matchday_squad_player (club_short_name, slot_kind, sort_order);

-- ---------------------------------------------------------------------------
-- Save squad (owner's club only)
-- p_slots: [{ player_id, slot_kind, pitch_slot?, sort_order? }, ...]
-- ---------------------------------------------------------------------------

DROP FUNCTION IF EXISTS public.club_save_matchday_squad(jsonb);

CREATE OR REPLACE FUNCTION public.club_save_matchday_squad(
  p_slots jsonb,
  p_pitch_layout jsonb DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := public.my_club_shortname();
  v_row jsonb;
  v_player_id text;
  v_kind text;
  v_pitch_slot text;
  v_sort smallint;
  v_total int := 0;
  v_pitch_count int := 0;
  v_bench_count int := 0;
  v_reserve_count int := 0;
  v_layout jsonb;
BEGIN
  IF v_club IS NULL OR v_club = '' THEN
    RAISE EXCEPTION 'No club linked to your account';
  END IF;

  IF p_slots IS NULL OR jsonb_typeof(p_slots) <> 'array' THEN
    RAISE EXCEPTION 'p_slots must be a JSON array';
  END IF;

  IF jsonb_array_length(p_slots) > 23 THEN
    RAISE EXCEPTION 'Matchday squad cannot exceed 23 players';
  END IF;

  FOR v_row IN SELECT value FROM jsonb_array_elements(p_slots)
  LOOP
    v_player_id := btrim(v_row->>'player_id');
    v_kind := btrim(v_row->>'slot_kind');
    v_pitch_slot := nullif(btrim(v_row->>'pitch_slot'), '');
    v_sort := coalesce((v_row->>'sort_order')::smallint, 0);

    IF v_player_id IS NULL OR v_player_id = '' THEN
      RAISE EXCEPTION 'Each slot needs player_id';
    END IF;

    IF v_kind NOT IN ('pitch', 'bench', 'reserve') THEN
      RAISE EXCEPTION 'Invalid slot_kind for player %', v_player_id;
    END IF;

    IF v_kind = 'pitch' AND v_pitch_slot IS NULL THEN
      RAISE EXCEPTION 'Pitch players need pitch_slot';
    END IF;

    IF v_kind <> 'pitch' AND v_pitch_slot IS NOT NULL THEN
      RAISE EXCEPTION 'Only pitch players may have pitch_slot';
    END IF;

    IF NOT EXISTS (
      SELECT 1 FROM public."Players" p
      WHERE p."Konami_ID"::text = v_player_id
        AND p."Contracted_Team" = v_club
    ) THEN
      RAISE EXCEPTION 'Player % is not in your contracted squad', v_player_id;
    END IF;

    v_total := v_total + 1;
    IF v_kind = 'pitch' THEN v_pitch_count := v_pitch_count + 1;
    ELSIF v_kind = 'bench' THEN v_bench_count := v_bench_count + 1;
    ELSE v_reserve_count := v_reserve_count + 1;
    END IF;
  END LOOP;

  IF v_pitch_count > 11 THEN
    RAISE EXCEPTION 'Maximum 11 players on the pitch (got %)', v_pitch_count;
  END IF;
  IF v_bench_count > 12 THEN
    RAISE EXCEPTION 'Maximum 12 bench players (got %)', v_bench_count;
  END IF;
  IF v_reserve_count > 0 THEN
    RAISE EXCEPTION 'Reserves are no longer used — use bench slots (max 12)';
  END IF;

  v_layout := coalesce(p_pitch_layout, '{}'::jsonb);
  IF jsonb_typeof(v_layout) IS DISTINCT FROM 'object' THEN
    RAISE EXCEPTION 'p_pitch_layout must be a JSON object';
  END IF;

  INSERT INTO public.club_matchday_squad (club_short_name, pitch_layout, updated_at)
  VALUES (v_club, v_layout, now())
  ON CONFLICT (club_short_name) DO UPDATE
  SET pitch_layout = EXCLUDED.pitch_layout,
      updated_at = now();

  DELETE FROM public.club_matchday_squad_player
  WHERE club_short_name = v_club;

  FOR v_row IN SELECT value FROM jsonb_array_elements(p_slots)
  LOOP
    v_player_id := btrim(v_row->>'player_id');
    v_kind := btrim(v_row->>'slot_kind');
    v_pitch_slot := nullif(btrim(v_row->>'pitch_slot'), '');
    v_sort := coalesce((v_row->>'sort_order')::smallint, 0);

    INSERT INTO public.club_matchday_squad_player (
      club_short_name,
      player_id,
      slot_kind,
      pitch_slot,
      sort_order
    )
    VALUES (v_club, v_player_id, v_kind, v_pitch_slot, v_sort);
  END LOOP;

  RETURN jsonb_build_object(
    'club_short_name', v_club,
    'total', v_total,
    'pitch', v_pitch_count,
    'bench', v_bench_count,
    'reserve', v_reserve_count
  );
END;
$function$;

-- ---------------------------------------------------------------------------
-- Saved custom formations (5 per club)
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.club_matchday_saved_formation (
  club_short_name text NOT NULL
    REFERENCES public."Clubs" ("ShortName") ON DELETE CASCADE,
  slot_no smallint NOT NULL,
  name text NOT NULL,
  pitch_layout jsonb NOT NULL DEFAULT '{}'::jsonb,
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT club_matchday_saved_formation_slot_chk
    CHECK (slot_no >= 1 AND slot_no <= 5),
  PRIMARY KEY (club_short_name, slot_no)
);

CREATE OR REPLACE FUNCTION public.club_save_matchday_formation(
  p_slot_no smallint,
  p_name text,
  p_pitch_layout jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := public.my_club_shortname();
  v_name text := btrim(p_name);
BEGIN
  IF v_club IS NULL OR v_club = '' THEN
    RAISE EXCEPTION 'No club linked to your account';
  END IF;

  IF p_slot_no IS NULL OR p_slot_no < 1 OR p_slot_no > 5 THEN
    RAISE EXCEPTION 'Formation slot must be 1–5';
  END IF;

  IF v_name IS NULL OR v_name = '' THEN
    RAISE EXCEPTION 'Formation name is required';
  END IF;

  IF p_pitch_layout IS NULL OR jsonb_typeof(p_pitch_layout) IS DISTINCT FROM 'object' THEN
    RAISE EXCEPTION 'p_pitch_layout must be a JSON object';
  END IF;

  INSERT INTO public.club_matchday_squad (club_short_name, updated_at)
  VALUES (v_club, now())
  ON CONFLICT (club_short_name) DO NOTHING;

  INSERT INTO public.club_matchday_saved_formation (
    club_short_name,
    slot_no,
    name,
    pitch_layout,
    updated_at
  )
  VALUES (v_club, p_slot_no, v_name, p_pitch_layout, now())
  ON CONFLICT (club_short_name, slot_no) DO UPDATE
  SET name = EXCLUDED.name,
      pitch_layout = EXCLUDED.pitch_layout,
      updated_at = now();

  RETURN jsonb_build_object(
    'club_short_name', v_club,
    'slot_no', p_slot_no,
    'name', v_name
  );
END;
$function$;

-- ---------------------------------------------------------------------------
-- Public view
-- ---------------------------------------------------------------------------

DROP VIEW IF EXISTS public.club_matchday_saved_formation_public;
CREATE VIEW public.club_matchday_saved_formation_public
WITH (security_invoker = false)
AS
SELECT
  f.club_short_name,
  f.slot_no,
  f.name,
  f.pitch_layout,
  f.updated_at
FROM public.club_matchday_saved_formation f
WHERE f.club_short_name = public.my_club_shortname()
ORDER BY f.slot_no;

DROP VIEW IF EXISTS public.club_matchday_pitch_layout_public;
CREATE VIEW public.club_matchday_pitch_layout_public
WITH (security_invoker = false)
AS
SELECT
  s.club_short_name,
  s.pitch_layout,
  s.updated_at
FROM public.club_matchday_squad s
WHERE s.club_short_name = public.my_club_shortname();

DROP VIEW IF EXISTS public.club_matchday_squad_public;
CREATE VIEW public.club_matchday_squad_public
WITH (security_invoker = false)
AS
SELECT
  sp.club_short_name,
  sp.player_id,
  sp.slot_kind,
  sp.pitch_slot,
  sp.sort_order,
  p."Name" AS player_name,
  p."Position" AS player_position,
  p."Rating" AS player_rating,
  s.updated_at AS squad_updated_at
FROM public.club_matchday_squad_player sp
JOIN public.club_matchday_squad s ON s.club_short_name = sp.club_short_name
JOIN public."Players" p ON p."Konami_ID"::text = sp.player_id
WHERE sp.club_short_name = public.my_club_shortname()
ORDER BY
  CASE sp.slot_kind
    WHEN 'pitch' THEN 1
    WHEN 'bench' THEN 2
    ELSE 3
  END,
  sp.sort_order,
  sp.pitch_slot;

-- ---------------------------------------------------------------------------
-- RLS + grants
-- ---------------------------------------------------------------------------

ALTER TABLE public.club_matchday_squad ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.club_matchday_squad_player ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.club_matchday_saved_formation ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS club_matchday_squad_read ON public.club_matchday_squad;
CREATE POLICY club_matchday_squad_read ON public.club_matchday_squad
  FOR SELECT TO authenticated USING (true);

DROP POLICY IF EXISTS club_matchday_squad_owner ON public.club_matchday_squad;
CREATE POLICY club_matchday_squad_owner ON public.club_matchday_squad
  FOR ALL TO authenticated
  USING (club_short_name = public.my_club_shortname())
  WITH CHECK (club_short_name = public.my_club_shortname());

DROP POLICY IF EXISTS club_matchday_squad_player_read ON public.club_matchday_squad_player;
CREATE POLICY club_matchday_squad_player_read ON public.club_matchday_squad_player
  FOR SELECT TO authenticated USING (true);

DROP POLICY IF EXISTS club_matchday_squad_player_owner ON public.club_matchday_squad_player;
CREATE POLICY club_matchday_squad_player_owner ON public.club_matchday_squad_player
  FOR ALL TO authenticated
  USING (club_short_name = public.my_club_shortname())
  WITH CHECK (club_short_name = public.my_club_shortname());

DROP POLICY IF EXISTS club_matchday_saved_formation_read ON public.club_matchday_saved_formation;
CREATE POLICY club_matchday_saved_formation_read ON public.club_matchday_saved_formation
  FOR SELECT TO authenticated USING (true);

DROP POLICY IF EXISTS club_matchday_saved_formation_owner ON public.club_matchday_saved_formation;
CREATE POLICY club_matchday_saved_formation_owner ON public.club_matchday_saved_formation
  FOR ALL TO authenticated
  USING (club_short_name = public.my_club_shortname())
  WITH CHECK (club_short_name = public.my_club_shortname());

GRANT SELECT ON public.club_matchday_squad TO authenticated;
GRANT SELECT ON public.club_matchday_squad_player TO authenticated;
GRANT SELECT ON public.club_matchday_saved_formation TO authenticated;
GRANT SELECT ON public.club_matchday_squad_public TO authenticated;
GRANT SELECT ON public.club_matchday_pitch_layout_public TO authenticated;
GRANT SELECT ON public.club_matchday_saved_formation_public TO authenticated;
GRANT EXECUTE ON FUNCTION public.club_save_matchday_squad(jsonb, jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.club_save_matchday_formation(smallint, text, jsonb) TO authenticated;

NOTIFY pgrst, 'reload schema';
