-- =============================================================================
-- Owner scouting: up to 4 nameable tactic boards (shared shortlist)
--
-- - Shortlist (owner_scouting_targets) unchanged — one list per owner
-- - Tactic planner keyed by (owner_id, board_no 1–4) + editable name
-- - Existing layout becomes Board 1; Boards 2–4 created empty
--
-- Run once in Supabase SQL Editor after owner_scouting_persist.sql.
-- Safe re-run.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Schema: board_no + name (drop player FK BEFORE changing planner PK)
-- ---------------------------------------------------------------------------

ALTER TABLE public.owner_scouting_planner
  ADD COLUMN IF NOT EXISTS board_no smallint;

ALTER TABLE public.owner_scouting_planner
  ADD COLUMN IF NOT EXISTS name text;

UPDATE public.owner_scouting_planner
SET board_no = 1
WHERE board_no IS NULL;

UPDATE public.owner_scouting_planner
SET name = 'Board 1'
WHERE name IS NULL OR btrim(name) = '';

ALTER TABLE public.owner_scouting_planner
  ALTER COLUMN board_no SET DEFAULT 1;

ALTER TABLE public.owner_scouting_planner
  ALTER COLUMN board_no SET NOT NULL;

ALTER TABLE public.owner_scouting_planner
  ALTER COLUMN name SET DEFAULT 'Board 1';

ALTER TABLE public.owner_scouting_planner
  ALTER COLUMN name SET NOT NULL;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'owner_scouting_planner_board_no_chk'
      AND conrelid = 'public.owner_scouting_planner'::regclass
  ) THEN
    ALTER TABLE public.owner_scouting_planner
      ADD CONSTRAINT owner_scouting_planner_board_no_chk
      CHECK (board_no BETWEEN 1 AND 4);
  END IF;
END $$;

ALTER TABLE public.owner_scouting_planner_player
  ADD COLUMN IF NOT EXISTS board_no smallint;

UPDATE public.owner_scouting_planner_player
SET board_no = 1
WHERE board_no IS NULL;

ALTER TABLE public.owner_scouting_planner_player
  ALTER COLUMN board_no SET DEFAULT 1;

ALTER TABLE public.owner_scouting_planner_player
  ALTER COLUMN board_no SET NOT NULL;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'owner_scouting_planner_player_board_no_chk'
      AND conrelid = 'public.owner_scouting_planner_player'::regclass
  ) THEN
    ALTER TABLE public.owner_scouting_planner_player
      ADD CONSTRAINT owner_scouting_planner_player_board_no_chk
      CHECK (board_no BETWEEN 1 AND 4);
  END IF;
END $$;

-- Must drop dependent FKs before changing planner primary key
ALTER TABLE public.owner_scouting_planner_player
  DROP CONSTRAINT IF EXISTS owner_scouting_planner_player_owner_id_fkey;

ALTER TABLE public.owner_scouting_planner_player
  DROP CONSTRAINT IF EXISTS owner_scouting_planner_player_board_fkey;

DO $$
DECLARE
  r record;
BEGIN
  FOR r IN
    SELECT c.conname
    FROM pg_constraint c
    WHERE c.conrelid = 'public.owner_scouting_planner_player'::regclass
      AND c.contype = 'f'
      AND c.confrelid = 'public.owner_scouting_planner'::regclass
  LOOP
    EXECUTE format(
      'ALTER TABLE public.owner_scouting_planner_player DROP CONSTRAINT %I',
      r.conname
    );
  END LOOP;
END $$;

ALTER TABLE public.owner_scouting_planner_player
  DROP CONSTRAINT IF EXISTS owner_scouting_planner_player_unique;

ALTER TABLE public.owner_scouting_planner_player
  DROP CONSTRAINT IF EXISTS owner_scouting_planner_pitch_slot_unique;

-- Drop single-column (owner_id) PK only — keep composite PK on re-run
DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM pg_constraint c
    WHERE c.conname = 'owner_scouting_planner_pkey'
      AND c.conrelid = 'public.owner_scouting_planner'::regclass
      AND c.contype = 'p'
      AND (
        SELECT count(*) FROM unnest(c.conkey) AS k
      ) = 1
      AND EXISTS (
        SELECT 1
        FROM pg_attribute a
        WHERE a.attrelid = c.conrelid
          AND a.attnum = c.conkey[1]
          AND a.attname = 'owner_id'
      )
  ) THEN
    ALTER TABLE public.owner_scouting_planner
      DROP CONSTRAINT owner_scouting_planner_pkey;
  END IF;
END $$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'owner_scouting_planner_pkey'
      AND conrelid = 'public.owner_scouting_planner'::regclass
  ) THEN
    ALTER TABLE public.owner_scouting_planner
      ADD CONSTRAINT owner_scouting_planner_pkey
      PRIMARY KEY (owner_id, board_no);
  END IF;
END $$;

COMMENT ON TABLE public.owner_scouting_planner IS
  'Owner scouting tactic boards (up to 4 named boards per owner; shared shortlist).';

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'owner_scouting_planner_player_unique'
      AND conrelid = 'public.owner_scouting_planner_player'::regclass
  ) THEN
    ALTER TABLE public.owner_scouting_planner_player
      ADD CONSTRAINT owner_scouting_planner_player_unique
      UNIQUE (owner_id, board_no, player_id);
  END IF;
END $$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'owner_scouting_planner_pitch_slot_unique'
      AND conrelid = 'public.owner_scouting_planner_player'::regclass
  ) THEN
    ALTER TABLE public.owner_scouting_planner_player
      ADD CONSTRAINT owner_scouting_planner_pitch_slot_unique
      UNIQUE (owner_id, board_no, pitch_slot);
  END IF;
END $$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'owner_scouting_planner_player_board_fkey'
      AND conrelid = 'public.owner_scouting_planner_player'::regclass
  ) THEN
    ALTER TABLE public.owner_scouting_planner_player
      ADD CONSTRAINT owner_scouting_planner_player_board_fkey
      FOREIGN KEY (owner_id, board_no)
      REFERENCES public.owner_scouting_planner (owner_id, board_no)
      ON DELETE CASCADE;
  END IF;
END $$;

CREATE INDEX IF NOT EXISTS owner_scouting_planner_player_board_idx
  ON public.owner_scouting_planner_player (owner_id, board_no, slot_kind, sort_order);

-- ---------------------------------------------------------------------------
-- Ensure boards 1–4 exist for every owner who already has any planner row
-- ---------------------------------------------------------------------------

INSERT INTO public.owner_scouting_planner (owner_id, board_no, name, pitch_layout, updated_at)
SELECT o.owner_id, n.board_no, 'Board ' || n.board_no::text, '{}'::jsonb, now()
FROM (SELECT DISTINCT owner_id FROM public.owner_scouting_planner) o
CROSS JOIN (VALUES (1), (2), (3), (4)) AS n(board_no)
ON CONFLICT (owner_id, board_no) DO NOTHING;

-- ---------------------------------------------------------------------------
-- Helpers / RPCs
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.scouting_ensure_boards()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_owner uuid := auth.uid();
  v_n smallint;
BEGIN
  IF v_owner IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  FOR v_n IN 1..4 LOOP
    INSERT INTO public.owner_scouting_planner (
      owner_id, board_no, name, pitch_layout, updated_at
    )
    VALUES (
      v_owner,
      v_n,
      'Board ' || v_n::text,
      '{}'::jsonb,
      now()
    )
    ON CONFLICT (owner_id, board_no) DO NOTHING;
  END LOOP;

  RETURN coalesce(
    (
      SELECT jsonb_agg(
        jsonb_build_object(
          'board_no', p.board_no,
          'name', p.name,
          'updated_at', p.updated_at
        )
        ORDER BY p.board_no
      )
      FROM public.owner_scouting_planner p
      WHERE p.owner_id = v_owner
    ),
    '[]'::jsonb
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.scouting_rename_board(
  p_board_no smallint,
  p_name text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_owner uuid := auth.uid();
  v_name text;
BEGIN
  IF v_owner IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  IF p_board_no IS NULL OR p_board_no < 1 OR p_board_no > 4 THEN
    RAISE EXCEPTION 'Board must be 1–4';
  END IF;

  v_name := left(btrim(coalesce(p_name, '')), 40);
  IF v_name = '' THEN
    RAISE EXCEPTION 'Board name is required';
  END IF;

  PERFORM public.scouting_ensure_boards();

  UPDATE public.owner_scouting_planner
  SET name = v_name,
      updated_at = now()
  WHERE owner_id = v_owner
    AND board_no = p_board_no;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Board not found';
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'board_no', p_board_no,
    'name', v_name
  );
END;
$function$;

-- Replace 2-arg save with board-aware version (defaults to Board 1)
DROP FUNCTION IF EXISTS public.club_save_scouting_planner(jsonb, jsonb);

CREATE OR REPLACE FUNCTION public.club_save_scouting_planner(
  p_slots jsonb,
  p_pitch_layout jsonb DEFAULT NULL,
  p_board_no smallint DEFAULT 1
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_owner uuid := auth.uid();
  v_board smallint := coalesce(p_board_no, 1)::smallint;
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

  IF v_board < 1 OR v_board > 4 THEN
    RAISE EXCEPTION 'Board must be 1–4';
  END IF;

  PERFORM public.scouting_ensure_boards();

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
  IF v_bench_count > 17 THEN
    RAISE EXCEPTION 'Maximum 17 on bench';
  END IF;

  INSERT INTO public.owner_scouting_planner (
    owner_id, board_no, name, pitch_layout, updated_at
  )
  VALUES (
    v_owner,
    v_board,
    'Board ' || v_board::text,
    coalesce(p_pitch_layout, '{}'::jsonb),
    now()
  )
  ON CONFLICT (owner_id, board_no) DO UPDATE
  SET pitch_layout = coalesce(
        p_pitch_layout,
        owner_scouting_planner.pitch_layout
      ),
      updated_at = now();

  DELETE FROM public.owner_scouting_planner_player
  WHERE owner_id = v_owner
    AND board_no = v_board;

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
      owner_id, board_no, player_id, slot_kind, pitch_slot, sort_order
    )
    VALUES (v_owner, v_board, v_pid, v_kind, v_pitch, v_order);
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true,
    'owner_id', v_owner,
    'board_no', v_board,
    'pitch_count', v_pitch_count,
    'bench_count', v_bench_count
  );
END;
$function$;

-- Unstar still removes the player from every tactic board
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

REVOKE ALL ON FUNCTION public.scouting_ensure_boards() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.scouting_rename_board(smallint, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.club_save_scouting_planner(jsonb, jsonb, smallint) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.scouting_toggle_target(text, smallint) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.scouting_ensure_boards() TO authenticated;
GRANT EXECUTE ON FUNCTION public.scouting_rename_board(smallint, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.club_save_scouting_planner(jsonb, jsonb, smallint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.scouting_toggle_target(text, smallint) TO authenticated;

NOTIFY pgrst, 'reload schema';
