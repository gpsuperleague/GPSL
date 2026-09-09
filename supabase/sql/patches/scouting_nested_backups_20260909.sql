-- =============================================================================
-- Nested scouting backups under top targets (anchor_player_id)
--
-- Run after owner_scouting_persist.sql / owner_scouting_active_targets.sql.
-- Safe re-run.
--
-- - Backups / 3rd / 4th nest under a top target via anchor_player_id
-- - Placing a nested player on XI / subs / fillers promotes them to tier 1
--   (clears anchor); displaced prior first targets stay in the pool as top targets
-- =============================================================================

ALTER TABLE public.owner_scouting_targets
  ADD COLUMN IF NOT EXISTS anchor_player_id text;

COMMENT ON COLUMN public.owner_scouting_targets.anchor_player_id IS
  'When set, this row is a nested backup/3rd/4th under that top-target player_id.';

CREATE INDEX IF NOT EXISTS owner_scouting_targets_anchor_idx
  ON public.owner_scouting_targets (owner_id, anchor_player_id)
  WHERE anchor_player_id IS NOT NULL;

-- Promoting to tier 1 always clears any nest link
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
  SET
    tier = v_tier,
    anchor_player_id = CASE WHEN v_tier = 1 THEN NULL ELSE anchor_player_id END
  WHERE owner_id = v_owner AND player_id = v_pid;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Player is not on your scouting list';
  END IF;

  RETURN jsonb_build_object('ok', true, 'player_id', v_pid, 'tier', v_tier);
END;
$function$;

-- Nest a shortlist player under a top target as Backup / 3rd / 4th
CREATE OR REPLACE FUNCTION public.scouting_set_target_anchor(
  p_player_id text,
  p_anchor_player_id text,
  p_tier smallint DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_owner uuid := auth.uid();
  v_pid text;
  v_anchor text;
  v_tier smallint;
  v_used smallint[];
  v_free smallint;
BEGIN
  IF v_owner IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  v_pid := btrim(coalesce(p_player_id, ''));
  v_anchor := btrim(coalesce(p_anchor_player_id, ''));
  IF v_pid = '' OR v_anchor = '' THEN
    RAISE EXCEPTION 'Player and anchor are required';
  END IF;
  IF v_pid = v_anchor THEN
    RAISE EXCEPTION 'A player cannot be nested under themselves';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.owner_scouting_targets t
    WHERE t.owner_id = v_owner AND t.player_id = v_pid
  ) THEN
    RAISE EXCEPTION 'Player is not on your scouting list';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.owner_scouting_targets t
    WHERE t.owner_id = v_owner AND t.player_id = v_anchor
  ) THEN
    RAISE EXCEPTION 'Anchor player is not on your scouting list';
  END IF;

  -- Anchor must be a top-level target (not nested under someone else)
  IF EXISTS (
    SELECT 1 FROM public.owner_scouting_targets t
    WHERE t.owner_id = v_owner
      AND t.player_id = v_anchor
      AND t.anchor_player_id IS NOT NULL
  ) THEN
    RAISE EXCEPTION 'Cannot nest under a backup target — pick a top target';
  END IF;

  SELECT coalesce(array_agg(t.tier ORDER BY t.tier), ARRAY[]::smallint[])
  INTO v_used
  FROM public.owner_scouting_targets t
  WHERE t.owner_id = v_owner
    AND t.anchor_player_id = v_anchor
    AND t.player_id <> v_pid;

  IF p_tier IS NULL THEN
    v_free := NULL;
    FOREACH v_tier IN ARRAY ARRAY[2, 3, 4]::smallint[]
    LOOP
      IF NOT (v_tier = ANY (v_used)) THEN
        v_free := v_tier;
        EXIT;
      END IF;
    END LOOP;
    IF v_free IS NULL THEN
      RAISE EXCEPTION 'This top target already has Backup, 3rd and 4th choices';
    END IF;
    v_tier := v_free;
  ELSE
    v_tier := p_tier::smallint;
    IF v_tier < 2 OR v_tier > 4 THEN
      RAISE EXCEPTION 'Nested tier must be 2–4';
    END IF;
    IF v_tier = ANY (v_used) THEN
      RAISE EXCEPTION 'That nested slot is already filled under this top target';
    END IF;
  END IF;

  -- If this player had nested backups, unlink them (they become top targets)
  UPDATE public.owner_scouting_targets
  SET tier = 1, anchor_player_id = NULL
  WHERE owner_id = v_owner AND anchor_player_id = v_pid;

  -- Ensure the anchor is treated as a top target
  UPDATE public.owner_scouting_targets
  SET tier = 1, anchor_player_id = NULL
  WHERE owner_id = v_owner AND player_id = v_anchor;

  UPDATE public.owner_scouting_targets
  SET tier = v_tier, anchor_player_id = v_anchor
  WHERE owner_id = v_owner AND player_id = v_pid;

  RETURN jsonb_build_object(
    'ok', true,
    'player_id', v_pid,
    'anchor_player_id', v_anchor,
    'tier', v_tier
  );
END;
$function$;

-- Unlink nest (or promote after placing on the tactic board) → top target again
CREATE OR REPLACE FUNCTION public.scouting_promote_to_first_target(
  p_player_id text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_owner uuid := auth.uid();
  v_pid text;
BEGIN
  IF v_owner IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  v_pid := btrim(coalesce(p_player_id, ''));
  IF v_pid = '' THEN
    RAISE EXCEPTION 'Player is required';
  END IF;

  UPDATE public.owner_scouting_targets
  SET tier = 1, anchor_player_id = NULL
  WHERE owner_id = v_owner AND player_id = v_pid;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Player is not on your scouting list';
  END IF;

  RETURN jsonb_build_object('ok', true, 'player_id', v_pid, 'tier', 1);
END;
$function$;

REVOKE ALL ON FUNCTION public.scouting_set_target_anchor(text, text, smallint) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.scouting_promote_to_first_target(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.scouting_set_target_anchor(text, text, smallint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.scouting_promote_to_first_target(text) TO authenticated;
