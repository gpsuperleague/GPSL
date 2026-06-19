-- =============================================================================
-- GPDB scouting targets (per club) — tiered shortlists + tactic planner
-- Run once in Supabase SQL Editor. UI: scouting.html, GPDB ☆, Transfer Centre
-- Requires: my_club_shortname() from special_auctions.sql
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.club_scouting_targets (
  club_id text NOT NULL,
  player_id text NOT NULL,
  tier smallint NOT NULL DEFAULT 1,
  sort_order int NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (club_id, player_id),
  CONSTRAINT club_scouting_targets_tier_chk CHECK (tier BETWEEN 1 AND 4)
);

CREATE INDEX IF NOT EXISTS club_scouting_targets_club_tier_idx
  ON public.club_scouting_targets (club_id, tier, sort_order, created_at);

COMMENT ON TABLE public.club_scouting_targets IS
  'Owner scouting shortlist from GPDB. Tier 1=top, 2=backup, 3=third, 4=fourth.';

CREATE TABLE IF NOT EXISTS public.club_scouting_planner (
  club_short_name text NOT NULL PRIMARY KEY
    REFERENCES public."Clubs" ("ShortName") ON DELETE CASCADE,
  pitch_layout jsonb NOT NULL DEFAULT '{}'::jsonb,
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.club_scouting_planner_player (
  club_short_name text NOT NULL
    REFERENCES public.club_scouting_planner (club_short_name) ON DELETE CASCADE,
  player_id text NOT NULL,
  slot_kind text NOT NULL,
  pitch_slot text,
  sort_order smallint NOT NULL DEFAULT 0,
  CONSTRAINT club_scouting_planner_player_kind_chk
    CHECK (slot_kind IN ('pitch', 'bench')),
  CONSTRAINT club_scouting_planner_player_pitch_chk
    CHECK (
      (slot_kind = 'pitch' AND pitch_slot IS NOT NULL)
      OR (slot_kind = 'bench' AND pitch_slot IS NULL)
    ),
  CONSTRAINT club_scouting_planner_player_unique UNIQUE (club_short_name, player_id),
  CONSTRAINT club_scouting_planner_pitch_slot_unique UNIQUE (club_short_name, pitch_slot)
);

ALTER TABLE public.club_scouting_targets ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.club_scouting_planner ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.club_scouting_planner_player ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS club_scouting_targets_select ON public.club_scouting_targets;
CREATE POLICY club_scouting_targets_select ON public.club_scouting_targets
  FOR SELECT TO authenticated
  USING (club_id = public.my_club_shortname());

DROP POLICY IF EXISTS club_scouting_targets_write ON public.club_scouting_targets;
CREATE POLICY club_scouting_targets_write ON public.club_scouting_targets
  FOR ALL TO authenticated
  USING (club_id = public.my_club_shortname())
  WITH CHECK (club_id = public.my_club_shortname());

DROP POLICY IF EXISTS club_scouting_planner_select ON public.club_scouting_planner;
CREATE POLICY club_scouting_planner_select ON public.club_scouting_planner
  FOR SELECT TO authenticated
  USING (club_short_name = public.my_club_shortname());

DROP POLICY IF EXISTS club_scouting_planner_write ON public.club_scouting_planner;
CREATE POLICY club_scouting_planner_write ON public.club_scouting_planner
  FOR ALL TO authenticated
  USING (club_short_name = public.my_club_shortname())
  WITH CHECK (club_short_name = public.my_club_shortname());

DROP POLICY IF EXISTS club_scouting_planner_player_select ON public.club_scouting_planner_player;
CREATE POLICY club_scouting_planner_player_select ON public.club_scouting_planner_player
  FOR SELECT TO authenticated
  USING (club_short_name = public.my_club_shortname());

DROP POLICY IF EXISTS club_scouting_planner_player_write ON public.club_scouting_planner_player;
CREATE POLICY club_scouting_planner_player_write ON public.club_scouting_planner_player
  FOR ALL TO authenticated
  USING (club_short_name = public.my_club_shortname())
  WITH CHECK (club_short_name = public.my_club_shortname());

GRANT SELECT, INSERT, UPDATE, DELETE ON public.club_scouting_targets TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.club_scouting_planner TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.club_scouting_planner_player TO authenticated;

-- ---------------------------------------------------------------------------
-- Toggle / tier
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.scouting_toggle_target(
  p_player_id text,
  p_tier smallint DEFAULT 1
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text;
  v_pid text;
  v_tier smallint;
  v_exists boolean;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  v_club := public.my_club_shortname();
  IF v_club IS NULL OR btrim(v_club) = '' THEN
    RAISE EXCEPTION 'No club linked to this account';
  END IF;

  v_pid := btrim(p_player_id);
  IF v_pid IS NULL OR v_pid = '' THEN
    RAISE EXCEPTION 'Player id is required';
  END IF;

  v_tier := coalesce(p_tier, 1)::smallint;
  IF v_tier < 1 OR v_tier > 4 THEN
    RAISE EXCEPTION 'Tier must be 1–4';
  END IF;

  SELECT EXISTS (
    SELECT 1 FROM public.club_scouting_targets t
    WHERE t.club_id = v_club AND t.player_id = v_pid
  ) INTO v_exists;

  IF v_exists THEN
    DELETE FROM public.club_scouting_planner_player pp
    WHERE pp.club_short_name = v_club AND pp.player_id = v_pid;

    DELETE FROM public.club_scouting_targets t
    WHERE t.club_id = v_club AND t.player_id = v_pid;

    RETURN jsonb_build_object('scouted', false, 'player_id', v_pid);
  END IF;

  INSERT INTO public.club_scouting_targets (club_id, player_id, tier)
  VALUES (v_club, v_pid, v_tier);

  RETURN jsonb_build_object('scouted', true, 'player_id', v_pid, 'tier', v_tier);
END;
$function$;

CREATE OR REPLACE FUNCTION public.scouting_set_target_tier(
  p_player_id text,
  p_tier smallint
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text;
  v_pid text;
  v_tier smallint;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  v_club := public.my_club_shortname();
  IF v_club IS NULL OR btrim(v_club) = '' THEN
    RAISE EXCEPTION 'No club linked to this account';
  END IF;

  v_pid := btrim(p_player_id);
  v_tier := p_tier::smallint;
  IF v_tier < 1 OR v_tier > 4 THEN
    RAISE EXCEPTION 'Tier must be 1–4';
  END IF;

  UPDATE public.club_scouting_targets
  SET tier = v_tier
  WHERE club_id = v_club AND player_id = v_pid;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Player is not on your scouting list';
  END IF;

  RETURN jsonb_build_object('ok', true, 'player_id', v_pid, 'tier', v_tier);
END;
$function$;

-- ---------------------------------------------------------------------------
-- Save tactic planner (scouting targets only)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.club_save_scouting_planner(
  p_slots jsonb,
  p_pitch_layout jsonb DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text;
  v_slot jsonb;
  v_pid text;
  v_kind text;
  v_pitch text;
  v_order smallint;
  v_pitch_count int := 0;
  v_bench_count int := 0;
  v_mirror_err text;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  v_club := public.my_club_shortname();
  IF v_club IS NULL OR btrim(v_club) = '' THEN
    RAISE EXCEPTION 'No club linked to this account';
  END IF;

  IF p_pitch_layout IS NOT NULL THEN
    v_mirror_err := public.validate_pitch_layout_mirroring(p_pitch_layout);
    IF v_mirror_err IS NOT NULL THEN
      RAISE EXCEPTION '%', v_mirror_err;
    END IF;
  END IF;

  IF jsonb_typeof(p_slots) IS DISTINCT FROM 'array' THEN
    RAISE EXCEPTION 'p_slots must be a JSON array';
  END IF;

  FOR v_slot IN SELECT value FROM jsonb_array_elements(p_slots)
  LOOP
    v_pid := btrim(v_slot->>'player_id');
    v_kind := lower(btrim(v_slot->>'slot_kind'));
    v_pitch := nullif(btrim(v_slot->>'pitch_slot'), '');
    v_order := coalesce((v_slot->>'sort_order')::smallint, 0);

    IF v_pid IS NULL OR v_pid = '' THEN
      CONTINUE;
    END IF;

    IF NOT EXISTS (
      SELECT 1 FROM public.club_scouting_targets t
      WHERE t.club_id = v_club AND t.player_id = v_pid
    ) THEN
      RAISE EXCEPTION 'Player % is not on your scouting list', v_pid;
    END IF;

    IF v_kind = 'pitch' THEN
      v_pitch_count := v_pitch_count + 1;
      IF v_pitch IS NULL THEN
        RAISE EXCEPTION 'Pitch slot required for player %', v_pid;
      END IF;
    ELSIF v_kind = 'bench' THEN
      v_bench_count := v_bench_count + 1;
    ELSE
      RAISE EXCEPTION 'Invalid slot_kind %', v_kind;
    END IF;
  END LOOP;

  IF v_pitch_count > 11 THEN
    RAISE EXCEPTION 'Maximum 11 on pitch';
  END IF;
  IF v_bench_count > 12 THEN
    RAISE EXCEPTION 'Maximum 12 on bench';
  END IF;

  INSERT INTO public.club_scouting_planner (club_short_name, pitch_layout, updated_at)
  VALUES (
    v_club,
    coalesce(p_pitch_layout, '{}'::jsonb),
    now()
  )
  ON CONFLICT (club_short_name) DO UPDATE
  SET pitch_layout = coalesce(p_pitch_layout, club_scouting_planner.pitch_layout),
      updated_at = now();

  DELETE FROM public.club_scouting_planner_player
  WHERE club_short_name = v_club;

  FOR v_slot IN SELECT value FROM jsonb_array_elements(p_slots)
  LOOP
    v_pid := btrim(v_slot->>'player_id');
    v_kind := lower(btrim(v_slot->>'slot_kind'));
    v_pitch := nullif(btrim(v_slot->>'pitch_slot'), '');
    v_order := coalesce((v_slot->>'sort_order')::smallint, 0);

    IF v_pid IS NULL OR v_pid = '' THEN
      CONTINUE;
    END IF;

    INSERT INTO public.club_scouting_planner_player (
      club_short_name, player_id, slot_kind, pitch_slot, sort_order
    )
    VALUES (v_club, v_pid, v_kind, v_pitch, v_order);
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true,
    'club_short_name', v_club,
    'pitch_count', v_pitch_count,
    'bench_count', v_bench_count
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.scouting_toggle_target(text, smallint) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.scouting_set_target_tier(text, smallint) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.club_save_scouting_planner(jsonb, jsonb) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.scouting_toggle_target(text, smallint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.scouting_set_target_tier(text, smallint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.club_save_scouting_planner(jsonb, jsonb) TO authenticated;

NOTIFY pgrst, 'reload schema';
