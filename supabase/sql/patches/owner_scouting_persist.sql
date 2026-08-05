-- =============================================================================
-- Owner-scoped scouting (targets + tactic board follow the owner)
--
-- Run after club_scouting_targets.sql. Safe re-run.
--
-- - New tables keyed by owner_id (auth.users)
-- - Migrates existing club_* rows via Clubs.owner_id
-- - Rewrites scouting RPCs to use auth.uid() (club link optional for save)
-- - Season reset / club vacate / archive / change-club leave owner boards intact
--
-- UI: scouting_targets.js reads owner_scouting_* ; GPDB ☆ / Transfer Centre unchanged
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.owner_scouting_targets (
  owner_id uuid NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  player_id text NOT NULL,
  tier smallint NOT NULL DEFAULT 1,
  sort_order int NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (owner_id, player_id),
  CONSTRAINT owner_scouting_targets_tier_chk CHECK (tier BETWEEN 1 AND 4)
);

CREATE INDEX IF NOT EXISTS owner_scouting_targets_owner_tier_idx
  ON public.owner_scouting_targets (owner_id, tier, sort_order, created_at);

COMMENT ON TABLE public.owner_scouting_targets IS
  'Owner scouting shortlist (follows owner across club moves / archive / reset). Tier 1–4.';

CREATE TABLE IF NOT EXISTS public.owner_scouting_planner (
  owner_id uuid NOT NULL PRIMARY KEY REFERENCES auth.users (id) ON DELETE CASCADE,
  pitch_layout jsonb NOT NULL DEFAULT '{}'::jsonb,
  updated_at timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.owner_scouting_planner IS
  'Owner scouting tactic-board layout (follows owner).';

CREATE TABLE IF NOT EXISTS public.owner_scouting_planner_player (
  owner_id uuid NOT NULL
    REFERENCES public.owner_scouting_planner (owner_id) ON DELETE CASCADE,
  player_id text NOT NULL,
  slot_kind text NOT NULL,
  pitch_slot text,
  sort_order smallint NOT NULL DEFAULT 0,
  CONSTRAINT owner_scouting_planner_player_kind_chk
    CHECK (slot_kind IN ('pitch', 'bench')),
  CONSTRAINT owner_scouting_planner_player_pitch_chk
    CHECK (
      (slot_kind = 'pitch' AND pitch_slot IS NOT NULL)
      OR (slot_kind = 'bench' AND pitch_slot IS NULL)
    ),
  CONSTRAINT owner_scouting_planner_player_unique UNIQUE (owner_id, player_id),
  CONSTRAINT owner_scouting_planner_pitch_slot_unique UNIQUE (owner_id, pitch_slot)
);

ALTER TABLE public.owner_scouting_targets ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.owner_scouting_planner ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.owner_scouting_planner_player ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS owner_scouting_targets_select ON public.owner_scouting_targets;
CREATE POLICY owner_scouting_targets_select ON public.owner_scouting_targets
  FOR SELECT TO authenticated
  USING (owner_id = auth.uid());

DROP POLICY IF EXISTS owner_scouting_targets_write ON public.owner_scouting_targets;
CREATE POLICY owner_scouting_targets_write ON public.owner_scouting_targets
  FOR ALL TO authenticated
  USING (owner_id = auth.uid())
  WITH CHECK (owner_id = auth.uid());

DROP POLICY IF EXISTS owner_scouting_planner_select ON public.owner_scouting_planner;
CREATE POLICY owner_scouting_planner_select ON public.owner_scouting_planner
  FOR SELECT TO authenticated
  USING (owner_id = auth.uid());

DROP POLICY IF EXISTS owner_scouting_planner_write ON public.owner_scouting_planner;
CREATE POLICY owner_scouting_planner_write ON public.owner_scouting_planner
  FOR ALL TO authenticated
  USING (owner_id = auth.uid())
  WITH CHECK (owner_id = auth.uid());

DROP POLICY IF EXISTS owner_scouting_planner_player_select ON public.owner_scouting_planner_player;
CREATE POLICY owner_scouting_planner_player_select ON public.owner_scouting_planner_player
  FOR SELECT TO authenticated
  USING (owner_id = auth.uid());

DROP POLICY IF EXISTS owner_scouting_planner_player_write ON public.owner_scouting_planner_player;
CREATE POLICY owner_scouting_planner_player_write ON public.owner_scouting_planner_player
  FOR ALL TO authenticated
  USING (owner_id = auth.uid())
  WITH CHECK (owner_id = auth.uid());

GRANT SELECT, INSERT, UPDATE, DELETE ON public.owner_scouting_targets TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.owner_scouting_planner TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.owner_scouting_planner_player TO authenticated;

-- ---------------------------------------------------------------------------
-- One-time migrate from club-scoped tables (current club owners only)
-- ---------------------------------------------------------------------------

INSERT INTO public.owner_scouting_targets (owner_id, player_id, tier, sort_order, created_at)
SELECT c.owner_id, t.player_id, t.tier, t.sort_order, t.created_at
FROM public.club_scouting_targets t
JOIN public."Clubs" c ON c."ShortName" = t.club_id
WHERE c.owner_id IS NOT NULL
ON CONFLICT (owner_id, player_id) DO NOTHING;

INSERT INTO public.owner_scouting_planner (owner_id, pitch_layout, updated_at)
SELECT c.owner_id, p.pitch_layout, p.updated_at
FROM public.club_scouting_planner p
JOIN public."Clubs" c ON c."ShortName" = p.club_short_name
WHERE c.owner_id IS NOT NULL
ON CONFLICT (owner_id) DO NOTHING;

INSERT INTO public.owner_scouting_planner_player (
  owner_id, player_id, slot_kind, pitch_slot, sort_order
)
SELECT c.owner_id, pp.player_id, pp.slot_kind, pp.pitch_slot, pp.sort_order
FROM public.club_scouting_planner_player pp
JOIN public."Clubs" c ON c."ShortName" = pp.club_short_name
WHERE c.owner_id IS NOT NULL
  AND EXISTS (
    SELECT 1 FROM public.owner_scouting_planner osp WHERE osp.owner_id = c.owner_id
  )
ON CONFLICT (owner_id, player_id) DO NOTHING;

-- ---------------------------------------------------------------------------
-- RPCs — owner-scoped (no longer require a linked club)
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
  v_owner uuid := auth.uid();
  v_pid text;
  v_tier smallint;
  v_exists boolean;
BEGIN
  IF v_owner IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
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
    SELECT 1 FROM public.owner_scouting_targets t
    WHERE t.owner_id = v_owner AND t.player_id = v_pid
  ) INTO v_exists;

  IF v_exists THEN
    DELETE FROM public.owner_scouting_planner_player pp
    WHERE pp.owner_id = v_owner AND pp.player_id = v_pid;

    DELETE FROM public.owner_scouting_targets t
    WHERE t.owner_id = v_owner AND t.player_id = v_pid;

    RETURN jsonb_build_object('scouted', false, 'player_id', v_pid);
  END IF;

  INSERT INTO public.owner_scouting_targets (owner_id, player_id, tier)
  VALUES (v_owner, v_pid, v_tier);

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
  v_owner uuid := auth.uid();
  v_pid text;
  v_tier smallint;
BEGIN
  IF v_owner IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  v_pid := btrim(p_player_id);
  v_tier := p_tier::smallint;
  IF v_tier < 1 OR v_tier > 4 THEN
    RAISE EXCEPTION 'Tier must be 1–4';
  END IF;

  UPDATE public.owner_scouting_targets
  SET tier = v_tier
  WHERE owner_id = v_owner AND player_id = v_pid;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Player is not on your scouting list';
  END IF;

  RETURN jsonb_build_object('ok', true, 'player_id', v_pid, 'tier', v_tier);
END;
$function$;

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
  v_owner uuid := auth.uid();
  v_slot jsonb;
  v_pid text;
  v_kind text;
  v_pitch text;
  v_order smallint;
  v_pitch_count int := 0;
  v_bench_count int := 0;
  v_mirror_err text;
BEGIN
  IF v_owner IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
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
      SELECT 1 FROM public.owner_scouting_targets t
      WHERE t.owner_id = v_owner AND t.player_id = v_pid
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

  INSERT INTO public.owner_scouting_planner (owner_id, pitch_layout, updated_at)
  VALUES (
    v_owner,
    coalesce(p_pitch_layout, '{}'::jsonb),
    now()
  )
  ON CONFLICT (owner_id) DO UPDATE
  SET pitch_layout = coalesce(p_pitch_layout, owner_scouting_planner.pitch_layout),
      updated_at = now();

  DELETE FROM public.owner_scouting_planner_player
  WHERE owner_id = v_owner;

  FOR v_slot IN SELECT value FROM jsonb_array_elements(p_slots)
  LOOP
    v_pid := btrim(v_slot->>'player_id');
    v_kind := lower(btrim(v_slot->>'slot_kind'));
    v_pitch := nullif(btrim(v_slot->>'pitch_slot'), '');
    v_order := coalesce((v_slot->>'sort_order')::smallint, 0);

    IF v_pid IS NULL OR v_pid = '' THEN
      CONTINUE;
    END IF;

    INSERT INTO public.owner_scouting_planner_player (
      owner_id, player_id, slot_kind, pitch_slot, sort_order
    )
    VALUES (v_owner, v_pid, v_kind, v_pitch, v_order);
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true,
    'owner_id', v_owner,
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
